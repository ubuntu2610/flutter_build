// 异常层次单元测试
//
// 验证各异常类的构造、字段、继承关系，以及默认退出码行为。

import 'package:flutter_win/flutter_win.dart';
import 'package:test/test.dart';

void main() {
  group('ToolException（工具异常基类）', () {
    test('message 和 hint 应能正确存储', () {
      final e = ToolException('构建失败', hint: '检查 CMake 版本');
      expect(e.message, '构建失败');
      expect(e.hint, '检查 CMake 版本');
      expect(e.exitCode, 1);
    });

    test('默认退出码为 1', () {
      expect(ToolException('x').exitCode, 1);
    });

    test('自定义退出码', () {
      final e = ToolException('x', exitCode: 42);
      expect(e.exitCode, 42);
    });

    test('toString 应包含 message', () {
      final e = ToolException('网络超时');
      expect(e.toString(), contains('网络超时'));
    });
  });

  group('MissingToolException（缺失工具异常）', () {
    test('继承自 ToolException', () {
      final e = MissingToolException('ninja', hint: 'apt install ninja-build');
      expect(e, isA<ToolException>());
      expect(e.message, contains('ninja'));
    });
  });

  group('FlutterSdkException（Flutter SDK 异常）', () {
    test('继承自 ToolException 且退出码为 3', () {
      final e = FlutterSdkException('找不到 Flutter');
      expect(e, isA<ToolException>());
      expect(e.exitCode, 3);
    });
  });

  group('ProjectException（工程异常）', () {
    test('继承自 ToolException', () {
      final e = ProjectException('无 pubspec.yaml');
      expect(e, isA<ToolException>());
    });
  });

  group('SubprocessException（子进程异常）', () {
    test('保留子进程退出码字段', () {
      final e = SubprocessException(
        executable: 'cmake',
        arguments: ['--build', '.'],
        subprocessExitCode: 2,
        stderrText: '找不到 Ninja',
      );
      expect(e, isA<ToolException>());
      expect(e.subprocessExitCode, 2);
      expect(e.executable, 'cmake');
      expect(e.stderrText, '找不到 Ninja');
      expect(e.arguments, ['--build', '.']);
    });
  });

  group('ArtifactException（制品异常）', () {
    test('基本构造', () {
      final e = ArtifactException('flutter_windows.dll 缺失');
      expect(e, isA<ToolException>());
      expect(e.message, contains('flutter_windows.dll'));
    });
  });
}
