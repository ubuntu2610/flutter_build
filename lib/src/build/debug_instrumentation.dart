// 给 Windows runner 注入调试信息，让引擎日志默认显示在启动它的控制台
// （PowerShell / cmd）里，用于排查"运行后无窗口、无提示"的静默失败。
//
// 背景：Flutter 的 runner 是 GUI 子系统程序（-mwindows）。标准 main.cpp 只在
// "检测到调试器"时才创建控制台，且从 PowerShell 启动时虽然会 AttachConsole 到
// 父控制台，却**没有把 stdout/stderr 重开到 CONOUT$**，所以引擎的 stderr 日志
// 根本出不来；窗口/引擎启动失败时还会直接 `return EXIT_FAILURE` 静默退出。
//
// 本模块对 **暂存副本**（windows_src/runner/main.cpp）做最小改写：
//   1) 附着到启动它的控制台（PowerShell/cmd），没有则新建一个；随后 freopen
//      stdout/stderr 到 CONOUT$ 并调用 FlutterDesktopResyncOutputStreams()，
//      使引擎日志实时显示在该控制台；
//   2) 启动失败时向 stderr 输出诊断信息（data/flutter_assets 或 data/app.so
//      缺失等常见原因）；
//   3) 运行时保持占用启动它的控制台，关闭程序（窗口）后才释放控制台并
//      干净退出——即 PowerShell/cmd 在程序运行期间不会回到提示符，关闭
//      程序后才回到提示符，避免"关掉程序后控制台不退出 / 日志丢失"。
//
// 只放纯函数（便于单测）；实际读写文件由 pipeline 编排。默认开启，可用
// `--no-debug-console` 关闭（发布干净版本时）。

/// 幂等哨兵：已注入则不再重复。
const String _sentinel = '// flutter_build debug instrumentation';

/// 标准 main.cpp 里 utils.h 的引入行（在其后补所需头文件）。
const String _utilsInclude = '#include "utils.h"';

/// 标准 main.cpp 里创建控制台的代码块（整体替换为"始终附着/新建控制台并重开流"）。
const String _consoleBlock =
    '  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {\n'
    '    CreateAndAttachConsole();\n'
    '  }';

/// runner 启动失败时的静默返回点。
const String _failReturn = 'return EXIT_FAILURE;';

/// runner 正常退出点（窗口被关闭、消息循环结束后）。
const String _successReturn = 'return EXIT_SUCCESS;';

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
  //    控制台会一直保持附着，直到下方的正常/失败退出点释放——因此程序
  //    运行期间 PowerShell/cmd 不会回到提示符，关闭程序后才回到提示符。
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

  // 3) 启动失败处（window.Create 失败）：向 stderr 输出诊断信息。
  if (out.contains(_failReturn)) {
    out = out.replaceFirst(
      _failReturn,
      'fprintf(stderr, "[flutter_build] engine/window failed to start "\n'
      '        "(likely empty data/flutter_assets or missing data/app.so)\\n");\n'
      '    fflush(stderr);\n'
      '    ::FreeConsole();\n'
      '    $_failReturn',
    );
  }

  // 4) 正常退出点（窗口被关闭、消息循环结束后）：先刷新标准流，再释放我们
  //    附着/新建的控制台，使 PowerShell/cmd 在关闭程序后干净回到提示符，
  //    而不是留下挂起或被占用的控制台。
  if (out.contains(_successReturn)) {
    out = out.replaceFirst(
      _successReturn,
      'fflush(stdout);\n'
      '    fflush(stderr);\n'
      '    ::FreeConsole();\n'
      '    $_successReturn',
    );
  }

  return '$_sentinel\n$out';
}
