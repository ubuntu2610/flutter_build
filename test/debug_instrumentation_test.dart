// runner 调试注入逻辑测试（纯函数）。

import 'package:flutter_build/src/build/debug_instrumentation.dart';
import 'package:test/test.dart';

// 贴近标准 Flutter Windows runner/main.cpp 的片段。
const _sampleMain = '''
#include <flutter/dart_project.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

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
    test('补充所需头文件', () {
      final out = instrumentRunnerMain(_sampleMain);
      expect(out, contains('#include <stdio.h>'));
      expect(out, contains('#include <flutter_windows.h>'));
    });

    test('把引擎日志接到控制台（CONOUT\$）而非文件', () {
      final out = instrumentRunnerMain(_sampleMain);
      // 附着父控制台，无则新建。
      expect(out, contains('AttachConsole(ATTACH_PARENT_PROCESS)'));
      expect(out, contains('AllocConsole()'));
      // 重开标准流到控制台，并让引擎重新同步。
      expect(out, contains(r'freopen_s(&fb_console, "CONOUT$", "w", stdout)'));
      expect(out, contains('FlutterDesktopResyncOutputStreams()'));
      // 不再走文件方案。
      expect(out, isNot(contains('flutter_build_debug.log')));
    });

    test('启动失败处注入 stderr 诊断', () {
      final out = instrumentRunnerMain(_sampleMain);
      expect(out, contains('failed to start'));
      expect(out.indexOf('failed to start'),
          lessThan(out.indexOf('return EXIT_FAILURE;')));
      expect(out, contains('return EXIT_SUCCESS;')); // 成功路径不受影响
    });

    test('幂等：重复注入内容不变', () {
      final once = instrumentRunnerMain(_sampleMain);
      final twice = instrumentRunnerMain(once);
      expect(twice, once);
    });

    test('找不到标记时仅加哨兵、可重复调用稳定', () {
      const noMarkers = 'int main() { return 0; }\n';
      final out = instrumentRunnerMain(noMarkers);
      expect(out, contains('int main() { return 0; }'));
      expect(instrumentRunnerMain(out), out);
    });
  });
}
