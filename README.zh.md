# flutter_build

在 **Linux** 上交叉编译 Flutter Windows (x86_64) 桌面应用——无需 MSVC、无需 Windows SDK、无需 Windows 虚拟机。

- C/C++ 工具链：[LLVM-MinGW](https://github.com/mstorsjo/llvm-mingw)（Clang + LLD + mingw-w64）
- Dart AOT：在 [Wine](https://www.winehq.org/) 下运行官方的 Windows `gen_snapshot.exe`
- 产物：`<app>.exe` + `flutter_windows.dll` + `data/`，与真实 Windows 主机上 `flutter build windows` 产出的结果字节级兼容。

## 功能特性

- 完全开源的工具链——不含任何专有组件。
- 一键工具链准备：支持自动下载、镜像、手动指定，或 `apt` 回退。
- MSVC → GCC/Clang 的 CMake 编译标志翻译器，使大多数原生插件无需修改即可构建。
- 静态链接 `libstdc++`、`libgcc`、`libwinpthread`——最小化运行时 DLL。
- 带插件扫描的 `doctor` 命令，用于发现 WinRT / DirectX 12 / `__uuidof` 等坑点。

## 环境要求

| 依赖                | 安装方式                                    |
|---------------------|---------------------------------------------|
| Linux x86_64        | 已验证 Ubuntu 24.04                         |
| Flutter SDK ≥ 3.13  | https://flutter.dev                         |
| PATH 中的 Dart SDK  | 随 Flutter 一同提供                         |
| Wine（64 位）       | `sudo apt install wine64`                   |
| CMake ≥ 3.15        | `sudo apt install cmake`                    |
| Ninja               | `sudo apt install ninja-build`              |

另需一个 Windows 交叉工具链——见下方的[工具链准备](#3-准备交叉工具链三选一)。

---

## 安装

### 1. 激活 CLI

```bash
git clone <this-repo> flutter_build
cd flutter_build
dart pub global activate --source path .
```

### 2. 将 `~/.pub-cache/bin` 加入 PATH  ← **必须执行，否则会提示 `flutter_build: command not found`**

`dart pub global activate` 会将可执行文件安装到 `~/.pub-cache/bin`，而在全新 Ubuntu shell 中该目录**并不在** PATH 中。只需添加一次：

```bash
echo 'export PATH="$PATH:$HOME/.pub-cache/bin"' >> ~/.bashrc
source ~/.bashrc
```

验证：

```bash
which flutter_build        # → /home/you/.pub-cache/bin/flutter_build
flutter_build --version
```

> 不想修改 PATH？在本仓库目录内，随时可以改用 `dart run flutter_build <command>` 运行。

### 3. 准备交叉工具链（三选一）

**A. 自动下载 LLVM-MinGW（推荐，约 250 MB，一次性）**

```bash
flutter_build precache
```

**B. 手动下载（网络快 / 代理 / 镜像 / U 盘）**

```bash
wget https://github.com/mstorsjo/llvm-mingw/releases/download/20240619/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz
tar -xJf llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz -C ~/
export LLVM_MINGW_ROOT=~/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64
# 持久化：将上面这行 export 追加到 ~/.bashrc。
```

**C. 通过 `apt` 安装系统 GCC-MinGW（最快，兼容性略低）**

```bash
sudo apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
# 当 LLVM-MinGW 不可用时，flutter_build 会自动检测并使用它。
```

若想在弱网环境下给方案 A 提速，可指向镜像：

```bash
export FLUTTER_BUILD_MIRROR=https://mirrors.example.com/llvm-mingw/releases/download
flutter_build precache
```

---

## 快速开始

```bash
cd my_flutter_app

# 每个项目只需执行一次——若缺少 Windows 工程脚手架则添加。
flutter create --platforms=windows .

flutter pub get
flutter_build doctor          # 检查主机 + 工程环境
flutter_build windows --release # 生成 .exe
```

产物目录结构——`build/win_cross/release/<app>/`：

```
<app>/
├── <app>.exe
├── flutter_windows.dll
└── data/
    ├── icudtl.dat
    ├── app.so                # 仅 release / profile 模式
    └── flutter_assets/
```

---

## 命令

### `flutter_build doctor [--allow-download]`

飞行前诊断——检查 Flutter SDK、工程脚手架、交叉工具链、Windows 引擎产物。同时扫描插件原生代码中 MinGW 不友好的头文件（`winrt::`、`<winrt/...>`、`<d3d12...>`、`__uuidof`）。

### `flutter_build precache [--toolchain-only | --engine-only] [--toolchain-path DIR]`

提前下载 LLVM-MinGW 和 Windows 引擎产物——适用于 CI / Docker 镜像。

### `flutter_build windows [flags]`

| 参数                                   | 用途                                                       |
|----------------------------------------|-----------------------------------------------------------|
| `--debug` / `--profile` / `--release`  | 构建模式（`--release` 为默认）                            |
| `-D key=value`                         | Dart `--define`，可重复多次                               |
| `-t lib/foo.dart`                      | 入口文件（默认：`lib/main.dart`）                         |
| `-o path`                              | 输出根目录（默认：`<project>/build/win_cross`）           |
| `--obfuscate --split-debug-info=<dir>` | AOT 混淆，需要拆分调试信息目录                            |
| `--no-precache`                        | 禁止自动下载工具链 / 产物，缺失时直接失败                 |
| `--toolchain-path <dir>`               | 使用预装的 LLVM-MinGW；等同于 `LLVM_MINGW_ROOT`           |
| `--[no-]tree-shake-icons`              | 摇树优化图标字体（默认开启）                              |

顶层参数：`-v` / `--verbose`、`--no-color`、`--cache-dir <dir>`、`--version`。

### `flutter_build clean [-o path] [--cmake]`

删除当前项目的 `build/win_cross/`。**不会**触碰工具链 / 引擎缓存——如需清除，请自行删除 `~/.flutter_build/`。

| 参数       | 用途                                                                |
|------------|---------------------------------------------------------------------|
| `-o path`  | 要清理的构建根目录（默认：`<project>/build/win_cross`）。           |
| `--cmake`  | 仅删除各模式的 `cmake_build/`（CMake 配置与 Ninja 缓存），保留       |
|            | `intermediates/`（kernel dill、AOT elf）和最终产物。更换编译标志或    |
|            | 垫片头文件后可用此选项强制 CMake 重新配置，无需重跑耗时的 AOT 编译。  |

---

## 自动部署到 Windows 机器

构建成功后，`flutter_build` 可自动通过 SCP 把产物 bundle 拷到远程 Windows
机器便于测试。在 `pubspec.yaml` 旁边（或上层目录树任意位置）创建
`config.yaml`，以 [`config.example.yaml`](config.example.yaml) 为模板：

```yaml
host: 192.168.1.100         # Windows 机器 IP / 主机名
username: ubuntu             # SSH 登录名
password: secret             # 或留空改用 SSH 密钥
auto_copy: true              # 每次构建成功后自动拷贝
remote_dir: C:/flutter_build # Windows 上的目标根目录
```

产物拷到 `remote_dir/<app_name>`（扁平结构，不镜像本地完整路径）。例如
`remote_dir` 为 `C:/flutter_build`、app 名为 `flutter_build_example`：

```
C:/flutter_build/flutter_build_example/
  ├── flutter_build_example.exe
  ├── flutter_windows.dll
  └── data/
```

`--copy` / `--no-copy` 可在单次运行时覆盖 `auto_copy`。密码登录需安装
`sshpass`（`sudo apt install sshpass`）。

---

## 架构

```
┌──────────────────────────── Linux 主机 ────────────────────────────┐
│                                                                     │
│  ① frontend_server.dart.snapshot  （主机 Dart VM）                  │
│      → app.dill               （平台无关的 kernel）                 │
│                                                                     │
│  ② Wine + gen_snapshot.exe    （运行于 Wine 下的 Windows PE 二进制）│
│      → app.so                 （ELF 容器，x86_64 机器码）           │
│                                                                     │
│  ③ LLVM-MinGW clang / lld + CMake / Ninja                           │
│      → <app>.exe              （通过 C ABI 链接 flutter_windows.dll）│
│                                                                     │
│  ④ 资源打包器              （pubspec → flutter_assets/）            │
│                                                                     │
│  ⑤ 产物打包器            （组装最终可分发包）                       │
└─────────────────────────────────────────────────────────────────────┘
```

## 关键设计决策

1. **`flutter_windows.dll` 原样使用。** 它导出的是纯 C ABI，因此 MSVC 构建的 DLL 能与 MinGW 编译的目标文件干净链接。MinGW 导入库要么复用引擎缓存中的版本，要么通过 `llvm-dlltool` 重新生成。

2. **我们改写 `windows/flutter/CMakeLists.txt`。** Flutter 原版会回调 `flutter assemble`，从而在主机的 Dart 工具链中再次进入。我们生成一个静态等价版本，提供相同的 CMake 目标，但不会产生这种二次进入。

3. **MSVC 编译标志翻译。** 插件的 CMakeLists 常常带有 MSVC 专属标志（`/W3`、`/EHsc`、`/std:c++17`、`/utf-8` 等）。一个基于正则的翻译器会在工程树的暂存副本中把它们改写为 Clang 等价物。

4. **静态 C++ / pthreads 运行时。** `-static-libstdc++ -static-libgcc
   -static-libwinpthread` 意味着可执行文件不依赖 MinGW 运行时 DLL。

5. **ELF 格式 AOT 快照。** `gen_snapshot --snapshot_kind=app-aot-elf` 无论目标操作系统为何都会写出 ELF 文件。Flutter Windows 引擎内置了 ELF 加载器，会在运行时消费它。

6. **尽量少改动被编译的程序。** 解决交叉编译兼容性问题时，优先使用仅在 `flutter_build` 内的方案——编译器标志（`-Wno-…`）、MinGW 兼容垫片头文件、CMake 配置——而非修改插件或应用源码。源码补丁是最后手段，只作用于物化后的副本（绝不碰 pub-cache 原件），且必须保持 MSVC 兼容，确保应用在真正的 Windows 主机上仍可不加修改地构建。

---

## 故障排查

**`flutter_build: command not found`  /  `flutter_build：未找到命令`**
`dart pub global activate` 成功了，但 `~/.pub-cache/bin` 不在 PATH 中。请执行安装步骤 2 中的 `export`，或在本仓库目录内改用 `dart run flutter_build <cmd>`。

**`Neither LLVM-MinGW nor system GCC-MinGW could be found.`**
在安装步骤 3 中选择一种工具链方案，或将 `LLVM_MINGW_ROOT` 指向已有的安装目录。

**插件报错，提示 `<winrt/...>` 或 `<d3d12*>` 头文件缺失**
mingw-w64 的 WinRT/DX12 头文件不完整。`flutter_build doctor` 会提前标记这些插件。可选方案：换用纯 Dart 的替代插件、在本地修补该插件，或在真实 Windows 主机上构建该插件并把生成的 DLL 放到 exe 旁边。

**Wine 下 AOT 快照失败（`err:module:import_dll`、缺失 DLL）**
确保有一个可正常工作的 64 位 Wine（`wine64 --version` ≥ 6.0）。在精简版 Ubuntu 镜像上：`sudo apt install wine64 winbind`。

---

## 限制

- **仅支持 x86_64。** 暂不支持 arm64 目标。
- 使用了 **WinRT**、**C++/WinRT** 或 **DirectX 12** 头文件的插件可能在 mingw-w64 下编译失败——`doctor` 会在你撞上编译器报错前发出警告。
- 资源打包目前还不支持延迟加载组件（deferred components）或资源转换器（asset transformers）。
- 生成的 `.exe` 未签名。若要在 Linux 上做 Authenticode 签名，构建后可使用 [`osslsigncode`](https://github.com/mtrojnar/osslsigncode)。

## 示例

见 [`example/`](example/)——一个最小化的 Flutter Windows 应用，附带中文分步说明 README。

## 许可证

Apache-2.0——详见 [LICENSE](LICENSE)。
