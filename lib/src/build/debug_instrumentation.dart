// 给 Windows runner 注入调试信息，让引擎日志默认显示在启动它的控制台
// （PowerShell / cmd）里，用于排查“运行后无窗口、无提示”的静默失败。
//
// 背景：Flutter 的 runner 是 GUI 子系统程序（-mwindows）。标准 main.cpp 只在
// “检测到调试器”时才创建控制台，且从 PowerShell 启动时虽然会 AttachConsole 到
// 父控制台，却**没有把 stdout/stderr 重开到 CONOUT$**，所以引擎的 stderr 日志
// 根本出不来；窗口/引擎启动失败时还会直接 `return EXIT_FAILURE` 静默退出。
//
// 本模块对 **暂存副本**（windows_src/runner/main.cpp）做最小改写：
//   1) 附着到启动它的控制台（PowerShell/cmd），没有则新建一个；随后 freopen
//      stdout/stderr 到 CONOUT$ 并调用 FlutterDesktopResyncOutputStreams()，
//      使引擎日志实时显示在该控制台；
//   2) 启动失败时弹 MessageBox —— 双击（无父控制台）时控制台会一闪而过，
//      弹框可确保失败信息不被错过。
//
// 只放纯函数（便于单测）；实际读写文件由 pipeline 编排。默认开启，可用
// `--no-debug-console` 关闭（发布干净版本时）。

/// 幂等哨兵：已注入则不再重复。
const String _sentinel = '// flutter_build debug instrumentation';

/// 标准 main.cpp 里 utils.h 的引入行（在其后补所需头文件）。
const String _utilsInclude = '#include "utils.h"';

/// 标准 main.cpp 里创建控制台的代码块（整体替换为“始终附着/新建控制台并重开流”）。
const String _consoleBlock =
    '  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {\n'
    '    CreateAndAttachConsole();\n'
    '  }';

/// runner 启动失败时的静默返回点。
const String _failReturn = 'return EXIT_FAILURE;';

/// 给 [source]（runner/main.cpp 内容）注入调试代码，返回改写后的内容。幂等。
String instrumentRunnerMain(String source) {
  if (source.contains(_sentinel)) return source;
  var out = source;

  // 1) 需要 <stdio.h> 的 freopen_s/fprintf，以及 <flutter_windows.h> 的
  //    FlutterDesktopResyncOutputStreams。
  if (out.contains(_utilsInclude)) {
    out = out.replaceFirst(
      _utilsInclude,
      '$_utilsInclude\n'
      '#include <stdio.h>          // flutter_build\n'
      '#include <flutter_windows.h> // flutter_build',
    );
  }

  // 2) 始终把引擎日志接到启动它的控制台（PowerShell/cmd），没有父控制台
  //    （如双击）时新建一个；随后重开标准流并让引擎重新同步。
  if (out.contains(_consoleBlock)) {
    out = out.replaceFirst(
      _consoleBlock,
      '  // flutter_build: surface engine logs on the launching console\n'
      '  if (!::AttachConsole(ATTACH_PARENT_PROCESS)) {\n'
      '    ::AllocConsole();\n'
      '  }\n'
      '  {\n'
      '    FILE* fb_console = nullptr;\n'
      '    freopen_s(&fb_console, "CONOUT\$", "w", stdout);\n'
      '    freopen_s(&fb_console, "CONOUT\$", "w", stderr);\n'
      '    FlutterDesktopResyncOutputStreams();\n'
      '    fprintf(stderr, "[flutter_build] wWinMain reached; init engine...\\n");\n'
      '    fflush(stderr);\n'
      '  }',
    );
  }

  // 3) 启动失败处（window.Create 失败）：记日志 + 弹 MessageBox。
  if (out.contains(_failReturn)) {
    out = out.replaceFirst(
      _failReturn,
      'fprintf(stderr, "[flutter_build] engine/window failed to start "\n'
      '        "(likely empty data/flutter_assets or missing data/app.so)\\n");\n'
      '    fflush(stderr);\n'
      '    ::MessageBoxW(nullptr,\n'
      '        L"flutter_build: engine/window failed to start.\\n"\n'
      '        L"Run from PowerShell to see engine logs, or check that\\n"\n'
      '        L"data/flutter_assets and data/app.so exist.",\n'
      '        L"flutter_build debug", MB_OK | MB_ICONERROR);\n'
      '    $_failReturn',
    );
  }

  return '$_sentinel\n$out';
}
