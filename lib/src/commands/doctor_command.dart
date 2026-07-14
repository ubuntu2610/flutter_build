// `flutter_win doctor` — diagnose the host environment.
//
// Never mutates state. Emits a colored, tabular summary that shows what
// was found, what's missing, and precise commands to remediate.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../cache_paths.dart';
import '../engine_artifacts.dart';
import '../exceptions.dart';
import '../flutter_env.dart';
import '../logger.dart';
import '../process_runner.dart';
import '../project.dart';
import '../toolchain.dart';

class DoctorCommand extends Command<int> {
  DoctorCommand() {
    argParser.addFlag(
      'allow-download',
      help: 'Auto-download LLVM-MinGW during doctor if missing.',
      defaultsTo: false,
    );
  }

  @override
  String get name => 'doctor';
  @override
  String get description =>
      'Check the Linux host for everything needed to cross-build.';

  @override
  Future<int> run() async {
    final log = Logger.instance;
    final runner = ProcessRunner(logger: log);
    final cacheDir = globalResults?['cache-dir'] as String?;
    final paths = CachePaths.resolve(cacheDirOverride: cacheDir);
    await paths.ensure();

    var problems = 0;
    void fail(String msg) {
      problems++;
      log.error(msg);
    }

    // 1. Flutter SDK.
    FlutterEnv? env;
    await log.group('Flutter SDK', () async {
      try {
        env = await FlutterEnv.locate(runner: runner);
        log.kv(env!.describe());
      } on ToolException catch (e) {
        fail(e.message);
        if (e.hint != null) log.hint(e.hint!);
      }
    });

    // 2. Target project (best-effort — allow running outside a project).
    await log.group('Target project (cwd)', () async {
      try {
        final project = await FlutterProject.load();
        log.kv({
          'Root': project.root,
          'App': project.appName,
          'Entry': p.relative(project.entryPoint, from: project.root),
          'windows/ scaffold': project.hasWindowsScaffold ? 'present' : 'MISSING',
          'Windows plugins': project.plugins.isEmpty
              ? '(none)'
              : project.plugins
                  .map((pl) => '${pl.name}${pl.hasNativeCode ? '' : '  (dart-only)'}')
                  .join(', '),
        });
        if (!project.hasWindowsScaffold) {
          fail('Project has no windows/ scaffold.');
          log.hint('Run: flutter create --platforms=windows .');
        }
        _scanForRiskyPluginCode(project, log, () => problems++);
      } on ProjectException catch (e) {
        log.info('  (not a Flutter project; run inside one for full checks)');
        log.debug(e.message);
      }
    });

    // 3. Cross toolchain.
    Toolchain? toolchain;
    await log.group('Cross-compile toolchain', () async {
      try {
        final provisioner = ToolchainProvisioner(paths: paths, runner: runner);
        toolchain = await provisioner.provision(
          allowDownload: argResults?['allow-download'] == true,
        );
        log.kv(toolchain!.describe());
      } on ToolException catch (e) {
        fail(e.message);
        if (e.hint != null) log.hint(e.hint!);
      }
    });

    // 4. Engine artifacts (only if we located Flutter).
    if (env != null) {
      await log.group('Windows engine artifacts', () async {
        try {
          final art = EngineArtifactsProvisioner(env: env!, runner: runner);
          final a = await art.ensure();
          log.kv(a.describe());
        } on ToolException catch (e) {
          fail(e.message);
          if (e.hint != null) log.hint(e.hint!);
        }
      });
    }

    // 5. Cache summary.
    await log.group('Local cache', () async {
      log.kv({'Cache root': paths.root});
      for (final d in [paths.toolchainsDir, paths.engineDir, paths.downloadsDir]) {
        final exists = Directory(d).existsSync();
        log.kv({d: exists ? 'ok' : '(will be created on demand)'});
      }
    });

    log.info('');
    if (problems == 0) {
      log.success('doctor: no problems found.');
      return 0;
    }
    log.error('doctor: $problems issue(s) — fix the hints above and re-run.');
    return 1;
  }

  /// Lightweight heuristic scan for Windows plugin source that is likely
  /// to hit mingw-w64 header gaps (WinRT / C++/WinRT / DirectX 12).
  void _scanForRiskyPluginCode(
    FlutterProject project,
    Logger log,
    void Function() bumpProblem,
  ) {
    final risky = <String, List<String>>{};
    const patterns = <String, String>{
      'WinRT / C++/WinRT': 'winrt::',
      '<winrt/*.h>': '<winrt/',
      'DirectX 12': '#include <d3d12',
      'MSVC __uuidof': '__uuidof',
    };

    for (final plugin in project.plugins) {
      if (!plugin.hasNativeCode) continue;
      final dir = Directory(plugin.windowsCMakeDir);
      if (!dir.existsSync()) continue;
      final hits = <String>[];
      for (final e in dir.listSync(recursive: true)) {
        if (e is! File) continue;
        final ext = p.extension(e.path);
        if (!const {'.cpp', '.cc', '.cxx', '.h', '.hpp'}.contains(ext)) continue;
        final txt = e.readAsStringSync();
        for (final entry in patterns.entries) {
          if (txt.contains(entry.value)) {
            hits.add('${entry.key} in ${p.relative(e.path, from: plugin.rootPath)}');
          }
        }
      }
      if (hits.isNotEmpty) risky[plugin.name] = hits;
    }

    if (risky.isEmpty) return;
    log.warn('Plugins with potentially MinGW-incompatible headers:');
    for (final entry in risky.entries) {
      log.warn('  ${entry.key}:');
      for (final hit in entry.value) {
        log.warn('    - $hit');
      }
    }
    log.hint('These plugins may need patches to compile under LLVM-MinGW.');
  }
}
