// flutter/ephemeral 生成逻辑测试（纯函数）
//
// 覆盖版本解析、generated_config.cmake 渲染、flutter_assemble 中和三块。

import 'package:flutter_build/src/build/flutter_ephemeral.dart';
import 'package:test/test.dart';

void main() {
  group('parseFlutterVersion', () {
    test('标准 name+build：1.0.0+1', () {
      final v = parseFlutterVersion('1.0.0+1');
      expect(v.full, '1.0.0+1');
      expect([v.major, v.minor, v.patch, v.build], [1, 0, 0, 1]);
    });

    test('无 build 号：2.3.4', () {
      final v = parseFlutterVersion('2.3.4');
      expect([v.major, v.minor, v.patch, v.build], [2, 3, 4, 0]);
    });

    test('缺省/空 → 回退 1.0.0', () {
      final v = parseFlutterVersion(null);
      expect(v.full, '1.0.0');
      expect([v.major, v.minor, v.patch, v.build], [1, 0, 0, 0]);
      expect(parseFlutterVersion('  ').major, 1);
    });

    test('位数不足补 0：1.2', () {
      final v = parseFlutterVersion('1.2');
      expect([v.major, v.minor, v.patch], [1, 2, 0]);
    });

    test('非数字 build 号 → 0（对齐 flutter_tools）', () {
      expect(parseFlutterVersion('1.0.0+foo').build, 0);
    });
  });

  group('renderGeneratedConfigCmake', () {
    test('包含路径与版本变量', () {
      final out = renderGeneratedConfigCmake(
        flutterRoot: '/opt/flutter',
        projectDir: '/home/user/app',
        version: parseFlutterVersion('1.2.3+4'),
      );
      expect(out, contains('file(TO_CMAKE_PATH "/opt/flutter" FLUTTER_ROOT)'));
      expect(out, contains('file(TO_CMAKE_PATH "/home/user/app" PROJECT_DIR)'));
      expect(out, contains('set(FLUTTER_VERSION "1.2.3+4" PARENT_SCOPE)'));
      expect(out, contains('set(FLUTTER_VERSION_MAJOR 1 PARENT_SCOPE)'));
      expect(out, contains('set(FLUTTER_VERSION_BUILD 4 PARENT_SCOPE)'));
    });
  });

  group('neutralizeFlutterAssemble', () {
    const sample = '''
add_dependencies(flutter flutter_assemble)

# === Flutter tool backend ===
set(PHONY_OUTPUT "\${CMAKE_CURRENT_BINARY_DIR}/_phony_")
add_custom_command(
  OUTPUT \${FLUTTER_LIBRARY}
  COMMAND \${CMAKE_COMMAND} -E env
    "\${FLUTTER_ROOT}/packages/flutter_tools/bin/tool_backend.bat"
      windows-x64 \$<CONFIG>
  VERBATIM
)
add_custom_target(flutter_assemble DEPENDS
  "\${FLUTTER_LIBRARY}"
)
''';

    test('移除 tool_backend 并保留空 flutter_assemble 目标', () {
      final out = neutralizeFlutterAssemble(sample);
      expect(out, isNot(contains('tool_backend')));
      expect(out, isNot(contains('add_custom_command')));
      expect(out, contains('add_custom_target(flutter_assemble)'));
      // 标记前的内容保留。
      expect(out, contains('add_dependencies(flutter flutter_assemble)'));
    });

    test('无标记时原样返回', () {
      const noMarker = 'add_custom_target(flutter_assemble)\n';
      expect(neutralizeFlutterAssemble(noMarker), noMarker);
    });
  });
}
