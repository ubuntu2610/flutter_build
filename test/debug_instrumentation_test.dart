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
    test('补充 <stdio.h> 引入', () {
      final out = instrumentRunnerMain(_sampleMain);
      expect(out, contains('#include "utils.h"\n#include <stdio.h>'));
    });

    test('把日志重定向到 flutter_build_debug.log', () {
      final out = instrumentRunnerMain(_sampleMain);
      expect(out, contains('flutter_build_debug.log'));
      expect(out, contains('freopen_s'));
      // 重定向发生在控制台块之后、进入引擎之前。
      expect(out.indexOf('freopen_s'),
          greaterThan(out.indexOf('CreateAndAttachConsole')));
    });

    test('启动失败处注入 MessageBox 并指向日志文件', () {
      final out = instrumentRunnerMain(_sampleMain);
      expect(out, contains('MessageBoxW'));
      expect(out, contains('failed to start'));
      expect(out.indexOf('MessageBoxW'),
          lessThan(out.indexOf('return EXIT_FAILURE;')));
      expect(out, contains('return EXIT_SUCCESS;')); // 成功路径不受影响
    });

    test('幂等：重复注入内容不变、MessageBox 只有一处', () {
      final once = instrumentRunnerMain(_sampleMain);
      final twice = instrumentRunnerMain(once);
      expect(twice, once);
      expect('MessageBoxW'.allMatches(twice).length, 1);
    });

    test('找不到标记时仅加哨兵、不崩', () {
      const noMarkers = 'int main() { return 0; }\n';
      final out = instrumentRunnerMain(noMarkers);
      expect(out, contains('int main() { return 0; }'));
      // 可重复调用保持稳定。
      expect(instrumentRunnerMain(out), out);
    });
  });
}
