// MSVC 编译标志翻译器单元测试
//
// 测试的核心在于确保 CMakeLists.txt 里出现的 MSVC-only 标志被正确转换为
// GCC/Clang 等价物，包括：
//   - /W3 → -Wall
//   - /WX → -Werror
//   - /EHsc → 移除（GCC 默认启用异常）
//   - /std:c++17 → -std=c++17
//   - /GR- → -fno-rtti
//   - "foo.lib" → "foo" (让 CMake 用 -l 找库)
//   - APPLY_STANDARD_SETTINGS 宏函数替换
//
// 注意：这些测试仅验证文本转换逻辑，不涉及真实 CMake 调用。

import 'dart:io';

import 'package:flutter_build/src/build/msvc_flag_translator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // 临时目录用于写入 mock CMakeLists.txt 并交给 translator 处理。
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('msvc_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  /// 辅助函数：把 [content] 写入 tmpDir/CMakeLists.txt 然后跑翻译。
  Future<String> translate(String content) async {
    final file = File(p.join(tmpDir.path, 'CMakeLists.txt'));
    file.writeAsStringSync(content);
    await MsvcFlagTranslator().transformTree(tmpDir.path);
    return file.readAsStringSync();
  }

  group('基础标志映射', () {
    test('/W3 转为 -Wall', () async {
      final out = await translate(r'target_compile_options(foo PRIVATE /W3)');
      expect(out, contains('-Wall'));
      expect(out, isNot(contains('/W3')));
    });

    test('/WX 转为 -Werror', () async {
      final out = await translate(r'target_compile_options(foo PRIVATE /WX)');
      expect(out, contains('-Werror'));
    });

    test('/EHsc 被移除', () async {
      final out = await translate(
        r'target_compile_options(foo PRIVATE /EHsc /W3)',
      );
      expect(out, isNot(contains('/EHsc')));
      expect(out, contains('-Wall'));
    });

    test('/std:c++17 转为 -std=c++17', () async {
      final out = await translate(
        r'target_compile_options(foo PRIVATE /std:c++17)',
      );
      expect(out, contains('-std=c++17'));
    });

    test('/GR- 转为 -fno-rtti', () async {
      final out = await translate(
        r'target_compile_options(foo PRIVATE /GR-)',
      );
      expect(out, contains('-fno-rtti'));
    });
  });

  group('库引用重写', () {
    test('"foo.lib" 转为 "foo"', () async {
      final out = await translate(
        'target_link_libraries(app PRIVATE "advapi32.lib")',
      );
      expect(out, contains('"advapi32"'));
      expect(out, isNot(contains('.lib')));
    });
  });

  group('APPLY_STANDARD_SETTINGS 宏替换', () {
    test('function(APPLY_STANDARD_SETTINGS ...) 应被替换', () async {
      const input = '''
function(APPLY_STANDARD_SETTINGS target)
  target_compile_options(\${target} PRIVATE /W3 /WX)
endfunction()

APPLY_STANDARD_SETTINGS(foo)
''';
      final out = await translate(input);
      // 原始的 function 定义应被替换为条件编译版本
      expect(out, isNot(contains('PRIVATE /W3 /WX')));
      // 应保留函数名调用
      expect(out, contains('APPLY_STANDARD_SETTINGS'));
    });
  });

  group('不处理非 CMakeLists 文件', () {
    test('纯文本文件应被忽略', () async {
      final file = File(p.join(tmpDir.path, 'README.md'));
      file.writeAsStringSync('/W3 /WX');
      await MsvcFlagTranslator().transformTree(tmpDir.path);
      expect(file.readAsStringSync(), '/W3 /WX');
    });
  });

  group('扩展标志映射', () {
    test('/W4 转为 -Wall -Wextra', () async {
      final out = await translate('add_compile_options(/W4)');
      expect(out, contains('-Wall -Wextra'));
      expect(out, isNot(contains('/W4')));
    });

    test('/std:c++20 转为 -std=c++20', () async {
      final out = await translate(
        r'target_compile_options(x PRIVATE /std:c++20)',
      );
      expect(out, contains('-std=c++20'));
    });

    test('/permissive- 与 /MP 被移除', () async {
      final out = await translate('add_compile_options(/permissive- /MP)');
      expect(out, isNot(contains('/permissive-')));
      expect(out, isNot(contains('/MP')));
    });

    test('/GS- 转为 -fno-stack-protector', () async {
      final out = await translate('add_compile_options(/GS-)');
      expect(out, contains('-fno-stack-protector'));
    });
  });

  group('APPLY_STANDARD_SETTINGS 双分支', () {
    test('保留 MSVC 分支并生成 else 分支', () async {
      const input = '''
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_options(\${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(\${TARGET} PRIVATE /EHsc)
  target_compile_definitions(\${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
endfunction()
''';
      final out = await translate(input);
      expect(out, contains('if(MSVC)'));
      expect(out, contains('else()'));
      expect(out, contains('endif()'));
      // MSVC 分支保留原始 MSVC 标志（未被翻译成 GCC 形式）。
      expect(out, contains('/W4 /WX'));
      // MinGW/Clang 分支使用等价 GCC 标志。
      expect(out, contains('-Wall -Werror'));
    });

    test('保留原始参数名', () async {
      const input = '''
function(APPLY_STANDARD_SETTINGS MYTARGET)
  target_compile_options(\${MYTARGET} PRIVATE /W3)
endfunction()
''';
      final out = await translate(input);
      expect(out, contains('function(APPLY_STANDARD_SETTINGS MYTARGET)'));
      expect(out, contains(r'${MYTARGET}'));
    });
  });

  group('_HAS_EXCEPTIONS 中和', () {
    test('独立的 _HAS_EXCEPTIONS=0 改写为 MSVC 生成器表达式', () async {
      final out = await translate(
        'target_compile_definitions(app PRIVATE "_HAS_EXCEPTIONS=0")',
      );
      expect(out, contains(r'$<$<CXX_COMPILER_ID:MSVC>:_HAS_EXCEPTIONS=0>'));
      expect(out, isNot(contains('"_HAS_EXCEPTIONS=0"')));
    });
  });

  group('未识别标志告警', () {
    test('未知 /Qxxx 标志被记录为告警', () {
      final warnings = <String>[];
      const MsvcFlagTranslator().transformContent(
        r'target_compile_options(x PRIVATE /W3 /Qunknown)',
        warnings: warnings,
      );
      expect(warnings, isNotEmpty);
      expect(warnings.join(), contains('/Qunknown'));
    });

    test('路径片段不触发误报', () {
      final warnings = <String>[];
      const MsvcFlagTranslator().transformContent(
        'add_compile_options(-I /usr/include)',
        warnings: warnings,
      );
      expect(warnings, isEmpty);
    });
  });
}
