// MinGW-w64 兼容垫片：缺失的 Windows SDK 头文件 + 库文件大小写修正。
//
// 设计原则（见 .codebuddy/rules.md）：能用垫片头文件 / 编译标志解决的兼容性
// 问题，一律不改插件源码。本模块把 pipeline 里内联的垫片数据与物化逻辑抽出，
// 便于独立测试与后续扩充。
//
// 垫片头文件写入构建中间目录，并通过 `CMAKE_CXX_FLAGS` 的 `-I` 加入搜索路径，
// 让插件源码中 `#include <shobjidl_core.h>` 等无需修改即可在 MinGW 下编译。

import 'dart:io';

import 'package:path/path.dart' as p;

/// MinGW-w64 缺失的 Windows SDK 头文件垫片。
///
/// key: 被引用的头文件名（`#include <...>` 中的名字）；
/// value: 垫片内容（通常 `#include` 等价的 MinGW 头文件）。
const Map<String, String> kMingwCompatHeaders = {
  // Windows 10 SDK 拆分出的核心 shell 接口头文件，MinGW-w64 只有 shobjidl.h。
  'shobjidl_core.h': '// flutter_build MinGW compatibility shim\n'
      '// shobjidl_core.h is a Windows 10 SDK header absent from MinGW-w64;\n'
      '// its interfaces are available via shobjidl.h.\n'
      '#ifndef _FLUTTER_BUILD_SHOBJIDL_CORE_SHIM\n'
      '#define _FLUTTER_BUILD_SHOBJIDL_CORE_SHIM\n'
      '#include <shobjidl.h>\n'
      '#endif\n',
  // 大小写问题：MinGW 头文件全小写，Linux 文件系统大小写敏感。
  'Windows.h': '// flutter_build MinGW compatibility shim\n'
      '// On case-sensitive filesystems <Windows.h> is not found because\n'
      '// MinGW ships the header as <windows.h> (lowercase).\n'
      '#ifndef _FLUTTER_BUILD_WINDOWS_H_SHIM\n'
      '#define _FLUTTER_BUILD_WINDOWS_H_SHIM\n'
      '#include <windows.h>\n'
      '#endif\n',
};

/// 在 [outDir] 下生成 MinGW 兼容垫片头文件，返回 [outDir]。
///
/// 仅在文件不存在或内容变化时写入，避免增量构建中因时间戳变化触发 ninja 全量
/// 重编。
///
/// 同时创建库文件大小写修正符号链接：`-fms-extensions` 让 Clang 处理
/// `#pragma comment(lib, "Gdi32.lib")`，传 `-lGdi32` 给链接器，但 MinGW 的库
/// 文件全小写 `libgdi32.a`，Linux 大小写敏感找不到。创建
/// `libGdi32.a → libgdi32.a` 符号链接桥接。[mingwLibDir] 为目标三元组下的 `lib`
/// 目录（如 `<root>/x86_64-w64-mingw32/lib`）。
Future<String> materializeMingwCompat({
  required String outDir,
  required String mingwLibDir,
}) async {
  final dir = Directory(outDir);
  await dir.create(recursive: true);

  for (final entry in kMingwCompatHeaders.entries) {
    final file = File(p.join(dir.path, entry.key));
    if (!file.existsSync() || file.readAsStringSync() != entry.value) {
      await file.writeAsString(entry.value);
    }
  }

  // 库大小写修正：#pragma comment(lib, "Gdi32.lib") → -lGdi32 → libGdi32.a
  // MinGW 实际文件为 libgdi32.a（全小写），Linux 大小写敏感。
  final gdi32Target = p.join(mingwLibDir, 'libgdi32.a');
  if (File(gdi32Target).existsSync()) {
    final link = Link(p.join(dir.path, 'libGdi32.a'));
    if (!link.existsSync()) {
      await link.create(gdi32Target);
    }
  }

  return dir.path;
}
