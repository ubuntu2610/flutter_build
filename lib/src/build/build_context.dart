// 一次 Windows 交叉构建的全部已解析输入与派生命径。
//
// BuildContext 是一份不可变的“构建契约”：把 env / project / artifacts /
// toolchain 等探测结果，连同用户选项（mode、dart-defines、混淆开关等）汇
// 总起来，并据此派生出构建过程中所有约定好的目录 / 文件路径，供流水线各
// 阶段共享，避免每处都重复拼路径。

import 'package:path/path.dart' as p;

import '../engine_artifacts.dart';
import '../flutter_env.dart';
import '../project.dart';
import '../toolchain.dart';

/// 一次交叉构建的不可变上下文。
class BuildContext {
  BuildContext({
    required this.env,
    required this.project,
    required this.artifacts,
    required this.toolchain,
    required this.mode,
    required this.buildRoot,
    this.dartDefines = const <String>[],
    this.enableObfuscation = false,
    this.splitDebugInfoDir,
    this.treeShakeIcons = true,
    this.verbose = false,
    this.debugConsole = false,
    this.incremental = true,
    this.dllSearchRoot,
  });

  final FlutterEnv env;
  final FlutterProject project;
  final EngineArtifacts artifacts;
  final Toolchain toolchain;
  final WindowsFlavor mode;
  final String buildRoot;
  final List<String> dartDefines;
  final bool enableObfuscation;
  final String? splitDebugInfoDir;
  final bool treeShakeIcons;
  final bool verbose;

  /// 是否给 runner 注入调试信息（始终开控制台 + 失败输出 stderr 诊断），
  /// 用于排查在 Windows 上运行后无窗口/静默退出的问题。由 `--debug-console` 控制。
  final bool debugConsole;

  /// 是否启用增量构建：kernel / AOT 输入未变时跳过重编。由 `--no-incremental`
  /// 关闭（默认开启）。
  final bool incremental;

  /// 预构建 DLL 的搜索根目录（由 `--dll-search-root` 指定）。为 null 时默认使用
  /// 项目根的祖父目录，覆盖 libcimbar / paddle_ocr 等兄弟目录。收窄它可显著加快
  /// 大型工作区下的产物组装。
  final String? dllSearchRoot;

  /// `buildRoot/<mode>` — 当前模式的根目录。
  String get modeDir => p.join(buildRoot, mode.cliName);

  /// `modeDir/windows_src` — 暂存的 CMake 源（从 `windows/` 复制并改写）。
  String get windowsStageDir => p.join(modeDir, 'windows_src');

  /// `modeDir/cmake_build` — CMake 配置与构建输出目录。
  String get cmakeBuildDir => p.join(modeDir, 'cmake_build');

  /// `modeDir/intermediates` — kernel dill 与 AOT elf 的临时产物。
  String get intermediatesDir => p.join(modeDir, 'intermediates');

  /// `intermediates/app.dill` — 编译出的 kernel 快照。
  String get kernelDill => p.join(intermediatesDir, 'app.dill');

  /// `intermediates/app.so` — AOT 产物（debug/JIT 模式下不会生成）。
  String get appAotElf => p.join(intermediatesDir, 'app.so');

  /// `modeDir/<appName>/<appName>.exe` — 最终打包的可执行文件。
  String get finalExe =>
      p.join(modeDir, project.appName, '${project.appName}.exe');

  /// `dirname(finalExe)` — 最终 bundle 的输出目录（含 exe / dll / data/）。
  String get outputDir => p.dirname(finalExe);

  /// `outputDir/data` — 运行时数据目录（icudtl.dat / app.so / flutter_assets）。
  String get dataDir => p.join(outputDir, 'data');

  /// `dataDir/flutter_assets` — 运行时资源目录。
  String get flutterAssetsDir => p.join(dataDir, 'flutter_assets');

  /// `intermediates/mingw_compat` — MinGW 兼容垫片头文件目录。
  String get mingwCompatDir => p.join(intermediatesDir, 'mingw_compat');
}
