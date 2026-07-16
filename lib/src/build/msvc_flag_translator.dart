// MSVC → GCC/Clang 编译标志翻译器。
//
// Flutter 的 Windows 脚手架（windows/CMakeLists.txt）里大量使用 MSVC-only
// 的编译选项与链接写法。在 Linux 上用 LLVM-MinGW 交叉编译时，这些写法会
// 直接让 CMake 报错。本模块在“暂存源码”阶段对 CMakeLists.txt 做文本改写，
// 把 MSVC 标志翻译成 GCC/Clang 等价物。
//
// 注意：这是纯文本转换，不涉及真实 CMake 调用，测试也只是验证文本结果。

import 'dart:io';

import 'package:path/path.dart' as p;

/// 遍历目录树下所有 `CMakeLists.txt`，把 MSVC 专属写法翻译为 GCC/Clang 等价物。
class MsvcFlagTranslator {
  const MsvcFlagTranslator();

  /// 对 [rootPath] 下每个 `CMakeLists.txt` 应用 [transformContent]。
  ///
  /// 非 CMake 文件（README、.dart 等）会被忽略。幂等：重复调用只会在内容
  /// 发生变化时回写。
  Future<void> transformTree(String rootPath) async {
    final dir = Directory(rootPath);
    if (!dir.existsSync()) return;

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (p.basename(entity.path) != 'CMakeLists.txt') continue;

      final original = entity.readAsStringSync();
      final translated = transformContent(original);
      if (translated != original) {
        entity.writeAsStringSync(translated);
      }
    }
  }

  /// 转换单个 CMake 文件内容。纯函数，便于测试复用。
  String transformContent(String content) {
    final afterApply = _transformApplyStandardSettings(content);
    final afterFlags = _translateFlags(afterApply);
    return _translateLibRefs(afterFlags);
  }

  /// 把 MSVC 编译/链接标志翻译成 GCC/Clang 等价物。
  String _translateFlags(String content) {
    return content
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z0-9+/])/W3(?![A-Za-z0-9+/])'),
          (_) => '-Wall',
        )
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z0-9+/])/WX(?![A-Za-z0-9+/])'),
          (_) => '-Werror',
        )
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z0-9+/])/GR-(?![A-Za-z0-9+/])'),
          (_) => '-fno-rtti',
        )
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z0-9+/])/std:c\+\+17(?![A-Za-z0-9+/])'),
          (_) => '-std=c++17',
        )
        // /EHsc 在 GCC 下默认启用异常，直接移除该标志。
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z0-9+/])/EHsc(?![A-Za-z0-9+/])'),
          (_) => '',
        );
  }

  /// 把 `"foo.lib"` 形式库引用改写为 `"foo"`，让 CMake 用 `-l` 去找库。
  String _translateLibRefs(String content) {
    return content.replaceAllMapped(
      RegExp(r'"([A-Za-z0-9_]+)\.lib"'),
      (m) => '"${m.group(1)}"',
    );
  }

  /// 改写 `function(APPLY_STANDARD_SETTINGS target) ... endfunction()` 块。
  ///
  /// 原定义里的 MSVC-only 选项（/W3 /WX）在 MinGW 下无效，整块替换为等价
  /// 的 Clang 版本，从而保留下游的 `APPLY_STANDARD_SETTINGS(target)` 调用。
  String _transformApplyStandardSettings(String content) {
    final re = RegExp(
      r'function\(APPLY_STANDARD_SETTINGS[^)]*\)(.*?)endfunction\(\)',
      dotAll: true,
    );
    return content.replaceAllMapped(re, (match) {
      final header = match.group(0)!;
      final nameMatch =
          RegExp(r'function\(APPLY_STANDARD_SETTINGS\s+(\w+)').firstMatch(header);
      final param = nameMatch?.group(1) ?? 'target';
      return '# Translated by flutter_build: MSVC-only settings replaced with\n'
          '# GCC/Clang equivalents so the macro still resolves under MinGW.\n'
          'function(APPLY_STANDARD_SETTINGS $param)\n'
          '  target_compile_options(\${$param} PRIVATE -Wall -Werror)\n'
          'endfunction()';
    });
  }
}
