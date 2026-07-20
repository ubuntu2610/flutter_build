// MSVC → GCC/Clang 编译标志翻译器。
//
// Flutter 的 Windows 脚手架（windows/CMakeLists.txt、runner/CMakeLists.txt）
// 硬编码了大量 MSVC-only 写法（/W4 /WX /EHsc /std:c++17、`_HAS_EXCEPTIONS=0`、
// `"xxx.lib"` 等）。在 Linux 上用 LLVM-MinGW 交叉编译时 clang++ 不认识这些
// 写法，CMake 会直接报错。本模块在“暂存源码”阶段对 CMakeLists.txt 做纯文本
// 改写，把 MSVC 写法翻译成 GCC/Clang 等价物。
//
// 改写只作用于暂存副本，不触碰用户源码树与 pub-cache（符合项目规则：只在
// flutter_build 侧解决兼容性）。设计要点（合并自早期 lib2 实验的优点）：
//
//   1. 声明式标志映射表 `_flagMap`，覆盖 Flutter 脚手架及常见插件用到的
//      MSVC 标志；未识别的 `/X` 标志不会被静默丢弃，而是记录为 warning，
//      避免“悄悄漏译”导致的隐性行为差异。
//   2. `APPLY_STANDARD_SETTINGS` 改写为 `if(MSVC)...else()...endif()` 双分支：
//      MinGW/Clang 侧沿用既有的 `-Wall -Werror`（不改变交叉编译结果），同时
//      **保留 MSVC 分支**，使改写后的 CMake 在真实 Windows + MSVC 上仍可原样
//      构建（符合“保持 MSVC 可原样构建”规则）。
//   3. 中和无条件定义的 `_HAS_EXCEPTIONS=0`（该宏会破坏 MinGW 的
//      libstdc++/libc++ 头），改写为仅在 MSVC 下生效的生成器表达式。
//
// 注意：这是纯文本转换，不涉及真实 CMake 调用，测试也只验证文本结果。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';

/// 遍历目录树下所有 `CMakeLists.txt`，把 MSVC 专属写法翻译为 GCC/Clang 等价物。
class MsvcFlagTranslator {
  /// [logger] 为空时回退到 [Logger.instance]，因此默认构造仍可为 `const`
  /// （测试与无日志场景直接 `const MsvcFlagTranslator()`）。
  const MsvcFlagTranslator({Logger? logger}) : _logger = logger;

  final Logger? _logger;

  Logger get _log => _logger ?? Logger.instance;

  /// 对 [rootPath] 下每个 `CMakeLists.txt` 应用翻译。
  ///
  /// 非 CMake 文件（README、.dart 等）会被忽略。幂等：仅在内容变化时回写。
  Future<void> transformTree(String rootPath) async {
    final dir = Directory(rootPath);
    if (!dir.existsSync()) return;

    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (p.basename(entity.path) != 'CMakeLists.txt') continue;

      final original = entity.readAsStringSync();
      final warnings = <String>[];
      final translated = transformContent(
        original,
        warnings: warnings,
        sourcePath: entity.path,
      );
      if (translated != original) {
        entity.writeAsStringSync(translated);
        _log.debug('MSVC 翻译：已改写 ${p.relative(entity.path, from: rootPath)}');
      }
      for (final w in warnings) {
        _log.warn('MSVC 翻译：$w');
      }
    }
  }

  /// 转换单个 CMake 文件内容。纯函数，便于测试复用。
  ///
  /// 若传入 [warnings]，未识别的 `/X` 风格标志会被追加进去（不影响转换结果，
  /// 仅用于日志提示）。[sourcePath] 仅用于告警信息里标注来源文件。
  ///
  /// 执行顺序有意为之：
  ///   1. 先中和无条件的 `_HAS_EXCEPTIONS=0`（此时尚未注入我们自己的
  ///      APPLY_STANDARD_SETTINGS，故不会误伤注入块里 MSVC 分支的该宏）。
  ///   2. 再替换 APPLY_STANDARD_SETTINGS（注入块用保护标记包裹）。
  ///   3. 然后翻译其余标志（保护标记内的 MSVC 分支会被跳过，不被翻译掉）。
  ///   4. 最后改写 `.lib` 库引用。
  String transformContent(
    String content, {
    List<String>? warnings,
    String? sourcePath,
  }) {
    var result = content;
    result = _neutralizeHasExceptions(result);
    result = _transformApplyStandardSettings(result);
    result =
        _translateFlags(result, warnings: warnings, sourcePath: sourcePath);
    result = _translateLibRefs(result);
    return result;
  }

  // 保护标记：夹在其间的行不参与标志翻译 / 未知标志告警。用于包裹我们注入的
  // APPLY_STANDARD_SETTINGS 双分支——其 MSVC 分支需保留 /W4 /WX 等 MSVC 标志，
  // 不能被翻译掉。标记本身是合法的 CMake 注释，保留在产物中亦无害且自解释。
  static const String _guardBegin =
      '# >>> flutter_build: APPLY_STANDARD_SETTINGS (no-translate)';
  static const String _guardEnd = '# <<< flutter_build';

  /// MSVC → GCC/Clang 单标志映射。键为 MSVC 标志，值为等价 GCC/Clang 标志
  /// （空串表示直接移除——如 GCC 默认启用异常，`/EHsc` 无需保留）。
  static const Map<String, String> _flagMap = {
    '/EHsc': '',
    '/EHa': '',
    '/EHs': '',
    '/GR-': '-fno-rtti',
    '/GR': '-frtti',
    '/GS-': '-fno-stack-protector',
    '/std:c++20': '-std=c++20',
    '/std:c++17': '-std=c++17',
    '/std:c++14': '-std=c++14',
    '/std:c11': '-std=c11',
    '/W0': '-w',
    '/W1': '-Wall',
    '/W2': '-Wall',
    '/W3': '-Wall',
    '/W4': '-Wall -Wextra',
    '/WX': '-Werror',
    '/permissive-': '',
    '/Zc:__cplusplus': '',
    '/Zc:preprocessor': '',
    '/MP': '',
    '/utf-8': '-finput-charset=UTF-8 -fexec-charset=UTF-8',
  };

  // 已知可忽略、不必告警的 MSVC 风格 token（宏定义 /D、包含目录 /I、
  // 输入输出文件 /Fo /Fd /Fp /Tp /Tc、抑制告警码 /wdNNNN）。
  static final RegExp _ignorableToken = RegExp(
    r'^/(?:D|I|Fo|Fd|Fp|Tp|Tc|wd\d+)',
    caseSensitive: false,
  );

  bool _looksLikeFlagsLine(String line) {
    return line.contains('compile_options') ||
        line.contains('CMAKE_CXX_FLAGS') ||
        line.contains('CMAKE_C_FLAGS') ||
        line.contains('add_compile_options') ||
        line.contains('add_definitions');
  }

  /// 生成带边界的匹配，避免把 `/W3` 之类误匹配进更长 token（如 `/W3X`），也避免
  /// `/GR` 命中 `/GR-` 的前缀。
  RegExp _boundaryRegExp(String flag) {
    return RegExp(
      r'(?<![A-Za-z0-9+/])' + RegExp.escape(flag) + r'(?![A-Za-z0-9+/-])',
    );
  }

  /// 按行翻译 MSVC 标志（仅处理形似“标志行”的行，避免误伤路径/注释）。被
  /// [_guardBegin]/[_guardEnd] 包裹的行会被整体跳过。
  String _translateFlags(
    String content, {
    List<String>? warnings,
    String? sourcePath,
  }) {
    var inGuard = false;
    return content.split('\n').map((line) {
      if (line.contains(_guardBegin)) {
        inGuard = true;
        return line;
      }
      if (line.contains(_guardEnd)) {
        inGuard = false;
        return line;
      }
      if (inGuard) return line;
      if (!_looksLikeFlagsLine(line)) return line;

      var out = line;
      _flagMap.forEach((msvc, gcc) {
        out = out.replaceAll(_boundaryRegExp(msvc), gcc);
      });

      if (warnings != null) {
        final leftover = _detectUnknownFlags(out);
        if (leftover.isNotEmpty) {
          final where = sourcePath == null ? '' : '（$sourcePath）';
          warnings.add('未识别的 MSVC 风格标志$where：${leftover.join(', ')}');
        }
      }
      return out;
    }).join('\n');
  }

  /// 在已翻译的一行里找出仍残留的 `/X` 风格 token。路径片段（后紧跟 `/`，如
  /// `/usr/include`）和已知可忽略 token 会被排除，尽量减少误报。
  List<String> _detectUnknownFlags(String line) {
    final matches =
        RegExp(r'(?<![A-Za-z0-9])/[A-Za-z][A-Za-z0-9:_"+.-]*').allMatches(line);
    final result = <String>[];
    for (final m in matches) {
      final tok = m.group(0)!;
      final nextIsSlash = m.end < line.length && line[m.end] == '/';
      if (nextIsSlash) continue; // 形如 /usr/include 的路径片段，非标志。
      if (_ignorableToken.hasMatch(tok)) continue;
      result.add(tok);
    }
    return result;
  }

  /// 把 `"foo.lib"` 形式库引用改写为 `"foo"`，让 CMake 用 `-l` 去找库。
  String _translateLibRefs(String content) {
    return content.replaceAllMapped(
      RegExp(r'"([A-Za-z0-9_]+)\.lib"'),
      (m) => '"${m.group(1)}"',
    );
  }

  /// 把无条件的 `"_HAS_EXCEPTIONS=0"` 定义改写为仅 MSVC 生效的生成器表达式。
  ///
  /// 该宏会破坏 MinGW 的 libstdc++/libc++ 头；用 `$<$<CXX_COMPILER_ID:MSVC>:…>`
  /// 包裹后，MSVC 仍定义、Clang/MinGW 侧变为 no-op，同时保持 MSVC 可原样构建。
  /// 本步骤在注入我们自己的 APPLY_STANDARD_SETTINGS 之前执行，因此不会误伤注入
  /// 块 MSVC 分支里那处（本就受 `if(MSVC)` 保护的）`_HAS_EXCEPTIONS=0`。
  String _neutralizeHasExceptions(String content) {
    return content.replaceAll(
      '"_HAS_EXCEPTIONS=0"',
      r'"$<$<CXX_COMPILER_ID:MSVC>:_HAS_EXCEPTIONS=0>"',
    );
  }

  /// 改写 `function(APPLY_STANDARD_SETTINGS <param>) ... endfunction()`：
  ///
  /// 保留原参数名，替换为 `if(MSVC)...else()...endif()` 双分支——MinGW/Clang 侧
  /// 沿用既有的 `-Wall -Werror`（与旧行为一致，不改变交叉编译结果），同时保留
  /// MSVC 分支，使改写后的 CMake 在真实 Windows + MSVC 上仍可原样构建。整段用
  /// 保护标记包裹，避免其中的 MSVC 标志随后被 [_translateFlags] 翻译掉。
  String _transformApplyStandardSettings(String content) {
    final re = RegExp(
      r'function\s*\(\s*APPLY_STANDARD_SETTINGS\s+(\w+)[^)]*\)'
      r'[\s\S]*?endfunction\s*\([^)]*\)',
      caseSensitive: false,
    );
    return content.replaceAllMapped(re, (m) {
      final param = m.group(1) ?? 'TARGET';
      final ref = '\${$param}';
      return '$_guardBegin\n'
          '# 由 flutter_build 改写：保留 MSVC 分支（真实 Windows 仍可原样构建），\n'
          '# MinGW/Clang 侧走等价标志。\n'
          'function(APPLY_STANDARD_SETTINGS $param)\n'
          '  target_compile_features($ref PUBLIC cxx_std_17)\n'
          '  if(MSVC)\n'
          '    target_compile_options($ref PRIVATE /W4 /WX /wd"4100")\n'
          '    target_compile_options($ref PRIVATE /EHsc)\n'
          '    target_compile_definitions($ref PRIVATE "_HAS_EXCEPTIONS=0")\n'
          '  else()\n'
          '    target_compile_options($ref PRIVATE -Wall -Werror)\n'
          '  endif()\n'
          '  target_compile_definitions($ref PRIVATE "\$<\$<CONFIG:Debug>:_DEBUG>")\n'
          'endfunction()\n'
          '$_guardEnd';
    });
  }
}
