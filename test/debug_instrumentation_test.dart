// runner 调试注入逻辑测试（纯函数）。

import 'package:flutter_build/src/build/debug_instrumentation.dart';
import 'package:test/test.dart';

// 标准 Flutter Windows runner/main.cpp 的关键片段。
const _sampleMain = '''
int APIENTRY wWinMain(...) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  FlutterWindow window(project);
  if (!window.Create(L"hello", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  return EXIT_SUCCESS;
}
''';

void main() {
  group('instrumentRunnerMain', () {
    test('始终创建控制台：去掉 IsDebuggerPresent 限制', () {
      final out = instrumentRunnerMain(_sampleMain);
      expect(out, isNot(contains('IsDebuggerPresent')));
      expect(out, contains('if (!::AttachConsole(ATTACH_PARENT_PROCESS)) {'));
    });

    test('启动失败处注入 MessageBox', () {
      final out = instrumentRunnerMain(_sampleMain);
      expect(out, contains('MessageBoxW'));
      expect(out, contains('failed to start'));
      // MessageBox 在 return EXIT_FAILURE 之前。
      expect(out.indexOf('MessageBoxW'),
          lessThan(out.indexOf('return EXIT_FAILURE;')));
      // 不影响成功返回。
      expect(out, contains('return EXIT_SUCCESS;'));
    });

    test('幂等：重复注入不产生第二个 MessageBox', () {
      final once = instrumentRunnerMain(_sampleMain);
      final twice = instrumentRunnerMain(once);
      expect(twice, once);
      expect('MessageBoxW'.allMatches(twice).length, 1);
    });

    test('找不到标记时基本原样返回', () {
      const noMarkers = 'int main() { return 0; }\n';
      expect(instrumentRunnerMain(noMarkers), noMarkers);
    });
  });
}
