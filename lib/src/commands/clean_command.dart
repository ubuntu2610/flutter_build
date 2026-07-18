// `flutter_build clean` — remove the cross-build output.
//
// Never touches the local toolchain / engine caches; use
// `rm -rf $HOME/.flutter_build` (or the value returned by `--cache-dir`)
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
      help: 'Build root to clean (default: <project>/build/win_cross).',
    );
    argParser.addFlag(
      'cmake',
      negatable: false,
      help: 'Only remove CMake build caches (cmake_build/) for all modes, '
          'preserving intermediates and final output. '
          'Useful for forcing a CMake reconfigure after flag changes.',
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

    String buildRoot;
    final override = argResults?['output-dir'] as String?;
    if (override != null) {
      buildRoot = override;
    } else {
      final project = await FlutterProject.load();
      buildRoot = p.join(project.root, 'build', 'win_cross');
    }

    final cmakeOnly = argResults?['cmake'] as bool? ?? false;
    if (cmakeOnly) {
      return _cleanCmakeCache(buildRoot, log);
    }

    final dir = Directory(buildRoot);
    if (!dir.existsSync()) {
      log.info('Nothing to clean at $buildRoot.');
      return 0;
    }
    log.step('Removing $buildRoot');
    await dir.delete(recursive: true);
    log.success('Cleaned.');
    return 0;
  }

  /// 仅删除各模式目录下的 `cmake_build/`（CMake 配置与 Ninja 构建缓存），
  /// 保留 `intermediates/`（kernel dill、AOT elf）和最终产物。适用于更换
  /// 编译标志或垫片后强制 CMake 重新配置，而不必重跑耗时的 AOT 编译。
  Future<int> _cleanCmakeCache(String buildRoot, Logger log) async {
    final root = Directory(buildRoot);
    if (!root.existsSync()) {
      log.info('Nothing to clean at $buildRoot.');
      return 0;
    }

    final cleaned = <String>[];
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final cacheDir = Directory(p.join(entity.path, 'cmake_build'));
      if (cacheDir.existsSync()) {
        final rel = p.relative(cacheDir.path, from: buildRoot);
        await cacheDir.delete(recursive: true);
        cleaned.add(rel);
      }
    }

    if (cleaned.isEmpty) {
      log.info('No CMake cache found under $buildRoot.');
    } else {
      log.step('Removed: ${cleaned.join(', ')}');
      log.success('CMake cache cleaned. Intermediates and output preserved.');
    }
    return 0;
  }
}
