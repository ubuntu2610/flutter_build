// 阶段计时记录与时长格式化（纯数据 + 纯函数，便于单测）。

/// 单个阶段的耗时记录（用于流水线结束的计时报告）。
///
/// [lane] 标明阶段属于哪条流水线（`native` / `dart` / `assets` / `join`），并行
/// 模式下同一 lane 内的阶段串行、不同 lane 之间重叠；[elapsed] 是该阶段自身的
/// wall 耗时。
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

/// 把 [Duration] 格式化为易读字符串：
///   < 1s   → `NNNms`
///   < 60s  → `N.Ns`
///   ≥ 60s  → `Mm S.Ss`
String formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  final secs = ms / 1000;
  if (secs < 60) return '${secs.toStringAsFixed(1)}s';
  final m = ms ~/ 60000;
  final s = ((ms % 60000) / 1000).toStringAsFixed(1);
  return '${m}m ${s}s';
}
