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

  /// `dirname(finalExe)/data/flutter_assets` — 运行时资源目录。
  String get flutterAssetsDir =>
      p.join(p.dirname(finalExe), 'data', 'flutter_assets');
}
