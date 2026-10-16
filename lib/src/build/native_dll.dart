// 原生 / 预构建 Windows DLL 的发现与打包校验。
//
// 某些插件依赖预编译的 Windows DLL（如 opencv_world490.dll），并在其
// windows/CMakeLists.txt 里以 Windows 绝对路径（C:/...）或「另行预编译」的产物
// 路径引用，且常被 `if(EXISTS ...)` 包裹——Linux 交叉构建时文件不存在就被静默
// 跳过，最终只在 Windows 上运行时才暴露为 `DynamicLibrary.open` 失败。
//
// 本模块负责：
//   1. [referencedDllPaths]：从 CMake 文本里提取被引用的预编译 DLL 字面路径；
//   2. [copyDllIfChanged]：内容判等拷贝原语（产物里已有同基名 DLL 且内容
//      一致才跳过，内容不同一律覆盖）；
//   3. [NativeDllScanner.copyPrebuiltDlls]：在指定根目录下搜索 DLL 拷入产物；
//   4. [NativeDllScanner.verifyPluginNativeDlls]：编译期校验声明要打包却缺失的
//      原生 DLL，显著告警而非留到运行时。
//
// 【为什么必须"内容不同则覆盖"而非"同基名即跳过"】产物目录是跨构建复用的
// 暂存目录，插件源码/依赖升级后重编译出的新 DLL 会被旧的"跳过"逻辑留在
// 产物里，形成 Dart 快照新、原生 DLL 旧的混搭（生产事故：pp_ocr 0.5.x 的
// Dart 绑定查找 `pp_ocr_options_size`，而产物里还是 0.4.x 的旧 DLL，
// 运行时报 "Failed to lookup symbol ... error 127"）。判等依据是**内容**
// （size 不同必不同；size 相同再比 sha256，防重编译后恰好同大小的假阴性），
// 不用 mtime——`File.copy` 不保留源 mtime，跨构建的 mtime 比较必然失配。

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../logger.dart';
import '../project.dart';

/// 搜索预构建 DLL 时的默认递归深度上限。
const int kDefaultDllSearchDepth = 5;

/// 单个 DLL 的拷贝动作分类。
enum DllCopyOutcome {
  /// 目标原本不存在，新拷入。
  fresh,

  /// 目标已存在但内容不同，已覆盖为新内容。
  updated,

  /// 目标已存在且内容完全一致，无需动作。
  identical,
}

/// 把 [source] 拷到 [dest]——仅当内容不同时才真正拷贝。
///
/// 判等依据是**内容**：
///   - 目标不存在 → 拷入（[DllCopyOutcome.fresh]）；
///   - size 不同 → 必然内容不同，覆盖（[DllCopyOutcome.updated]）；
///   - size 相同 → 比 sha256（重编译的 DLL 可能恰好同大小，不能只比
///     size），一致跳过（[DllCopyOutcome.identical]），不一致覆盖。
///
/// 不比较 mtime：`File.copy` 不保留源 mtime，目标 mtime 恒为拷贝时刻，
/// 跨构建比较必然失配、退化成每次全量重拷。
///
/// 产物最大单文件几十 MB（如 opencv 世界库），整体读入算哈希可接受；
/// 仅对"目标已存在且 size 相同"的文件碰哈希，其余路径零哈希开销。
Future<DllCopyOutcome> copyDllIfChanged(File source, File dest) async {
  final existing = File(dest.path);
  if (existing.existsSync()) {
    if (source.statSync().size == existing.statSync().size &&
        _sha256Of(source) == _sha256Of(existing)) {
      return DllCopyOutcome.identical;
    }
    Directory(p.dirname(dest.path)).createSync(recursive: true);
    await source.copy(dest.path);
    return DllCopyOutcome.updated;
  }
  Directory(p.dirname(dest.path)).createSync(recursive: true);
  await source.copy(dest.path);
  return DllCopyOutcome.fresh;
}

String _sha256Of(File f) => sha256.convert(f.readAsBytesSync()).toString();

/// 搜索预构建 DLL 时始终跳过的目录名（构建产物 / 缓存 / 伪文件系统）。
const Set<String> kDllSearchSkipDirs = {
  'build',
  '.dart_tool',
  '.pub-cache',
  '.git',
  '.flutter_build',
  '.cache', // OpenCV 等的下载缓存（如 .cache/ffmpeg/<md5>-<name>.dll），非预构建产物。
  'snap',
  'proc',
  'sys',
  'dev',
};

/// 从 CMake 文件内容里提取被引用的 `.dll` 字面路径。
///
/// 会剔除 `#` 行注释，并忽略 `$<TARGET_FILE:...>` 等由构建自动产生的目标（它们
/// 不是需要预先存在的预编译 DLL）。纯函数，便于单测。
List<String> referencedDllPaths(String cmakeContent) {
  final out = <String>[];
  for (final rawLine in cmakeContent.split('\n')) {
    final hash = rawLine.indexOf('#'); // 去掉 CMake 行注释（# 到行尾）。
    final line = hash >= 0 ? rawLine.substring(0, hash) : rawLine;
    for (final m in RegExp(r'''[^\s"'()]+\.dll''', caseSensitive: false)
        .allMatches(line)) {
      final ref = m.group(0)!;
      if (ref.contains(r'$<')) continue; // 生成器表达式目标，非预编译 DLL。
      out.add(ref);
    }
  }
  return out;
}

/// 判断 CMake 引用的路径是否是 Windows 绝对路径（盘符开头，如 `C:/...`）。
bool looksLikeWindowsAbsPath(String ref) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(ref);

/// 汇总 [plugins] 的 CMakeLists 里声明的预编译 DLL 基名（小写）。
///
/// 用于给广度扫描（[NativeDllScanner.copyPrebuiltDlls]）提供「白名单」：
/// 只拷贝被某个插件声明过的 DLL，避免把工作区里无关的预编译 DLL
/// （如仅为 MSVC 构建准备的 OpenCV 世界库）盲目塞进产物。
///
/// 文件名本身含未解析 CMake 变量的引用（如动态拼接的
/// `opencv_world${VER}.dll`）不是具体 DLL 名，跳过；目录部分含变量
/// （如 `${CMAKE_CURRENT_SOURCE_DIR}/../x/y.dll`）不影响基名，照常统计。
Set<String> declaredDllBasenames(Iterable<WindowsPluginRef> plugins) {
  final out = <String>{};
  for (final plugin in plugins.where((pl) => pl.hasNativeCode)) {
    final cmake = File(p.join(plugin.windowsCMakeDir, 'CMakeLists.txt'));
    if (!cmake.existsSync()) continue;
    for (final ref in referencedDllPaths(cmake.readAsStringSync())) {
      final base = p.basename(ref.replaceAll(r'\', '/'));
      if (base.contains(r'${')) continue; // 文件名非字面量，无法对应具体 DLL。
      out.add(base.toLowerCase());
    }
  }
  return out;
}

/// 把插件 CMakeLists 里的一条 DLL 引用 [rawRef] 解析为绝对路径，基准目录为
/// [cmakeDir]（插件 `windows/`）。无法解析时返回 null：
///   - 仍含未展开的 CMake 变量（除 CMAKE_CURRENT_SOURCE_DIR / LIST_DIR）；
///   - Windows 绝对路径（`C:/...`，交叉环境不存在）。
///
/// 顶层纯函数，便于单测。
String? resolveReferencedDll(String rawRef, String cmakeDir) {
  var ref = rawRef.replaceAll(r'\', '/');
  // 仅展开以「当前 CMake 目录」为基准的变量；二者都指向 CMakeLists 所在目录。
  ref = ref
      .replaceAll(r'${CMAKE_CURRENT_SOURCE_DIR}', cmakeDir)
      .replaceAll(r'${CMAKE_CURRENT_LIST_DIR}', cmakeDir);
  if (ref.contains(r'${')) return null; // 仍有未解析变量。
  if (looksLikeWindowsAbsPath(ref)) return null; // C:/... 交叉环境不存在。
  final abs = p.isAbsolute(ref) ? ref : p.join(cmakeDir, ref);
  return p.normalize(abs);
}

/// 预构建 DLL 的发现与校验器。
class NativeDllScanner {
  NativeDllScanner({Logger? logger}) : _log = logger ?? Logger.instance;

  final Logger _log;

  /// 在 [searchRoot] 下递归搜索预构建的 Windows DLL 并拷到 [outDir]。
  ///
  /// 拷贝走 [copyDllIfChanged] 内容判等：目标缺失拷入、内容不同覆盖、
  /// 内容一致跳过。[handled] 是本轮来源声明集（小写基名）——同基名的多个
  /// 来源**首个命中者生效**，避免后面搜索到的同名旧文件反过来覆盖先拷入
  /// 的新文件。搜索深度受 [maxDepth] 限制，并跳过 [kDllSearchSkipDirs]
  /// 中的构建 / 缓存目录。
  ///
  /// [onlyBasenames] 非空时，只考虑基名在集合内的 DLL（小写比较）——广度
  /// 扫描是「插件声明了但精确解析失败」的兜底发现机制，不应打包工作区里
  /// 未被任何插件声明的 DLL。传 null 保持旧行为（全部考虑）。
  Future<void> copyPrebuiltDlls({
    required String outDir,
    required String searchRoot,
    int maxDepth = kDefaultDllSearchDepth,
    Set<String>? onlyBasenames,
  }) async {
    // 本轮来源声明集（小写基名）。只对**来源**去重：同一基名的后续来源
    // 一律跳过——首个命中者已与 outDir 现状做过内容判等（拷入 / 覆盖 /
    // 确认一致），无需再看。不预填 outDir 已有基名，否则首个来源会被
    // Set.add 的 false 误跳过，永远轮不到与旧内容比较。
    final handled = <String>{};

    final found = <File>[];
    _findDlls(Directory(searchRoot), found, 0, maxDepth);

    for (final dll in found) {
      final name = p.basename(dll.path);
      final lower = name.toLowerCase();
      if (!handled.add(lower)) continue;
      if (onlyBasenames != null && !onlyBasenames.contains(lower)) {
        continue; // 未被任何插件声明，不盲拷。
      }
      final outcome = await copyDllIfChanged(dll, File(p.join(outDir, name)));
      switch (outcome) {
        case DllCopyOutcome.fresh:
          _log.info('  预构建 DLL: $name');
        case DllCopyOutcome.updated:
          _log.info('  预构建 DLL(内容已变，覆盖旧版): $name');
        case DllCopyOutcome.identical:
          break; // 已存在且一致，静默。
      }
    }
  }

  /// 按插件 `windows/CMakeLists.txt` 里声明的引用**精确解析**并拷入实际存在的
  /// 预编译 DLL。
  ///
  /// 相比广度扫描，这里直接命中插件声明的目标文件，且能覆盖位于 `.pub-cache`
  /// 内的 path/hosted 插件——广度扫描会跳过 `.pub-cache`。仅解析以
  /// `${CMAKE_CURRENT_SOURCE_DIR}` / `${CMAKE_CURRENT_LIST_DIR}` 为基准或纯相对
  /// 的引用；含其它 CMake 变量或 Windows 绝对路径（`C:/...`）的引用无法在交叉
  /// 环境解析，交由广度扫描 / 缺失校验处理。
  ///
  /// 拷贝走 [copyDllIfChanged] 内容判等（缺失拷入 / 不同覆盖 / 一致跳过），
  /// 同基名首个来源生效。
  Future<void> copyResolvedReferencedDlls({
    required String outDir,
    required Iterable<WindowsPluginRef> plugins,
  }) async {
    final handled = <String>{}; // 来源声明集：同基名首个来源生效。
    for (final file in resolveReferencedDllFiles(plugins)) {
      final name = p.basename(file.path);
      if (!handled.add(name.toLowerCase())) continue;
      final outcome = await copyDllIfChanged(file, File(p.join(outDir, name)));
      switch (outcome) {
        case DllCopyOutcome.fresh:
          _log.info('  预构建 DLL(按声明解析): $name');
        case DllCopyOutcome.updated:
          _log.info('  预构建 DLL(按声明解析，内容已变，覆盖旧版): $name');
        case DllCopyOutcome.identical:
          break;
      }
    }
  }

  /// 解析 [plugins] 的 CMakeLists 里可解析的相对 DLL 引用，返回实际存在的文件。
  /// 纯函数式（只读文件系统探测），便于单测。
  List<File> resolveReferencedDllFiles(Iterable<WindowsPluginRef> plugins) {
    final out = <File>[];
    for (final plugin in plugins.where((pl) => pl.hasNativeCode)) {
      final cmakeDir = plugin.windowsCMakeDir;
      final cmake = File(p.join(cmakeDir, 'CMakeLists.txt'));
      if (!cmake.existsSync()) continue;
      for (final rawRef in referencedDllPaths(cmake.readAsStringSync())) {
        final resolved = resolveReferencedDll(rawRef, cmakeDir);
        if (resolved == null) continue;
        final f = File(resolved);
        if (f.existsSync()) out.add(f);
      }
    }
    return out;
  }

  /// 校验插件在 `windows/CMakeLists.txt` 里声明要打包的预编译 DLL 是否已进
  /// [outDir]。缺失项以告警形式集中报出（含缺失原因），避免留到运行时。
  void verifyPluginNativeDlls({
    required String outDir,
    required Iterable<WindowsPluginRef> plugins,
  }) {
    final present = _presentDllBasenames(outDir);

    // 基名 -> 原始引用（保留原始路径用于说明缺失原因）。
    final missing = <String, String>{};
    for (final plugin in plugins.where((pl) => pl.hasNativeCode)) {
      final cmake = File(p.join(plugin.windowsCMakeDir, 'CMakeLists.txt'));
      if (!cmake.existsSync()) continue;
      for (final ref in referencedDllPaths(cmake.readAsStringSync())) {
        final base = p.basename(ref.replaceAll(r'\', '/'));
        // 文件名含未解析 CMake 变量（动态拼接名）时不是具体 DLL，无法校验。
        if (base.contains(r'${')) continue;
        if (present.contains(base.toLowerCase())) continue;
        missing.putIfAbsent(base, () => ref);
      }
    }
    if (missing.isEmpty) return;

    _log.warn('原生 DLL 缺失：以下 DLL 被插件声明要随产物一起打包，但本次交叉');
    _log.warn('构建的产物目录里没有——应用在 Windows 上运行时会因加载不到它们而');
    _log.warn('失败（如 "Bad state: ... is not ready"）：');
    missing.forEach((base, ref) {
      final reason = looksLikeWindowsAbsPath(ref)
          ? '硬编码 Windows 路径，交叉环境不存在'
          : 'Windows 预编译产物路径，未在 Linux 侧生成';
      _log.warn('  ✗ $base（$reason：$ref）');
    });
    _log.hint('解决：在 Linux 侧交叉编译出这些 DLL 放入产物目录，或从 Windows'
        ' 拷入同目录；若确非必需可忽略此告警。');
  }

  /// 收集 [outDir] 顶层已有的 DLL 基名（小写，用于去重 / 判断是否已打包）。
  Set<String> _presentDllBasenames(String outDir) {
    final present = <String>{};
    final dir = Directory(outDir);
    if (!dir.existsSync()) return present;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.dll')) {
        present.add(p.basename(entity.path).toLowerCase());
      }
    }
    return present;
  }

  /// 递归搜索 .dll 文件，限制深度 [maxDepth]，跳过构建 / 缓存目录。
  void _findDlls(Directory dir, List<File> results, int depth, int maxDepth) {
    if (depth > maxDepth) return;
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is File) {
        if (entity.path.endsWith('.dll')) results.add(entity);
      } else if (entity is Directory) {
        if (kDllSearchSkipDirs.contains(p.basename(entity.path))) continue;
        _findDlls(entity, results, depth + 1, maxDepth);
      }
    }
  }
}
