// 构建阶段判定测试：AOT 阶段仅在 release/profile 运行；其余阶段各模式均运行；
// 阶段名符合预期。

import 'package:flutter_build/src/build/build_context.dart';
import 'package:flutter_build/src/build/stages/aot_compile_stage.dart';
import 'package:flutter_build/src/build/stages/assemble_bundle_stage.dart';
import 'package:flutter_build/src/build/stages/build_stage.dart';
import 'package:flutter_build/src/build/stages/cmake_build_stage.dart';
import 'package:flutter_build/src/build/stages/compile_kernel_stage.dart';
import 'package:flutter_build/src/build/stages/source_staging_stage.dart';
import 'package:flutter_build/src/build/stages/translate_flags_stage.dart';
import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:test/test.dart';

import 'support/stubs.dart';

void main() {
  BuildContext ctx(WindowsFlavor mode) =>
      stubContext(mode: mode, buildRoot: '/build');

  group('AotCompileStage.shouldRun', () {
    test('release / profile 运行 AOT', () {
      expect(AotCompileStage().shouldRun(ctx(WindowsFlavor.release)), isTrue);
      expect(AotCompileStage().shouldRun(ctx(WindowsFlavor.profile)), isTrue);
    });

    test('debug 跳过 AOT', () {
      expect(AotCompileStage().shouldRun(ctx(WindowsFlavor.debug)), isFalse);
    });
  });

  group('非 AOT 阶段各模式均运行', () {
    final stages = <BuildStage>[
      SourceStagingStage(),
      TranslateFlagsStage(),
      CompileKernelStage(),
      CMakeBuildStage(),
      AssembleBundleStage(),
    ];
    for (final mode in WindowsFlavor.values) {
      for (final s in stages) {
        test('${s.name} @ ${mode.cliName}', () {
          expect(s.shouldRun(ctx(mode)), isTrue);
        });
      }
    }
  });

  test('阶段名符合预期', () {
    expect(SourceStagingStage().name, 'stage Windows CMake sources');
    expect(TranslateFlagsStage().name, 'translate MSVC flags');
    expect(CompileKernelStage().name, 'compile Dart kernel');
    expect(AotCompileStage().name, 'AOT compile');
    expect(CMakeBuildStage().name, 'configure & build with CMake');
    expect(AssembleBundleStage().name, 'assemble Windows bundle');
  });
}
