// 插件源码补丁：修复第三方插件 C++ 源码在 Clang/LLVM-MinGW 交叉编译下的
// 兼容性问题。
//
// `.plugin_symlinks/` 下的插件目录是指向 pub-cache 的符号链接。为避免修改
// pub-cache 原件，需要补丁的插件目录会先从符号链接替换为真实副本，再对
// 副本做文本补丁。
//
// 补丁函数均为纯函数（输入原文 → 输出补丁后文本），便于单测；文件 I/O
// 与符号链接物化由 [PluginSourcePatcher.apply] 编排。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';

// ─── 纯函数补丁 ─────────────────────────────────────────────────────

/// 修补 `window_manager/windows/window_manager.cpp`：
///
/// 1. 移除 `#pragma once`——该 .cpp 既被直接编译又被 `#include` 进
///    `window_manager_plugin.cpp`，作为主文件编译时触发
///    `-Wpragma-once-outside-header`（-Werror 升级为错误）。
/// 2. `<Windows.h>` → `<windows.h>`——MinGW 的头文件全小写，Linux 上
///    大小写敏感的文件系统找不到 `Windows.h`。
/// 3. 移除类体内成员声明上的多余 `WindowManager::` 限定——MSVC 允许但
///    Clang 视为错误 `extra qualification on member`。仅匹配缩进行（类
///    体内），不影响类外定义（行首无缩进）。
String patchWindowManagerCpp(String content) {
  var out = content;
  // 1) 移除 #pragma once
  out = out.replaceAll('#pragma once\n', '');
  // 2) 修复 Windows.h 大小写
  out = out.replaceAll('#include <Windows.h>', '#include <windows.h>');
  // 3) 移除类体内多余限定（仅缩进行的 WindowManager::）
  out = out.replaceAllMapped(
    RegExp(r'^(  +\w.*?)WindowManager::', multiLine: true),
    (m) => m.group(1)!,
  );
  return out;
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

/// 给插件 `CMakeLists.txt` 追加 `-Wno-deprecated-declarations`。
///
/// `window_manager` 和 `screen_retriever_windows` 使用了 C++17 弃用的
/// `std::wstring_convert` / `std::codecvt_utf8_utf16`。插件 CMakeLists.txt
/// 已定义 `_SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING`，但该宏
/// 只对 MSVC 有效；Clang/libc++ 需要 `-Wno-deprecated-declarations`。
String addNoDeprecatedDeclarations(String content) {
  if (content.contains('-Wno-deprecated-declarations')) return content;
  final re = RegExp(r'apply_standard_settings\(\$\{PLUGIN_NAME\}\)');
  final match = re.firstMatch(content);
  if (match == null) return content;
  return content.replaceRange(
    match.end,
    match.end,
    '\n'
        'target_compile_options(\${PLUGIN_NAME} PRIVATE '
        '-Wno-deprecated-declarations)',
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
    'CMakeLists.txt': addNoDeprecatedDeclarations,
  },
  'hotkey_manager_windows': {
    'hotkey_manager_windows_plugin.cpp': patchHotkeyManagerPluginCpp,
  },
  'screen_retriever_windows': {
    'screen_retriever_windows_plugin.h': patchScreenRetrieverPluginH,
    'CMakeLists.txt': addNoDeprecatedDeclarations,
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
