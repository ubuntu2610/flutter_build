// 阶段 4：用 gen_snapshot（经 Wine）把 kernel 编译为 AOT elf（release / profile）。
//
// 仅在 AOT 模式（release / profile）运行；debug 走 JIT，无此阶段。

import 'dart:io';

import '../../engine_artifacts.dart';
import '../build_context.dart';
import '../incremental.dart';
import '../wine_wrapper.dart';
import 'build_stage.dart';

/// 把 kernel 编译为 AOT `app.so`（仅 release / profile）。
class AotCompileStage extends BuildStage {
  AotCompileStage({super.logger, super.runner});

  @override
  String get name => 'AOT compile';

  @override
  bool shouldRun(BuildContext ctx) => ctx.mode.isAot;

  @override
  Future<void> run(BuildContext ctx) async {
    // 增量：app.so 比 kernel 新且 AOT 专属输入指纹未变（混淆 / split-debug /
    // dart-define / gen_snapshot 路径——这些不体现在 kernel dill 里）则跳过昂贵
    // 的 gen_snapshot。
    final stampPath = '${ctx.appAotElf}.stamp';
    final stamp = hashInputs(<String>[
      'obfuscate=${ctx.enableObfuscation}',
      'splitDebug=${ctx.splitDebugInfoDir ?? ''}',
      ...ctx.dartDefines,
      'genSnapshot=${ctx.artifacts.genSnapshotExe(ctx.mode)}',
    ]);
    if (ctx.incremental &&
        isUpToDate(
          outputPath: ctx.appAotElf,
          inputPaths: <String>[ctx.kernelDill],
          stampPath: stampPath,
          expectedStamp: stamp,
        )) {
      log.info('  AOT 产物已是最新（kernel 未更新），跳过 gen_snapshot。');
      return;
    }

    final wine =
        WineWrapper(toolchain: ctx.toolchain, buildRoot: ctx.buildRoot);
    await wine.materialize();

    final args = <String>[
      ctx.artifacts.genSnapshotExe(ctx.mode),
      '--snapshot-kind=app-aot-elf',
      '--elf=${ctx.appAotElf}',
      if (ctx.enableObfuscation) '--obfuscate',
      if (ctx.splitDebugInfoDir != null)
        '--split-debug-info=${ctx.splitDebugInfoDir}',
      for (final define in ctx.dartDefines) '--define=$define',
      ctx.kernelDill,
    ];
    await runner.run(
      wine.scriptPath,
      <String>[ctx.artifacts.genSnapshotExe(ctx.mode), ...args.skip(1)],
      tag: 'gen_snapshot',
      environment: wine.environment(),
    );
    // 记录本次 AOT 的输入指纹，供下次增量判断。
    await File(stampPath).writeAsString(stamp);
  }
}
