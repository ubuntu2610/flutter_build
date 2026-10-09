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
//
// 增量部署：产物 bundle 的大头是几乎不变的原生 DLL（opencv / onnxruntime /
// flutter_windows 等），每次全量 scp 重传浪费明显。本地保留一份上次部署的文件
// 清单（大小 + mtime + sha256），再次部署时只上传内容变化的文件、删除远端已
// 移除的文件；清单缺失（首次部署 / 被清理）或增量任何一步失败时自动回退全量
// 拷贝，行为与历史版本一致。清单文件放 bundle 目录同级（不入产物目录、不上
// 传远端）：`<bundle 同级>/.<app 名>.deploy_manifest.json`。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'exceptions.dart';
import 'io/fs_utils.dart';
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
    this.incrementalDeploy = true,
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

  /// 是否启用增量部署（只传变化的文件）。config 里 `incremental_deploy: false`
  /// 可关闭，回退为每次全量拷贝。
  final bool incrementalDeploy;

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
      incrementalDeploy: doc['incremental_deploy'] != false,
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

/// 增量部署清单里单个文件的指纹。
///
/// [size] + [mtimeMicros] 相同即视为未变（免哈希，热路径零开销）；二者任一
/// 变化时再算 [sha256] 确认（mtime 粒度 / 复制导致的假变化可免传输）。
class FileFingerprint {
  FileFingerprint({
    required this.size,
    required this.mtimeMicros,
    this.sha256,
  });

  final int size;
  final int mtimeMicros;

  /// 差分时回填 / 沿用历史哈希，故可变（其余字段不可变）。
  String? sha256;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'size': size,
        'mtime': mtimeMicros,
        if (sha256 != null) 'sha256': sha256,
      };

  static FileFingerprint fromJson(Map<String, dynamic> j) => FileFingerprint(
        size: j['size'] as int,
        mtimeMicros: j['mtime'] as int,
        sha256: j['sha256'] as String?,
      );
}

/// 清单落盘位置：bundle 目录同级、以 app 名命名的隐藏 JSON 文件，
/// 避免混入被部署的产物目录（也不会被上传到远端）。
String deployManifestPathFor(String localDir) {
  final abs = p.normalize(p.absolute(localDir));
  return p.join(p.dirname(abs), '.${p.basename(abs)}.deploy_manifest.json');
}

/// 递归扫描目录生成清单（相对 POSIX 路径 → 指纹）。不跟随符号链接：
/// 产物目录里不应有链接，遇到时保守跳过。
Map<String, FileFingerprint> scanDeployManifest(Directory root) {
  final out = <String, FileFingerprint>{};
  void walk(Directory d, String rel) {
    for (final e in d.listSync(followLinks: false)) {
      if (e is Link) continue;
      final child =
          rel.isEmpty ? p.basename(e.path) : '$rel/${p.basename(e.path)}';
      if (e is Directory) {
        walk(e, child);
      } else if (e is File) {
        final st = e.statSync();
        out[child] = FileFingerprint(
          size: st.size,
          mtimeMicros: st.modified.microsecondsSinceEpoch,
        );
      }
    }
  }

  walk(root, '');
  return out;
}

/// 读取上次部署清单；文件不存在或损坏时返回 null（触发全量部署）。
Map<String, FileFingerprint>? loadDeployManifest(String localDir) {
  final f = File(deployManifestPathFor(localDir));
  if (!f.existsSync()) return null;
  try {
    final doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final files = doc['files'];
    if (files is! Map) return null;
    return <String, FileFingerprint>{
      for (final e in files.entries)
        e.key as String:
            FileFingerprint.fromJson((e.value as Map).cast<String, dynamic>()),
    };
  } catch (_) {
    return null;
  }
}

/// 保存部署清单（按路径排序，稳定输出便于 diff / 审查）。
void saveDeployManifest(String localDir, Map<String, FileFingerprint> files) {
  final keys = files.keys.toList()..sort();
  File(deployManifestPathFor(localDir)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
    'files': <String, dynamic>{
      for (final k in keys) k: files[k]!.toJson(),
    },
  }));
}

/// 对单个文件算 sha256。产物最大单文件约几十 MB（如 opencv DLL），
/// 整体读入内存可接受；仅在上传候选文件上调用，热路径不会走到。
String hashDeployFile(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

/// 上次清单 vs 本地现状的差分结果。
class ManifestDiff {
  const ManifestDiff({
    required this.current,
    required this.changed,
    required this.removed,
  });

  /// 本次扫描的完整清单（含补全后的 sha256），部署成功后回写本地。
  final Map<String, FileFingerprint> current;

  /// 新增或内容变化的文件（需上传）。
  final List<String> changed;

  /// 本地已不存在、需从远端删除的文件。
  final List<String> removed;
}

/// 差分上次部署清单与本地目录现状（纯函数，仅对候选文件碰磁盘算哈希）。
ManifestDiff diffDeployManifests(
  Directory dir,
  Map<String, FileFingerprint> prev,
) {
  final current = scanDeployManifest(dir);
  final changed = <String>[];
  final removed = prev.keys.where((k) => !current.containsKey(k)).toList()
    ..sort();

  for (final entry in current.entries) {
    final old = prev[entry.key];
    if (old == null) {
      // 新文件。
      entry.value.sha256 = hashDeployFile(p.join(dir.path, entry.key));
      changed.add(entry.key);
      continue;
    }
    if (old.size == entry.value.size &&
        old.mtimeMicros == entry.value.mtimeMicros) {
      // size/mtime 都没变：沿用历史哈希（清单逐步补全），免传输。
      entry.value.sha256 = old.sha256;
      continue;
    }
    // size/mtime 变了：哈希确认，mtime 假变化时仍可免传输。
    final h = hashDeployFile(p.join(dir.path, entry.key));
    entry.value.sha256 = h;
    if (old.sha256 != null && old.sha256 == h) continue;
    changed.add(entry.key);
  }
  changed.sort();
  return ManifestDiff(current: current, changed: changed, removed: removed);
}

/// 增量部署的返回值：null 表示产物与上次完全一致（无需传输）。
class _IncrementalOutcome {
  _IncrementalOutcome(this.result, this.manifest);

  final DeployResult result;

  /// 部署成功后要回写本地的清单。
  final Map<String, FileFingerprint> manifest;
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
  ///
  /// 优先增量（见文件头注释）：本地有上次部署清单时只传变化文件；清单缺失
  /// 或增量失败时回退全量拷贝（与历史行为一致）。[DeployResult.bytes] 在
  /// 增量路径下是实际传输的字节数（全量路径为 bundle 总大小）。
  Future<DeployResult> deployDir(String localDir) async {
    final dir = Directory(localDir);
    if (!dir.existsSync()) {
      throw ArtifactException('待拷贝目录不存在: $localDir');
    }
    final remotePath = config.remotePathFor(localDir);
    final remoteParent = _posixDirname(remotePath);
    final bytes = dirSize(dir);

    if (config.password != null) {
      await _requireTool('sshpass', '密码登录需要 sshpass：sudo apt install sshpass');
    }
    await _requireTool('scp', '需要 scp：sudo apt install openssh-client');

    _log.step('Deploy · 拷贝到 ${config.username}@${config.host} → $remotePath');
    _log.info('  大小 ${_fmtBytes(bytes)}');

    final sw = Stopwatch()..start();

    // —— 增量路径 ——
    final prev = config.incrementalDeploy ? loadDeployManifest(localDir) : null;
    if (prev != null) {
      try {
        final inc = await _deployIncremental(dir, prev, remotePath);
        if (inc == null) {
          sw.stop();
          _log.success('Deploy 完成（产物无变化，跳过传输）: $remotePath  '
              'bundle 总大小 ${_fmtBytes(bytes)}');
          return DeployResult(
              remotePath: remotePath, duration: sw.elapsed, bytes: 0);
        }
        sw.stop();
        saveDeployManifest(localDir, inc.manifest);
        _log.success('Deploy 完成（增量）: $remotePath  用时 '
            '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
            '(${_fmtBytes(inc.result.bytes)}, '
            '${_fmtRate(inc.result.bytes, sw.elapsed)}) · '
            'bundle 总大小 ${_fmtBytes(bytes)}');
        return inc.result;
      } on Exception catch (e) {
        // 任何一步失败（远端被手工改动、exe 被运行中的进程锁定等）都回退
        // 全量拷贝；若全量也失败，下面的路径会给出明确错误。
        _log.info('  增量部署失败，回退全量拷贝：$e');
        sw
          ..reset()
          ..start();
      }
    }

    // —— 全量路径（与历史行为一致）——
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
    // 2) 先删除远程旧产物目录，再拷贝。scp 覆盖式拷贝不会清走旧文件：
    //    部分更新时会留下新旧混搭（曾出现 kernel_blob（Dart 快照）与
    //    原生 DLL 版本错位，导致运行期行为异常）。目录不存在则静默
    //    跳过；删除失败（如远程 exe 正在运行锁定文件）中止部署并提示。
    _log.info('  清理远程旧目录（防止新旧文件混搭）: $remotePath');
    try {
      await _ssh([
        'powershell',
        '-NoProfile',
        '-Command',
        "if (Test-Path '$remotePath') { "
            "Remove-Item -Recurse -Force -ErrorAction Stop '$remotePath' }",
      ]);
    } on SubprocessException catch (e) {
      throw ArtifactException(
        '清理远程目录失败: $remotePath\n'
        '远程应用可能正在运行并锁定了文件，请先关闭远程窗口后重试。\n'
        '$e',
      );
    }
    // 3) scp -r 把 localDir 拷进远程父目录（→ remoteParent/<basename>）。
    await _scp(localDir, remoteParent);
    sw.stop();

    // 全量成功后重建清单，作为下次增量部署的基准。
    saveDeployManifest(localDir, scanDeployManifest(dir));

    final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
    _log.success('Deploy 完成: $remotePath  用时 ${secs}s '
        '(${_fmtBytes(bytes)}, ${_fmtRate(bytes, sw.elapsed)})');
    return DeployResult(
        remotePath: remotePath, duration: sw.elapsed, bytes: bytes);
  }

  /// 增量部署：只上传变化的文件、删除远端已移除的文件。
  ///
  /// 返回 null 表示产物与上次完全一致（无需传输）。任何失败都抛异常，
  /// 由调用方回退全量拷贝。
  Future<_IncrementalOutcome?> _deployIncremental(
    Directory dir,
    Map<String, FileFingerprint> prev,
    String remotePath,
  ) async {
    final diff = diffDeployManifests(dir, prev);

    if (diff.changed.isEmpty && diff.removed.isEmpty) {
      // 无变化：确认远端目录仍在（被手工删除时回退全量重建）。
      final r = await _sshOut(<String>[
        'powershell',
        '-NoProfile',
        '-Command',
        "Test-Path '$remotePath'",
      ]);
      if (!r.stdout.trim().endsWith('True')) {
        throw ArtifactException('远端目录缺失: $remotePath（需全量重建）');
      }
      _log.info('  增量部署：产物与上次部署一致，无需传输。');
      return null;
    }

    final transferred = _sumSizes(dir, diff.changed);
    _log.info('  增量部署：${diff.changed.length} 个文件变化'
        '（${_fmtBytes(transferred)}），${diff.removed.length} 个删除。');
    for (final f in diff.changed.take(20)) {
      _log.info('    + $f');
    }
    if (diff.changed.length > 20) {
      _log.info('    … 共 ${diff.changed.length} 个');
    }

    // 1) 确保远端目标目录存在（scp -r 合并上传要求它已存在，避免
    //    单目录时被当成重命名目标）。
    await _ssh([
      'powershell',
      '-NoProfile',
      '-Command',
      "New-Item -ItemType Directory -Force -Path '$remotePath'",
    ]);

    // 2) 删除远端已移除的文件（保留“不残留旧文件”的语义，等价于旧版的
    //    整目录重建；-ErrorAction SilentlyContinue 容忍远端已被手工删过）。
    if (diff.removed.isNotEmpty) {
      final paths = [
        for (final rel in diff.removed) "'$remotePath/$rel'",
      ].join(',');
      await _ssh([
        'powershell',
        '-NoProfile',
        '-Command',
        'Remove-Item -Force -ErrorAction SilentlyContinue '
            '-LiteralPath $paths',
      ]);
    }

    // 3) 变化文件按原相对路径镜像暂存后一次 scp -r 上传：避免逐文件 scp
    //    的多次 ssh 握手；目录结构由 scp -r 在远端自动补齐。
    if (diff.changed.isNotEmpty) {
      final staging =
          await Directory.systemTemp.createTemp('flutter_build_deploy_');
      try {
        for (final rel in diff.changed) {
          final dst = p.join(staging.path, rel);
          Directory(p.dirname(dst)).createSync(recursive: true);
          File(p.join(dir.path, rel)).copySync(dst);
        }
        final entries = diff.changed
            .map((rel) => rel.split('/').first)
            .toSet()
            .map((seg) => p.join(staging.path, seg))
            .toList();
        await _scpEntries(entries, remotePath);
      } finally {
        staging.deleteSync(recursive: true);
      }
    }

    return _IncrementalOutcome(
      DeployResult(
          remotePath: remotePath, duration: Duration.zero, bytes: transferred),
      diff.current,
    );
  }

  static int _sumSizes(Directory dir, List<String> rels) => rels.fold(
        0,
        (n, rel) => n + File(p.join(dir.path, rel)).lengthSync(),
      );

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

  /// 执行 ssh 命令并捕获 stdout（不流式打印），用于读取远端探针结果
  /// （如 Test-Path）。输出量小，不会撑爆内存。
  Future<ProcessResult> _sshOut(List<String> remoteCmd) {
    final args = <String>[
      ..._commonSshOpts,
      '-p',
      '${config.port}',
      '${config.username}@${config.host}',
      ...remoteCmd,
    ];
    return _runWithAuth('ssh', args, stream: false);
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

  /// 把若干本地顶层条目合并拷入远端已存在的目录（增量上传用）。
  /// scp -r 会在远端自动创建不存在的子目录。
  Future<void> _scpEntries(List<String> localEntries, String remoteDir) async {
    final target = '${config.username}@${config.host}:$remoteDir';
    final args = <String>[
      '-r',
      ..._commonSshOpts,
      '-P',
      '${config.port}',
      ...localEntries,
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

  Future<ProcessResult> _runWithAuth(
    String tool,
    List<String> args, {
    bool stream = true,
  }) async {
    if (config.password != null) {
      // 用 `sshpass -e` + 环境变量 SSHPASS，而非 `-p <密码>`：避免密码出现在
      // 进程参数列表与 verbose 日志（ProcessRunner 会 debug 打印命令行）中。
      return _runner.run(
        'sshpass',
        ['-e', tool, ...args],
        environment: {'SSHPASS': config.password!},
        stream: stream,
        tag: 'deploy',
      );
    }
    return _runner.run(tool, args, stream: stream, tag: 'deploy');
  }

  Future<void> _requireTool(String tool, String hint) async {
    final path = await _runner.which(tool);
    if (path == null) throw MissingToolException(tool, hint: hint);
  }

  static String _posixDirname(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? path : path.substring(0, i);
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
