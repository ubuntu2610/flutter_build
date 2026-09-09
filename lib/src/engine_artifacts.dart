// Provisioning of Windows engine artifacts on Linux.
//
// Strategy: delegate to `flutter precache --windows` which knows exactly
// which zips to fetch for the current SDK. Then expose typed getters for
// the individual files we need in the build pipeline.
//
// We deliberately don't reinvent the URL/artifact scheme: Flutter's
// artifact naming has changed several times across releases (per-mode
// zips, split zips, embedder vs runtime), and re-encoding that policy
// here would guarantee drift.
//
// 【Flutter 版本接缝】对引擎产物目录布局的版本敏感假设集中在 [_resolve] 与
// [EngineArtifacts] 的 getter 里：debug/JIT 用 windows-x64，release/profile 用
// windows-x64-release/-profile 的 AOT 引擎；icudtl.dat 在新版共享于 linux-x64。
// 升级 Flutter 若构建报缺失产物，优先核对这些路径。

import 'dart:io';

import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'flutter_env.dart';
import 'logger.dart';
import 'process_runner.dart';

/// The three Flutter build modes for a Windows target.
enum WindowsFlavor { debug, profile, release }

extension WindowsFlavorX on WindowsFlavor {
  String get cliName => switch (this) {
        WindowsFlavor.debug => 'debug',
        WindowsFlavor.profile => 'profile',
        WindowsFlavor.release => 'release',
      };

  /// Whether this mode uses AOT (gen_snapshot) or a JIT kernel blob.
  bool get isAot => this != WindowsFlavor.debug;

  /// Whether the Dart VM runs in "product" mode (release-only) — matters for
  /// picking `flutter_patched_sdk_product` vs `flutter_patched_sdk`.
  bool get isProduct => this == WindowsFlavor.release;

  /// frontend_server 需要的模式常量（`key=value` 形式，调用方自行加
  /// `--define=` 前缀）。它们决定 Dart 侧的 `kReleaseMode` / `kProfileMode` /
  /// `kDebugMode` 常量，与 `flutter_tools` 的 `buildModeOptions` 保持一致：
  ///   - release: product=true, profile=false
  ///   - profile: product=false, profile=true
  ///   - debug:   两者皆 false
  List<String> get kernelModeDefines => switch (this) {
        WindowsFlavor.debug => const [
            'dart.vm.profile=false',
            'dart.vm.product=false',
          ],
        WindowsFlavor.profile => const [
            'dart.vm.profile=true',
            'dart.vm.product=false',
          ],
        WindowsFlavor.release => const [
            'dart.vm.profile=false',
            'dart.vm.product=true',
          ],
      };
}

/// Resolved paths to the Windows engine artifacts on disk.
class EngineArtifacts {
  EngineArtifacts({
    required this.env,
    required this.embedderDir,
    required this.releaseArtifactsDir,
    required this.profileArtifactsDir,
    required this.hostEngineDir,
  });

  final FlutterEnv env;

  /// `<flutter>/bin/cache/artifacts/engine/windows-x64/` — contains
  /// `flutter_windows.dll`, `flutter_windows.h`, header set,
  /// `cpp_client_wrapper/`, `flutter_windows.dll.lib` and (older Flutter)
  /// `icudtl.dat`.
  final String embedderDir;

  /// `.../windows-x64-release/` — contains the release `gen_snapshot.exe`.
  final String releaseArtifactsDir;

  /// `.../windows-x64-profile/` — contains the profile `gen_snapshot.exe`.
  final String profileArtifactsDir;

  /// `.../linux-x64/` — modern Flutter ships one shared `icudtl.dat` here
  /// instead of duplicating it into every per-platform artifact folder.
  final String hostEngineDir;

  String get flutterWindowsDll => p.join(embedderDir, 'flutter_windows.dll');

  /// 按构建模式解析 `flutter_windows.dll`。
  ///
  /// `windows-x64` 是 **debug/JIT** 引擎；release/profile 必须用
  /// `windows-x64-release` / `windows-x64-profile` 里的 **AOT** 引擎。否则引擎
  /// 会运行在 JIT 模式，而 bundle 里只有 app.so（AOT），启动即失败：
  /// “Not running in AOT mode but could not resolve the kernel binary”。
  String flutterWindowsDllForMode(WindowsFlavor mode) {
    final dir = switch (mode) {
      WindowsFlavor.release => releaseArtifactsDir,
      WindowsFlavor.profile => profileArtifactsDir,
      WindowsFlavor.debug => embedderDir,
    };
    return p.join(dir, 'flutter_windows.dll');
  }

  String get flutterWindowsHeader => p.join(embedderDir, 'flutter_windows.h');
  String get cppClientWrapperDir => p.join(embedderDir, 'cpp_client_wrapper');
  String get flutterWindowsImportLib =>
      p.join(embedderDir, 'flutter_windows.dll.lib');

  /// Resolve `icudtl.dat`, preferring the per-platform copy if present
  /// (older Flutter) and falling back to the shared host copy (newer).
  String get icudtl {
    final perPlatform = p.join(embedderDir, 'icudtl.dat');
    if (File(perPlatform).existsSync()) return perPlatform;
    return p.join(hostEngineDir, 'icudtl.dat');
  }

  /// `gen_snapshot.exe` for the given mode (release / profile).
  String genSnapshotExe(WindowsFlavor mode) {
    final dir = switch (mode) {
      WindowsFlavor.release => releaseArtifactsDir,
      WindowsFlavor.profile => profileArtifactsDir,
      WindowsFlavor.debug =>
        throw ArgumentError('debug mode does not use gen_snapshot'),
    };
    return p.join(dir, 'gen_snapshot.exe');
  }

  Map<String, String> describe() => {
        'embedder dir': embedderDir,
        'flutter_windows.dll': _existsMark(flutterWindowsDll),
        'flutter_windows.h': _existsMark(flutterWindowsHeader),
        'cpp_client_wrapper': _existsMark(cppClientWrapperDir),
        'icudtl.dat': _existsMark(icudtl),
        'gen_snapshot (release)':
            _existsMark(genSnapshotExe(WindowsFlavor.release)),
        'gen_snapshot (profile)':
            _existsMark(genSnapshotExe(WindowsFlavor.profile)),
      };

  String _existsMark(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound
          ? '$path  ✓'
          : '$path  (missing)';
}

class EngineArtifactsProvisioner {
  EngineArtifactsProvisioner({
    required this.env,
    Logger? logger,
    ProcessRunner? runner,
  })  : _log = logger ?? Logger.instance,
        _runner = runner ?? ProcessRunner(logger: logger ?? Logger.instance);

  final FlutterEnv env;
  final Logger _log;
  final ProcessRunner _runner;

  /// Idempotent: skips the Flutter subcall if all expected files are present
  /// **and** provably fresh (see [isStale]).
  ///
  /// [allowDownload] 为 false（`--no-precache` / doctor 不带 `--allow-download`）
  /// 时，缺失或过期直接抛 [ArtifactException]，不触发下载。
  ///
  /// [force] 为 true 时跳过新鲜度判断，无条件用 `--force` 重新获取——用于
  /// AOT 阶段检测到 kernel 格式版本错配后的自动修复。
  Future<EngineArtifacts> ensure({
    bool allowDownload = true,
    bool force = false,
  }) async {
    final artifacts = _resolve();
    final missing = !_allPresent(artifacts);
    final stale = !missing && isStale(artifacts);

    if (!force && !missing && !stale) {
      _log.debug('Windows engine artifacts already present.');
      return artifacts;
    }

    if (!allowDownload) {
      throw ArtifactException(
        missing
            ? 'Windows engine artifacts are missing.'
            : 'Windows engine artifacts are stale: gen_snapshot.exe predates '
                'the SDK Dart toolchain — the kernel format mismatch will '
                'break AOT compilation.',
        hint: 'Re-run without --no-precache (or with --allow-download), or '
            'fix manually:\n'
            '  flutter precache --no-android --no-ios --windows --force',
      );
    }

    // stale 时必须 --force：SDK 自动升级（snap 等）后，flutter 的 cache stamp
    // 可能已被「空更新」污染——Linux 主机上 WindowsEngineArtifacts 的下载列
    // 表为空，update 后 stamp 照写当前 engine hash——普通 precache 会静默跳过
    // （2026-09 在 Flutter 3.47.2 + snap 升级场景实测）。
    await _precache(force: force || stale);

    var current = _resolve();
    if (_allPresent(current) && !isStale(current)) return current;

    // 兜底：missing 场景下普通 precache 也可能因 stamp 污染静默无效，强刷一次。
    if (!force && !stale) {
      await _precache(force: true);
      current = _resolve();
      if (_allPresent(current) && !isStale(current)) return current;
    }

    throw ArtifactException(
      'Windows engine artifacts still missing or stale after `flutter precache`.\n'
      '${current.describe().entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}',
      hint: 'Try upgrading Flutter (`flutter upgrade`) or check network '
          'access to storage.googleapis.com.',
    );
  }

  Future<void> _precache({required bool force}) async {
    _log.step('flutter precache --windows${force ? ' --force' : ''} '
        '(populating engine artifacts)');
    await _runner.run(
      p.join(env.sdkRoot, 'bin', 'flutter'),
      [
        'precache',
        '--no-android',
        '--no-ios',
        '--windows',
        if (force) '--force',
      ],
      stream: true,
      tag: 'flutter',
    );
  }

  /// Windows 引擎产物是否与当前 SDK 的 Dart 工具链版本错配（stale）。
  ///
  /// 【Flutter 版本接缝 · 2026-09 实测】SDK 自动升级（snap / flutter upgrade）
  /// 只刷新 dart-sdk / frontend_server（kernel 生产者），Windows 引擎产物
  /// （kernel 消费者 gen_snapshot.exe、flutter_windows.dll）残留旧版；且
  /// flutter 的 stamp 在 Linux 主机上会被「空更新」污染（见 [ensure]），
  /// 普通 precache 无法自愈。错配时 AOT 编译失败特征：
  ///   Can't load Kernel binary: Invalid kernel binary format version
  ///   (expected 130, found 138).
  ///
  /// 判据：产物文件的 mtime 保留自 zip 内时间戳（引擎构建时间）。同一引擎
  /// 构建的 frontend_server 与 gen_snapshot.exe 时间差在小时级；差值超过
  /// 7 天说明二者来自不同引擎版本。frontend_server 缺失或无法读取时保守
  /// 放行（返回 false），不阻塞构建。
  bool isStale(EngineArtifacts a) {
    final ref = File(env.frontendServerSnapshot);
    if (!ref.existsSync()) return false;
    final refTime = ref.lastModifiedSync();
    const threshold = Duration(days: 7);
    for (final path in <String>[
      a.genSnapshotExe(WindowsFlavor.release),
      a.genSnapshotExe(WindowsFlavor.profile),
      a.flutterWindowsDll,
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue; // 缺失由 _allPresent 负责。
      if (refTime.difference(f.lastModifiedSync()).abs() > threshold) {
        return true;
      }
    }
    return false;
  }

  EngineArtifacts _resolve() {
    final engineBase = p.join(
      env.sdkRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
    );
    return EngineArtifacts(
      env: env,
      embedderDir: p.join(engineBase, 'windows-x64'),
      releaseArtifactsDir: p.join(engineBase, 'windows-x64-release'),
      profileArtifactsDir: p.join(engineBase, 'windows-x64-profile'),
      hostEngineDir: p.join(engineBase, 'linux-x64'),
    );
  }

  bool _allPresent(EngineArtifacts a) {
    return File(a.flutterWindowsDll).existsSync() &&
        File(a.flutterWindowsHeader).existsSync() &&
        Directory(a.cppClientWrapperDir).existsSync() &&
        File(a.icudtl).existsSync() &&
        File(a.genSnapshotExe(WindowsFlavor.release)).existsSync() &&
        File(a.genSnapshotExe(WindowsFlavor.profile)).existsSync();
  }
}
