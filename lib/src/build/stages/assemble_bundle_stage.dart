// 阶段 6：把构建产物组装到最终输出目录，布局与 Windows 上 `flutter build` 一致：
//   <app>/
//     <app>.exe
//     flutter_windows.dll
//     data/
//       icudtl.dat
//       app.so            (release/profile)
//       flutter_assets/   (由 flutter assemble copy_flutter_bundle 生成)

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../engine_artifacts.dart';
import '../../exceptions.dart';
import '../build_context.dart';
import '../native_dll.dart' as dll;
import 'build_stage.dart';

/// 组装最终 Windows 产物 bundle。
class AssembleBundleStage extends BuildStage {
  AssembleBundleStage({super.logger, super.runner});

  @override
  String get name => 'assemble Windows bundle';

  @override
  Future<void> run(BuildContext ctx) async {
    final outDir = ctx.outputDir;
    final dataDir = ctx.dataDir;
    await Directory(outDir).create(recursive: true);
    await Directory(ctx.flutterAssetsDir).create(recursive: true);

    // 单遍扫描 cmake_build/：一次递归遍历同时定位 runner exe 与收集插件 DLL，
    // 取代此前「找 exe」与「收集 DLL」两次独立的递归遍历。
    final scan = _scanCmakeBuild(ctx);
    final builtExe = scan.exe;
    if (builtExe == null) {
      throw ArtifactException(
        '构建成功但未在 ${ctx.cmakeBuildDir} 下找到 '
        '${ctx.project.appName}.exe。',
      );
    }
    await builtExe.copy(ctx.finalExe);

    // 嵌入器动态库与 exe 同级；icu 放 data/。按模式选对引擎 DLL：
    // release/profile 用 AOT 引擎，debug 用 JIT 引擎（否则模式不匹配启动失败）。
    final engineDll = ctx.artifacts.flutterWindowsDllForMode(ctx.mode);
    if (File(engineDll).existsSync()) {
      await File(engineDll).copy(p.join(outDir, 'flutter_windows.dll'));
    }

    // 插件 DLL：来自上面的单遍扫描。generated_plugins.cmake 已设 PREFIX ""
    // IMPORT_PREFIX "" 去掉 MinGW 的 lib 前缀，此处直接按原始文件名拷贝即可。
    for (final dllFile in scan.dlls) {
      final name = p.basename(dllFile.path);
      final dest = p.join(outDir, name);
      if (!File(dest).existsSync()) await dllFile.copy(dest);
    }

    // 预构建 DLL：部分插件依赖预编译的 Windows DLL（如 opencv_world490.dll），
    // 在插件 CMakeLists.txt 里以路径引用，Linux 上 if(EXISTS ...) 失败不会自动
    // 拷贝。分两步补齐：
    final scanner = dll.NativeDllScanner(logger: log);
    // 1) 先按插件声明**精确解析**可解析的相对引用（覆盖位于 .pub-cache 内、
    //    广度扫描会跳过的插件）。
    await scanner.copyResolvedReferencedDlls(
      outDir: outDir,
      plugins: ctx.project.plugins,
    );
    // 2) 广度扫描兜底：默认项目根的祖父目录（覆盖 libcimbar / paddle_ocr 等
    //    兄弟目录），可用 --dll-search-root 收窄以加速大型工作区。
    await scanner.copyPrebuiltDlls(
      outDir: outDir,
      searchRoot: ctx.dllSearchRoot ?? p.dirname(p.dirname(ctx.project.root)),
    );

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
      log.warn('data/flutter_assets 仍为空：资源打包可能失败，'
          '应用在 Windows 上很可能无窗口/静默退出。');
      log.warn('从 PowerShell 运行 exe 可看到引擎日志'
          '（可加 --debug-console 构建以查看）。');
    }

    // 编译期校验：插件声明要打包、却缺失的预编译原生 DLL（避免留到运行时）。
    scanner.verifyPluginNativeDlls(
      outDir: outDir,
      plugins: ctx.project.plugins,
    );
  }

  /// 对 `cmake_build/` 做一次递归遍历，同时返回 runner 可执行文件与全部插件
  /// `.dll`。合并了历史上的两次遍历（定位 exe + 收集 DLL）。
  ({File? exe, List<File> dlls}) _scanCmakeBuild(BuildContext ctx) {
    final name = '${ctx.project.appName}.exe';
    final sep = p.separator;
    final dlls = <File>[];
    final exeCandidates = <File>[];
    final dir = Directory(ctx.cmakeBuildDir);
    if (dir.existsSync()) {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final base = p.basename(e.path);
        if (base.endsWith('.dll')) {
          dlls.add(e);
        } else if (base == name && !e.path.contains('${sep}CMakeFiles$sep')) {
          // 跳过 CMakeFiles/ 里的编译器检测产物。
          exeCandidates.add(e);
        }
      }
    }
    return (exe: _pickExe(ctx, exeCandidates, name), dlls: dlls);
  }

  /// 从候选里选定 runner exe：偏好 runner/ 子目录，其次根目录，最后任意候选
  /// （与历史 `_findBuiltExe` 的偏好顺序一致）。
  File? _pickExe(BuildContext ctx, List<File> candidates, String name) {
    for (final pref in <String>[
      p.join(ctx.cmakeBuildDir, 'runner', name),
      p.join(ctx.cmakeBuildDir, name),
    ]) {
      for (final f in candidates) {
        if (p.equals(f.path, pref)) return f;
      }
    }
    return candidates.isNotEmpty ? candidates.first : null;
  }

  /// 生成 flutter_assets（AssetManifest / 字体 / NOTICES / shaders 等）。
  ///
  /// 复用 flutter 自己的资源打包逻辑：`flutter assemble copy_flutter_bundle`。
  /// 该 target 只依赖 KernelSnapshot（不触发 gen_snapshot / 无需 Windows 二进制），
  /// 因此能在 Linux 上产出 flutter_assets，直接输出到 data/flutter_assets/。
  /// release/profile 不含 kernel_blob（用 app.so）；debug 会带 kernel_blob 及快照。
  Future<void> _bundleFlutterAssets(BuildContext ctx) async {
    log.info('  生成 flutter_assets（flutter assemble copy_flutter_bundle）…');
    // flutter assemble 在面向 windows-x64 时会读取 PROGRAMFILES(X86) 来探测
    // Visual Studio 路径。Linux 上该变量不存在，导致 dart_build target 直接
    // 报错退出。设为空字符串即可绕过探测——copy_flutter_bundle 只需 Dart 产物
    // （kernel / AOT），不需要 MSVC。includeParentEnvironment 默认 true，此
    // map 仅追加一个变量，不覆盖宿主 PATH 等。
    final env = <String, String>{
      'PROGRAMFILES(X86)': '',
    };
    await runner.run(
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
      environment: env,
      stream: true,
      tag: 'assemble',
    );
  }
}
