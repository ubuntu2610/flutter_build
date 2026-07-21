// 阶段 1：把工程 `windows/` 脚手架暂存到构建目录，并生成交叉构建所需的
// `flutter/ephemeral/`、插件符号链接、源码补丁与 `.rc` 归一化等。
//
// 正常由 `flutter build windows` 完成的一批准备工作，在 Linux 交叉构建下必须
// 自行复现，否则 flutter/CMakeLists.txt 会因找不到 generated_config.cmake 等而
// 配置失败。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../io/fs_utils.dart';
import '../build_context.dart';
import '../debug_instrumentation.dart';
import '../flutter_ephemeral.dart';
import '../plugin_source_patcher.dart';
import 'build_stage.dart';

/// 在 `flutter/ephemeral/.plugin_symlinks/` 下为每个原生 Windows 插件创建链接。
///
/// 不依赖源工程里是否已经跑过 `flutter build windows`；交叉构建时统一在暂存目录
/// 里重建，既避免缺失，也避免继承旧的坏链或循环链接。
Future<void> materializePluginSymlinks(
    BuildContext ctx, String ephemeralDir) async {
  final symlinkDir = Directory(p.join(ephemeralDir, '.plugin_symlinks'));
  if (symlinkDir.existsSync()) {
    await symlinkDir.delete(recursive: true);
  }
  await symlinkDir.create(recursive: true);

  for (final plugin in ctx.project.plugins.where((p) => p.hasNativeCode)) {
    await Link(p.join(symlinkDir.path, plugin.name))
        .create(plugin.rootPath, recursive: true);
  }
}

/// 暂存 CMake 源并生成 ephemeral / 插件链接 / 补丁 / 归一化。
class SourceStagingStage extends BuildStage {
  SourceStagingStage({super.logger, super.runner});

  @override
  String get name => 'stage Windows CMake sources';

  @override
  Future<void> run(BuildContext ctx) async {
    await Directory(ctx.intermediatesDir).create(recursive: true);
    await Directory(ctx.windowsStageDir).create(recursive: true);
    await copyTree(ctx.project.windowsDir, ctx.windowsStageDir);
    await _generateFlutterEphemeral(ctx);
    await _patchPluginSources(ctx);
    await _normalizeResourceScripts(ctx);
    if (ctx.debugConsole) await _instrumentRunner(ctx);
  }

  /// 给暂存的 runner/main.cpp 注入调试信息（始终开控制台 + 启动失败输出 stderr）。
  /// 仅在 --debug-console 时调用，不影响正常发布构建。
  Future<void> _instrumentRunner(BuildContext ctx) async {
    final mainCpp = File(p.join(ctx.windowsStageDir, 'runner', 'main.cpp'));
    if (!mainCpp.existsSync()) {
      log.debug('未找到 runner/main.cpp，跳过调试注入。');
      return;
    }
    final patched = instrumentRunnerMain(await mainCpp.readAsString());
    await mainCpp.writeAsString(patched);
    log.info('已注入调试信息（--debug-console 显式开启）：'
        '从 PowerShell/cmd 运行可看到引擎日志，启动失败输出 stderr 诊断；'
        '注意此模式下双击运行会新建控制台窗口。');
  }

  /// 对暂存目录下 `.plugin_symlinks/` 中已知有 Clang/MinGW 兼容问题的插件
  /// 应用源码补丁。在生成 ephemeral（创建符号链接）之后、翻译 CMakeLists.txt
  /// 标志之前执行。
  Future<void> _patchPluginSources(BuildContext ctx) async {
    final ephemeralDir = p.join(ctx.windowsStageDir, 'flutter', 'ephemeral');
    await const PluginSourcePatcher().apply(ephemeralDir, logger: log);
  }

  /// 归一化暂存目录里所有 `.rc` 资源脚本中的路径分隔符：把转义反斜杠
  /// `\\` 换成 `/`。llvm-rc 在 Linux 上不把 `\` 当路径分隔符，导致图标等
  /// 资源文件（如 `resources\\app_icon.ico`）找不到；`/` 在 Windows/Linux 下
  /// 均可用。
  Future<void> _normalizeResourceScripts(BuildContext ctx) async {
    final dir = Directory(ctx.windowsStageDir);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != '.rc') continue;
      final content = await entity.readAsString();
      if (!content.contains(r'\\')) continue;
      await entity.writeAsString(content.replaceAll(r'\\', '/'));
    }
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
    await copyFileIfExists(
        art.flutterWindowsDll, p.join(ephemeralDir, 'flutter_windows.dll'));
    await copyFileIfExists(art.flutterWindowsImportLib,
        p.join(ephemeralDir, 'flutter_windows.dll.lib'));
    // 嵌入器头文件：已知清单与 embedderDir 下其余顶层 .h 的并集（Flutter 未来
    // 新增头文件可自动纳入，避免因清单过时而漏拷）。
    for (final h in _embedderHeaderNames(art.embedderDir)) {
      await copyFileIfExists(
          p.join(art.embedderDir, h), p.join(ephemeralDir, h));
    }
    // C++ 客户端包装层（递归）。
    await copyTree(
        art.cppClientWrapperDir, p.join(ephemeralDir, 'cpp_client_wrapper'));
    // icudtl.dat（兼容每平台 / 共享两种布局）。
    await copyFileIfExists(art.icudtl, p.join(ephemeralDir, 'icudtl.dat'));
    // 重新生成插件链接，避免依赖源工程里已有的 ephemeral/.plugin_symlinks。
    await materializePluginSymlinks(ctx, ephemeralDir);

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
        log.debug('flutter/CMakeLists.txt 未找到 tool backend 标记，'
            '跳过 flutter_assemble 中和（可能是非标准模板）。');
      } else {
        await flutterCmake.writeAsString(patched);
      }
    }

    // Patch generated_plugins.cmake：为每个插件目标设置 PREFIX "" IMPORT_PREFIX ""。
    // SDK 生成的文件不含此设置（MSVC 不加 lib 前缀），但 MinGW 默认给 shared
    // library 加 lib 前缀（libfoo.dll）。PREFIX "" 去掉 DLL 前缀，IMPORT_PREFIX ""
    // 去掉导入库（.dll.a）前缀——否则 dlltool 从导入库文件名推导依赖 DLL 名时
    // 会加 lib 前缀，导致 EXE 运行时寻找 libfoo.dll 而实际产物是 foo.dll。
    // 仅 patch 普通插件循环（${plugin}），FFI 插件（${ffi_plugin}）不创建
    // _plugin 目标，无需设置。
    final generatedPlugins =
        File(p.join(stagedFlutterDir, 'generated_plugins.cmake'));
    if (generatedPlugins.existsSync()) {
      final content = await generatedPlugins.readAsString();
      if (!content.contains('IMPORT_PREFIX')) {
        const marker =
            '  add_subdirectory(flutter/ephemeral/.plugin_symlinks/\${plugin}/windows plugins/\${plugin})';
        const insertion = '$marker\n'
            '  set_target_properties(\${plugin}_plugin PROPERTIES PREFIX "" IMPORT_PREFIX "")';
        final patched = content.replaceAll(marker, insertion);
        if (patched != content) {
          await generatedPlugins.writeAsString(patched);
          log.debug('已为插件目标设置 PREFIX "" IMPORT_PREFIX "" '
              '以去除 MinGW lib 前缀。');
        }
      }
    }
  }

  /// 需要拷入 ephemeral/ 的嵌入器头文件名集合：[kEmbedderHeaders] 已知清单与
  /// [embedderDir] 下实际存在的其余顶层 `.h` 的并集。取并集是为了对未来 Flutter
  /// 版本前向兼容——即便引擎新增了头文件，也能自动随包拷入，而不会因硬编码清单
  /// 过时而遗漏。
  Iterable<String> _embedderHeaderNames(String embedderDir) {
    final names = <String>{...kEmbedderHeaders};
    final dir = Directory(embedderDir);
    if (dir.existsSync()) {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File && p.extension(entity.path) == '.h') {
          names.add(p.basename(entity.path));
        }
      }
    }
    return names;
  }
}
