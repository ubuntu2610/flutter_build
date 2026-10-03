// 流水线调度模型：把固定的 7 阶段清单按依赖切成「可并行的 lane 组 + 汇合串行组」。
//
// 依赖关系（面向 Windows 目标）：
//   原生轨  暂存 → 翻译标志 → CMake 构建   （读 windows/，产出 exe / 插件 DLL）
//   Dart 轨 kernel 编译 → AOT 编译          （读 Dart 源码，产出 app.dill / app.so）
//   资源轨  copy_flutter_bundle             （纯 host Dart，独立于上面两轨）
//   汇合    组装 bundle                       （依赖前三轨全部产物）
//
// 三条前置 lane 文件集互不重叠，可并行；组装阶段依赖三者，必须在它们全部完成后
// 串行执行。把调度决策从 [BuildPipeline] 的执行逻辑里抽成纯函数，便于脱离真实
// 构建单测分组与顺序。

import 'stages/build_stage.dart';

/// 一条 lane：人类可读标签 + 按序执行的阶段序列。
class StageLane {
  const StageLane(this.label, this.stages);

  /// lane 标签，用于日志分组前缀（`native` / `dart` / `assets` / `join`）。
  final String label;

  /// 本 lane 内按序执行的阶段（同一 lane 内串行）。
  final List<BuildStage> stages;
}

/// 一次流水线的调度计划。
class BuildSchedule {
  const BuildSchedule({required this.concurrent, required this.serial});

  /// 可并行执行的 lane 组（彼此无依赖）。
  final List<StageLane> concurrent;

  /// 在 [concurrent] 全部完成后，按序串行执行的 lane 组。
  final List<StageLane> serial;
}

/// Windows 流水线的固定阶段索引（对应 [BuildPipeline._stages] 的顺序）。
const int stagingIdx = 0;
const int translateIdx = 1;
const int kernelIdx = 2;
const int aotIdx = 3;
const int cmakeIdx = 4;
const int assetsIdx = 5;
const int assembleIdx = 6;

/// Windows 流水线固定阶段数。
const int kStageCount = 7;

/// 依据 [parallel] 把有序阶段清单切成调度计划。
///
/// [stages] 必须是 [BuildPipeline._stages] 约定的固定 7 项顺序；不符则抛
/// [ArgumentError]（避免静默错位分组）。
BuildSchedule planSchedule(
  List<BuildStage> stages, {
  required bool parallel,
}) {
  if (stages.length != kStageCount) {
    throw ArgumentError.value(
      stages.length,
      'stages',
      'Windows 流水线固定 $kStageCount 个阶段',
    );
  }
  if (parallel) {
    return BuildSchedule(
      concurrent: <StageLane>[
        StageLane('native', [stages[stagingIdx], stages[translateIdx], stages[cmakeIdx]]),
        StageLane('dart', [stages[kernelIdx], stages[aotIdx]]),
        StageLane('assets', [stages[assetsIdx]]),
      ],
      serial: <StageLane>[
        StageLane('join', [stages[assembleIdx]]),
      ],
    );
  }
  // 顺序回退：保持暂存→翻译→kernel→AOT→CMake→资源→组装的原始次序，
  // concurrent 置空、全部落到 serial 依序执行。
  return BuildSchedule(
    concurrent: const <StageLane>[],
    serial: <StageLane>[
      StageLane('native', [stages[stagingIdx], stages[translateIdx]]),
      StageLane('dart', [stages[kernelIdx], stages[aotIdx]]),
      StageLane('native', [stages[cmakeIdx]]),
      StageLane('assets', [stages[assetsIdx]]),
      StageLane('join', [stages[assembleIdx]]),
    ],
  );
}
