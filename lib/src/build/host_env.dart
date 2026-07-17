// 为 Windows 交叉构建净化宿主环境变量。
//
// 某些 Flutter 安装方式——尤其是 Linux 上的 **snap**——会导出一批编译/链接
// 标志（CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS、include/library 搜索路径、pkg-config
// 目录等），好让其自带的 GCC 能构建 **Linux** 桌面应用。
//
// 当我们改用 CMake + LLVM-MinGW 面向 **Windows** 目标交叉编译时，CMake 会从这些
// 环境变量初始化默认标志（如 `CMAKE_CXX_FLAGS` 取自 `$CXXFLAGS`、
// `CMAKE_EXE_LINKER_FLAGS` 取自 `$LDFLAGS`），于是宿主库被注入进来，例如
// `-lepoxy` / `-lfontconfig`，导致交叉链接失败：
//   lld: error: unable to find library -lepoxy
//
// 因此在把环境交给交叉构建子进程前，先剥离这些变量。PATH / LD_LIBRARY_PATH /
// HOME 等保持不变，以便（snap 自带的）cmake/ninja 仍能正常运行。

/// 会影响 **目标** 编译器/链接器、不能从被污染宿主（如 Flutter snap）泄漏进
/// 交叉构建的环境变量集合。
const Set<String> kHostBuildFlagVars = {
  'CFLAGS',
  'CXXFLAGS',
  'CPPFLAGS',
  'LDFLAGS',
  'CPATH',
  'C_INCLUDE_PATH',
  'CPLUS_INCLUDE_PATH',
  'OBJC_INCLUDE_PATH',
  'LIBRARY_PATH',
  'PKG_CONFIG_PATH',
  'PKG_CONFIG_LIBDIR',
  'PKG_CONFIG_SYSROOT_DIR',
  'CMAKE_PREFIX_PATH',
};

/// 返回 [base] 的副本，移除 [kHostBuildFlagVars] 中的变量，并在其上应用
/// [overrides]。
///
/// 结果应配合 `includeParentEnvironment: false` 使用，以获得对子进程环境的
/// 完全控制（避免父进程的污染变量再度合并进来）。
Map<String, String> sanitizedCrossBuildEnv(
  Map<String, String> base, {
  Map<String, String>? overrides,
}) {
  final env = <String, String>{
    for (final entry in base.entries)
      if (!kHostBuildFlagVars.contains(entry.key)) entry.key: entry.value,
  };
  if (overrides != null) env.addAll(overrides);
  return env;
}
