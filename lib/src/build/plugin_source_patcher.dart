// 插件源码补丁基础设施。
//
// 设计原则（见 .codebuddy/rules.md）：能用编译标志 / 垫片头文件解决的，
// 不改插件源码。绝大多数兼容性问题已由 pipeline 的 `CMAKE_CXX_FLAGS`
// （`-fms-extensions -Wno-error=microsoft-extra-qualification` 等）和垫片
// 头文件统一处理。
//
// 仅保留 1 个无法用标志解决的 C++ 类型硬错误补丁：EncodableMap 初始化
// （Clang/libc++ 的 initializer_list<pair> 转换规则比 MSVC STL 更严格）。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';

/// 修补 `hotkey_manager_windows/windows/hotkey_manager_windows_plugin.cpp`：
///
/// `EncodableMap({{"identifier", identifier}})` 在 Clang/libc++ 下无法将
/// `{"identifier", identifier}` 推导为 `pair<EncodableValue, EncodableValue>`
/// （Clang 的 initializer_list 元素 copy-list-initialization 不允许两个
/// 用户定义转换：`const char*`→`EncodableValue` 和
/// `std::string`→`EncodableValue`）。MSVC STL 允许，故此行在 Windows +
/// MSVC 下正常编译。显式包装为 `EncodableValue` 即可，且修改后仍与 MSVC
/// 兼容。
String patchHotkeyManagerPluginCpp(String content) {
  return content.replaceAll(
    'flutter::EncodableMap({{"identifier", identifier}})',
    'flutter::EncodableMap({{flutter::EncodableValue("identifier"), '
        'flutter::EncodableValue(identifier)}})',
  );
}

/// 已知需要源码补丁的插件及其文件级补丁规则。
const Map<String, Map<String, String Function(String)>> _pluginPatches = {
  'hotkey_manager_windows': {
    'hotkey_manager_windows_plugin.cpp': patchHotkeyManagerPluginCpp,
  },
};

/// 对暂存目录下 `.plugin_symlinks/` 中已知有兼容问题的插件应用源码补丁。
class PluginSourcePatcher {
  const PluginSourcePatcher();

  /// 对 [ephemeralDir]（`flutter/ephemeral/`）下的插件链接应用补丁。
  ///
  /// 需要补丁的插件目录会从符号链接替换为真实副本（不修改 pub-cache 原
  /// 件），然后对副本做文本补丁。当前 `_pluginPatches` 含 1 条规则
  /// （hotkey_manager_windows 的 EncodableMap 初始化，见上文说明）；若某项目
  /// 未依赖该插件，对应链接不存在时会被静默跳过。
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
