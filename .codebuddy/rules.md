# flutter_build 项目规则

## 核心原则：最小化被编译程序的改动

本项目尽量保留被编译的 app 与 MSVC 兼容，少改动被编译程序，只修改
flutter_build 里面的源码。

### 规则

1. **优先使用编译器标志**

   能用 `-Wno-xxx` 等 Clang 标志抑制的警告（如 `-Werror` 升级的
   `-Wpragma-once-outside-header`、`-Wdeprecated-declarations`），不改源码，
   通过 `CMAKE_CXX_FLAGS` 全局设置。

2. **优先使用垫片头文件**

   MinGW-w64 缺失的 Windows SDK 头文件（如 `shobjidl_core.h`、大小写问题
   `Windows.h`），在构建中间目录创建垫片（`#include` 等价头文件），通过
   `-I` 加入搜索路径，不改源码。

3. **源码补丁是最后手段**

   仅用于 Clang 硬错误（无法用标志 / 垫片解决），如 `extra qualification on
   member`（多余类名限定）、类型推导失败（`EncodableMap` 初始化列表推导）。
   补丁只作用于物化后的副本（符号链接 → 真实拷贝），绝不修改 pub-cache 原件。

4. **保持 MSVC 兼容**

   任何源码修改必须确保代码仍能在 Windows + MSVC 下编译——被编译的 app 在
   真正的 Windows 主机上应可不加修改地构建。
