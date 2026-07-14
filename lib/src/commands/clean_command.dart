// `flutter_win clean` — remove the cross-build output.
//
// Never touches the local toolchain / engine caches; use
// `rm -rf $HOME/.flutter_win` (or the value returned by `--cache-dir`)
// to wipe those.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../logger.dart';
import '../project.dart';

class CleanCommand extends Command<int> {
  CleanCommand() {
    argParser.addOption(
      'output-dir',
      abbr: 'o',
      help: 'Directory to remove (default: <project>/build/win_cross).',
    );
  }

  @override
  String get name => 'clean';
  @override
  String get description =>
      'Delete the cross-build output directory for this project.';

  @override
  Future<int> run() async {
    final log = Logger.instance;

    String target;
    final override = argResults?['output-dir'] as String?;
    if (override != null) {
      target = override;
    } else {
      final project = await FlutterProject.load();
      target = p.join(project.root, 'build', 'win_cross');
    }

    final dir = Directory(target);
    if (!dir.existsSync()) {
      log.info('Nothing to clean at $target.');
      return 0;
    }
    log.step('Removing $target');
    await dir.delete(recursive: true);
    log.success('Cleaned.');
    return 0;
  }
}
