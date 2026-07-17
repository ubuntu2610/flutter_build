// 给 Windows runner 注入调试信息，用于排查“运行后无窗口、无提示”的静默失败。
//
// Flutter 的 runner 是 GUI 子系统程序（-mwindows），默认没有控制台；标准
// main.cpp 在窗口/引擎启动失败时直接 `return EXIT_FAILURE` 静默退出。于是在
// Windows 上双击运行常常“什么都没有”。而临时 AllocConsole 出来的控制台会随
// 进程退出一闪而过，来不及看。
//
// 因此本模块对 **暂存副本**（windows_src/runner/main.cpp）做最小改写：
//   1) 把 stdout/stderr 重定向到 exe 旁的 flutter_build_debug.log —— 引擎的
//      日志会持久写入文件，进程退出后仍可查看；
//   2) 启动失败时弹 MessageBox —— 阻塞式、不会一闪而过，并提示去看日志文件。
//
// 只放纯函数（便于单测）；实际读写文件由 pipeline 编排，且仅在 --debug-console
// 开启时应用，不影响正常发布构建。

/// 幂等哨兵：已注入则不再重复。
const String _sentinel = '// flutter_build debug instrumentation';

/// 标准 main.cpp 里 utils.h 的引入行（在其后补 <stdio.h>）。
const String _utilsInclude = '#include "utils.h"';

/// 标准 main.cpp 里创建控制台的代码块（在其后插入文件日志重定向）。
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

  // 1) 需要 <stdio.h> 的 freopen_s / fprintf（与 utils.cpp 用法一致）。
  if (out.contains(_utilsInclude)) {
    out = out.replaceFirst(_utilsInclude, '$_utilsInclude\n#include <stdio.h>');
  }

  // 2) 在 wWinMain 开头（控制台块之后）把 stdout/stderr 重定向到日志文件，
  //    并打一个到达标记。引擎的 stderr 日志随后会写进该文件。
  if (out.contains(_consoleBlock)) {
    out = out.replaceFirst(
      _consoleBlock,
      '$_consoleBlock\n'
      '  {  // flutter_build: redirect logs to a file (survives silent exit)\n'
      '    FILE* fb_log = nullptr;\n'
      '    freopen_s(&fb_log, "flutter_build_debug.log", "w", stderr);\n'
      '    freopen_s(&fb_log, "flutter_build_debug.log", "a", stdout);\n'
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
      '        L"See flutter_build_debug.log next to the app for details.\\n"\n'
      '        L"Most likely data/flutter_assets is empty or data/app.so is missing.",\n'
      '        L"flutter_build debug", MB_OK | MB_ICONERROR);\n'
      '    $_failReturn',
    );
  }

  return '$_sentinel\n$out';
}
