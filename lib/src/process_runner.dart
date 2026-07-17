// Subprocess helpers.
//
// Wraps `Process.start` with three behaviors we always want:
//   1. Live streaming of stdout/stderr to our [Logger] (with prefix).
//   2. Collected output for post-mortem diagnostics on failure.
//   3. Typed non-zero-exit failure via [SubprocessException].

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';
import 'logger.dart';

class ProcessResult {
  ProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

class ProcessRunner {
  ProcessRunner({Logger? logger}) : _log = logger ?? Logger.instance;

  final Logger _log;

  /// Run [executable] with [arguments]. If [checked] is true (default) a
  /// non-zero exit throws [SubprocessException]. If [stream] is true the
  /// subprocess's stdout/stderr are also mirrored to our stdout/stderr in
  /// real time (each line prefixed with `[<tag>]` if [tag] is provided).
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool checked = true,
    bool stream = false,
    String? tag,
  }) async {
    _log.debug(
      'exec: $executable ${arguments.join(' ')}'
      '${workingDirectory != null ? '  (cwd: $workingDirectory)' : ''}',
    );

    final Process proc;
    try {
      proc = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      throw MissingToolException(
        executable,
        hint: 'Underlying error: ${e.message}',
      );
    }

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final prefix = tag != null ? '[$tag] ' : '';

    // 用容错 UTF-8 解码：远程 Windows（可能是 GBK 等非 UTF-8 代码页）或 scp 的
    // 进度输出可能含非法 UTF-8 字节，严格解码会抛 FormatException 直接崩溃整个
    // 进程。allowMalformed 让非法字节变成占位符而非抛错。
    const decoder = Utf8Decoder(allowMalformed: true);

    final stdoutDone = proc.stdout
        .transform(decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stdoutBuf.writeln(line);
      if (stream) stdout.writeln('$prefix$line');
    }).asFuture<void>();

    final stderrDone = proc.stderr
        .transform(decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderrBuf.writeln(line);
      if (stream) stderr.writeln('$prefix$line');
    }).asFuture<void>();

    final code = await proc.exitCode;
    await Future.wait<void>([stdoutDone, stderrDone]);

    final result = ProcessResult(
      exitCode: code,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );

    if (checked && code != 0) {
      throw SubprocessException(
        executable: executable,
        arguments: arguments,
        subprocessExitCode: code,
        stderrText:
            result.stderr.trim().isEmpty ? result.stdout : result.stderr,
      );
    }
    return result;
  }

  /// Return the absolute path to [executable] on PATH, or `null` if it
  /// cannot be found. Uses `which` on POSIX.
  Future<String?> which(String executable) async {
    try {
      final r = await run('which', [executable], checked: false);
      if (r.exitCode != 0) return null;
      final line = r.stdout.trim();
      return line.isEmpty ? null : line;
    } on MissingToolException {
      return null;
    }
  }
}
