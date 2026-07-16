// 交叉构建流水线编排。
//
// BuildPipeline 把一次 Windows 交叉编译拆成若干个阶段：暂存 CMake 源 →
// 翻译 MSVC 标志 → 编译 kernel →（AOT 模式）编译 AOT → CMake 配置/构建 →
// 打包产物。每个阶段消费 [BuildContext] 派生出的路径，并把产出留给下一阶段。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine_artifacts.dart';
import '../logger.dart';
import '../process_runner.dart';
import 'build_context.dart';
import 'msvc_flag_translator.dart';
import 'wine_wrapper.dart';

/// 编排 Windows 交叉构建的整个流程。
class BuildPipeline {
  BuildPipeline({
    Logger? logger,
    ProcessRunner? runner,
  })  : _log = logger ?? Logger.instance,
        _runner = runner ?? ProcessRunner(logger: logger ?? Logger.instance);

  final Logger _log;
  final ProcessRunner _runner;

  /// 运行完整流水线。
  Future<void> run(BuildContext ctx) async {
    await _log.group('Stage 1/6 · stage Windows CMake sources',
        () => _stageSources(ctx));
    await _log.group('Stage 2/6 · translate MSVC flags',
        () => _translateFlags(ctx));
    await _log.group('Stage 3/6 · compile Dart kernel',
        () => _compileKernel(ctx));

    if (ctx.mode.isAot) {
      await _log.group('Stage 4/6 · AOT compile', () => _aotCompile(ctx));
    }

    await _log.group('Stage 5/6 · configure & build with CMake',
        () => _buildWithCMake(ctx));
    await _log.group('Stage 6/6 · assemble Windows bundle',
        () => _assembleBundle(ctx));

    _log.success('Windows build complete: ${ctx.finalExe}');
  }

  /// 把工程里的 `windows/` 脚手架复制到暂存目录，作为改写对象。
  Future<void> _stageSources(BuildContext ctx) async {
    await Directory(ctx.intermediatesDir).create(recursive: true);
    await Directory(ctx.windowsStageDir).create(recursive: true);
    await _copyTree(ctx.project.windowsDir, ctx.windowsStageDir);
  }

  /// 翻译暂存目录里所有 CMakeLists.txt 的 MSVC 标志。
  Future<void> _translateFlags(BuildContext ctx) async {
    await const MsvcFlagTranslator().transformTree(ctx.windowsStageDir);
  }

  /// 用 frontend_server 把 Dart 入口编译成 kernel `.dill`。
  Future<void> _compileKernel(BuildContext ctx) async {
    final args = <String>[
      ctx.env.frontendServerSnapshot,
      '--sdk-root',
      ctx.env.patchedSdkPath(product: ctx.mode.isProduct),
      '--target=flutter',
      if (ctx.treeShakeIcons) '--tree-shake-icons',
      for (final define in ctx.dartDefines) '--define=$define',
      '-o',
      ctx.kernelDill,
      ctx.project.entryPoint,
    ];
    await _runner.run(ctx.env.dartExecutable, args, tag: 'frontend_server');
  }

  /// 用 gen_snapshot 把 kernel 编译为 AOT elf（release / profile）。
  Future<void> _aotCompile(BuildContext ctx) async {
    final wine = WineWrapper(toolchain: ctx.toolchain, buildRoot: ctx.buildRoot);
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
    await _runner.run(
      wine.scriptPath,
      <String>[ctx.artifacts.genSnapshotExe(ctx.mode), ...args.skip(1)],
      tag: 'gen_snapshot',
      environment: wine.environment(),
    );
  }

  /// 配置并构建 CMake 工程（用 LLVM-MinGW 工具链）。
  Future<void> _buildWithCMake(BuildContext ctx) async {
    final wine = WineWrapper(toolchain: ctx.toolchain, buildRoot: ctx.buildRoot);
    await wine.materialize();
    await Directory(ctx.cmakeBuildDir).create(recursive: true);

    final configureArgs = <String>[
      '-S',
      ctx.windowsStageDir,
      '-B',
      ctx.cmakeBuildDir,
      '-G',
      'Ninja',
      '-DCMAKE_BUILD_TYPE=${ctx.mode.name.toUpperCase()}',
      '-DCMAKE_C_COMPILER=${ctx.toolchain.clang}',
      '-DCMAKE_CXX_COMPILER=${ctx.toolchain.clangxx}',
      '-DCMAKE_RC_COMPILER=${ctx.toolchain.llvmRc}',
      '-DCMAKE_MAKE_PROGRAM=${ctx.toolchain.ninjaExecutable}',
    ];
    await _runner.run(
      ctx.toolchain.cmakeExecutable,
      configureArgs,
      tag: 'cmake',
      environment: wine.environment(),
    );

    await _runner.run(
      ctx.toolchain.cmakeExecutable,
      <String>['--build', ctx.cmakeBuildDir],
      tag: 'cmake',
      environment: wine.environment(),
    );
  }

  /// 把构建产物（exe / dll / icu / assets 目录）组装到最终输出目录。
  Future<void> _assembleBundle(BuildContext ctx) async {
    final outDir = p.dirname(ctx.finalExe);
    await Directory(outDir).create(recursive: true);
    await Directory(ctx.flutterAssetsDir).create(recursive: true);

    final builtExe = p.join(ctx.cmakeBuildDir, '${ctx.project.appName}.exe');
    if (File(builtExe).existsSync()) {
      await File(builtExe).copy(ctx.finalExe);
    }
    for (final src in <String>[
      ctx.artifacts.flutterWindowsDll,
      ctx.artifacts.icudtl,
    ]) {
      if (File(src).existsSync()) {
        await File(src).copy(p.join(outDir, p.basename(src)));
      }
    }
  }

  /// 递归复制目录树。源不存在时静默跳过。
  Future<void> _copyTree(String src, String dst) async {
    final dir = Directory(src);
    if (!dir.existsSync()) return;
    await Directory(dst).create(recursive: true);

    for (final entity in dir.listSync(recursive: false)) {
      final target = p.join(dst, p.basename(entity.path));
      if (entity is Directory) {
        await _copyTree(entity.path, target);
      } else if (entity is File) {
        await File(entity.path).copy(target);
      }
    }
  }
}
