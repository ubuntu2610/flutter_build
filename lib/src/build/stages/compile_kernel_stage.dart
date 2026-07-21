// 阶段 3：用 frontend_server 把 Dart 入口编译成 kernel `.dill`。
//
// 参数对齐 flutter_tools 的 KernelSnapshot 目标；AOT 快照运行时的选择由
// [FlutterEnv.frontendServerRuntime] 负责（AOT 快照必须用 dartaotruntime）。

import 'dart:io';

import '../../engine_artifacts.dart';
import '../build_context.dart';
import '../incremental.dart';
import 'build_stage.dart';

/// 编译 Dart kernel（`app.dill`）。
class CompileKernelStage extends BuildStage {
  CompileKernelStage({super.logger, super.runner});

  @override
  String get name => 'compile Dart kernel';

  @override
  Future<void> run(BuildContext ctx) async {
    // 参数对齐 flutter_tools 的 KernelSnapshot 目标。现代引擎用的是标准
    // package:frontend_server AOT 快照：输出用 --output-dill（非旧版 -o），
    // 且不认 --tree-shake-icons——图标 tree-shaking 是资源打包阶段的独立
    // 步骤（由 IconTreeShaker 处理），不属于 frontend_server。
    if (ctx.treeShakeIcons) {
      log.debug('note: icon tree-shaking 尚未在打包阶段实现，本次不生效。');
    }
    // Dart 插件注册器：path_provider_windows / shared_preferences_windows 等
    // 纯 Dart 实现的插件，其 registerWith() 由 Flutter 生成的
    // dart_plugin_registrant.dart 调用。必须像 flutter_tools 那样把它作为
    // --source 传给 frontend_server，并用 -Dflutter.dart_plugin_registrant 指定
    // 其 URI；否则运行时会 MissingPluginException（如 path_provider 的
    // getApplicationDocumentsDirectory 无实现）。
    final registrant = File(ctx.project.dartPluginRegistrant).absolute;
    final hasRegistrant = registrant.existsSync();
    if (hasRegistrant) {
      log.debug('接入 Dart 插件注册器：${registrant.path}');
    } else {
      log.debug('未找到 dart_plugin_registrant.dart；若用到纯 Dart 插件'
          '（path_provider_windows 等），请先在项目里执行 flutter pub get。');
    }

    // 增量：kernel 输入（源码依赖 + 编译输入指纹）未变则跳过重编。frontend_server
    // 的 --depfile 记录源码依赖；模式 / dart-define / 注册器等不体现在 depfile
    // 里的输入用 stamp 指纹覆盖。任何不确定都会重编（见 isUpToDate）。
    final depfile = '${ctx.kernelDill}.d';
    final stampPath = '${ctx.kernelDill}.stamp';
    final stamp = hashInputs(<String>[
      'mode=${ctx.mode.cliName}',
      'product=${ctx.mode.isProduct}',
      'aot=${ctx.mode.isAot}',
      ...ctx.mode.kernelModeDefines,
      ...ctx.dartDefines,
      'entry=${ctx.project.entryPoint}',
      'sdkRoot=${ctx.env.sdkRoot}',
      'registrant=$hasRegistrant',
    ]);
    if (ctx.incremental &&
        _kernelUpToDate(
            ctx, depfile, stampPath, stamp, hasRegistrant, registrant)) {
      log.info('  kernel 未变化，跳过编译（--no-incremental 可强制重编）。');
      return;
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
      // 纯 Dart 插件注册（见上）：与 flutter_tools KernelSnapshot 一致。
      if (hasRegistrant) ...[
        '--source',
        registrant.path,
        '--source',
        'package:flutter/src/dart_plugin_registrant.dart',
        '-Dflutter.dart_plugin_registrant=${registrant.uri}',
      ],
      '--depfile',
      depfile,
      '--output-dill',
      ctx.kernelDill,
      ctx.project.entryPoint,
    ];
    // frontend_server_aot.dart.snapshot 是 AOT 快照，必须用 dartaotruntime
    // 运行；旧版 frontend_server.dart.snapshot 才用 dart。由 env 按快照类型
    // 自动选择正确的运行时，避免 exit 255。
    await runner.run(ctx.env.frontendServerRuntime, args,
        tag: 'frontend_server');
    // 记录本次编译的输入指纹，供下次增量判断。
    await File(stampPath).writeAsString(stamp);
  }

  /// kernel 是否相对源码依赖（depfile）、package_config、注册器与输入指纹保持
  /// 最新。depfile 不存在（首次构建 / 曾被清理）时返回 false，触发重编。
  bool _kernelUpToDate(BuildContext ctx, String depfile, String stampPath,
      String stamp, bool hasRegistrant, File registrant) {
    final depFile = File(depfile);
    if (!depFile.existsSync()) return false;
    return isUpToDate(
      outputPath: ctx.kernelDill,
      inputPaths: <String>[
        ...parseDepfileInputs(depFile.readAsStringSync()),
        ctx.project.packageConfig,
        if (hasRegistrant) registrant.path,
      ],
      stampPath: stampPath,
      expectedStamp: stamp,
    );
  }
}
