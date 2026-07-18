// 构建产物远程部署：编译成功后把 Windows 产物 bundle 通过 scp 拷到远程
// Windows 机器，便于在 Windows 上直接测试运行。
//
// 关于 "git lfs"：它是 git 的大文件版本管理扩展（把大文件以指针形式存进
// git 仓库），无法把文件"通过 SSH 拷到远程 Windows 的 C 盘目录"。SSH→Windows
// 目录拷贝的标准工具是 scp（可正常处理大文件，如 45MB 的 flutter_windows.dll）。
// 因此本模块用 scp 实现目标；密码登录借助 sshpass 做非交互认证。
//
// 配置来自 config.yaml（git 不上传，附带 config.example.yaml 模板）：
//   host / ip、username、password、auto_copy、remote_dir[、port]
//
// 远程目标 = remote_dir / <app_name>（扁平结构，不镜像本地完整路径）。
// 例如 remote_dir 为 C:/flutter_build、app 名为 flutter_build_example：
//   远程 C:/flutter_build/flutter_build_example

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'exceptions.dart';
import 'logger.dart';
import 'process_runner.dart';

/// 远程部署配置（解析自 config.yaml）。
class DeployConfig {
  const DeployConfig({
    required this.host,
    required this.username,
    required this.password,
    required this.autoCopy,
    required this.remoteDir,
    required this.baseDir,
    this.port = 22,
  });

  /// 远程主机 IP / 域名。
  final String host;

  /// SSH 登录名。
  final String username;

  /// SSH 密码；为 null 时改用 SSH 密钥（不经 sshpass）。
  final String? password;

  /// 构建成功后是否自动拷贝。
  final bool autoCopy;

  /// 远程镜像根目录（如 `C:/project/flutter_build`），统一用正斜杠。
  final String remoteDir;

  /// 本地镜像根 = config.yaml 所在目录。用于计算产物的相对路径。
  final String baseDir;

  /// SSH 端口。
  final int port;

  static const fileName = 'config.yaml';

  /// 从 [startDir] 逐级向上查找 [fileName]；找到则解析，否则返回 null。
  ///
  /// 搜索顺序：
  /// 1. [startDir] 及其父目录（项目本地 config）
  /// 2. `Platform.script` 所在目录及其父目录（flutter_build 工具自身的 config
  ///    —— 全局激活 `--source path` 时 script 指向源码 bin/，向上可找到
  ///    仓库根的 config.yaml，对全局生效）
  /// 3. `~/.flutter_build/config.yaml`（全局兜底）
  static DeployConfig? find(String startDir) {
    // 1) 项目本地
    final local = _findFrom(startDir);
    if (local != null) return local;

    // 2) flutter_build 工具自身目录
    try {
      final scriptDir = p.dirname(Platform.script.toFilePath());
      final tool = _findFrom(scriptDir);
      if (tool != null) return tool;
    } catch (_) {
      // Platform.script 可能非 file: URI（如 snapshot），忽略
    }

    // 3) 全局兜底
    final home = Platform.environment['HOME'];
    if (home != null) {
      final f = File(p.join(home, '.flutter_build', fileName));
      if (f.existsSync()) {
        return parse(f.readAsStringSync(), baseDir: p.dirname(f.path));
      }
    }

    return null;
  }

  /// 从 [dir] 逐级向上查找 [fileName]；找到则解析，否则返回 null。
  static DeployConfig? _findFrom(String dir) {
    var d = Directory(p.normalize(p.absolute(dir)));
    while (true) {
      final f = File(p.join(d.path, fileName));
      if (f.existsSync()) {
        return parse(f.readAsStringSync(), baseDir: d.path);
      }
      final parent = d.parent;
      if (parent.path == d.path) return null; // 已到文件系统根
      d = parent;
    }
  }

  /// 解析 YAML 文本。[baseDir] 为 config.yaml 所在目录（本地镜像根）。
  static DeployConfig parse(String yamlText, {required String baseDir}) {
    final doc = loadYaml(yamlText);
    if (doc is! YamlMap) {
      throw ToolException('config.yaml 不是有效的 YAML 映射。');
    }
    final host = (doc['host'] ?? doc['ip'])?.toString().trim();
    if (host == null || host.isEmpty) {
      throw ToolException('config.yaml 缺少 host（或 ip）。');
    }
    final remoteDir = doc['remote_dir']?.toString().trim();
    if (remoteDir == null || remoteDir.isEmpty) {
      throw ToolException('config.yaml 缺少 remote_dir（远程目标根目录）。');
    }
    final rawPwd = doc['password']?.toString();
    return DeployConfig(
      host: host,
      username: doc['username']?.toString().trim() ?? 'ubuntu',
      password: (rawPwd != null && rawPwd.isNotEmpty) ? rawPwd : null,
      autoCopy: doc['auto_copy'] == true,
      remoteDir: _toPosix(remoteDir),
      baseDir: p.normalize(p.absolute(baseDir)),
      port: doc['port'] is int ? doc['port'] as int : 22,
    );
  }

  /// 计算 [localPath]（本地构建产物目录）在远程的目标路径：
  /// `remoteDir/<basename>`（扁平结构）。
  ///
  /// 例如 localPath 为 `.../build/win_cross/release/flutter_build_example`，
  /// remoteDir 为 `C:/flutter_build` → `C:/flutter_build/flutter_build_example`。
  String remotePathFor(String localPath) {
    final base = remoteDir.endsWith('/')
        ? remoteDir.substring(0, remoteDir.length - 1)
        : remoteDir;
    final name = p.basename(p.normalize(p.absolute(localPath)));
    return name.isEmpty ? base : '$base/$name';
  }

  static String _toPosix(String s) => s.replaceAll('\\', '/');
}

/// 一次部署的结果。
class DeployResult {
  DeployResult({
    required this.remotePath,
    required this.duration,
    required this.bytes,
  });

  final String remotePath;
  final Duration duration;
  final int bytes;
}

/// 用 scp（密码经 sshpass）把本地目录拷到远程 Windows。
class SshDeployer {
  SshDeployer({
    required this.config,
    Logger? logger,
    ProcessRunner? runner,
  })  : _log = logger ?? Logger.instance,
        _runner = runner ?? ProcessRunner(logger: logger ?? Logger.instance);

  final DeployConfig config;
  final Logger _log;
  final ProcessRunner _runner;

  /// 把 [localDir]（构建产物目录）拷到远程镜像位置，返回耗时与字节数。
  Future<DeployResult> deployDir(String localDir) async {
    final dir = Directory(localDir);
    if (!dir.existsSync()) {
      throw ArtifactException('待拷贝目录不存在: $localDir');
    }
    final remotePath = config.remotePathFor(localDir);
    final remoteParent = _posixDirname(remotePath);
    final bytes = _dirSize(dir);

    if (config.password != null) {
      await _requireTool('sshpass', '密码登录需要 sshpass：sudo apt install sshpass');
    }
    await _requireTool('scp', '需要 scp：sudo apt install openssh-client');

    _log.step('Deploy · 拷贝到 ${config.username}@${config.host} → $remotePath');
    _log.info('  大小 ${_fmtBytes(bytes)}');

    final sw = Stopwatch()..start();
    // 1) 确保远程父目录存在（不存在则自动创建，含多级）。
    //    New-Item -Force：可建多级目录、已存在也不报错，天然满足"没有则创建"。
    //    不用 `| Out-Null` 管道——远程默认 shell 若是 cmd.exe 会把 `|` 当成
    //    自身的管道而出错；输出交由容错解码打印即可。
    _log.info('  确保远程目录存在（不存在则创建）: $remoteParent');
    await _ssh([
      'powershell',
      '-NoProfile',
      '-Command',
      "New-Item -ItemType Directory -Force -Path '$remoteParent'",
    ]);
    // 2) scp -r 把 localDir 拷进远程父目录（→ remoteParent/<basename>）。
    await _scp(localDir, remoteParent);
    sw.stop();

    final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
    _log.success('Deploy 完成: $remotePath  用时 ${secs}s '
        '(${_fmtBytes(bytes)}, ${_fmtRate(bytes, sw.elapsed)})');
    return DeployResult(
        remotePath: remotePath, duration: sw.elapsed, bytes: bytes);
  }

  Future<void> _ssh(List<String> remoteCmd) async {
    final args = <String>[
      ..._commonSshOpts,
      '-p',
      '${config.port}',
      '${config.username}@${config.host}',
      ...remoteCmd,
    ];
    await _runWithAuth('ssh', args);
  }

  Future<void> _scp(String localDir, String remoteParent) async {
    final target = '${config.username}@${config.host}:$remoteParent';
    final args = <String>[
      '-r',
      ..._commonSshOpts,
      '-P', // 注意：scp 用大写 -P 指定端口
      '${config.port}',
      localDir,
      target,
    ];
    await _runWithAuth('scp', args);
  }

  static const List<String> _commonSshOpts = [
    '-o',
    'StrictHostKeyChecking=no',
    '-o',
    'UserKnownHostsFile=/dev/null',
    '-o',
    'LogLevel=ERROR',
  ];

  Future<void> _runWithAuth(String tool, List<String> args) async {
    if (config.password != null) {
      // 用 `sshpass -e` + 环境变量 SSHPASS，而非 `-p <密码>`：避免密码出现在
      // 进程参数列表与 verbose 日志（ProcessRunner 会 debug 打印命令行）中。
      await _runner.run(
        'sshpass',
        ['-e', tool, ...args],
        environment: {'SSHPASS': config.password!},
        stream: true,
        tag: 'deploy',
      );
    } else {
      await _runner.run(tool, args, stream: true, tag: 'deploy');
    }
  }

  Future<void> _requireTool(String tool, String hint) async {
    final path = await _runner.which(tool);
    if (path == null) throw MissingToolException(tool, hint: hint);
  }

  static String _posixDirname(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? path : path.substring(0, i);
  }

  int _dirSize(Directory dir) {
    var total = 0;
    for (final e in dir.listSync(recursive: true)) {
      if (e is File) total += e.lengthSync();
    }
    return total;
  }

  String _fmtBytes(int b) {
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(1)} KB';
    return '$b B';
  }

  String _fmtRate(int bytes, Duration d) {
    final s = d.inMilliseconds / 1000.0;
    if (s <= 0) return '—';
    return '${((bytes / (1 << 20)) / s).toStringAsFixed(1)} MB/s';
  }
}
