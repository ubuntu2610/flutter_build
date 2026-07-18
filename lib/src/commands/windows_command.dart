// `flutter_build windows [--debug|--profile|--release]`
//
// The command performs the full cross-build pipeline on the current
// directory (assumed to be a Flutter app project).

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../build/build_context.dart';
import '../build/pipeline.dart';
import '../cache_paths.dart';
import '../deploy.dart';
import '../engine_artifacts.dart';
import '../exceptions.dart';
import '../flutter_env.dart';
import '../logger.dart';
import '../process_runner.dart';
import '../project.dart';
import '../toolchain.dart';

class WindowsCommand extends Command<int> {
  WindowsCommand() {
    argParser
      ..addFlag('debug',
          negatable: false, help: 'Build the debug (JIT) flavor.')
      ..addFlag('profile',
          negatable: false,
          help: 'Build the profile (AOT + observatory) flavor.')
      ..addFlag('release',
          negatable: false, help: 'Build the release (AOT) flavor. Default.')
      ..addMultiOption('dart-define',
          abbr: 'D',
          help: 'Pass a Dart --define to the kernel compiler.',
          splitCommas: false)
      ..addFlag('obfuscate',
          negatable: false,
          help: 'Enable AOT obfuscation (release/profile). '
              'Requires --split-debug-info.')
      ..addOption('split-debug-info',
          help: 'Directory to save split debug symbols/obfuscation map.')
      ..addFlag('tree-shake-icons',
          defaultsTo: true,
          help: 'Tree-shake icon fonts based on IconData usage.')
      ..addOption('target',
          abbr: 't', help: 'Entry point (default: lib/main.dart).')
      ..addOption('output-dir',
          abbr: 'o', help: 'Override output root (default: build/win_cross).')
      ..addFlag('no-precache',
          negatable: false,
          help: 'Fail instead of downloading LLVM-MinGW / engine artifacts.')
      ..addOption('toolchain-path',
          help: 'Path to a pre-installed LLVM-MinGW directory.\n'
              'Same as setting env LLVM_MINGW_ROOT. Skips download.')
      ..addFlag('copy',
          help: '构建成功后把产物拷到 config.yaml 指定的远程 Windows 机器。\n'
              '显式指定时覆盖 config 里的 auto_copy（--no-copy 可禁用）。')
      ..addOption('config', help: '指定 config.yaml 路径（默认依次查找：项目目录向上、'
          'flutter_build 工具目录向上、~/.flutter_build/config.yaml）。')
      ..addFlag('debug-console',
          defaultsTo: true,
          help: '默认开启：给 runner 注入调试信息，让引擎日志显示在启动它的\n'
              'PowerShell/cmd 控制台，并在启动失败时弹窗。\n'
              '发布干净版本用 --no-debug-console 关闭。');
  }

  @override
  String get name => 'windows';
  @override
  String get description =>
      'Cross-compile the Flutter Windows executable for the current project.';

  @override
  Future<int> run() async {
    final log = Logger.instance;
    final runner = ProcessRunner(logger: log);

    final flavor = _pickFlavor();
    log.debug('Requested flavor: ${flavor.cliName}');

    final project = await FlutterProject.load();
    final env = await FlutterEnv.locate(runner: runner);
    final paths = CachePaths.resolve(
      cacheDirOverride: globalResults?['cache-dir'] as String?,
    );
    await paths.ensure();

    final allowDownload = argResults?['no-precache'] != true;
    final toolchainPath = argResults?['toolchain-path'] as String?;
    final toolchain = await ToolchainProvisioner(
      paths: paths,
      runner: runner,
      toolchainPathOverride: toolchainPath,
    ).provision(allowDownload: allowDownload);

    final artifacts = await EngineArtifactsProvisioner(
      env: env,
      runner: runner,
    ).ensure();

    final buildRoot = (argResults?['output-dir'] as String?) ??
        p.join(project.root, 'build', 'win_cross');

    final defines = List<String>.from(
      (argResults?['dart-define'] as List<dynamic>?)?.cast<String>() ??
          const [],
    );
    final obfuscate = argResults?['obfuscate'] == true;
    final splitDebug = argResults?['split-debug-info'] as String?;
    if (obfuscate && splitDebug == null) {
      throw ToolException(
        '--obfuscate requires --split-debug-info=<dir> for the symbol map.',
      );
    }

    final context = BuildContext(
      env: env,
      project: project,
      artifacts: artifacts,
      toolchain: toolchain,
      mode: flavor,
      buildRoot: buildRoot,
      dartDefines: defines,
      enableObfuscation: obfuscate,
      splitDebugInfoDir: splitDebug,
      treeShakeIcons: argResults?['tree-shake-icons'] == true,
      verbose: log.verbose,
      debugConsole: argResults?['debug-console'] == true,
    );

    await BuildPipeline().run(context);
    await _maybeDeploy(context, log, runner);
    return 0;
  }

  /// 构建成功后按 config.yaml 把产物 bundle 拷到远程 Windows 机器。
  ///
  /// 是否拷贝：显式 `--copy`/`--no-copy` 优先，否则用 config 的 auto_copy。
  /// 未找到 config.yaml 时静默跳过。
  Future<void> _maybeDeploy(
    BuildContext ctx,
    Logger log,
    ProcessRunner runner,
  ) async {
    final configPath = argResults?['config'] as String?;
    final DeployConfig? config;
    if (configPath != null) {
      final f = File(configPath);
      if (!f.existsSync()) {
        throw ToolException('指定的 config 不存在: $configPath');
      }
      config = DeployConfig.parse(f.readAsStringSync(),
          baseDir: p.dirname(p.absolute(configPath)));
    } else {
      config = DeployConfig.find(ctx.project.root);
    }

    if (config == null) {
      log.debug('未找到 config.yaml，跳过远程拷贝。');
      return;
    }

    final bool shouldCopy;
    if (argResults?.wasParsed('copy') == true) {
      shouldCopy = argResults?['copy'] == true;
    } else {
      shouldCopy = config.autoCopy;
    }
    if (!shouldCopy) {
      log.debug('auto_copy 关闭且未指定 --copy，跳过远程拷贝。');
      return;
    }

    final bundleDir = p.dirname(ctx.finalExe);
    await SshDeployer(config: config, logger: log, runner: runner)
        .deployDir(bundleDir);
  }

  WindowsFlavor _pickFlavor() {
    final debug = argResults?['debug'] == true;
    final profile = argResults?['profile'] == true;
    final release = argResults?['release'] == true;
    final count = [debug, profile, release].where((b) => b).length;
    if (count > 1) {
      throw ToolException(
        '--debug, --profile and --release are mutually exclusive.',
      );
    }
    if (debug) return WindowsFlavor.debug;
    if (profile) return WindowsFlavor.profile;
    // Default is release, matching `flutter build windows`.
    return WindowsFlavor.release;
  }
}
