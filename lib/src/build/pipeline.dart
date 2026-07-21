// 交叉构建流水线编排。
//
// BuildPipeline 把一次 Windows 交叉编译拆成若干个阶段（见 stages/）：暂存 CMake
// 源 → 翻译 MSVC 标志 → 编译 kernel →（AOT 模式）编译 AOT → CMake 配置/构建 →
// 打包产物。本文件只负责「按序运行阶段」，各阶段的具体逻辑分散在 stages/ 下的
// [BuildStage] 实现里，便于单独理解与测试。

import '../io/fs_utils.dart';
import '../logger.dart';
import '../process_runner.dart';
import 'build_context.dart';
import 'native_dll.dart' as dll;
import 'stages/aot_compile_stage.dart';
import 'stages/assemble_bundle_stage.dart';
import 'stages/build_stage.dart';
import 'stages/cmake_build_stage.dart';
import 'stages/compile_kernel_stage.dart';
import 'stages/source_staging_stage.dart';
import 'stages/translate_flags_stage.dart';

// 保留既有公共 API：`materializePluginSymlinks` 现居 source_staging_stage.dart，
// 通过再导出让历史导入路径（package:flutter_build/src/build/pipeline.dart）继续可用。
export 'stages/source_staging_stage.dart' show materializePluginSymlinks;

/// 递归复制目录树，但不跟随符号链接（保留 `.plugin_symlinks`）。
///
/// 历史公共 API：委托给 `fs_utils` 的 [copyTree]。这对 Flutter
/// `windows/flutter/ephemeral/.plugin_symlinks/` 很关键：插件链接通常指向包根
/// 目录；若跟随它们，示例工程里的 `build/` 会被重新扫进暂存目录，进而形成
/// 无限嵌套路径。
Future<void> copyTreePreservingLinks(String src, String dst) =>
    copyTree(src, dst);

/// 编排 Windows 交叉构建的整个流程。
class BuildPipeline {
  BuildPipeline({
    Logger? logger,
    ProcessRunner? runner,
  })  : _log = logger ?? Logger.instance,
        _runner = runner ?? ProcessRunner(logger: logger ?? Logger.instance);

  final Logger _log;
  final ProcessRunner _runner;

  /// 构建按序执行的阶段清单（面向 Windows 目标）。
  List<BuildStage> _stages() => <BuildStage>[
        SourceStagingStage(logger: _log, runner: _runner),
        TranslateFlagsStage(logger: _log, runner: _runner),
        CompileKernelStage(logger: _log, runner: _runner),
        AotCompileStage(logger: _log, runner: _runner),
        CMakeBuildStage(logger: _log, runner: _runner),
        AssembleBundleStage(logger: _log, runner: _runner),
      ];

  /// 运行完整流水线。跳过 `shouldRun` 为 false 的阶段（如 debug 模式无 AOT），
  /// 阶段编号按实际会运行的阶段数动态计算。
  Future<void> run(BuildContext ctx) async {
    final stages = _stages().where((s) => s.shouldRun(ctx)).toList();
    final total = stages.length;
    for (var i = 0; i < total; i++) {
      final stage = stages[i];
      await _log.group(
        'Stage ${i + 1}/$total · ${stage.name}',
        () => stage.run(ctx),
      );
    }
    _log.success('Windows build complete: ${ctx.finalExe}');
  }

  /// 从 CMake 文件内容里提取被引用的 `.dll` 字面路径。保留为静态方法以维持
  /// 既有公共 API（委托给 `native_dll.dart` 的 `referencedDllPaths`）。
  static List<String> referencedDllPaths(String cmakeContent) =>
      dll.referencedDllPaths(cmakeContent);
}
