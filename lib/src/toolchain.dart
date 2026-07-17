// LLVM-MinGW 工具链下载与探测模块。
//
// 核心职责：
//   - LLVM-MinGW 自动下载：从 GitHub Releases 拉取 ~250MB tarball并解压到缓存目录。
//     固定一个已知良好的版本，避免因版本漂移导致不可再现构建。
//   - Wine / cmake / ninja 探测：只搜 PATH，不自动安装系统包。
//
// 使用方式：
//   final tc = await ToolchainProvisioner(paths: cachePaths, runner: runner)
//       .provision(allowDownload: true);
//   print(tc.clang);  // /home/you/.flutter_build/toolchains/llvm-mingw-.../bin/x86_64-w64-mingw32-clang
//
// 参考：
//   - https://github.com/mstorsjo/llvm-mingw : 官方 Release 页面
//   - https://clang.llvm.org/docs/CrossCompilation.html

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'cache_paths.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'process_runner.dart';

/// Metadata for one release of the LLVM-MinGW toolchain.
class LlvmMingwRelease {
  const LlvmMingwRelease({
    required this.version,
    required this.crt,
    required this.linuxDistroTag,
    this.sha256,
  });

  /// e.g. `20240619`
  final String version;

  /// `ucrt` (recommended, modern CRT) or `msvcrt` (legacy).
  final String crt;

  /// The Ubuntu tag of this release's Linux x86_64 build.
  ///
  /// 注意：这是工具链**被编译时所在的构建机** Ubuntu 版本，不是对运行
  /// 系统的要求。llvm-mingw 每个 release 的 Linux x86_64 只发布**一个**
  /// 构建，故意选用较老的 Ubuntu，使其 glibc 足够老，从而向前兼容所有
  /// 更新的发行版（新系统能跑旧二进制，反之不行）。因此在 Ubuntu 22.04 /
  /// 24.04 上运行 `ubuntu-20.04` 构建是完全正常的。
  ///
  /// 该 tag 由 [linuxTagForVersion] 按 release 版本解析，随版本自动切换，
  /// 避免升级 [version] 后仍用旧 tag 导致下载 404。
  final String linuxDistroTag;

  /// Optional expected sha256 of the tarball (hex). If null, integrity is
  /// not verified — enable in production builds.
  final String? sha256;

  String get archiveName =>
      'llvm-mingw-$version-$crt-$linuxDistroTag-x86_64.tar.xz';

  String downloadUrl() =>
      'https://github.com/mstorsjo/llvm-mingw/releases/download/'
      '$version/$archiveName';

  String get extractedDirName =>
      'llvm-mingw-$version-$crt-$linuxDistroTag-x86_64';

  /// 各 release 版本对应的 Linux x86_64 构建 Ubuntu tag。
  ///
  /// llvm-mingw 不为每个 Ubuntu 版本单独发包，而是每个 release 只有一个
  /// Linux 构建，其 tag 随 release 变化（例如 20240619 用 ubuntu-20.04，
  /// 20260616 用 ubuntu-22.04）。升级 [defaultLlvmMingw] 的 version 时，
  /// 在此登记对应 tag 即可。
  static const Map<String, String> _linuxTagByVersion = {
    '20240619': 'ubuntu-20.04',
    '20260616': 'ubuntu-22.04',
  };

  /// 未登记版本的后备 tag。选用已知最老的构建以最大化 glibc 向前兼容性。
  static const String _fallbackLinuxTag = 'ubuntu-20.04';

  /// 按 release 版本解析 Linux x86_64 构建的 Ubuntu tag。
  static String linuxTagForVersion(String version) =>
      _linuxTagByVersion[version] ?? _fallbackLinuxTag;

  /// 以指定版本构造 release，自动解析匹配的 Linux distro tag。
  factory LlvmMingwRelease.pinned({
    String version = '20240619',
    String crt = 'ucrt',
    String? sha256,
  }) =>
      LlvmMingwRelease(
        version: version,
        crt: crt,
        linuxDistroTag: linuxTagForVersion(version),
        sha256: sha256,
      );
}

/// Default LLVM-MinGW release we ship against.
///
/// This is intentionally pinned. To bump: update `version` in the factory
/// call below, register its Linux tag in [LlvmMingwRelease._linuxTagByVersion],
/// download the tarball once, compute sha256, and pass it here.
///
/// `linuxDistroTag` 不再硬编码，而是由 [LlvmMingwRelease.linuxTagForVersion]
/// 按 version 自动解析。
final LlvmMingwRelease defaultLlvmMingw = LlvmMingwRelease.pinned(
  version: '20240619',
  crt: 'ucrt',
  // sha256: 'fill-in-once-verified',
);

/// Resolved paths to the tools we drive during a cross-build.
///
/// 核心工具链实例。支持两种后端：
///   - [ToolchainBackend.llvmMingw]：推荐，clang + lld + mingw-w64 头
///   - [ToolchainBackend.systemMingw]：后备，系统 apt 安装的 GCC-MinGW
enum ToolchainBackend { llvmMingw, systemMingw }

class Toolchain {
  Toolchain({
    this.backend = ToolchainBackend.llvmMingw,
    required this.llvmMingwRoot,
    required this.targetTriple,
    required this.wineExecutable,
    required this.cmakeExecutable,
    required this.ninjaExecutable,
  });

  /// 当前使用的工具链后端。
  final ToolchainBackend backend;

  /// 工具链根目录（LLVM-MinGW 或 /usr 对于系统 GCC-MinGW）。
  final String llvmMingwRoot;

  /// Cross-compile target triple, e.g. `x86_64-w64-mingw32`.
  final String targetTriple;

  /// Absolute path to `wine` or `wine64`.
  final String wineExecutable;

  /// Absolute path to `cmake`.
  final String cmakeExecutable;

  /// Absolute path to `ninja`.
  final String ninjaExecutable;

  // ─── 编译器路径：根据后端自动切换 ───

  String get clang => backend == ToolchainBackend.llvmMingw
      ? p.join(llvmMingwRoot, 'bin', '$targetTriple-clang')
      : '$targetTriple-gcc';

  String get clangxx => backend == ToolchainBackend.llvmMingw
      ? p.join(llvmMingwRoot, 'bin', '$targetTriple-clang++')
      : '$targetTriple-g++';

  String get windres => backend == ToolchainBackend.llvmMingw
      ? p.join(llvmMingwRoot, 'bin', '$targetTriple-windres')
      : '$targetTriple-windres';

  String get lldLink => backend == ToolchainBackend.llvmMingw
      ? p.join(llvmMingwRoot, 'bin', 'ld.lld')
      : '$targetTriple-ld';

  String get llvmDllTool => backend == ToolchainBackend.llvmMingw
      ? p.join(llvmMingwRoot, 'bin', 'llvm-dlltool')
      : '$targetTriple-dlltool';

  String get llvmRc => p.join(llvmMingwRoot, 'bin', 'llvm-rc');
  String get llvmAr => backend == ToolchainBackend.llvmMingw
      ? p.join(llvmMingwRoot, 'bin', 'llvm-ar')
      : '$targetTriple-ar';
  String get llvmRanlib => backend == ToolchainBackend.llvmMingw
      ? p.join(llvmMingwRoot, 'bin', 'llvm-ranlib')
      : '$targetTriple-ranlib';

  /// 是否使用 LLD 链接器（仅 LLVM-MinGW 后端）。
  bool get usesLld => backend == ToolchainBackend.llvmMingw;

  Map<String, String> describe() => {
        'Backend': backend == ToolchainBackend.llvmMingw
            ? 'LLVM-MinGW'
            : 'System GCC-MinGW (apt)',
        'Root': llvmMingwRoot,
        'Target': targetTriple,
        'C compiler': clang,
        'C++ compiler': clangxx,
        'cmake': cmakeExecutable,
        'ninja': ninjaExecutable,
        'wine': wineExecutable,
      };
}

/// 自动供给器。支持多种工具链获取方式（优先级从高到低）：
///
///   1. 命令行 `--toolchain-path` 或环境变量 `LLVM_MINGW_ROOT`
///      → 直接使用用户指定的目录，不下载。
///   2. 缓存目录中已解压的 LLVM-MinGW
///      → 复用上次 precache 的产物。
///   3. 自动下载（支持镜像 URL `FLUTTER_BUILD_MIRROR`）
///      → 从 GitHub / 镜像拉取。
///   4. 系统 apt 安装的 GCC-MinGW（`apt install gcc-mingw-w64-x86-64`）
///      → 当上述全部失败时作为后备。
class ToolchainProvisioner {
  ToolchainProvisioner({
    required this.paths,
    Logger? logger,
    ProcessRunner? runner,
    LlvmMingwRelease? release,
    String targetTriple = 'x86_64-w64-mingw32',
    this.toolchainPathOverride,
  })  : _log = logger ?? Logger.instance,
        _runner = runner ?? ProcessRunner(logger: logger ?? Logger.instance),
        _release = release ?? defaultLlvmMingw,
        _targetTriple = targetTriple;

  final CachePaths paths;
  final Logger _log;
  final ProcessRunner _runner;
  final LlvmMingwRelease _release;
  final String _targetTriple;

  /// 外部传入的工具链路径（从 CLI `--toolchain-path` 获取）。
  final String? toolchainPathOverride;

  /// 确保所有工具就位，返回解析后的 [Toolchain]。
  ///
  /// [allowDownload] 控制是否允许网络下载；
  /// [allowSystemFallback] 控制是否允许回退到 apt 安装的 GCC-MinGW。
  Future<Toolchain> provision({
    bool allowDownload = true,
    bool allowSystemFallback = true,
  }) async {
    await paths.ensure();

    final wine = await _detectWine();
    final cmake = await _detectRequired('cmake', 'sudo apt install cmake');
    final ninja =
        await _detectRequired('ninja', 'sudo apt install ninja-build');

    // ─── 策略 1：用户显式指定路径 ───
    final explicitRoot =
        toolchainPathOverride ?? Platform.environment['LLVM_MINGW_ROOT'];
    if (explicitRoot != null && explicitRoot.isNotEmpty) {
      _log.debug('使用用户指定的工具链: $explicitRoot');
      _validateLlvmMingwDir(explicitRoot);
      return Toolchain(
        backend: ToolchainBackend.llvmMingw,
        llvmMingwRoot: explicitRoot,
        targetTriple: _targetTriple,
        wineExecutable: wine,
        cmakeExecutable: cmake,
        ninjaExecutable: ninja,
      );
    }

    // ─── 策略 2：缓存命中 / 自动下载 ───
    try {
      final llvmRoot = await _ensureLlvmMingw(allowDownload: allowDownload);
      return Toolchain(
        backend: ToolchainBackend.llvmMingw,
        llvmMingwRoot: llvmRoot,
        targetTriple: _targetTriple,
        wineExecutable: wine,
        cmakeExecutable: cmake,
        ninjaExecutable: ninja,
      );
    } on ToolException catch (e) {
      // 如果不允许后备方案，直接抛出
      if (!allowSystemFallback) rethrow;
      _log.debug('LLVM-MinGW 不可用: ${e.message}，尝试系统 GCC-MinGW...');
    }

    // ─── 策略 3：系统 apt 安装的 GCC-MinGW 后备 ───
    return _trySystemMingw(
      wine: wine,
      cmake: cmake,
      ninja: ninja,
    );
  }

  Future<String> _ensureLlvmMingw({required bool allowDownload}) async {
    final destDir = paths.toolchainRoot(_release.extractedDirName);
    final marker = File(p.join(destDir, '.installed'));

    if (marker.existsSync()) {
      _log.debug('LLVM-MinGW cache hit: $destDir');
      return destDir;
    }

    if (!allowDownload) {
      throw ToolException(
        'LLVM-MinGW is not installed at $destDir',
        hint: 'Run `flutter_build precache` first, or set '
            'LLVM_MINGW_ROOT to a pre-existing installation, or '
            '`sudo apt install gcc-mingw-w64-x86-64` as fallback.',
      );
    }

    // 支持镜像 URL：环境变量 FLUTTER_BUILD_MIRROR 替换 GitHub URL。
    // 例如设置为 https://mirrors.example.com/llvm-mingw/releases/download
    // 则最终 URL = <mirror>/<version>/<archiveName>
    final mirror = Platform.environment['FLUTTER_BUILD_MIRROR'];
    final downloadUrl = mirror != null && mirror.isNotEmpty
        ? '$mirror/${_release.version}/${_release.archiveName}'
        : _release.downloadUrl();

    _log.step('Downloading LLVM-MinGW ${_release.version}');
    if (mirror != null && mirror.isNotEmpty) {
      _log.info('  Using mirror: $mirror');
    }
    final archivePath = p.join(paths.downloadsDir, _release.archiveName);
    await _download(downloadUrl, archivePath);

    if (_release.sha256 != null) {
      await _verifySha256(archivePath, _release.sha256!);
    }

    _log.step('Extracting ${_release.archiveName}');
    // Use system `tar` — piping through xz is streaming and avoids loading
    // the whole ~250MB tarball into memory.
    await Directory(paths.toolchainsDir).create(recursive: true);
    await _runner.run(
      'tar',
      ['-xJf', archivePath, '-C', paths.toolchainsDir],
      stream: false,
    );

    if (!Directory(destDir).existsSync()) {
      throw ArtifactException(
        'Extraction succeeded but expected directory is missing: $destDir',
      );
    }
    await marker.writeAsString(DateTime.now().toIso8601String());
    _log.success('LLVM-MinGW ${_release.version} ready at $destDir');
    return destDir;
  }

  /// 验证用户指定的 LLVM-MinGW 目录是否包含必要二进制。
  void _validateLlvmMingwDir(String root) {
    final clang = p.join(root, 'bin', '$_targetTriple-clang');
    if (!File(clang).existsSync()) {
      throw ToolException(
        'LLVM_MINGW_ROOT ($root) does not contain $clang',
        hint: 'Ensure the directory is a valid LLVM-MinGW installation.\n'
            'Expected layout: $root/bin/$_targetTriple-clang',
      );
    }
  }

  /// 尝试使用系统 apt 安装的 GCC-MinGW 作为后备方案。
  ///
  /// 安装命令：
  ///   sudo apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
  Future<Toolchain> _trySystemMingw({
    required String wine,
    required String cmake,
    required String ninja,
  }) async {
    // 检查系统是否有 x86_64-w64-mingw32-gcc
    final gccPath = await _runner.which('$_targetTriple-gcc');
    if (gccPath == null) {
      throw ToolException(
        'Neither LLVM-MinGW nor system GCC-MinGW could be found.',
        hint: 'Choose one:\n'
            '  • export LLVM_MINGW_ROOT=/path/to/llvm-mingw  (manually downloaded)\n'
            '  • flutter_build precache  (auto-download from GitHub)\n'
            '  • sudo apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64  (GCC fallback)',
      );
    }

    // GCC-MinGW 在 apt 中无独立根目录，用 /usr 作为象征性根。
    _log.warn('Using system GCC-MinGW (apt) as fallback. '
        'LLVM-MinGW is recommended for best compatibility.');
    return Toolchain(
      backend: ToolchainBackend.systemMingw,
      llvmMingwRoot: '/usr', // 占位，GCC-MinGW 的二进制在 PATH 上
      targetTriple: _targetTriple,
      wineExecutable: wine,
      cmakeExecutable: cmake,
      ninjaExecutable: ninja,
    );
  }

  Future<String> _detectWine() async {
    for (final name in ['wine64', 'wine']) {
      final path = await _runner.which(name);
      if (path != null) return path;
    }
    throw MissingToolException(
      'wine',
      hint: 'Install with: sudo apt install wine64',
    );
  }

  Future<String> _detectRequired(String tool, String installHint) async {
    final path = await _runner.which(tool);
    if (path != null) return path;
    throw MissingToolException(tool, hint: installHint);
  }

  Future<void> _download(String url, String destPath) async {
    _log.debug('GET $url');
    final dest = File(destPath);
    // Skip re-download if the file already exists (and has non-zero size).
    if (dest.existsSync() && dest.lengthSync() > 0) {
      _log.debug('Reusing cached download: $destPath');
      return;
    }
    final req = http.Request('GET', Uri.parse(url));
    final streamed = await req.send();
    if (streamed.statusCode ~/ 100 != 2) {
      throw ArtifactException(
        'HTTP ${streamed.statusCode} downloading $url',
      );
    }
    final tmp = File('$destPath.part');
    final sink = tmp.openWrite();
    var received = 0;
    final total = streamed.contentLength ?? 0;
    var lastReport = 0;
    await for (final chunk in streamed.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0 && received - lastReport > 4 * 1024 * 1024) {
        final pct = (received * 100 / total).toStringAsFixed(1);
        _log.debug('  … ${(received / (1024 * 1024)).toStringAsFixed(1)} MB / '
            '${(total / (1024 * 1024)).toStringAsFixed(1)} MB ($pct%)');
        lastReport = received;
      }
    }
    await sink.flush();
    await sink.close();
    await tmp.rename(destPath);
  }

  Future<void> _verifySha256(String path, String expectedHex) async {
    final stream = File(path).openRead();
    final digest = await sha256.bind(stream).first;
    final actual = digest.toString();
    if (actual.toLowerCase() != expectedHex.toLowerCase()) {
      throw ArtifactException(
        'SHA-256 mismatch for $path\n  expected: $expectedHex\n  actual:   $actual',
      );
    }
  }
}
