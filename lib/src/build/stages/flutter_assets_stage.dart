// 资源打包阶段：用 `flutter assemble copy_flutter_bundle` 生成 flutter_assets
// （AssetManifest / 字体 / NOTICES / shaders 等）。
//
// 为何独立成阶段：copy_flutter_bundle 是纯 host 侧 Dart 任务——它只依赖 Dart 工程
// 与 Flutter SDK（内部自带 kernel 编译），既不依赖 CMake 原生轨的产物（exe / 插件
// DLL），也不需要 Windows 二进制。此前它被塞进产物组装阶段串行执行，等于把这段
// Dart + 资源打包耗时叠在关键路径末尾。抽出后作为一条独立 lane，可与原生轨、Dart
// 轨并行，把资源打包藏进 CMake 构建的时间窗口里。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../engine_artifacts.dart';
import '../build_context.dart';
import 'build_stage.dart';

/// 构造 `flutter assemble copy_flutter_bundle` 的参数（纯函数，便于单测）。
///
/// 复用 flutter 自己的资源打包逻辑。参数含义：
///   - `-dTargetPlatform=windows-x64`：面向 Windows 打包资源（copy_flutter_bundle
///     只需 Dart 产物，不需要 MSVC）。
///   - `-dBuildMode=<mode>`：与本次构建模式一致。
///   - `-dTreeShakeIcons=<bool>`：图标 tree-shaking 开关透传。
///   - `--output=<dir>`：直接输出到 bundle 的 data/flutter_assets/。
List<String> assembleBundleArgs(BuildContext ctx) => <String>[
      'assemble',
      '-dTargetPlatform=windows-x64',
      '-dBuildMode=${ctx.mode.cliName}',
      '-dTreeShakeIcons=${ctx.treeShakeIcons}',
      '--output=${ctx.flutterAssetsDir}',
      'copy_flutter_bundle',
    ];

/// 运行 `flutter assemble` 时应注入的环境变量（纯函数，便于单测）。
///
/// flutter assemble 面向 windows-x64 时会读 PROGRAMFILES(X86) 探测 Visual Studio
/// 路径；Linux 上该变量不存在，导致 dart_build target 直接报错退出。置空即可绕过
/// 探测——copy_flutter_bundle 只需 Dart 产物，不需要 MSVC。
Map<String, String> assembleBundleEnv() => <String, String>{
      'PROGRAMFILES(X86)': '',
    };

/// 生成 flutter_assets 的资源打包阶段。
class FlutterAssetsStage extends BuildStage {
  FlutterAssetsStage({super.logger, super.runner});

  @override
  String get name => 'bundle Flutter assets';

  @override
  Future<void> run(BuildContext ctx) async {
    log.info('  生成 flutter_assets（flutter assemble copy_flutter_bundle）…');
    await Directory(ctx.flutterAssetsDir).create(recursive: true);
    await runner.run(
      p.join(ctx.env.sdkRoot, 'bin', 'flutter'),
      assembleBundleArgs(ctx),
      workingDirectory: ctx.project.root,
      environment: assembleBundleEnv(),
      stream: true,
      tag: 'assemble',
    );
  }
}
