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
// 增量部署（远程对账模式）：产物 bundle 的大头是几乎不变的原生 DLL
// （opencv / onnxruntime / flutter_windows 等），每次全量 scp 重传浪费明显。
//
// 远程 Windows 的产物目录可能被手工改动（删了文件 / 换了文件 / 混入无关
// 文件），只信本地清单会漏传、漏删。因此对账基准是**远端实际清单**：
//   1) SSH 取远端每个文件的 sha256（Get-FileHash）；
//   2) 与本地逐文件对账（本地哈希可沿用上次清单缓存，size/mtime 未变免算）：
//        远端缺失          → 上传（缺文件）
//        远端 hash 不一致  → 上传覆盖（旧文件）
//        远端 hash 一致    → 跳过（免传输）
//        远端多出          → 删除（无用文件），并清理遗留空目录
//   3) 待上传文件按顶层条目分组，多路 scp 并行上传（异步传输）；
//   4) 完成后按本次实测吞吐率估算"全量删除+重拷"的耗时并对比显示。
// 任何一步失败（远端不可达 / exe 被锁定等）自动回退全量拷贝，行为与历史
// 版本一致。本地清单仍保留（`<bundle 同级>/.<app 名>.deploy_manifest.json`），
// 仅作为本地哈希缓存加速对账，不再作为远端状态的依据。

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

/// 本地 vs 远端的逐文件对账结果（纯函数，可独立测试）。
///
/// 分类以**内容哈希**为唯一依据（远端 mtime/时区不可靠）：
///   - [missing]  远端缺失 → 上传
///   - [expired]  远端存在但哈希不同（旧文件）→ 上传覆盖
///   - [remove]   远端多出（本地没有，无用文件）→ 远端删除
///   - [same]     两端哈希一致 → 跳过（免传输）
class RemoteReconcile {
  const RemoteReconcile({
    required this.missing,
    required this.expired,
    required this.remove,
    required this.same,
  });

  final List<String> missing;
  final List<String> expired;
  final List<String> remove;
  final List<String> same;

  /// 需要上传的文件 = 缺失 + 过期。
  List<String> get upload => [...missing, ...expired]..sort();

  bool get needsTransfer => missing.isNotEmpty || expired.isNotEmpty || remove.isNotEmpty;

  static RemoteReconcile compute(
    Map<String, String> localHashes,
    Map<String, String> remoteHashes,
  ) {
    final missing = <String>[];
    final expired = <String>[];
    final same = <String>[];
    for (final entry in localHashes.entries) {
      final remote = remoteHashes[entry.key];
      if (remote == null) {
        missing.add(entry.key);
      } else if (remote == entry.value) {
        same.add(entry.key);
      } else {
        expired.add(entry.key);
      }
    }
    final remove = remoteHashes.keys
        .where((k) => !localHashes.containsKey(k))
        .toList()
      ..sort();
    return RemoteReconcile(
      missing: missing..sort(),
      expired: expired..sort(),
      remove: remove,
      same: same..sort(),
    );
  }
}

/// 把待上传文件按**顶层条目**聚合并均衡分配到最多 [maxGroups] 组。
///
/// 同一顶层条目（如 `data/`）的所有文件必须落在同一组：多路 scp 并行时各
/// 组写远端互不相交的子树，避免并发创建同一目录的竞争。条目按总字节降序
/// 贪心放入当前最轻的桶（LPT，字节近似均衡）。纯函数。
List<List<String>> balanceUploadGroups(
  Iterable<String> relPaths,
  int Function(String rel) sizeOf,
  int maxGroups,
) {
  // 顶层条目 → 文件列表 / 字节合计。
  final entries = <String, List<String>>{};
  final entryBytes = <String, int>{};
  for (final rel in relPaths) {
    final top = rel.contains('/') ? rel.split('/').first : rel;
    (entries[top] ??= []).add(rel);
    entryBytes[top] = (entryBytes[top] ?? 0) + sizeOf(rel);
  }
  if (entries.isEmpty) return const [];

  final tops = entryBytes.keys.toList()
    ..sort((a, b) => entryBytes[b]!.compareTo(entryBytes[a]!));
  final groupCount = maxGroups < 1 ? 1 : (maxGroups > tops.length ? tops.length : maxGroups);

  // LPT 贪心：下一个条目放入当前总字节最小的桶。
  final buckets = List.generate(groupCount, (_) => <String>[]);
  final bucketBytes = List<int>.filled(groupCount, 0);
  for (final top in tops) {
    var lightest = 0;
    for (var i = 1; i < groupCount; i++) {
      if (bucketBytes[i] < bucketBytes[lightest]) lightest = i;
    }
    buckets[lightest].addAll(entries[top]!);
    bucketBytes[lightest] += entryBytes[top]!;
  }
  for (final b in buckets) {
    b.sort();
  }
  return buckets;
}

/// 增量部署的返回值：null 表示远端与本地完全一致（无需传输）。
class _IncrementalOutcome {
  _IncrementalOutcome(
    this.result,
    this.manifest, {
    required this.reconcile,
    required this.transferElapsed,
  });

  final DeployResult result;

  /// 部署成功后要回写本地的清单。
  final Map<String, FileFingerprint> manifest;

  /// 本次对账的分类结果（供日志展示）。
  final RemoteReconcile reconcile;

  /// 纯传输阶段耗时（不含远端对账扫描），用于吞吐率估算。
  final Duration transferElapsed;
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

  /// 并行上传的路数（异步传输）。
  static const int _maxParallelUploads = 4;

  /// 把 [localDir]（构建产物目录）同步到远程镜像位置，返回耗时与字节数。
  ///
  /// 优先远端对账增量（见文件头注释）：以远端实际文件指纹为基准，只传缺失 /
  /// 过期文件、删除远端无用文件；对账任何一步失败时回退全量拷贝（与历史行为
  /// 一致）。[DeployResult.bytes] 在增量路径下是实际传输的字节数（全量路径为
  /// bundle 总大小）。
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

    _log.step('Deploy · 同步到 ${config.username}@${config.host} → $remotePath');
    _log.info('  bundle 总大小 ${_fmtBytes(bytes)}');

    final sw = Stopwatch()..start();

    // —— 增量路径（远端对账）——
    if (config.incrementalDeploy) {
      try {
        final inc = await _deployReconciled(dir, remotePath);
        if (inc == null) {
          sw.stop();
          _log.success('Deploy 完成（远端与本地逐文件一致，跳过传输）: '
              '$remotePath  bundle 总大小 ${_fmtBytes(bytes)}');
          return DeployResult(
              remotePath: remotePath, duration: sw.elapsed, bytes: 0);
        }
        sw.stop();
        saveDeployManifest(localDir, inc.manifest);
        final r = inc.reconcile;
        _log.success('Deploy 完成（增量同步）: $remotePath  用时 '
            '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
            '（上传 ${_fmtBytes(inc.result.bytes)}：缺 ${r.missing.length} / 旧 '
            '${r.expired.length} · 跳过 ${r.same.length} · 删除多余 '
            '${r.remove.length}）');
        _logComparison(
          bundleBytes: bytes,
          uploadedBytes: inc.result.bytes,
          elapsed: inc.transferElapsed,
        );
        return DeployResult(
            remotePath: remotePath,
            duration: sw.elapsed,
            bytes: inc.result.bytes);
      } on Exception catch (e) {
        // 任何一步失败（远端不可达、exe 被运行中的进程锁定等）都回退全量
        // 拷贝；若全量也失败，下面的路径会给出明确错误。
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

  /// 增量部署（远端对账模式）。
  ///
  /// 流程：取远端逐文件指纹 → 与本地对账（缺/旧/多余/一致）→ 删除远端多余
  /// 文件与空目录 → 按顶层条目分组并行上传缺失/过期文件。
  ///
  /// 返回 null 表示远端与本地完全一致（无需传输）。任何失败都抛异常，由
  /// 调用方回退全量拷贝。
  Future<_IncrementalOutcome?> _deployReconciled(
    Directory dir,
    String remotePath,
  ) async {
    // 1) 本地逐文件哈希（沿用上次清单缓存：size/mtime 未变免算哈希）。
    //    注意：缓存沿用可能得到 null（历史清单从未算过哈希的文件）——
    //    对账要求**每个**本地文件都有哈希，否则它不会出现在 localHashes
    //    里，远端的同名文件会被误判为"多余"而删除（数据破坏）。null 一律
    //    现算并回填，随清单持久化，下次免算。
    final prev = loadDeployManifest(dir.path) ?? const <String, FileFingerprint>{};
    final local = diffDeployManifests(dir, prev).current;
    final localHashes = <String, String>{};
    for (final e in local.entries) {
      final h = e.value.sha256 ?? hashDeployFile(p.join(dir.path, e.key));
      e.value.sha256 = h;
      localHashes[e.key] = h;
    }

    // 2) 远端实际清单（文件名 + sha256）。目录不存在 → 抛异常回退全量重建。
    final remoteHashes = await _fetchRemoteManifest(remotePath);

    // 3) 对账（以内容哈希为唯一依据）。
    final rec = RemoteReconcile.compute(localHashes, remoteHashes);
    if (!rec.needsTransfer) {
      _log.info('  对账完成：远端与本地逐文件一致（${rec.same.length} 个），'
          '无需传输。');
      return null;
    }

    final uploadBytes = _sumSizes(dir, rec.upload);
    _log.info('  对账结果：上传 ${rec.upload.length} 个'
        '（缺失 ${rec.missing.length} / 过期 ${rec.expired.length}，'
        '${_fmtBytes(uploadBytes)}）· 删除远端多余 ${rec.remove.length} 个 · '
        '一致 ${rec.same.length} 个跳过');
    for (final f in rec.upload.take(20)) {
      _log.info('    ↑ $f');
    }
    if (rec.upload.length > 20) {
      _log.info('    … 共 ${rec.upload.length} 个');
    }

    // 4) 确保远端目标目录存在（scp -r 合并上传要求它已存在）。
    await _ssh([
      'powershell',
      '-NoProfile',
      '-Command',
      "New-Item -ItemType Directory -Force -Path '$remotePath'",
    ]);

    // 5) 删除远端无用文件（本地不存在的），并清理遗留的空目录。
    if (rec.remove.isNotEmpty) {
      final paths = [
        for (final rel in rec.remove) "'$remotePath/$rel'",
      ].join(',');
      await _ssh([
        'powershell',
        '-NoProfile',
        '-Command',
        'Remove-Item -Force -ErrorAction SilentlyContinue '
            '-LiteralPath $paths',
      ]);
      await _pruneEmptyRemoteDirs(remotePath);
    }

    // 6) 按顶层条目分组并行上传（目录结构由 scp -r 在远端自动补齐）。
    final sw = Stopwatch()..start();
    final bytes = await _uploadGrouped(dir, rec.upload, remotePath);
    sw.stop();

    return _IncrementalOutcome(
      DeployResult(
          remotePath: remotePath, duration: Duration.zero, bytes: bytes),
      local,
      reconcile: rec,
      transferElapsed: sw.elapsed,
    );
  }

  /// 取远端 [remotePath] 下每个文件的 sha256 指纹（相对 POSIX 路径 → 哈希）。
  ///
  /// 用 PowerShell Get-FileHash 对远端全量内容算哈希；整个命令包在双引号里，
  /// 远端默认 shell（cmd）不解释引号内的管道。目录不存在时输出 NO_DIR，
  /// 抛异常触发全量回退。
  Future<Map<String, String>> _fetchRemoteManifest(String remotePath) async {
    final root = remotePath.replaceAll("'", "''");
    final r = await _sshOut(<String>[
      'powershell',
      '-NoProfile',
      '-Command',
      '"\$root = \'$root\'; '
          "if (-not (Test-Path -LiteralPath \$root)) { Write-Output 'NO_DIR' } "
          'else { Get-ChildItem -LiteralPath \$root -Recurse -File | '
          'ForEach-Object { '
          // 反斜杠用 [char]92 构造：字符串字面量的反斜杠经 ssh→cmd→
          // powershell 多层传递后转义层数不可控（实测 '\\\\' 到远端已是
          // 4 个字符，Replace 字面匹配失败，rel 保持反斜杠导致对账全错）。
          // [char]92 / [char]47 不经过任何转义层，行为确定。
          '\$rel = \$_.FullName.Substring(\$root.Length + 1)'
          '.Replace([char]92, [char]47); '
          '\$h = (Get-FileHash -LiteralPath \$_.FullName -Algorithm SHA256).Hash.ToLower(); '
          "Write-Output (\$rel + '|' + \$_.Length + '|' + \$h) } }\"",
    ]);
    final out = r.stdout.trim();
    if (out.startsWith('NO_DIR')) {
      throw ArtifactException('远端目录缺失: $remotePath（需全量重建）');
    }
    final hashes = <String, String>{};
    for (final raw in out.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line == 'NO_DIR') continue;
      final parts = line.split('|');
      if (parts.length < 3) continue; // 容错：跳过异常行
      final hash = parts.last.trim().toLowerCase();
      // 兜底归一化：远端 Replace 失效时 rel 可能带反斜杠。
      final rel =
          parts.sublist(0, parts.length - 2).join('|').trim().replaceAll('\\', '/');
      if (rel.isEmpty || hash.length != 64) continue;
      hashes[rel] = hash;
    }
    return hashes;
  }

  /// 删除远端多余文件被清走后遗留的空目录（从深到浅一轮）。
  Future<void> _pruneEmptyRemoteDirs(String remotePath) async {
    // 注意：每次 ssh 都是独立的 PowerShell 会话，\$root 不会延续——路径
    // 必须由 Dart 侧插值注入（单引号转义防路径注入）。
    final root = remotePath.replaceAll("'", "''");
    await _ssh([
      'powershell',
      '-NoProfile',
      '-Command',
      '"Get-ChildItem -LiteralPath \'$root\' -Recurse -Directory | '
          'Sort-Object { \$_.FullName.Length } -Descending | '
          'Where-Object { -not (Get-ChildItem -LiteralPath \$_.FullName '
          '-Force) } | Remove-Item -Force -ErrorAction SilentlyContinue"',
    ]);
  }

  /// 待上传文件按顶层条目分组、多路 scp 并行上传，返回传输字节数。
  ///
  /// 同一顶层条目的文件在同一组（见 [balanceUploadGroups]），各组写远端
  /// 互不相交的子树，避免并发目录创建竞争；组内仍按相对路径镜像暂存，
  /// 避免逐文件 scp 的多次 ssh 握手。
  Future<int> _uploadGrouped(
    Directory dir,
    List<String> files,
    String remotePath,
  ) async {
    if (files.isEmpty) return 0;
    final groups = balanceUploadGroups(
      files,
      (rel) => File(p.join(dir.path, rel)).lengthSync(),
      _maxParallelUploads,
    );
    var bytes = 0;
    await Future.wait(<Future<void>>[
      for (final group in groups)
        () async {
          if (group.isEmpty) return;
          bytes += _sumSizes(dir, group);
          final staging =
              await Directory.systemTemp.createTemp('flutter_build_deploy_');
          try {
            for (final rel in group) {
              final dst = p.join(staging.path, rel);
              Directory(p.dirname(dst)).createSync(recursive: true);
              File(p.join(dir.path, rel)).copySync(dst);
            }
            final entries = group
                .map((rel) => rel.split('/').first)
                .toSet()
                .map((seg) => p.join(staging.path, seg))
                .toList();
            await _scpEntries(entries, remotePath);
          } finally {
            staging.deleteSync(recursive: true);
          }
        }(),
    ]);
    return bytes;
  }

  /// 显示"增量同步 vs 全量删除+重拷"的耗时对比。
  ///
  /// 全量耗时按本次**纯传输**实测吞吐率对 bundle 总量估算（不做真实全量
  /// 基准——那需要删除远端全部重传，与节省的初衷相悖）。[elapsed] 为传输
  /// 阶段耗时；无传输时无法估算，跳过对比行。
  void _logComparison({
    required int bundleBytes,
    required int uploadedBytes,
    required Duration elapsed,
  }) {
    final secs = elapsed.inMilliseconds / 1000.0;
    if (uploadedBytes <= 0 || secs <= 0) return;
    final rate = uploadedBytes / secs; // bytes/s（含对账开销的实测均值）
    final estFullSec = bundleBytes / rate;
    if (estFullSec <= secs) return;
    final saved = ((1 - secs / estFullSec) * 100).clamp(0, 100);
    _log.info('  对比全量删除+重拷：bundle 总量 ${_fmtBytes(bundleBytes)}，'
        '实测吞吐 ${_fmtRate(uploadedBytes, elapsed)} → 全量约需 '
        '${estFullSec.toStringAsFixed(1)}s，本次增量同步 '
        '${secs.toStringAsFixed(1)}s，节省约 ${saved.toStringAsFixed(0)}%');
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
    await _runScp(<String>[
      '-r',
      ..._commonSshOpts,
      '-P', // 注意：scp 用大写 -P 指定端口
      '${config.port}',
      localDir,
      target,
    ]);
  }

  /// 把若干本地顶层条目合并拷入远端已存在的目录（增量上传用）。
  /// scp -r 会在远端自动创建不存在的子目录。
  Future<void> _scpEntries(List<String> localEntries, String remoteDir) async {
    final target = '${config.username}@${config.host}:$remoteDir';
    await _runScp(<String>[
      '-r',
      ..._commonSshOpts,
      '-P',
      '${config.port}',
      ...localEntries,
      target,
    ]);
  }

  /// 执行 scp：优先 `-O` 强制传统 rcp 协议。
  ///
  /// 【实测坑】OpenSSH 9.0+ 的 scp 默认走 SFTP 协议，对本工程的 Windows
  /// OpenSSH 目标会**静默丢文件**：exit 0、无任何警告，但部分文件（尤其是
  /// bundle 顶层的多个 DLL）根本没落地——119 MB 的 bundle 远端只有 37 MB，
  /// 历史上所有"部署成功"实际都不完整，导致远端新旧文件混搭。`-O`（rcp
  /// 协议）实测完整可靠。老版本 OpenSSH（<9.0）不认识 `-O`，识别到参数
  /// 错误时回退默认协议。
  Future<void> _runScp(List<String> scpArgs) async {
    try {
      await _runWithAuth('scp', <String>['-O', ...scpArgs]);
    } on SubprocessException catch (e) {
      final err = e.stderrText.toLowerCase();
      if (!err.contains('unknown option') &&
          !err.contains('unrecognized option')) {
        rethrow;
      }
      _log.debug('scp 不支持 -O（OpenSSH < 9.0），回退默认协议。');
      await _runWithAuth('scp', scpArgs);
    }
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
