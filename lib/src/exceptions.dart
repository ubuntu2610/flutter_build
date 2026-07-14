// 异常层次结构。
//
// 所有异常继承自 [ToolException]，携带：
//   - message: 用户可读的错误描述
//   - hint:    可选的修复建议（通常是一条 shell 命令）
//   - exitCode: CLI 退出码，分层约定：
//       1 = 通用错误
//       2 = 缺失工具（wine/cmake/ninja）
//       3 = Flutter SDK 问题
//       4 = 工程问题（无 pubspec / 无 windows 脚手架）
//       5 = 子进程失败
//       6 = 制品完整性问题（下载校验失败 / 缺失文件）
//
// main() 里 catch(ToolException) 统一渲染，不输出 stack trace。

class ToolException implements Exception {
  ToolException(this.message, {this.hint, this.exitCode = 1});

  final String message;
  final String? hint;
  final int exitCode;

  @override
  String toString() => message;
}

/// A required external program (cmake, ninja, wine, ...) could not be found.
class MissingToolException extends ToolException {
  MissingToolException(String toolName, {String? hint})
      : super(
          'Required tool not found on PATH: $toolName',
          hint: hint,
          exitCode: 2,
        );
}

/// The user's Flutter SDK layout is not what we expect (missing engine
/// version file, unsupported channel, etc.).
class FlutterSdkException extends ToolException {
  FlutterSdkException(super.message, {super.hint}) : super(exitCode: 3);
}

/// The current directory is not a valid Flutter application project.
class ProjectException extends ToolException {
  ProjectException(super.message, {super.hint}) : super(exitCode: 4);
}

/// A subprocess exited with a non-zero code.
class SubprocessException extends ToolException {
  SubprocessException({
    required this.executable,
    required this.arguments,
    required this.subprocessExitCode,
    required this.stderrText,
  }) : super(
          'Subprocess failed (exit $subprocessExitCode): $executable '
              '${arguments.join(' ')}\n$stderrText',
          exitCode: 5,
        );

  final String executable;
  final List<String> arguments;
  final int subprocessExitCode;
  final String stderrText;
}

/// A downloaded artifact failed integrity or layout checks.
class ArtifactException extends ToolException {
  ArtifactException(super.message, {super.hint}) : super(exitCode: 6);
}
