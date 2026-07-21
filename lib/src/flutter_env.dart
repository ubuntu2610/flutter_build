// Discovery of the user's Flutter SDK.
//
// We deliberately avoid shelling out to `flutter --version` on every call
// (slow, ~2s cold start): once we've located the SDK root by resolving
// the `flutter` script on PATH we can read the file layout directly.
//
// 【Flutter 版本接缝】本文件集中了对 Flutter 目录布局的版本敏感假设，升级
// Flutter 时优先检查这里：
//   - `version` 顶层文件在 ≈3.13+ 被移除（改从 git 计算）——已作可选处理；
//   - frontend_server 快照在 ≈3.16+ 更名为 `_aot` 且改用 dartaotruntime 运行，
//     并可能位于 dart-sdk/bin/snapshots/ 下——见 [FlutterEnv.locate] 的候选列表；
//   - flutter_patched_sdk(_product) 位于 engine/common/ 下——见 [patchedSdkPath]。

import 'dart:io';

import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'logger.dart';
import 'process_runner.dart';

/// A snapshot of the Flutter SDK we can find on the host.
class FlutterEnv {
  FlutterEnv._({
    required this.sdkRoot,
    required this.flutterVersion,
    required this.dartSdkVersion,
    required this.engineCommitHash,
    required this.engineRealm,
    required this.storageBaseUrl,
    required this.dartExecutable,
    required this.frontendServerSnapshot,
    required this.hostEngineDir,
  });

  /// 仅用于单元测试：允许不探测磁盘直接构造实例。
  // ignore: sort_unnamed_constructors_first
  FlutterEnv.forTesting({
    required this.sdkRoot,
    required this.flutterVersion,
    required this.dartSdkVersion,
    required this.engineCommitHash,
    required this.engineRealm,
    required this.storageBaseUrl,
    required this.dartExecutable,
    required this.frontendServerSnapshot,
    required this.hostEngineDir,
  });

  /// Absolute path to the Flutter SDK root (the directory containing `bin/`).
  final String sdkRoot;

  /// Framework version, e.g. `3.41.6`.
  final String flutterVersion;

  /// Bundled Dart SDK version, e.g. `3.11.4`.
  final String dartSdkVersion;

  /// The engine commit SHA from `bin/internal/engine.version`.
  final String engineCommitHash;

  /// Optional non-empty value from `bin/internal/engine.realm` (used for
  /// staging channels / forks). Empty string when unset.
  final String engineRealm;

  /// Base URL for downloading engine artifacts. Honors
  /// `FLUTTER_STORAGE_BASE_URL` env var if the user has one set.
  final String storageBaseUrl;

  /// Absolute path to `bin/cache/dart-sdk/bin/dart`.
  final String dartExecutable;

  /// Absolute path to the linux-x64 frontend server snapshot. Used to
  /// compile Dart source to kernel `.dill` files without shelling out to
  /// `flutter assemble`.
  ///
  /// 可能是现代的 `frontend_server_aot.dart.snapshot`（AOT 快照，必须用
  /// [dartAotRuntimeExecutable] 运行）或旧版 `frontend_server.dart.snapshot`
  /// （用 `dart` 运行）。启动时请用 [frontendServerRuntime] 选择正确的运行时。
  final String frontendServerSnapshot;

  /// Host engine artifacts directory (linux-x64). Used to locate
  /// `frontend_server.dart.snapshot`, `flutter_patched_sdk`, etc.
  final String hostEngineDir;

  /// Path to the `flutter_patched_sdk/` needed by frontend_server for
  /// kernel compilation. Located under [hostEngineDir]'s sibling
  /// `common/flutter_patched_sdk` or `common/flutter_patched_sdk_product`.
  String patchedSdkPath({required bool product}) {
    // Layout:
    //   bin/cache/artifacts/engine/common/flutter_patched_sdk
    //   bin/cache/artifacts/engine/common/flutter_patched_sdk_product
    final common = p.join(p.dirname(hostEngineDir), 'common');
    return p.join(
      common,
      product ? 'flutter_patched_sdk_product' : 'flutter_patched_sdk',
    );
  }

  /// Absolute path to `dartaotruntime`, the runtime for AOT snapshots such as
  /// the modern `frontend_server_aot.dart.snapshot`. Sits next to
  /// [dartExecutable] in `bin/cache/dart-sdk/bin/`.
  String get dartAotRuntimeExecutable =>
      p.join(p.dirname(dartExecutable), 'dartaotruntime');

  /// Whether [frontendServerSnapshot] is an AOT snapshot. Modern Flutter
  /// (≈ 3.16+) ships `frontend_server_aot.dart.snapshot`, which is an AOT
  /// snapshot and must be launched with `dartaotruntime` — running it with
  /// plain `dart` fails with "is an AOT snapshot and should be run with
  /// 'dartaotruntime'" (exit 255).
  bool get frontendServerIsAot =>
      p.basename(frontendServerSnapshot).contains('_aot');

  /// The correct executable to launch [frontendServerSnapshot]:
  /// [dartAotRuntimeExecutable] for AOT snapshots, otherwise the Dart VM
  /// ([dartExecutable]).
  String get frontendServerRuntime =>
      frontendServerIsAot ? dartAotRuntimeExecutable : dartExecutable;

  /// Locate the SDK.
  ///
  /// Resolves `flutter` on PATH (or [flutterExecutable] if provided), follows
  /// symlinks to reach the real bin script, then walks two levels up.
  static Future<FlutterEnv> locate({
    String? flutterExecutable,
    ProcessRunner? runner,
    Logger? logger,
  }) async {
    final log = logger ?? Logger.instance;
    final r = runner ?? ProcessRunner(logger: log);

    final flutter = flutterExecutable ?? await r.which('flutter');
    if (flutter == null) {
      throw FlutterSdkException(
        'Cannot find the `flutter` executable on PATH.',
        hint: 'Install Flutter and ensure `flutter --version` works.',
      );
    }

    // Resolve symlink chain (asdf, homebrew, custom installs).
    final resolved = await File(flutter).resolveSymbolicLinks();
    // .../<sdk>/bin/flutter → .../<sdk>
    final sdkRoot = p.normalize(p.join(p.dirname(resolved), '..'));

    if (!Directory(sdkRoot).existsSync()) {
      throw FlutterSdkException(
        'Resolved Flutter SDK path does not exist: $sdkRoot',
      );
    }

    final versionFile = File(p.join(sdkRoot, 'version'));
    final engineVersionFile =
        File(p.join(sdkRoot, 'bin', 'internal', 'engine.version'));
    final engineRealmFile =
        File(p.join(sdkRoot, 'bin', 'internal', 'engine.realm'));
    final dartExe = p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
    final dartSdkVersionFile =
        File(p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'version'));

    // Newer Flutter (≈ 3.13+) dropped the top-level `version` file in
    // favour of computing the value from git. We treat it as optional:
    // when absent we fall back to reading FLUTTER_VERSION or to a
    // synthetic "unknown" value — the framework version is only used
    // for diagnostics, never for build correctness.
    String flutterVersion;
    if (versionFile.existsSync()) {
      flutterVersion = versionFile.readAsStringSync().trim();
    } else {
      flutterVersion = Platform.environment['FLUTTER_VERSION']?.trim() ??
          'unknown (no version file)';
      log.debug('No top-level `version` file at ${versionFile.path}; '
          'falling back to "$flutterVersion".');
    }

    if (!engineVersionFile.existsSync()) {
      throw FlutterSdkException(
        'Missing engine.version file: ${engineVersionFile.path}',
        hint: 'This may be a broken Flutter checkout; try `flutter upgrade`.',
      );
    }
    if (!File(dartExe).existsSync()) {
      throw FlutterSdkException(
        'Bundled Dart SDK not found: $dartExe',
        hint: 'Run `flutter doctor` once to trigger the initial download.',
      );
    }

    // Host engine artifacts.
    final hostEngineDir = p.join(
      sdkRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'linux-x64',
    );
    // Modern Flutter (≈ 3.16+) renamed the snapshot to `_aot` and also
    // ships it under `bin/cache/dart-sdk/bin/snapshots/`. We probe the
    // most-preferred locations first and fall back through older names.
    final frontendServerCandidates = <String>[
      p.join(hostEngineDir, 'frontend_server_aot.dart.snapshot'),
      p.join(hostEngineDir, 'frontend_server.dart.snapshot'),
      p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots',
          'frontend_server_aot.dart.snapshot'),
      p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots',
          'frontend_server.dart.snapshot'),
    ];
    final frontendServer = frontendServerCandidates.firstWhere(
      (path) => File(path).existsSync(),
      orElse: () => '',
    );

    if (frontendServer.isEmpty) {
      throw FlutterSdkException(
        'frontend_server snapshot not found. Searched:\n'
        '${frontendServerCandidates.map((c) => '  $c').join('\n')}',
        hint: 'Run `flutter precache --linux` to populate host artifacts.',
      );
    }

    // AOT 快照（frontend_server_aot.*）必须用 `dartaotruntime` 运行，而非
    // `dart`。提前确认运行时存在，否则在 Stage 3 才会报晦涩的 exit 255：
    // "is an AOT snapshot and should be run with 'dartaotruntime'"。
    if (p.basename(frontendServer).contains('_aot')) {
      final aotRuntime = p.join(p.dirname(dartExe), 'dartaotruntime');
      if (!File(aotRuntime).existsSync()) {
        throw FlutterSdkException(
          'Selected AOT frontend_server snapshot but dartaotruntime is '
          'missing: $aotRuntime',
          hint: 'Run `flutter doctor` once to repair the bundled Dart SDK.',
        );
      }
    }

    return FlutterEnv._(
      sdkRoot: sdkRoot,
      flutterVersion: flutterVersion,
      dartSdkVersion: dartSdkVersionFile.existsSync()
          ? dartSdkVersionFile.readAsStringSync().trim()
          : 'unknown',
      engineCommitHash: engineVersionFile.readAsStringSync().trim(),
      engineRealm: engineRealmFile.existsSync()
          ? engineRealmFile.readAsStringSync().trim()
          : '',
      storageBaseUrl: Platform.environment['FLUTTER_STORAGE_BASE_URL'] ??
          'https://storage.googleapis.com',
      dartExecutable: dartExe,
      frontendServerSnapshot: frontendServer,
      hostEngineDir: hostEngineDir,
    );
  }

  /// The URL prefix under which per-hash engine artifacts live. E.g.
  /// `https://storage.googleapis.com/flutter_infra_release/flutter/<hash>/`.
  Uri artifactsBase() {
    final realm = engineRealm.isEmpty ? '' : '$engineRealm/';
    return Uri.parse(
      '$storageBaseUrl/${realm}flutter_infra_release/flutter/$engineCommitHash/',
    );
  }

  Map<String, String> describe() => {
        'Flutter SDK': sdkRoot,
        'Framework': flutterVersion,
        'Dart SDK': dartSdkVersion,
        'Engine hash': engineCommitHash,
        if (engineRealm.isNotEmpty) 'Engine realm': engineRealm,
        'Storage base': storageBaseUrl,
      };
}
