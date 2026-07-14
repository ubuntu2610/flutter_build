// `flutter_build precache` — download the toolchain + engine artifacts
// so that a subsequent `windows` is fully offline.

import 'package:args/command_runner.dart';

import '../cache_paths.dart';
import '../engine_artifacts.dart';
import '../flutter_env.dart';
import '../logger.dart';
import '../process_runner.dart';
import '../toolchain.dart';

class PrecacheCommand extends Command<int> {
  PrecacheCommand() {
    argParser.addFlag(
      'toolchain-only',
      help: 'Only fetch LLVM-MinGW; skip Windows engine artifacts.',
      defaultsTo: false,
    );
    argParser.addFlag(
      'engine-only',
      help: 'Only fetch engine artifacts; skip LLVM-MinGW.',
      defaultsTo: false,
    );
    argParser.addOption(
      'toolchain-path',
      help: 'Path to a pre-installed LLVM-MinGW directory (skips download).',
    );
  }

  @override
  String get name => 'precache';
  @override
  String get description =>
      'Download LLVM-MinGW toolchain + Windows engine artifacts.';

  @override
  Future<int> run() async {
    final log = Logger.instance;
    final runner = ProcessRunner(logger: log);
    final paths = CachePaths.resolve(
      cacheDirOverride: globalResults?['cache-dir'] as String?,
    );
    await paths.ensure();

    final toolchainOnly = argResults?['toolchain-only'] == true;
    final engineOnly = argResults?['engine-only'] == true;

    if (!engineOnly) {
      log.info('==> Provisioning LLVM-MinGW toolchain');
      final toolchainPath = argResults?['toolchain-path'] as String?;
      final provisioner = ToolchainProvisioner(
        paths: paths,
        runner: runner,
        toolchainPathOverride: toolchainPath,
      );
      final tc = await provisioner.provision(allowDownload: true);
      log.kv(tc.describe());
    }

    if (!toolchainOnly) {
      log.info('');
      log.info('==> Provisioning Windows engine artifacts');
      final env = await FlutterEnv.locate(runner: runner);
      log.kv(env.describe());
      final artifactsProv = EngineArtifactsProvisioner(env: env, runner: runner);
      final a = await artifactsProv.ensure();
      log.kv(a.describe());
    }

    log.success('precache complete.');
    return 0;
  }
}
