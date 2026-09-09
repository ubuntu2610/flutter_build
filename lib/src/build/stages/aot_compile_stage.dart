// 阶段 4：用 gen_snapshot（经 Wine）把 kernel 编译为 AOT elf（release / profile）。
//
// 仅在 AOT 模式（release / profile）运行；debug 走 JIT，无此阶段。

import 'dart:io';

import '../../engine_artifacts.dart';
import '../../exceptions.dart';
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
    // dart-define / gen_snapshot 身份——这些不体现在 kernel dill 里）则跳过昂贵
    // 的 gen_snapshot。gen_snapshot.exe 会在 Windows 引擎产物刷新时被**原地
    // 替换**（路径不变），故指纹额外包含其 mtime+size，确保替换后增量正确失效。
    final stampPath = '${ctx.appAotElf}.stamp';
    String computeStamp() {
      final gs = File(ctx.artifacts.genSnapshotExe(ctx.mode));
      return hashInputs(<String>[
        'obfuscate=${ctx.enableObfuscation}',
        'splitDebug=${ctx.splitDebugInfoDir ?? ''}',
        ...ctx.dartDefines,
        'genSnapshot=${ctx.artifacts.genSnapshotExe(ctx.mode)}',
        'genSnapshotIdentity=${gs.existsSync() ? '${gs.lastModifiedSync().toIso8601String()}:${gs.lengthSync()}' : 'missing'}',
      ]);
    }

    final stamp = computeStamp();
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

    try {
      await _runGenSnapshot(ctx, wine);
    } on SubprocessException catch (e) {
      final mismatch = RegExp(
        r'Invalid kernel binary format version\s*\(expected (\d+), found (\d+)\)',
      ).firstMatch(e.stderrText);
      if (mismatch == null) rethrow;

      // 【SDK 升级接缝】gen_snapshot.exe（Windows 引擎产物）与 frontend_server
      // （host dart-sdk）版本错配：SDK 自动升级只刷新了后者。stamp 污染使普通
      // precache 静默无效，必须 --force 强制刷新。刷新成功后重试一次。
      log.warn('gen_snapshot.exe 与 Flutter SDK 的 kernel 格式不匹配'
          '（expected ${mismatch[1]}, found ${mismatch[2]}）');
      log.warn('SDK 升级后 Windows 引擎产物未刷新，正在强制重新获取并重试…');
      await EngineArtifactsProvisioner(
        env: ctx.env,
        logger: log,
        runner: runner,
      ).ensure(force: true);
      await _runGenSnapshot(ctx, wine);
    }
    // 记录本次 AOT 的输入指纹，供下次增量判断。放在最后计算：重试路径下
    // gen_snapshot.exe 已被替换，指纹须按新文件内容计算。
    await File(stampPath).writeAsString(computeStamp());
  }

  Future<void> _runGenSnapshot(BuildContext ctx, WineWrapper wine) {
    final args = <String>[
      '--snapshot-kind=app-aot-elf',
      '--elf=${ctx.appAotElf}',
      if (ctx.enableObfuscation) '--obfuscate',
      if (ctx.splitDebugInfoDir != null)
        '--split-debug-info=${ctx.splitDebugInfoDir}',
      for (final define in ctx.dartDefines) '--define=$define',
      ctx.kernelDill,
    ];
    return runner.run(
      wine.scriptPath,
      <String>[ctx.artifacts.genSnapshotExe(ctx.mode), ...args],
      tag: 'gen_snapshot',
      environment: wine.environment(),
    );
  }
}
