// 交叉构建流水线编排。
//
// BuildPipeline 把一次 Windows 交叉编译拆成若干阶段（见 stages/）：暂存 CMake
// 源 → 翻译 MSVC 标志 → 编译 kernel →（AOT 模式）编译 AOT → CMake 配置/构建 →
// 打包产物。本文件负责「调度阶段」：两条互不依赖的流水线（原生轨与 Dart 轨）
// 并行执行，产物组装阶段汇合两轨结果。各阶段具体逻辑分散在 stages/ 下的
// [BuildStage] 实现里，便于单独理解与测试。流水线结束时打印每阶段耗时与总用时
// （含并行相对串行的节省），便于定位编译瓶颈。

import 'dart:io';

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
import 'wine_wrapper.dart';

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

/// 单个阶段的耗时记录（用于流水线结束的计时报告）。
///
/// [lane] 标明阶段属于哪条流水线（`native` / `dart` / `join`），并行模式下同一
/// lane 内的阶段串行、不同 lane 之间重叠；[elapsed] 是该阶段自身的 wall 耗时。
class StageTiming {
  StageTiming({
    required this.lane,
    required this.name,
    required this.elapsed,
  });

  final String lane;
  final String name;
  final Duration elapsed;
}

/// 编排 Windows 交叉构建的整个流程。
class BuildPipeline {
  BuildPipeline({
    Logger? logger,
    ProcessRunner? runner,
  })  : _log = logger ?? Logger.instance,
        _runner = runner ?? ProcessRunner(logger: logger ?? Logger.instance);

  final Logger _log;
  final ProcessRunner _runner;

  /// 构建阶段清单（面向 Windows 目标，按原始执行顺序）。
  ///
  /// 此清单保持与历史一致：暂存→翻译→kernel→AOT→CMake→组装。[run] 从中按
  /// 依赖重组为两条 lane：原生轨 = 暂存 + 翻译 + CMake（all[0,1,4]），Dart 轨 =
  /// kernel + AOT（all[2,3]），组装（all[5]）为汇合点。两轨文件集互不重叠，
  /// 故可并行。
  List<BuildStage> _stages() => <BuildStage>[
        SourceStagingStage(logger: _log, runner: _runner),
        TranslateFlagsStage(logger: _log, runner: _runner),
        CompileKernelStage(logger: _log, runner: _runner),
        AotCompileStage(logger: _log, runner: _runner),
        CMakeBuildStage(logger: _log, runner: _runner),
        AssembleBundleStage(logger: _log, runner: _runner),
      ];

  /// 运行完整流水线。跳过 `shouldRun` 为 false 的阶段（如 debug 模式无 AOT）。
  ///
  /// 原生轨（源码暂存 → 标志翻译 → CMake 构建）与 Dart 轨（kernel 编译 →
  /// AOT 编译）互不依赖，并行执行以缩短 wall-clock；产物组装阶段依赖两轨结果，
  /// 置于两轨完成之后。结束时打印计时报告。
  Future<void> run(BuildContext ctx) async {
    final all = _stages();
    final staging = all[0];
    final translate = all[1];
    final kernel = all[2];
    final aot = all[3];
    final cmake = all[4];
    final assemble = all[5];

    // 两轨并行前的公共准备：
    //   1. intermediates 目录原由暂存阶段创建，但 kernel 阶段也会写入其中，
    //      并行时 kernel 可能先于暂存启动，故提前创建。
    //   2. wine 包装脚本被 AOT（gen_snapshot 走 wine）与 CMake 阶段共用；提前
    //      落盘一次，配合 materialize 的原子写，避免并行竞争。
    await Directory(ctx.intermediatesDir).create(recursive: true);
    await WineWrapper(toolchain: ctx.toolchain, buildRoot: ctx.buildRoot)
        .materialize();

    final timings = <StageTiming>[];
    final wall = Stopwatch()..start();

    if (ctx.parallel) {
      // 原生轨 ∥ Dart 轨。Future.wait 在任一轨抛错时以首个错误失败；另一轨的
      // 子进程随之结束，构建整体失败（快速失败语义）。
      await Future.wait<void>([
        _runLane('native', [staging, translate, cmake], ctx, timings),
        _runLane('dart', [kernel, aot], ctx, timings),
      ]);
    } else {
      // 顺序回退：保持既有次序暂存→翻译→kernel→AOT→CMake→组装。
      await _runLane('native', [staging, translate], ctx, timings);
      await _runLane('dart', [kernel, aot], ctx, timings);
      await _runLane('native', [cmake], ctx, timings);
    }
    // 组装阶段依赖两轨产物，串行在汇合点之后。
    await _runLane('join', [assemble], ctx, timings);

    wall.stop();
    _log.success('Windows build complete: ${ctx.finalExe}');
    _reportTimings(timings, wall.elapsed, ctx.parallel);
  }

  /// 顺序运行一条 lane 内的阶段：过滤 `shouldRun`，逐个执行并记录耗时。
  Future<void> _runLane(
    String lane,
    List<BuildStage> stages,
    BuildContext ctx,
    List<StageTiming> timings,
  ) async {
    for (final stage in stages) {
      if (!stage.shouldRun(ctx)) continue;
      final sw = Stopwatch()..start();
      await _log.group('[$lane] ${stage.name}', () => stage.run(ctx));
      sw.stop();
      timings.add(
          StageTiming(lane: lane, name: stage.name, elapsed: sw.elapsed));
    }
  }

  /// 打印计时报告：每阶段耗时 + 总用时。并行模式下额外给出「各阶段串行之和 vs
  /// 并行实际」的节省，直观体现并行收益。
  void _reportTimings(
      List<StageTiming> timings, Duration wall, bool parallel) {
    final pairs = <String, String>{};
    var serialSum = Duration.zero;
    for (final t in timings) {
      pairs['[${t.lane}] ${t.name}'] = _fmtDuration(t.elapsed);
      serialSum += t.elapsed;
    }
    _log.info('');
    _log.step('构建计时 · 总用时 ${_fmtDuration(wall)}'
        '${parallel ? '（并行）' : '（顺序）'}');
    _log.kv(pairs);
    if (parallel) {
      final saved = serialSum - wall;
      final pct = serialSum.inMilliseconds > 0
          ? (saved.inMilliseconds / serialSum.inMilliseconds * 100)
              .toStringAsFixed(0)
          : '0';
      _log.info('  各阶段串行之和 ${_fmtDuration(serialSum)}，'
          '并行实际 ${_fmtDuration(wall)}，'
          '节省约 ${_fmtDuration(saved)}（${pct}%）');
    }
  }

  /// 把 [Duration] 格式化为易读字符串（ms / s / m·s 三档）。
  String _fmtDuration(Duration d) {
    final ms = d.inMilliseconds;
    if (ms < 1000) return '${ms}ms';
    final secs = ms / 1000;
    if (secs < 60) return '${secs.toStringAsFixed(1)}s';
    final m = ms ~/ 60000;
    final s = ((ms % 60000) / 1000).toStringAsFixed(1);
    return '${m}m ${s}s';
  }

  /// 从 CMake 文件内容里提取被引用的 `.dll` 字面路径。保留为静态方法以维持
  /// 既有公共 API（委托给 `native_dll.dart` 的 `referencedDllPaths`）。
  static List<String> referencedDllPaths(String cmakeContent) =>
      dll.referencedDllPaths(cmakeContent);
}
