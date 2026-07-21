// 阶段 2：翻译暂存目录里所有 CMakeLists.txt 的 MSVC 专属标志。
//
// 实际转换逻辑见 [MsvcFlagTranslator]；本阶段只是把它接入流水线。

import '../build_context.dart';
import '../msvc_flag_translator.dart';
import 'build_stage.dart';

/// 把暂存 CMake 源里的 MSVC 标志翻译为 GCC/Clang 等价物。
class TranslateFlagsStage extends BuildStage {
  TranslateFlagsStage({super.logger, super.runner});

  @override
  String get name => 'translate MSVC flags';

  @override
  Future<void> run(BuildContext ctx) async {
    await MsvcFlagTranslator(logger: log).transformTree(ctx.windowsStageDir);
  }
}
