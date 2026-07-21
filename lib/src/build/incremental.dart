// 增量构建支持：基于依赖新鲜度（mtime）与输入指纹（stamp）判断能否跳过
// 昂贵的重编（kernel 编译、AOT gen_snapshot）。
//
// 判定采用经典 make 风格：产物存在、输入指纹匹配、且产物比所有输入都新 → 可
// 跳过。任何不确定（产物 / 指纹 / 依赖缺失，或依赖更新）都保守地判为「需要重
// 编」，绝不冒险产出陈旧产物。可用 `--no-incremental` 完全关闭。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 解析 Makefile 风格 depfile（frontend_server `--depfile` 产物）里的输入依赖。
///
/// 格式为 `<output>: <dep1> <dep2> ...`，其中：
///   - 行末反斜杠表示续行；
///   - 路径中的空格 / 反斜杠以 `\` 转义（`\ ` / `\\`）。
///
/// 仅取第一个 `:` 之后的依赖列表（输出目标为 Linux 路径，不含盘符冒号）。纯函数。
List<String> parseDepfileInputs(String content) {
  // 先消解行续接：反斜杠 + 换行 → 空格。
  final unwrapped = content.replaceAll('\\\n', ' ');
  final colon = unwrapped.indexOf(':');
  if (colon < 0) return const <String>[];
  final deps = unwrapped.substring(colon + 1);

  final result = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < deps.length; i++) {
    final c = deps[i];
    if (c == r'\' && i + 1 < deps.length) {
      final next = deps[i + 1];
      if (next == ' ' || next == r'\') {
        buf.write(next); // 还原被转义的空格 / 反斜杠。
        i++;
        continue;
      }
    }
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      if (buf.isNotEmpty) {
        result.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(c);
    }
  }
  if (buf.isNotEmpty) result.add(buf.toString());
  return result;
}

/// 对一组输入片段计算稳定指纹（sha256 十六进制）。用于把「不体现在依赖文件里」
/// 的编译输入（构建模式、dart-define、混淆开关、工具路径等）纳入新鲜度判断：
/// 这些值一变，即便源码 mtime 未变也必须重编。
String hashInputs(Iterable<String> parts) {
  final digest = sha256.convert(utf8.encode(parts.join('\u0000')));
  return digest.toString();
}

/// 判断 [outputPath] 是否相对 [inputPaths] 与指纹保持最新（可跳过重编）。
///
/// 返回 true（可跳过）当且仅当：
///   1. [outputPath] 存在；
///   2. 若给定 [stampPath]，其存在且内容等于 [expectedStamp]；
///   3. 每个 [inputPaths] 都存在，且其修改时间不晚于产物修改时间。
///
/// 任一条件不满足即返回 false（需要重编）。纯粹依赖文件系统 stat，无副作用。
bool isUpToDate({
  required String outputPath,
  required Iterable<String> inputPaths,
  String? stampPath,
  String? expectedStamp,
}) {
  final output = File(outputPath);
  if (!output.existsSync()) return false;

  if (stampPath != null) {
    final stampFile = File(stampPath);
    if (!stampFile.existsSync()) return false;
    if (stampFile.readAsStringSync() != (expectedStamp ?? '')) return false;
  }

  final outMtime = output.lastModifiedSync();
  for (final input in inputPaths) {
    final f = File(input);
    if (!f.existsSync()) return false;
    if (f.lastModifiedSync().isAfter(outMtime)) return false;
  }
  return true;
}
