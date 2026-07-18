// 插件源码补丁：修复第三方插件 C++ 源码在 Clang/LLVM-MinGW 交叉编译下的
// 兼容性问题。
//
// `.plugin_symlinks/` 下的插件目录是指向 pub-cache 的符号链接。为避免修改
// pub-cache 原件，需要补丁的插件目录会先从符号链接替换为真实副本，再对
// 副本做文本补丁。
//
// 补丁函数均为纯函数（输入原文 → 输出补丁后文本），便于单测；文件 I/O
// 与符号链接物化由 [PluginSourcePatcher.apply] 编排。
//
// 设计原则：能用编译标志 / 垫片头文件解决的（如缺失头文件、-Werror 升级
// 的警告），不在此处改源码——那些由 pipeline 的 `CMAKE_CXX_FLAGS` 和
// `_materializeCompatHeaders` 统一处理。此处仅保留无法用标志/垫片解决的
// 硬错误（类型不匹配、Clang 不接受的 MSVC 扩展语法）。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';

// ─── 纯函数补丁 ─────────────────────────────────────────────────────

/// 修补 `window_manager/windows/window_manager.cpp`：
///
/// 移除类体内成员声明上的多余 `WindowManager::` 限定——MSVC 允许但
/// Clang 视为硬错误 `extra qualification on member`。仅匹配缩进行（类
/// 体内），不影响类外定义（行首无缩进）。
///
/// 其余兼容性问题（`#pragma once`、`<Windows.h>` 大小写、`codecvt` 弃用）
/// 已由 pipeline 的全局 `CMAKE_CXX_FLAGS` 和垫片头文件解决，无需改源码。
String patchWindowManagerCpp(String content) {
  return content.replaceAllMapped(
    RegExp(r'^(  +\w.*?)WindowManager::', multiLine: true),
    (m) => m.group(1)!,
  );
}

/// 修补 `window_manager/windows/window_manager_plugin.cpp`：
///
/// 移除类体内成员声明上的多余 `WindowManagerPlugin::` 限定——MSVC 允许但
/// Clang 视为硬错误 `extra qualification on member`。仅匹配缩进行（类
/// 体内），不影响类外定义（行首无缩进）。
String patchWindowManagerPluginCpp(String content) {
  return content.replaceAllMapped(
    RegExp(r'^(  +\w.*?)WindowManagerPlugin::', multiLine: true),
    (m) => m.group(1)!,
  );
}

/// 修补 `hotkey_manager_windows/windows/hotkey_manager_windows_plugin.cpp`：
///
/// `EncodableMap({{"identifier", identifier}})` 在 Clang 下无法将
/// `{"identifier", identifier}` 推导为 `pair<EncodableValue, EncodableValue>`
/// （两个元素均需用户定义转换：`const char*`→`EncodableValue` 和
/// `std::string`→`EncodableValue`）。显式包装为 `EncodableValue` 即可。
String patchHotkeyManagerPluginCpp(String content) {
  return content.replaceAll(
    'flutter::EncodableMap({{"identifier", identifier}})',
    'flutter::EncodableMap({{flutter::EncodableValue("identifier"), '
        'flutter::EncodableValue(identifier)}})',
  );
}

/// 修补 `screen_retriever_windows/windows/screen_retriever_windows_plugin.h`：
///
/// 移除成员函数声明上的多余 `ScreenRetrieverWindowsPlugin::` 限定
/// （Clang: `extra qualification on member`）。
String patchScreenRetrieverPluginH(String content) {
  return content
      .replaceAll(
        'void ScreenRetrieverWindowsPlugin::GetCursorScreenPoint(',
        'void GetCursorScreenPoint(',
      )
      .replaceAll(
        'void ScreenRetrieverWindowsPlugin::GetPrimaryDisplay(',
        'void GetPrimaryDisplay(',
      )
      .replaceAll(
        'void ScreenRetrieverWindowsPlugin::GetAllDisplays(',
        'void GetAllDisplays(',
      );
}

// ─── 编排 ──────────────────────────────────────────────────────────

/// 已知需要源码补丁的插件及其文件级补丁规则。
///
/// key: 插件名（对应 `.plugin_symlinks/<name>`）；
/// value: `{相对 windows/ 的文件路径: 补丁函数}`。
const Map<String, Map<String, String Function(String)>> _pluginPatches = {
  'window_manager': {
    'window_manager.cpp': patchWindowManagerCpp,
    'window_manager_plugin.cpp': patchWindowManagerPluginCpp,
  },
  'hotkey_manager_windows': {
    'hotkey_manager_windows_plugin.cpp': patchHotkeyManagerPluginCpp,
  },
  'screen_retriever_windows': {
    'screen_retriever_windows_plugin.h': patchScreenRetrieverPluginH,
  },
};

/// 对暂存目录下 `.plugin_symlinks/` 中已知有兼容问题的插件应用源码补丁。
class PluginSourcePatcher {
  const PluginSourcePatcher();

  /// 对 [ephemeralDir]（`flutter/ephemeral/`）下的插件链接应用补丁。
  ///
  /// 需要补丁的插件目录会从符号链接替换为真实副本（不修改 pub-cache 原
  /// 件），然后对副本做文本补丁。
  Future<void> apply(String ephemeralDir, {Logger? logger}) async {
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
