// 交叉构建流水线编排。
//
// BuildPipeline 把一次 Windows 交叉编译拆成若干个阶段：暂存 CMake 源 →
// 翻译 MSVC 标志 → 编译 kernel →（AOT 模式）编译 AOT → CMake 配置/构建 →
// 打包产物。每个阶段消费 [BuildContext] 派生出的路径，并把产出留给下一阶段。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine_artifacts.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../process_runner.dart';
import 'build_context.dart';
import 'debug_instrumentation.dart';
import 'flutter_ephemeral.dart';
import 'host_env.dart';
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
    await _log.group(
        'Stage 1/6 · stage Windows CMake sources', () => _stageSources(ctx));
    await _log.group(
        'Stage 2/6 · translate MSVC flags', () => _translateFlags(ctx));
    await _log.group(
        'Stage 3/6 · compile Dart kernel', () => _compileKernel(ctx));

    if (ctx.mode.isAot) {
      await _log.group('Stage 4/6 · AOT compile', () => _aotCompile(ctx));
    }

    await _log.group(
        'Stage 5/6 · configure & build with CMake', () => _buildWithCMake(ctx));
    await _log.group(
        'Stage 6/6 · assemble Windows bundle', () => _assembleBundle(ctx));

    _log.success('Windows build complete: ${ctx.finalExe}');
  }

  /// 把工程里的 `windows/` 脚手架复制到暂存目录，作为改写对象。
  Future<void> _stageSources(BuildContext ctx) async {
    await Directory(ctx.intermediatesDir).create(recursive: true);
    await Directory(ctx.windowsStageDir).create(recursive: true);
    await _copyTree(ctx.project.windowsDir, ctx.windowsStageDir);
    await _generateFlutterEphemeral(ctx);
    await _normalizeResourceScripts(ctx);
    if (ctx.debugConsole) await _instrumentRunner(ctx);
  }

  /// 给暂存的 runner/main.cpp 注入调试信息（始终开控制台 + 启动失败弹窗）。
  /// 仅在 --debug-console 时调用，不影响正常发布构建。
  Future<void> _instrumentRunner(BuildContext ctx) async {
    final mainCpp = File(p.join(ctx.windowsStageDir, 'runner', 'main.cpp'));
    if (!mainCpp.existsSync()) {
      _log.debug('未找到 runner/main.cpp，跳过调试注入。');
      return;
    }
    final patched = instrumentRunnerMain(await mainCpp.readAsString());
    await mainCpp.writeAsString(patched);
    _log.info('已注入调试信息（默认开启，--no-debug-console 可关）：'
        '从 PowerShell/cmd 运行可看到引擎日志，启动失败会弹 MessageBox。');
  }

  /// 归一化暂存目录里所有 `.rc` 资源脚本中的路径分隔符：把转义反斜杠
  /// `\\` 换成 `/`。llvm-rc 在 Linux 上不把 `\` 当路径分隔符，导致图标等
  /// 资源文件（如 `resources\\app_icon.ico`）找不到；`/` 在 Windows/Linux 下
  /// 均可用。
  Future<void> _normalizeResourceScripts(BuildContext ctx) async {
    final dir = Directory(ctx.windowsStageDir);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != '.rc') continue;
      final content = await entity.readAsString();
      if (!content.contains(r'\\')) continue;
      await entity.writeAsString(content.replaceAll(r'\\', '/'));
    }
  }

  /// CMAKE_SYSTEM_NAME 只在**干净配置**时生效。若 cmake_build 里存在此前以非
  /// Windows（如本机 Linux）模式配置的旧缓存，或上次配置未走完留下的
  /// 半成品缓存，直接重配都不会正确切换到交叉模式（会继续报 RPATH 等错）。
  /// 用两个信号判定“健康的 Windows 交叉缓存”：
  ///   1. CMakeCache.txt 里 CMAKE_SYSTEM_NAME=Windows；
  ///   2. build.ninja 存在（只有 configure+generate 完整成功才会生成）。
  /// 不满足则删除 CMakeCache.txt 与 CMakeFiles/ 强制干净重配；满足则保留，
  /// 维持增量构建。
  Future<void> _ensureCleanCrossCache(BuildContext ctx) async {
    final cache = File(p.join(ctx.cmakeBuildDir, 'CMakeCache.txt'));
    if (!cache.existsSync()) return;
    final content = await cache.readAsString();
    final isWindowsCross = RegExp(
      r'^CMAKE_SYSTEM_NAME[^=\n]*=\s*Windows\s*$',
      multiLine: true,
    ).hasMatch(content);
    final generated =
        File(p.join(ctx.cmakeBuildDir, 'build.ninja')).existsSync();
    if (isWindowsCross && generated) return;
    _log.debug('清理不完整或非 Windows 交叉的 CMake 缓存后重新配置。');
    await cache.delete();
    final cmakeFiles = Directory(p.join(ctx.cmakeBuildDir, 'CMakeFiles'));
    if (cmakeFiles.existsSync()) await cmakeFiles.delete(recursive: true);
  }

  /// 生成 `flutter/ephemeral/`：铺入嵌入器文件 + 写 generated_config.cmake +
  /// 中和 flutter_assemble。正常由 `flutter build windows` 完成，交叉构建下必
  /// 须自行生成，否则 flutter/CMakeLists.txt 会因找不到 generated_config.cmake
  /// 而配置失败。
  Future<void> _generateFlutterEphemeral(BuildContext ctx) async {
    final stagedFlutterDir = p.join(ctx.windowsStageDir, 'flutter');
    final ephemeralDir = p.join(stagedFlutterDir, 'ephemeral');
    await Directory(ephemeralDir).create(recursive: true);

    final art = ctx.artifacts;
    // 嵌入器动态库 + 导入库。
    await _copyFileIfExists(
        art.flutterWindowsDll, p.join(ephemeralDir, 'flutter_windows.dll'));
    await _copyFileIfExists(art.flutterWindowsImportLib,
        p.join(ephemeralDir, 'flutter_windows.dll.lib'));
    // 嵌入器头文件。
    for (final h in kEmbedderHeaders) {
      await _copyFileIfExists(
          p.join(art.embedderDir, h), p.join(ephemeralDir, h));
    }
    // C++ 客户端包装层（递归）。
    await _copyTree(
        art.cppClientWrapperDir, p.join(ephemeralDir, 'cpp_client_wrapper'));
    // icudtl.dat（兼容每平台 / 共享两种布局）。
    await _copyFileIfExists(art.icudtl, p.join(ephemeralDir, 'icudtl.dat'));

    // generated_config.cmake。
    final version = parseFlutterVersion(ctx.project.versionString);
    await File(p.join(ephemeralDir, 'generated_config.cmake')).writeAsString(
      renderGeneratedConfigCmake(
        flutterRoot: ctx.env.sdkRoot,
        projectDir: ctx.project.root,
        version: version,
      ),
    );

    // 中和 flutter/CMakeLists.txt 里依赖 tool_backend.bat 的 flutter_assemble。
    final flutterCmake = File(p.join(stagedFlutterDir, 'CMakeLists.txt'));
    if (flutterCmake.existsSync()) {
      final original = await flutterCmake.readAsString();
      final patched = neutralizeFlutterAssemble(original);
      if (patched == original) {
        _log.debug('flutter/CMakeLists.txt 未找到 tool backend 标记，'
            '跳过 flutter_assemble 中和（可能是非标准模板）。');
      } else {
        await flutterCmake.writeAsString(patched);
      }
    }
  }

  /// 翻译暂存目录里所有 CMakeLists.txt 的 MSVC 标志。
  Future<void> _translateFlags(BuildContext ctx) async {
    await const MsvcFlagTranslator().transformTree(ctx.windowsStageDir);
  }

  /// 用 frontend_server 把 Dart 入口编译成 kernel `.dill`。
  Future<void> _compileKernel(BuildContext ctx) async {
    // 参数对齐 flutter_tools 的 KernelSnapshot 目标。现代引擎用的是标准
    // package:frontend_server AOT 快照：输出用 --output-dill（非旧版 -o），
    // 且不认 --tree-shake-icons——图标 tree-shaking 是资源打包阶段的独立
    // 步骤（由 IconTreeShaker 处理），不属于 frontend_server。
    if (ctx.treeShakeIcons) {
      _log.debug('note: icon tree-shaking 尚未在打包阶段实现，本次不生效。');
    }
    final args = <String>[
      ctx.env.frontendServerSnapshot,
      '--sdk-root',
      ctx.env.patchedSdkPath(product: ctx.mode.isProduct),
      '--target=flutter',
      '--no-print-incremental-dependencies',
      // 模式常量：决定 kReleaseMode / kProfileMode / kDebugMode。
      for (final define in ctx.mode.kernelModeDefines) '--define=$define',
      // debug 走 JIT，开启 asserts；AOT（release/profile）启用整程序转换，
      // 产出 gen_snapshot 可消费的 AOT kernel。
      if (!ctx.mode.isAot) '--enable-asserts',
      if (ctx.mode.isAot) ...['--aot', '--tfa'],
      // 用户自定义 --dart-define。
      for (final define in ctx.dartDefines) '--define=$define',
      '--packages',
      ctx.project.packageConfig,
      '--output-dill',
      ctx.kernelDill,
      ctx.project.entryPoint,
    ];
    // frontend_server_aot.dart.snapshot 是 AOT 快照，必须用 dartaotruntime
    // 运行；旧版 frontend_server.dart.snapshot 才用 dart。由 env 按快照类型
    // 自动选择正确的运行时，避免 exit 255。
    await _runner.run(ctx.env.frontendServerRuntime, args,
        tag: 'frontend_server');
  }

  /// 用 gen_snapshot 把 kernel 编译为 AOT elf（release / profile）。
  Future<void> _aotCompile(BuildContext ctx) async {
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
    await _runner.run(
      wine.scriptPath,
      <String>[ctx.artifacts.genSnapshotExe(ctx.mode), ...args.skip(1)],
      tag: 'gen_snapshot',
      environment: wine.environment(),
    );
  }

  /// 配置并构建 CMake 工程（用 LLVM-MinGW 工具链）。
  Future<void> _buildWithCMake(BuildContext ctx) async {
    final wine =
        WineWrapper(toolchain: ctx.toolchain, buildRoot: ctx.buildRoot);
    await wine.materialize();
    await Directory(ctx.cmakeBuildDir).create(recursive: true);
    await _ensureCleanCrossCache(ctx);

    final configureArgs = <String>[
      '-S',
      ctx.windowsStageDir,
      '-B',
      ctx.cmakeBuildDir,
      '-G',
      'Ninja',
      // 告知 CMake 这是面向 Windows 的交叉构建，否则它会当作本机 Linux
      // （ELF）处理，导致对可执行文件套用 RPATH 逻辑而报错，也会用错
      // .exe/.dll/导入库的命名与链接规则。必须在干净配置时设置（见
      // _ensureCleanCrossCache）。
      '-DCMAKE_SYSTEM_NAME=Windows',
      '-DCMAKE_SYSTEM_PROCESSOR=AMD64',
      // 让 CMake 的编译器检测只编译成静态库、不链接可执行文件。
      // 否则在干净配置时，因为下面给 EXE 加了 -municode，而检测用的
      // 测试程序只有 main（非 wWinMain），会报 `undefined symbol: wWinMain`。
      '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
      '-DCMAKE_BUILD_TYPE=${ctx.mode.name.toUpperCase()}',
      '-DCMAKE_C_COMPILER=${ctx.toolchain.clang}',
      '-DCMAKE_CXX_COMPILER=${ctx.toolchain.clangxx}',
      '-DCMAKE_RC_COMPILER=${ctx.toolchain.llvmRc}',
      // 资源编译器 llvm-rc 没有 clang 的 sysroot，需显式加 mingw include
      // 才能找到 winres.h 等系统头。
      '-DCMAKE_RC_FLAGS=-I ${ctx.toolchain.mingwSysrootInclude}',
      '-DCMAKE_MAKE_PROGRAM=${ctx.toolchain.ninjaExecutable}',
      // 强制指定全局链接标志，起到三个作用：
      // 1) 覆盖宿主（Flutter snap）经 env.sh 向 LDFLAGS 注入的
      //    -lepoxy/-lfontconfig 等 Linux 库；
      // 2) EXE 加 -municode：选用宽字符入口 CRT，匹配 Flutter runner 的
      //    wWinMain；否则 mingw 的 crtexewin 引用窄字符 WinMain 导致
      //    `undefined symbol: WinMain`；
      // 3) 全部加 -static：静态链接 LLVM-MinGW 的 C++ 运行时（libc++、
      //    libunwind 等），产物自包含。否则运行时会报缺失 libc++.dll /
      //    libunwind.dll（这两个 DLL 不在普通 Windows 上）。
      // 目标库由 CMake 工程经 target_link_libraries 指定，不依赖这些。
      '-DCMAKE_EXE_LINKER_FLAGS=-municode -static',
      '-DCMAKE_SHARED_LINKER_FLAGS=-static',
      '-DCMAKE_MODULE_LINKER_FLAGS=-static',
    ];
    // 用净化过的环境驱动 CMake：剥离宿主（如 Flutter snap）注入的
    // CFLAGS/CXXFLAGS/LDFLAGS 等，否则 -lepoxy/-lfontconfig 等 Linux 库会
    // 漏进面向 Windows 的交叉链接。配合 includeParentEnvironment=false，
    // 确保被剥离的变量不会再从父进程合并回来。
    final crossEnv = sanitizedCrossBuildEnv(
      Platform.environment,
      overrides: wine.environment(),
    );
    await _runner.run(
      ctx.toolchain.cmakeExecutable,
      configureArgs,
      tag: 'cmake',
      environment: crossEnv,
      includeParentEnvironment: false,
    );

    await _runner.run(
      ctx.toolchain.cmakeExecutable,
      <String>['--build', ctx.cmakeBuildDir],
      tag: 'cmake',
      environment: crossEnv,
      includeParentEnvironment: false,
    );
  }

  /// 把构建产物组装到最终输出目录，布局与 Windows 上 `flutter build` 一致：
  ///   <app>/
  ///     <app>.exe
  ///     flutter_windows.dll
  ///     data/
  ///       icudtl.dat
  ///       app.so            (release/profile)
  ///       flutter_assets/   (由 flutter assemble copy_flutter_bundle 生成)
  Future<void> _assembleBundle(BuildContext ctx) async {
    final outDir = p.dirname(ctx.finalExe);
    final dataDir = p.join(outDir, 'data');
    await Directory(outDir).create(recursive: true);
    await Directory(ctx.flutterAssetsDir).create(recursive: true);

    // runner 可执行文件：Ninja 会把它放在 cmake_build/runner/<name>.exe
    // （而非 cmake_build/ 根）。找不到则报错，避免谎报成功。
    final builtExe = _findBuiltExe(ctx);
    if (builtExe == null) {
      throw ArtifactException(
        '构建成功但未在 ${ctx.cmakeBuildDir} 下找到 '
        '${ctx.project.appName}.exe。',
      );
    }
    await builtExe.copy(ctx.finalExe);

    // 嵌入器动态库与 exe 同级；icu 放 data/。
    if (File(ctx.artifacts.flutterWindowsDll).existsSync()) {
      await File(ctx.artifacts.flutterWindowsDll)
          .copy(p.join(outDir, 'flutter_windows.dll'));
    }
    await Directory(dataDir).create(recursive: true);
    if (File(ctx.artifacts.icudtl).existsSync()) {
      await File(ctx.artifacts.icudtl).copy(p.join(dataDir, 'icudtl.dat'));
    }

    // AOT 库（release/profile）：引擎运行时从 data/app.so 加载。
    if (ctx.mode.isAot && File(ctx.appAotElf).existsSync()) {
      await File(ctx.appAotElf).copy(p.join(dataDir, 'app.so'));
    }

    // flutter_assets（AssetManifest / 字体 / NOTICES / shaders 等）。
    await _bundleFlutterAssets(ctx);

    // 安全网：生成后仍为空说明资源打包异常，明确告警。
    final assetsEmpty = Directory(ctx.flutterAssetsDir).listSync().isEmpty;
    if (assetsEmpty) {
      _log.warn('data/flutter_assets 仍为空：资源打包可能失败，'
          '应用在 Windows 上很可能无窗口/静默退出。');
      _log.warn('从 PowerShell 运行 exe 可看到引擎日志'
          '（调试信息默认已注入）。');
    }
  }

  /// 生成 flutter_assets（AssetManifest / 字体 / NOTICES / shaders 等）。
  ///
  /// 复用 flutter 自己的资源打包逻辑：`flutter assemble copy_flutter_bundle`。
  /// 该 target 只依赖 KernelSnapshot（不触发 gen_snapshot / 无需 Windows 二进制），
  /// 因此能在 Linux 上产出 flutter_assets，直接输出到 data/flutter_assets/。
  /// release/profile 不含 kernel_blob（用 app.so）；debug 会带 kernel_blob 及快照。
  Future<void> _bundleFlutterAssets(BuildContext ctx) async {
    _log.info('  生成 flutter_assets（flutter assemble copy_flutter_bundle）…');
    await _runner.run(
      p.join(ctx.env.sdkRoot, 'bin', 'flutter'),
      <String>[
        'assemble',
        '-dTargetPlatform=windows-x64',
        '-dBuildMode=${ctx.mode.cliName}',
        '-dTreeShakeIcons=${ctx.treeShakeIcons}',
        '--output=${ctx.flutterAssetsDir}',
        'copy_flutter_bundle',
      ],
      workingDirectory: ctx.project.root,
      stream: true,
      tag: 'assemble',
    );
  }

  /// 定位 CMake 构出的 runner 可执行文件。优先常见位置（runner/ 子目录），
  /// 其次根目录，最后递归兵底（跳过 CMakeFiles/ 里的编译器检测产物）。
  File? _findBuiltExe(BuildContext ctx) {
    final name = '${ctx.project.appName}.exe';
    for (final c in <String>[
      p.join(ctx.cmakeBuildDir, 'runner', name),
      p.join(ctx.cmakeBuildDir, name),
    ]) {
      if (File(c).existsSync()) return File(c);
    }
    final dir = Directory(ctx.cmakeBuildDir);
    if (dir.existsSync()) {
      final sep = p.separator;
      for (final e in dir.listSync(recursive: true)) {
        if (e is File &&
            p.basename(e.path) == name &&
            !e.path.contains('${sep}CMakeFiles$sep')) {
          return e;
        }
      }
    }
    return null;
  }

  /// 复制单个文件；源不存在时静默跳过（与 [_copyTree] 一致）。
  Future<void> _copyFileIfExists(String src, String dst) async {
    final f = File(src);
    if (!f.existsSync()) return;
    await Directory(p.dirname(dst)).create(recursive: true);
    await f.copy(dst);
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
