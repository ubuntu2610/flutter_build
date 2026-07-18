// 插件源码补丁基础设施。
//
// 设计原则（见 .codebuddy/rules.md）：能用编译标志 / 垫片头文件解决的，
// 不改插件源码。当前所有兼容性问题已由 pipeline 的 `CMAKE_CXX_FLAGS`
// （`-fms-extensions -fms-compatibility -Wno-error=...`）和垫片头文件
// 统一处理，无需源码补丁。
//
// 本模块保留物化符号链接 + 应用补丁的基础设施，以便未来遇到无法用标志 /
// 垫片解决的硬错误时可在此注册补丁，而不需修改 pipeline 编排逻辑。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';

/// 已知需要源码补丁的插件及其文件级补丁规则。
///
/// 当前为空——所有兼容性问题均通过编译标志和垫片头文件解决。
/// 注册格式：`{插件名: {相对 windows/ 的文件路径: 补丁函数}}`。
const Map<String, Map<String, String Function(String)>> _pluginPatches = {};

/// 对暂存目录下 `.plugin_symlinks/` 中已知有兼容问题的插件应用源码补丁。
class PluginSourcePatcher {
  const PluginSourcePatcher();

  /// 对 [ephemeralDir]（`flutter/ephemeral/`）下的插件链接应用补丁。
  ///
  /// 需要补丁的插件目录会从符号链接替换为真实副本（不修改 pub-cache 原
  /// 件），然后对副本做文本补丁。当前 `_pluginPatches` 为空，此方法为
  /// no-op。
  Future<void> apply(String ephemeralDir, {Logger? logger}) async {
    if (_pluginPatches.isEmpty) return;
    final log = logger ?? Logger.instance;
    final symlinkDir = Directory(p.join(ephemeralDir, '.plugin_symlinks'));
    if (!symlinkDir.existsSync()) return;

    final patched = <String>[];
    for (final entry in _pluginPatches.entries) {
      patched.addAll(
        await _patchPlugin(symlinkDir.path, entry.key, entry.value),
      );
    }

    if (patched.isNotEmpty) {
      log.info('已补丁插件源码（Clang/MinGW 兼容）：${patched.join(', ')}');
    }
  }

  /// 物化插件符号链接为真实副本，然后应用文件补丁。返回已补丁文件列表
  /// （`插件名/文件名`）。
  Future<List<String>> _patchPlugin(
    String symlinkDirPath,
    String pluginName,
    Map<String, String Function(String)> patches,
  ) async {
    final pluginLinkPath = p.join(symlinkDirPath, pluginName);
    final link = Link(pluginLinkPath);
    if (!link.existsSync()) return const [];

    // 物化：符号链接 → 真实副本（不修改 pub-cache 原件）。
    final realPath = link.resolveSymbolicLinksSync();
    await link.delete();
    await _copyTree(realPath, pluginLinkPath);

    final patchedFiles = <String>[];
    for (final entry in patches.entries) {
      final file = File(p.join(pluginLinkPath, 'windows', entry.key));
      if (!file.existsSync()) continue;
      final original = await file.readAsString();
      final result = entry.value(original);
      if (result != original) {
        await file.writeAsString(result);
        patchedFiles.add('$pluginName/${entry.key}');
      }
    }
    return patchedFiles;
  }

  /// 递归复制目录树，不跟随符号链接（与 pipeline.copyTreePreservingLinks
  /// 逻辑一致，此处独立实现以避免循环依赖）。
  Future<void> _copyTree(String src, String dst) async {
    await Directory(dst).create(recursive: true);
    for (final entity in Directory(src).listSync(followLinks: false)) {
      final target = p.join(dst, p.basename(entity.path));
      if (entity is Directory) {
        await _copyTree(entity.path, target);
      } else if (entity is File) {
        await entity.copy(target);
      } else if (entity is Link) {
        await Link(target)
            .create(entity.resolveSymbolicLinksSync(), recursive: true);
      }
    }
  }
}
