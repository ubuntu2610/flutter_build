// 给 Windows runner 注入调试信息，用于排查“运行后无窗口、无提示”的静默失败。
//
// Flutter 的 runner 是 GUI 子系统程序（-mwindows），默认没有控制台；且标准
// main.cpp 只在“检测到调试器”时才创建控制台，窗口/引擎启动失败时直接
// `return EXIT_FAILURE` 静默退出。于是在 Windows 上双击运行常常“什么都没有”。
//
// 本模块对 **暂存副本**（windows_src/runner/main.cpp）做最小改写：
//   1) 始终创建/附着控制台 —— 让 Flutter 引擎的 stderr 日志可见；
//   2) 启动失败时弹 MessageBox —— GUI 程序否则完全静默，看不到任何信息。
//
// 只放纯函数（便于单测）；实际读写文件由 pipeline 编排，且仅在 --debug-console
// 开启时应用，不影响正常发布构建。

/// 标准 main.cpp 里“仅调试器存在才创建控制台”的条件片段。
const String _consoleGuard =
    '!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()';

/// 去掉调试器限制后的条件：附着父控制台失败（如双击启动）就新建一个。
const String _consoleAlways = '!::AttachConsole(ATTACH_PARENT_PROCESS)';

/// runner 启动失败时的静默返回点。
const String _failReturn = 'return EXIT_FAILURE;';

/// 给 [source]（runner/main.cpp 内容）注入调试代码，返回改写后的内容。
///
/// 幂等：若已注入或找不到标记，则对应改写为 no-op，可安全重复调用。
String instrumentRunnerMain(String source) {
  var out = source;

  // 1) 始终创建控制台，使引擎日志可见。
  out = out.replaceAll(_consoleGuard, _consoleAlways);

  // 2) 启动失败时弹窗（只替换第一处 return EXIT_FAILURE，即 window.Create 失败处）。
  //    用哨兵注释避免重复注入。
  const sentinel = '// flutter_build: debug messagebox';
  if (!out.contains(sentinel) && out.contains(_failReturn)) {
    out = out.replaceFirst(
      _failReturn,
      '$sentinel\n'
      '    ::MessageBoxW(nullptr,\n'
      '        L"flutter_build: Flutter engine/window failed to start. "\n'
      '        L"Check that data/flutter_assets and data/app.so exist "\n'
      '        L"and match the engine version.",\n'
      '        L"flutter_build debug", MB_OK | MB_ICONERROR);\n'
      '    $_failReturn',
    );
  }
  return out;
}
