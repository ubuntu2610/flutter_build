// Windows 交叉构建流水线的阶段抽象。
//
// 把原先 BuildPipeline 里一个个私有方法（stage sources / translate flags /
// compile kernel / AOT / CMake / assemble）提升为独立的 [BuildStage] 实现，
// 每个阶段是一个可单独理解、单独测试的单元。BuildPipeline 退化为「按序运行一
// 组阶段」的薄编排器。
//
// 注意：这是 Windows 流水线的**内部模块化**拆分，不是跨平台抽象层——阶段清单
// 目前固定面向 Windows 目标。

import '../../logger.dart';
import '../../process_runner.dart';
import '../build_context.dart';

/// 一次交叉构建流水线中的单个阶段。
///
/// 子类通过构造函数注入 [log] / [runner]（缺省回退到全局单例 / 新建实例），
/// 在 [run] 中消费 [BuildContext] 派生出的路径并产出交给后续阶段的中间物。
abstract class BuildStage {
  BuildStage({Logger? logger, ProcessRunner? runner})
      : log = logger ?? Logger.instance,
        runner = runner ?? ProcessRunner(logger: logger ?? Logger.instance);

  /// 日志器。
  final Logger log;

  /// 子进程运行器。
  final ProcessRunner runner;

  /// 人类可读的阶段名，用于日志分组标题（如 `compile Dart kernel`）。
  String get name;

  /// 是否在当前上下文下运行本阶段。默认始终运行；例如 AOT 阶段仅在
  /// `ctx.mode.isAot` 时返回 true。
  bool shouldRun(BuildContext ctx) => true;

  /// 执行本阶段。
  Future<void> run(BuildContext ctx);
}
