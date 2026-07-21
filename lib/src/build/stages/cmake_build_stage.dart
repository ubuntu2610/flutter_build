// 阶段 5：用 LLVM-MinGW 工具链配置并构建 CMake 工程。
//
// 这里集中了大量交叉编译的关键标志（-DCMAKE_SYSTEM_NAME=Windows、-municode、
// -static、-fms-extensions、垫片 -I 等），均为在 Linux 上用 clang++ 面向 Windows
// 目标构建 Flutter runner + 插件所必需，改动需谨慎。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../build_context.dart';
import '../host_env.dart';
import '../mingw_compat.dart';
import '../wine_wrapper.dart';
import 'build_stage.dart';

/// 配置并构建 CMake 工程（runner + 插件）。
class CMakeBuildStage extends BuildStage {
  CMakeBuildStage({super.logger, super.runner});

  @override
  String get name => 'configure & build with CMake';

  @override
  Future<void> run(BuildContext ctx) async {
    final wine =
        WineWrapper(toolchain: ctx.toolchain, buildRoot: ctx.buildRoot);
    await wine.materialize();
    await Directory(ctx.cmakeBuildDir).create(recursive: true);
    await _ensureCleanCrossCache(ctx);

    // 生成 MinGW 兼容垫片头文件目录，供 CMake 以 -I 加入包含搜索路径。
    // 解决部分 Windows SDK 头文件在 MinGW-w64 中不存在的问题（如
    // shobjidl_core.h），无需修改插件源码。
    final compatDir = await _materializeCompatHeaders(ctx);

    final configureArgs = <String>[
      '-S',
      ctx.windowsStageDir,
      '-B',
      ctx.cmakeBuildDir,
      '-G',
      'Ninja',
      // 告知 CMake 这是面向 Windows 的交叉构建，否则它会当作本机 Linux
      // （ELF）处理，导致对可执行文件套用 RPATH 逻辑而报错，也会用错
      // .exe/.dll/导入库的命名与链接规则。必须在干净配置时设置（见
      // _ensureCleanCrossCache）。
      '-DCMAKE_SYSTEM_NAME=Windows',
      '-DCMAKE_SYSTEM_PROCESSOR=AMD64',
      // 让 CMake 的编译器检测只编译成静态库、不链接可执行文件。
      // 否则在干净配置时，因为下面给 EXE 加了 -municode，而检测用的
      // 测试程序只有 main（非 wWinMain），会报 `undefined symbol: wWinMain`。
      '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
      '-DCMAKE_BUILD_TYPE=${ctx.mode.name.toUpperCase()}',
      '-DCMAKE_C_COMPILER=${ctx.toolchain.clang}',
      '-DCMAKE_CXX_COMPILER=${ctx.toolchain.clangxx}',
      '-DCMAKE_RC_COMPILER=${ctx.toolchain.llvmRc}',
      // 资源编译器 llvm-rc 没有 clang 的 sysroot，需显式加 mingw include
      // 才能找到 winres.h 等系统头。
      '-DCMAKE_RC_FLAGS=-I ${ctx.toolchain.mingwSysrootInclude}',
      '-DCMAKE_MAKE_PROGRAM=${ctx.toolchain.ninjaExecutable}',
      // 强制指定全局链接标志，起到三个作用：
      // 1) 覆盖宿主（Flutter snap）经 env.sh 向 LDFLAGS 注入的
      //    -lepoxy/-lfontconfig 等 Linux 库；
      // 2) EXE 加 -municode：选用宽字符入口 CRT，匹配 Flutter runner 的
      //    wWinMain；否则 mingw 的 crtexewin 引用窄字符 WinMain 导致
      //    `undefined symbol: WinMain`；
      // 3) 全部加 -static：静态链接 LLVM-MinGW 的 C++ 运行时（libc++、
      //    libunwind 等），产物自包含。否则运行时会报缺失 libc++.dll /
      //    libunwind.dll（这两个 DLL 不在普通 Windows 上）。
      // 4) -ldwmapi：部分插件（如 window_manager）通过 MSVC 专属的
      //    `#pragma comment(lib, "dwmapi.lib")` 指定链接库。-fms-extensions
      //    会让 Clang 识别该 pragma 并自动传 -ldwmapi，此处 -ldwmapi 作为
      //    兜底。shcore 由插件运行时 LoadLibrary 动态加载，不需要链接。
      //    -L <compatDir>：compatDir 下有 libGdi32.a → libgdi32.a 的大小写
      //    修正符号链接（#pragma comment(lib, "Gdi32.lib") 传 -lGdi32，但
      //    MinGW 的库文件全小写 libgdi32.a，Linux 大小写敏感）。
      '-DCMAKE_EXE_LINKER_FLAGS=-municode -static -ldwmapi -L $compatDir',
      '-DCMAKE_SHARED_LINKER_FLAGS=-static -ldwmapi -L $compatDir',
      '-DCMAKE_MODULE_LINKER_FLAGS=-static',
      // 全局 C++ 编译标志（不修改插件源码，仅在 flutter_build 侧解决兼容性）：
      //   -I <compatDir>  — MinGW 缺失的 Windows SDK 头文件垫片（如
      //     shobjidl_core.h → shobjidl.h、Windows.h → windows.h）
      //   -Wno-pragma-once-outside-header — window_manager.cpp 既是主文件
      //     又被 #include，#pragma once 在主文件中触发 -Werror
      //   -Wno-deprecated-declarations — wstring_convert/codecvt_utf8_utf16
      //     在 C++17 弃用，_SILENCE_... 宏只对 MSVC 有效
      //   -Wno-error=X — 以下警告在 MSVC (/W3) 下不诊断，但 Clang -Wall
      //     会启用且 -Werror 升级为错误。-Wno-error=X 不受顺序影响（即使
      //     -Werror 在后面也生效），仅降级为 warning 不改源码：
      //     unknown-pragmas       — MSVC 专属 #pragma comment / #pragma warning
      //     unused-const-variable — constexpr 常量定义未引用（如 kWindowClassName）
      //     unused-local-typedef  — 函数内 typedef 名未引用（如 ACCENT_STATE）
      //     extra-qualification   — 类体内成员声明的多余类名限定（MSVC 允许）
      //   -fms-extensions — 让 Clang 识别 MSVC 扩展语法（#pragma comment 等），
      //     并将 extra-qualification 从硬错误降级为 ExtWarn（-fms-compatibility
      //     会破坏 MinGW-w64 标准库头文件，不可用）。-fms-extensions 下该警告
      //     的诊断组名为 microsoft-extra-qualification（非 extra-qualification）。
      '-DCMAKE_CXX_FLAGS=-I $compatDir '
          '-Wno-pragma-once-outside-header -Wno-deprecated-declarations '
          '-fms-extensions '
          '-Wno-error=unknown-pragmas '
          '-Wno-error=unused-const-variable '
          '-Wno-error=unused-local-typedef '
          '-Wno-error=microsoft-extra-qualification',
    ];
    // 用净化过的环境驱动 CMake：剥离宿主（如 Flutter snap）注入的
    // CFLAGS/CXXFLAGS/LDFLAGS 等，否则 -lepoxy/-lfontconfig 等 Linux 库会
    // 漏进面向 Windows 的交叉链接。配合 includeParentEnvironment=false，
    // 确保被剥离的变量不会再从父进程合并回来。
    final crossEnv = sanitizedCrossBuildEnv(
      Platform.environment,
      overrides: wine.environment(),
    );
    await runner.run(
      ctx.toolchain.cmakeExecutable,
      configureArgs,
      tag: 'cmake',
      environment: crossEnv,
      includeParentEnvironment: false,
    );

    await runner.run(
      ctx.toolchain.cmakeExecutable,
      <String>['--build', ctx.cmakeBuildDir],
      tag: 'cmake',
      environment: crossEnv,
      includeParentEnvironment: false,
    );
  }

  /// CMAKE_SYSTEM_NAME 只在**干净配置**时生效。若 cmake_build 里存在此前以非
  /// Windows（如本机 Linux）模式配置的旧缓存，或上次配置未走完留下的
  /// 半成品缓存，直接重配都不会正确切换到交叉模式（会继续报 RPATH 等错）。
  /// 用两个信号判定“健康的 Windows 交叉缓存”：
  ///   1. CMakeCache.txt 里 CMAKE_SYSTEM_NAME=Windows；
  ///   2. build.ninja 存在（只有 configure+generate 完整成功才会生成）。
  /// 不满足则删除 CMakeCache.txt 与 CMakeFiles/ 强制干净重配；满足则保留，
  /// 维持增量构建。
  Future<void> _ensureCleanCrossCache(BuildContext ctx) async {
    final cache = File(p.join(ctx.cmakeBuildDir, 'CMakeCache.txt'));
    if (!cache.existsSync()) return;
    final content = await cache.readAsString();
    final isWindowsCross = RegExp(
      r'^CMAKE_SYSTEM_NAME[^=\n]*=\s*Windows\s*$',
      multiLine: true,
    ).hasMatch(content);
    final generated =
        File(p.join(ctx.cmakeBuildDir, 'build.ninja')).existsSync();
    if (isWindowsCross && generated) return;
    log.debug('清理不完整或非 Windows 交叉的 CMake 缓存后重新配置。');
    await cache.delete();
    final cmakeFiles = Directory(p.join(ctx.cmakeBuildDir, 'CMakeFiles'));
    if (cmakeFiles.existsSync()) await cmakeFiles.delete(recursive: true);
  }

  /// 在构建中间目录下生成 MinGW 兼容垫片头文件，返回该目录路径。
  ///
  /// 垫片数据与物化 / 库大小写修正逻辑见 `materializeMingwCompat`。
  Future<String> _materializeCompatHeaders(BuildContext ctx) {
    return materializeMingwCompat(
      outDir: ctx.mingwCompatDir,
      mingwLibDir: p.join(
          ctx.toolchain.llvmMingwRoot, ctx.toolchain.targetTriple, 'lib'),
    );
  }
}
