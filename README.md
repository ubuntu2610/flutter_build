# flutter_build

Cross-compile Flutter Windows (x86_64) desktop applications **on Linux** — no
MSVC, no Windows SDK, no Windows VM.

- C/C++ toolchain: [LLVM-MinGW](https://github.com/mstorsjo/llvm-mingw) (Clang + LLD + mingw-w64)
- Dart AOT: the official Windows `gen_snapshot.exe` run under [Wine](https://www.winehq.org/)
- Output: `<app>.exe` + `flutter_windows.dll` + `data/`, byte-compatible with
  what `flutter build windows` produces on a real Windows host.

## Features

- Fully open-source toolchain — no proprietary components.
- One-shot toolchain provisioning: auto-download, mirror, manual, or `apt` fallback.
- MSVC → GCC/Clang CMake-flag translator so most stock plugins build unmodified.
- Static linkage of `libstdc++`, `libgcc`, `libwinpthread` — minimal runtime DLLs.
- `doctor` command with a plugin scan for WinRT / DirectX 12 / `__uuidof` gotchas.

## Requirements

| Dependency          | Install                                     |
|---------------------|---------------------------------------------|
| Linux x86_64        | Ubuntu 22.04 tested                         |
| Flutter SDK ≥ 3.13  | https://flutter.dev                         |
| Dart SDK on PATH    | Ships with Flutter                          |
| Wine (64-bit)       | `sudo apt install wine64`                   |
| CMake ≥ 3.15        | `sudo apt install cmake`                    |
| Ninja               | `sudo apt install ninja-build`              |

Plus a Windows cross toolchain — see [Toolchain options](#3-provision-the-cross-toolchain-choose-one) below.

---

## Install

### 1. Activate the CLI

```bash
git clone <this-repo> flutter_build
cd flutter_build
dart pub global activate --source path .
```

### 2. Put `~/.pub-cache/bin` on PATH  ← **do this or you'll see `flutter_build: command not found`**

`dart pub global activate` installs the binary into `~/.pub-cache/bin`, which
is **not** on PATH in a fresh Ubuntu shell. Add it once:

```bash
echo 'export PATH="$PATH:$HOME/.pub-cache/bin"' >> ~/.bashrc
source ~/.bashrc
```

Verify:

```bash
which flutter_build        # → /home/you/.pub-cache/bin/flutter_build
flutter_build --version
```

> Don't want to change PATH? From inside this repo you can always run
> `dart run flutter_build <command>` instead.

### 3. Provision the cross toolchain (choose one)

**A. Auto-download LLVM-MinGW (recommended, ~250 MB, one-time)**

```bash
flutter_build precache
```

**B. Manual download (fast networks / proxy / mirror / USB)**

```bash
wget https://github.com/mstorsjo/llvm-mingw/releases/download/20240619/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz
tar -xJf llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz -C ~/
export LLVM_MINGW_ROOT=~/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64
# Persist by appending the export to ~/.bashrc.
```

**C. System GCC-MinGW via `apt` (fastest, slightly lower compat)**

```bash
sudo apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
# flutter_build auto-detects this when LLVM-MinGW is unavailable.
```

To speed up option A behind a slow link, point at a mirror:

```bash
export FLUTTER_BUILD_MIRROR=https://mirrors.example.com/llvm-mingw/releases/download
flutter_build precache
```

---

## Quick Start

```bash
cd my_flutter_app

# One-time per project — add the Windows scaffold if absent.
flutter create --platforms=windows .

flutter pub get
flutter_build doctor          # sanity check the host + project
flutter_build windows --release # produce the .exe
```

Output layout — `build/win_cross/release/<app>/`:

```
<app>/
├── <app>.exe
├── flutter_windows.dll
└── data/
    ├── icudtl.dat
    ├── app.so                # release / profile only
    └── flutter_assets/
```

---

## Commands

### `flutter_build doctor [--allow-download]`

Pre-flight diagnostics — Flutter SDK, project scaffold, cross toolchain,
Windows engine artifacts. Also scans plugin native code for MinGW-unfriendly
headers (`winrt::`, `<winrt/...>`, `<d3d12...>`, `__uuidof`).

### `flutter_build precache [--toolchain-only | --engine-only] [--toolchain-path DIR]`

Downloads LLVM-MinGW and the Windows engine artifacts ahead of time — handy
for CI / Docker images.

### `flutter_build windows [flags]`

| Flag                                   | Purpose                                                     |
|----------------------------------------|-------------------------------------------------------------|
| `--debug` / `--profile` / `--release`  | Build mode (`--release` is default)                         |
| `-D key=value`                         | Dart `--define`, repeat for multiple                        |
| `-t lib/foo.dart`                      | Entry point (default: `lib/main.dart`)                      |
| `-o path`                              | Output root (default: `<project>/build/win_cross`)          |
| `--obfuscate --split-debug-info=<dir>` | AOT obfuscation, requires split-debug dir                   |
| `--no-precache`                        | Fail instead of auto-downloading toolchain / artifacts      |
| `--toolchain-path <dir>`               | Use a pre-installed LLVM-MinGW; same as `LLVM_MINGW_ROOT`   |
| `--[no-]tree-shake-icons`              | Tree-shake icon fonts (on by default)                       |

Top-level flags: `-v` / `--verbose`, `--no-color`, `--cache-dir <dir>`, `--version`.

### `flutter_build clean [-o path]`

Removes `build/win_cross/` for the current project. Does **not** touch the
toolchain / engine cache — delete `~/.flutter_build/` yourself to wipe those.

---

## Architecture

```
┌──────────────────────────── Linux host ─────────────────────────────┐
│                                                                     │
│  ① frontend_server.dart.snapshot  (host Dart VM)                    │
│      → app.dill               (platform-neutral kernel)             │
│                                                                     │
│  ② Wine + gen_snapshot.exe    (Windows PE binary under Wine)        │
│      → app.so                 (ELF container, x86_64 machine code)  │
│                                                                     │
│  ③ LLVM-MinGW clang / lld + CMake / Ninja                           │
│      → <app>.exe              (links flutter_windows.dll via C ABI) │
│                                                                     │
│  ④ Asset bundler              (pubspec → flutter_assets/)           │
│                                                                     │
│  ⑤ Output packager            (assemble the final distributable)    │
└─────────────────────────────────────────────────────────────────────┘
```

## Key design decisions

1. **`flutter_windows.dll` is used unchanged.** It exports a pure C ABI, so
   the MSVC-built DLL links cleanly against MinGW-compiled objects. The MinGW
   import library is either reused from the engine cache or regenerated via
   `llvm-dlltool`.

2. **We rewrite `windows/flutter/CMakeLists.txt`.** Flutter's stock version
   calls back into `flutter assemble`, which would re-enter the Dart tool on
   the host. We generate a static equivalent that provides the same CMake
   targets without the re-entry.

3. **MSVC flag translation.** Plugin CMakeLists often carry MSVC-only flags
   (`/W3`, `/EHsc`, `/std:c++17`, `/utf-8`, …). A regex-based translator
   rewrites them to Clang equivalents in a staging copy of the tree.

4. **Static C++ / pthreads runtime.** `-static-libstdc++ -static-libgcc
   -static-libwinpthread` means the executable does not depend on MinGW
   runtime DLLs.

5. **ELF AOT snapshot.** `gen_snapshot --snapshot_kind=app-aot-elf` writes an
   ELF file regardless of target OS. The Flutter Windows engine has a
   built-in ELF loader that consumes it at runtime.

---

## Troubleshooting

**`flutter_build: command not found`  /  `flutter_build：未找到命令`**
`dart pub global activate` succeeded, but `~/.pub-cache/bin` isn't on PATH.
Apply the `export` from install step 2, or use `dart run flutter_build <cmd>`
from inside this repo.

**`Neither LLVM-MinGW nor system GCC-MinGW could be found.`**
Pick a toolchain option in install step 3, or set `LLVM_MINGW_ROOT` to an
existing install directory.

**Plugin fails with `<winrt/...>` or `<d3d12*>` header errors**
mingw-w64's WinRT/DX12 headers are incomplete. `flutter_build doctor` flags
these plugins. Options: swap in a Dart-only alternative, patch the plugin
locally, or build that plugin on a real Windows host and drop the resulting
DLL alongside the exe.

**AOT snapshot fails under Wine (`err:module:import_dll`, missing DLL)**
Ensure a functional 64-bit Wine (`wine64 --version` ≥ 6.0). On minimal Ubuntu
images: `sudo apt install wine64 winbind`.

---

## Limitations

- **x86_64 only.** No arm64 target yet.
- Plugins using **WinRT**, **C++/WinRT**, or **DirectX 12** headers may fail
  against mingw-w64 — `doctor` warns before you hit the compiler error.
- Asset bundling does not yet handle deferred components or asset transformers.
- The output `.exe` is unsigned. For Authenticode signing on Linux use
  [`osslsigncode`](https://github.com/mtrojnar/osslsigncode) post-build.

## Example

See [`example/`](example/) — a minimal Flutter Windows app with a Chinese
step-by-step README.

## License

Apache-2.0 — see [LICENSE](LICENSE).
