// Structured, colored logger tailored for a Dart CLI.
//
// Kept dependency-free on purpose: swapping this out later for `package:logging`
// or a JSON logger for CI should touch only this file.

import 'dart:io';

class Logger {
  Logger({required this.verbose, required this.color});

  static Logger instance = Logger(verbose: false, color: false);

  final bool verbose;
  final bool color;

  static const _reset = '\x1B[0m';
  static const _dim = '\x1B[2m';
  static const _bold = '\x1B[1m';
  static const _red = '\x1B[31m';
  static const _green = '\x1B[32m';
  static const _yellow = '\x1B[33m';
  static const _blue = '\x1B[34m';
  static const _cyan = '\x1B[36m';

  String _c(String code, String s) => color ? '$code$s$_reset' : s;

  void debug(String message) {
    if (!verbose) return;
    stderr.writeln(_c(_dim, '  · $message'));
  }

  void info(String message) {
    stdout.writeln(message);
  }

  void step(String message) {
    stdout.writeln(_c('$_bold$_cyan', '▶ $message'));
  }

  void success(String message) {
    stdout.writeln(_c(_green, '✓ ') + message);
  }

  void warn(String message) {
    stderr.writeln(_c(_yellow, '! ') + message);
  }

  void error(String message) {
    stderr.writeln(_c('$_bold$_red', '✗ ') + message);
  }

  void hint(String message) {
    stderr.writeln(_c(_blue, '  → ') + message);
  }

  /// Print a small labeled table (key → value pairs). Column-aligned.
  void kv(Map<String, String> pairs) {
    if (pairs.isEmpty) return;
    final maxKey = pairs.keys.map((k) => k.length).reduce((a, b) => a > b ? a : b);
    for (final entry in pairs.entries) {
      final label = entry.key.padRight(maxKey);
      stdout.writeln('  ${_c(_dim, label)}  ${entry.value}');
    }
  }

  /// Group a set of related log lines under [title]. Purely cosmetic.
  Future<T> group<T>(String title, Future<T> Function() body) async {
    step(title);
    final sw = Stopwatch()..start();
    try {
      final result = await body();
      sw.stop();
      debug('$title finished in ${sw.elapsedMilliseconds}ms');
      return result;
    } catch (_) {
      sw.stop();
      rethrow;
    }
  }
}
