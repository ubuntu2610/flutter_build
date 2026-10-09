// 交叉构建流水线编排。
//
// BuildPipeline 把一次 Windows 交叉编译拆成若干阶段（见 stages/）：暂存 CMake
// 源 → 翻译 MSVC 标志 → 编译 kernel →（AOT 模式）编译 AOT → CMake 配置/构建 →
// 资源打包 → 打包产物。本文件负责「调度阶段」：原生轨、Dart 轨、资源轨三条互不
// 依赖的流水线并行执行，产物组装阶段汇合三轨结果。调度分组由 build_schedule.dart
// 的 planSchedule 决定；各阶段具体逻辑分散在 stages/ 下的 [BuildStage] 实现里，
// 便于单独理解与测试。流水线结束时打印每阶段耗时与总用时（含并行相对串行的
// 节省），便于定位编译瓶颈。

import 'dart:async';
import 'dart:io';

import '../io/fs_utils.dart';
import '../logger.dart';
import '../process_runner.dart';
import 'build_context.dart';
import 'build_schedule.dart';
import 'native_dll.dart' as dll;
import 'stage_timing.dart';
import 'stages/aot_compile_stage.dart';
import 'stages/assemble_bundle_stage.dart';
import 'stages/build_stage.dart';
import 'stages/cmake_build_stage.dart';
import 'stages/compile_kernel_stage.dart';
import 'stages/flutter_assets_stage.dart';
import 'stages/source_staging_stage.dart';
import 'stages/translate_flags_stage.dart';
import 'wine_wrapper.dart';

// 计时数据与调度类型现居独立文件；通过再导出保持既有导入路径可用。
export 'build_schedule.dart' show BuildSchedule, StageLane, planSchedule;
export 'stage_timing.dart' show StageTiming, formatDuration;

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

  /// 构建阶段清单（面向 Windows 目标，按固定顺序）。
  ///
  /// 顺序必须是 [planSchedule] 约定的 7 项：暂存→翻译→kernel→AOT→CMake→
  /// 资源打包→组装（索引 0..6）。[run] 把前三条 lane（原生/Dart/资源）并行，
  /// 组装为汇合点。
  List<BuildStage> _stages() => <BuildStage>[
        SourceStagingStage(logger: _log, runner: _runner),
        TranslateFlagsStage(logger: _log, runner: _runner),
        CompileKernelStage(logger: _log, runner: _runner),
        AotCompileStage(logger: _log, runner: _runner),
        CMakeBuildStage(logger: _log, runner: _runner),
        FlutterAssetsStage(logger: _log, runner: _runner),
        AssembleBundleStage(logger: _log, runner: _runner),
      ];

  /// 运行完整流水线。跳过 `shouldRun` 为 false 的阶段（如 debug 模式无 AOT）。
  ///
  /// 调度由 [planSchedule] 给出：并行时原生轨（暂存→翻译→CMake）、Dart 轨
  /// （kernel→AOT）、资源轨（copy_flutter_bundle）三条 lane 并行，随后串行执行
  /// 汇合的组装阶段。结束时打印计时报告。
  Future<void> run(BuildContext ctx) async {
    // 并行前的公共准备：
    //   1. intermediates 目录原由暂存阶段创建，但 kernel 阶段也会写入其中，
    //      并行时 kernel 可能先于暂存启动，故提前创建。
    //   2. wine 包装脚本被 AOT（gen_snapshot 走 wine）与 CMake 阶段共用；提前
    //      落盘一次，配合 materialize 的原子写，避免并行竞争。
    await Directory(ctx.intermediatesDir).create(recursive: true);
    await WineWrapper(toolchain: ctx.toolchain, buildRoot: ctx.buildRoot)
        .materialize();

    final schedule = planSchedule(
      _stages(),
      parallel: ctx.parallel,
      aggressive: ctx.aggressiveParallel,
    );

    // 为每个阶段建一个 Completer（按阶段名）。带 [StageLane.gateOnStageName] 的
    // lane 在启动前 await 前驱阶段的 Completer；前驱阶段结束时（无论成功/跳过/
    // 失败）在 finally 里 complete，避免前驱失败导致下游 gate 永久挂起。
    final gates = <String, Completer<void>>{};
    for (final lane in <StageLane>[
      ...schedule.concurrent,
      ...schedule.serial,
    ]) {
      for (final stage in lane.stages) {
        gates.putIfAbsent(stage.name, () => Completer<void>());
      }
    }

    final timings = <StageTiming>[];
    final wall = Stopwatch()..start();

    if (schedule.concurrent.isNotEmpty) {
      // 多 lane 并行。Future.wait 默认 eagerError=false：等所有 lane 收尾后
      // 再报首个错误，不会留下半死的子进程。资源轨会先等 kernel（gate）。
      await Future.wait<void>(schedule.concurrent
          .map((lane) => _runLane(lane, ctx, timings, gates)));
    }
    // 汇合阶段（组装）依赖并行组的全部产物，在所有并行 lane 完成后依序串行。
    for (final lane in schedule.serial) {
      await _runLane(lane, ctx, timings, gates);
    }

    wall.stop();
    _log.success('Windows build complete: ${ctx.finalExe}');
    _reportTimings(timings, wall.elapsed, ctx.parallel);
  }

  /// 运行一条 lane：先等其门控阶段（如有），再按序跑本 lane 阶段（过滤
  /// `shouldRun`），逐个记录耗时。每个阶段结束后都释放以其为门的 gate。
  Future<void> _runLane(
    StageLane lane,
    BuildContext ctx,
    List<StageTiming> timings,
    Map<String, Completer<void>> gates,
  ) async {
    final gateName = lane.gateOnStageName;
    if (gateName != null) {
      await gates[gateName]?.future;
    }
    for (final stage in lane.stages) {
      final sw = Stopwatch()..start();
      try {
        if (stage.shouldRun(ctx)) {
          await _log.group(
              '[${lane.label}] ${stage.name}', () => stage.run(ctx));
          sw.stop();
          timings.add(StageTiming(
              lane: lane.label, name: stage.name, elapsed: sw.elapsed));
        }
      } finally {
        // 无论成功 / 跳过 / 失败，都放行依赖本阶段的 gated lane。
        final gate = gates[stage.name];
        if (gate != null && !gate.isCompleted) gate.complete();
      }
    }
  }

  /// 打印计时报告：每阶段耗时 + 总用时。并行模式下额外给出「各阶段串行之和 vs
  /// 并行实际」的节省，直观体现并行收益。
  void _reportTimings(List<StageTiming> timings, Duration wall, bool parallel) {
    final pairs = <String, String>{};
    var serialSum = Duration.zero;
    for (final t in timings) {
      pairs['[${t.lane}] ${t.name}'] = formatDuration(t.elapsed);
      serialSum += t.elapsed;
    }
    _log.info('');
    _log.step('构建计时 · 总用时 ${formatDuration(wall)}'
        '${parallel ? '（并行）' : '（顺序）'}');
    _log.kv(pairs);
    if (parallel) {
      final saved = serialSum - wall;
      final pct = serialSum.inMilliseconds > 0
          ? (saved.inMilliseconds / serialSum.inMilliseconds * 100)
              .toStringAsFixed(0)
          : '0';
      _log.info('  各阶段串行之和 ${formatDuration(serialSum)}，'
          '并行实际 ${formatDuration(wall)}，'
          '节省约 ${formatDuration(saved)}（${pct}%）');
    }
  }

  /// 从 CMake 文件内容里提取被引用的 `.dll` 字面路径。保留为静态方法以维持
  /// 既有公共 API（委托给 `native_dll.dart` 的 `referencedDllPaths`）。
  static List<String> referencedDllPaths(String cmakeContent) =>
      dll.referencedDllPaths(cmakeContent);
}
