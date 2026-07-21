// 原生 / 预构建 Windows DLL 的发现与打包校验。
//
// 某些插件依赖预编译的 Windows DLL（如 opencv_world490.dll），并在其
// windows/CMakeLists.txt 里以 Windows 绝对路径（C:/...）或「另行预编译」的产物
// 路径引用，且常被 `if(EXISTS ...)` 包裹——Linux 交叉构建时文件不存在就被静默
// 跳过，最终只在 Windows 上运行时才暴露为 `DynamicLibrary.open` 失败。
//
// 本模块负责：
//   1. [referencedDllPaths]：从 CMake 文本里提取被引用的预编译 DLL 字面路径；
//   2. [NativeDllScanner.copyPrebuiltDlls]：在指定根目录下搜索 DLL 拷入产物；
//   3. [NativeDllScanner.verifyPluginNativeDlls]：编译期校验声明要打包却缺失的
//      原生 DLL，显著告警而非留到运行时。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';
import '../project.dart';

/// 搜索预构建 DLL 时的默认递归深度上限。
const int kDefaultDllSearchDepth = 5;

/// 搜索预构建 DLL 时始终跳过的目录名（构建产物 / 缓存 / 伪文件系统）。
const Set<String> kDllSearchSkipDirs = {
  'build',
  '.dart_tool',
  '.pub-cache',
  '.git',
  '.flutter_build',
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
  /// 已存在于 [outDir] 的 DLL（按小写基名去重）会被跳过。搜索深度受 [maxDepth]
  /// 限制，并跳过 [kDllSearchSkipDirs] 中的构建 / 缓存目录。
  Future<void> copyPrebuiltDlls({
    required String outDir,
    required String searchRoot,
    int maxDepth = kDefaultDllSearchDepth,
  }) async {
    final existing = _presentDllBasenames(outDir);

    final found = <File>[];
    _findDlls(Directory(searchRoot), found, 0, maxDepth);

    for (final dll in found) {
      final name = p.basename(dll.path);
      if (existing.contains(name.toLowerCase())) continue;
      await dll.copy(p.join(outDir, name));
      _log.info('  预构建 DLL: $name');
      existing.add(name.toLowerCase());
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
  Future<void> copyResolvedReferencedDlls({
    required String outDir,
    required Iterable<WindowsPluginRef> plugins,
  }) async {
    final existing = _presentDllBasenames(outDir);
    for (final file in resolveReferencedDllFiles(plugins)) {
      final name = p.basename(file.path);
      if (existing.contains(name.toLowerCase())) continue;
      await file.copy(p.join(outDir, name));
      _log.info('  预构建 DLL(按声明解析): $name');
      existing.add(name.toLowerCase());
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
