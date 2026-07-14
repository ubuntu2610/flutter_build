# flutter_build 示例工程

本目录本身就是一个标准 Flutter Windows 桌面应用（由 `flutter create --platforms=windows` 生成），
用于演示如何在 **Ubuntu (Linux)** 上使用 `flutter_build` 交叉编译出 `.exe`。

---

## 第 1 步：安装 `flutter_build` 命令

```bash
cd /path/to/flutter_build          # 仓库根目录，不是 example/
dart pub global activate --source path .
```

### **关键**：把 `~/.pub-cache/bin` 加进 PATH

如果直接运行 `flutter_build` 报：

```
flutter_build：未找到命令
```

原因是 `dart pub global activate` 把二进制装在 `~/.pub-cache/bin`，而这个目录
在 Ubuntu 默认 PATH 里 **没有**。修复：

```bash
echo 'export PATH="$PATH:$HOME/.pub-cache/bin"' >> ~/.bashrc
source ~/.bashrc

# 验证
which flutter_build        # 应输出 /home/xxx/.pub-cache/bin/flutter_build
flutter_build --version
```

> 不想动 PATH？也可以在仓库根目录用 `dart run flutter_build <命令>` 代替。

---

## 第 2 步：装系统依赖

```bash
sudo apt install wine64 cmake ninja-build
```

---

## 第 3 步：准备交叉编译工具链（三选一）

**方案 A：自动下载 LLVM-MinGW（推荐，~250 MB，一次性）**

```bash
flutter_build precache
```

**方案 B：手动下载后指定路径（国内推荐，避免 GitHub 慢）**

```bash
# 1. 任意快速方式（代理 / 镜像 / U 盘）拿到 tarball
wget https://github.com/mstorsjo/llvm-mingw/releases/download/20240619/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz
tar -xJf llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz -C ~/

# 2. 写入 ~/.bashrc 长期生效
export LLVM_MINGW_ROOT=~/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64
```

**方案 C：apt 装 GCC-MinGW（最快，兼容性略低）**

```bash
sudo apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
# flutter_build 在 LLVM-MinGW 不可用时会自动回退到它
```

有内网镜像时可加速方案 A：

```bash
export FLUTTER_BUILD_MIRROR=https://mirrors.yourcompany.com/llvm-mingw/releases/download
flutter_build precache
```

---

## 第 4 步：构建本示例

```bash
cd example
flutter pub get
flutter_build doctor            # 环境自检
flutter_build windows --release   # 交叉编译
```

---

## 构建产物

输出在 `build/win_cross/release/hello/`：

```
hello/
├── hello.exe               ← Windows 可执行文件
├── flutter_windows.dll     ← Flutter 引擎动态库
└── data/
    ├── icudtl.dat          ← ICU 国际化数据
    ├── app.so              ← Dart AOT 快照（ELF 格式）
    └── flutter_assets/     ← 图片、字体等资源
```

---

## 构建模式

| 命令                             | 说明                                |
|----------------------------------|-------------------------------------|
| `flutter_build windows --release`    | 生产模式（默认，AOT 编译）           |
| `flutter_build windows --profile`    | AOT + 性能分析标志                   |
| `flutter_build windows --debug`      | JIT 模式（附带 kernel_blob.bin）     |

## 其他命令

```bash
flutter_build doctor             # 环境诊断，扫描插件里的 WinRT / DX12 隐患
flutter_build precache           # 预下载工具链 + engine 产物（CI / Docker 常用）
flutter_build clean              # 只清理 build/win_cross/，不动缓存
```

---

## 常见问题

**Q：`flutter_build：未找到命令`**
A：`dart pub global activate` 执行过了，但 `~/.pub-cache/bin` 没进 PATH。
参见「第 1 步」中的 `export` 命令。

**Q：`Neither LLVM-MinGW nor system GCC-MinGW could be found.`**
A：第 3 步的三个方案都没生效，任选一种即可（推荐方案 A）。

**Q：某插件报 `<winrt/...>` 或 `<d3d12*>` 头文件缺失**
A：mingw-w64 对 WinRT / DX12 覆盖不全。`flutter_build doctor` 会预先扫出这类
插件。可选：换纯 Dart 替代实现、本地打补丁、或在真实 Windows 上编好插件 DLL
后拷进产物目录。

**Q：Wine 下运行 `gen_snapshot.exe` 报缺 DLL / `err:module:import_dll`**
A：确认 `wine64 --version` ≥ 6.0；最小化 Ubuntu 镜像加装
`sudo apt install wine64 winbind`。

---

## 技术原理

```
┌─────────────────────────────────────────────────────────────┐
│  Linux Host                                                 │
│                                                             │
│  frontend_server (Dart VM)                                  │
│    └─→ app.dill            (平台无关 kernel 字节码)         │
│                                                             │
│  Wine + gen_snapshot.exe                                    │
│    └─→ app.so              (ELF 容器，内含 x64 机器码)      │
│                                                             │
│  LLVM-MinGW / GCC-MinGW + CMake + Ninja                     │
│    └─→ hello.exe           (链接 flutter_windows.dll)       │
└─────────────────────────────────────────────────────────────┘
```

**核心要点：**

- `flutter_windows.dll` 只导出 C ABI，MinGW 可直接链接。
- `gen_snapshot.exe` 输出 ELF 格式快照（Flutter engine 内置 ELF loader）。
- Wine 只做系统调用翻译，产出字节与真实 Windows 一致。
- 全静态链接 libstdc++ / libgcc / libwinpthread，产物无额外运行时 DLL 依赖。

更多细节见仓库根目录的 [`README.md`](../README.md)。
