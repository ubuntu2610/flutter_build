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

import '../io/fs_utils.dart';
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

/// 修补 `file_selector_windows/windows/file_dialog_controller.h`：
///
/// `IFileDialogPtr dialog_ = nullptr;` 在 MinGW-w64 的 comip.h 下二义：
/// `decltype(nullptr)` 构造被 `_NATIVE_NULLPTR_SUPPORTED` 条件排除后，
/// nullptr 到 LPSTR / LPWSTR / Interface* 三个指针构造的隐式转换级别完全
/// 相同，无法选出最优。MSVC 的 comip.h 带该构造，故此写法在 Windows +
/// MSVC 下正常编译。改为默认构造（`m_pInterface(NULL)`）语义完全一致，
/// 且在两个编译器下均合法。
String patchFileDialogControllerH(String content) {
  return content.replaceAll(
    'IFileDialogPtr dialog_ = nullptr;',
    'IFileDialogPtr dialog_;',
  );
}

/// 修补 `file_selector_windows/windows/file_selector_plugin.cpp`：
///
/// 1. 删除与 `file_dialog_controller.h` 重复的
///    `_COM_SMARTPTR_TYPEDEF(IFileDialog, IID_IFileDialog);`：MinGW-w64 的
///    该宏展开含 inline 函数定义（`__IFileDialog_IID_getter`），同一翻译
///    单元两次定义直接 redefinition；MSVC 的展开只有 typedef，重复调用合
///    法。头文件已定义过，删除此处重复调用在两个编译器下语义等价。
/// 2. `IFileDialogPtr dialog = nullptr;` 的二义性同
///    [patchFileDialogControllerH]，改为默认构造。
String patchFileSelectorPluginCpp(String content) {
  var result = content;
  // CRLF（pub-cache 原件为 CRLF 行尾）优先，LF 兜底以防上游改变行尾。
  result = result.replaceFirst(
    '_COM_SMARTPTR_TYPEDEF(IFileDialog, IID_IFileDialog);\r\n',
    '',
  );
  if (result == content) {
    result = result.replaceFirst(
      '_COM_SMARTPTR_TYPEDEF(IFileDialog, IID_IFileDialog);\n',
      '',
    );
  }
  return result.replaceAll(
    'IFileDialogPtr dialog = nullptr;',
    'IFileDialogPtr dialog;',
  );
}

/// 已知需要源码补丁的插件及其文件级补丁规则。
const Map<String, Map<String, String Function(String)>> _pluginPatches = {
  'hotkey_manager_windows': {
    'hotkey_manager_windows_plugin.cpp': patchHotkeyManagerPluginCpp,
  },
  'file_selector_windows': {
    'file_dialog_controller.h': patchFileDialogControllerH,
    'file_selector_plugin.cpp': patchFileSelectorPluginCpp,
  },
};

/// 对暂存目录下 `.plugin_symlinks/` 中已知有兼容问题的插件应用源码补丁。
class PluginSourcePatcher {
  const PluginSourcePatcher();

  /// 对 [ephemeralDir]（`flutter/ephemeral/`）下的插件链接应用补丁。
  ///
  /// 需要补丁的插件目录会从符号链接替换为真实副本（不修改 pub-cache 原
  /// 件），然后对副本做文本补丁。当前 `_pluginPatches` 含 2 条规则
  /// （hotkey_manager_windows 的 EncodableMap 初始化、file_selector_windows
  /// 的 COM 智能指针兼容，见上文说明）；若某项目
  /// 未依赖某插件，对应链接不存在时会被静默跳过。
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
    await copyTree(realPath, pluginLinkPath);

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
}
