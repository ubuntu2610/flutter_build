// 共享文件系统工具。
//
// 集中放置流水线各处重复用到的目录复制 / 单文件复制 / 目录体积统计逻辑，
// 避免 pipeline、plugin_source_patcher、deploy 各自实现一份。
//
// 复制均采用「不跟随符号链接」策略并保留链接结构，这对 Flutter 的
// `flutter/ephemeral/.plugin_symlinks/` 至关重要：插件链接通常指向包根目录，
// 若跟随它们，示例工程里的 `build/` 会被重新扫进暂存目录，进而把
// `windows_src/.../.plugin_symlinks/...` 自身再复制一遍，形成无限嵌套路径。

import 'dart:io';

import 'package:path/path.dart' as p;

/// 复制目录树时同一目录内并发文件操作的默认上限。
///
/// 取值兼顾吞吐与文件描述符占用：过大在机械盘 / 网络盘上收益递减且更易触及
/// `ulimit -n`；8 在常见 SSD 上已能显著缩短大目录（如 `cpp_client_wrapper/`、
/// `flutter_assets/`）的复制时间。
const int kDefaultCopyConcurrency = 8;

/// 递归复制目录树，不跟随符号链接，并保留链接（改写为真实绝对目标）。
///
/// 语义与原 `copyTreePreservingLinks` 一致：
///   - [src] 不存在时静默返回（不创建 [dst]）；
///   - 空目录也会被创建到 [dst]；
///   - `Directory` 递归复制；`File` 直接复制；`Link` 解析为真实绝对目标后重建，
///     避免把「相对链接字符串」原样搬到新目录而变成坏链。
///
/// 性能：目录结构先同步建好，随后所有文件 / 链接操作汇入一个**有界**工作池并
/// 发执行（见 [kDefaultCopyConcurrency]），相比逐个 `await` 明显更快，同时不会
/// 因无界并发而耗尽文件描述符。
Future<void> copyTree(
  String src,
  String dst, {
  int concurrency = kDefaultCopyConcurrency,
}) async {
  final srcDir = Directory(src);
  if (!srcDir.existsSync()) return;

  // 先同步创建全部目录并收集文件 / 链接操作：保证每个文件落盘前其父目录已存在，
  // 从而可以安全地并发执行这些操作。链接目标在此阶段解析（listSync 期间 stat
  // 结果最稳定）。
  final ops = <Future<void> Function()>[];
  void walk(Directory dir, String target) {
    Directory(target).createSync(recursive: true);
    for (final entity in dir.listSync(recursive: false, followLinks: false)) {
      final t = p.join(target, p.basename(entity.path));
      if (entity is Directory) {
        walk(entity, t);
      } else if (entity is File) {
        ops.add(() => entity.copy(t));
      } else if (entity is Link) {
        final resolved = entity.resolveSymbolicLinksSync();
        ops.add(() => Link(t).create(resolved, recursive: true));
      }
    }
  }

  walk(srcDir, dst);
  await runBounded(ops, concurrency);
}

/// 复制单个文件；源不存在时静默跳过。会按需创建目标父目录。
Future<void> copyFileIfExists(String src, String dst) async {
  final f = File(src);
  if (!f.existsSync()) return;
  await Directory(p.dirname(dst)).create(recursive: true);
  await f.copy(dst);
}

/// 统计目录下所有普通文件的字节总和（递归）。
int dirSize(Directory dir) {
  var total = 0;
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is File) total += e.lengthSync();
  }
  return total;
}

/// 以至多 [concurrency] 的并发度依次执行 [ops] 中的异步操作。
///
/// 采用固定数量的 worker 争抢同一份任务队列（游标推进），是标准的有界并发池：
/// 空列表直接返回；[concurrency] < 1 时按 1 处理（退化为顺序执行）。任一操作
/// 抛出的异常会经由 `Future.wait` 向上传播。
Future<void> runBounded(
  List<Future<void> Function()> ops,
  int concurrency,
) async {
  if (ops.isEmpty) return;
  final limit = concurrency < 1 ? 1 : concurrency;
  var index = 0;

  Future<void> worker() async {
    while (index < ops.length) {
      final op = ops[index++];
      await op();
    }
  }

  final workerCount = limit < ops.length ? limit : ops.length;
  await Future.wait(<Future<void>>[
    for (var i = 0; i < workerCount; i++) worker(),
  ]);
}
