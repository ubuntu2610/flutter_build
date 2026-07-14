// Entry point for the `flutter_build` CLI.
//
// Wires the top-level [CommandRunner] with the subcommands defined in
// `lib/src/commands/`. Keeps this file intentionally tiny so global flags
// (`--verbose`, `--cache-dir`, `--no-color`) live in one obvious place.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_build/flutter_build.dart';
import 'package:flutter_build/src/commands/clean_command.dart';
import 'package:flutter_build/src/commands/doctor_command.dart';
import 'package:flutter_build/src/commands/precache_command.dart';
import 'package:flutter_build/src/commands/windows_command.dart';
import 'package:flutter_build/src/logger.dart';

Future<void> main(List<String> args) async {
  final runner = CommandRunner<int>(
    'flutter_build',
    'Cross-compile Flutter Windows apps on Linux (LLVM-MinGW + Wine).',
  )
    ..argParser.addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Emit debug-level logs, including full subprocess command lines.',
    )
    ..argParser.addFlag(
      'no-color',
      negatable: false,
      help: 'Disable ANSI color output.',
    )
    ..argParser.addOption(
      'cache-dir',
      help: 'Override toolchain / engine cache root '
          '(default: \$HOME/.flutter_build).',
    )
    ..argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the flutter_build version and exit.',
    );

  runner
    ..addCommand(DoctorCommand())
    ..addCommand(PrecacheCommand())
    ..addCommand(WindowsCommand())
    ..addCommand(CleanCommand());

  try {
    final topLevel = runner.argParser.parse(args);
    if (topLevel['version'] == true) {
      stdout.writeln('flutter_build $packageVersion');
      exit(0);
    }
    Logger.instance = Logger(
      verbose: topLevel['verbose'] == true,
      color: topLevel['no-color'] != true && stdout.supportsAnsiEscapes,
    );

    final exitCode = await runner.run(args) ?? 0;
    exit(exitCode);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on ToolException catch (e) {
    Logger.instance.error(e.message);
    if (e.hint != null) {
      Logger.instance.hint(e.hint!);
    }
    exit(e.exitCode);
  } catch (e, st) {
    Logger.instance.error('Unhandled error: $e');
    Logger.instance.debug(st.toString());
    exit(1);
  }
}
