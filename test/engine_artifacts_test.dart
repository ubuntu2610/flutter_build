// WindowsFlavor 枚举行为测试
//
// 验证三种构建模式（debug / profile / release）的属性判定正确：
//   - isAot: debug=false, profile/release=true
//   - isProduct: 仅 release=true
//   - cliName: 字面量匹配
//
// 以及 EngineArtifactsProvisioner.isStale 的 SDK 升级版本错配检测：
// snap / flutter upgrade 只刷新 dart-sdk（frontend_server），Windows 引擎
// 产物残留旧版，AOT 编译报
//   "Invalid kernel binary format version (expected 130, found 138)"
// ——isStale 通过 mtime 对账在构建前检出这种错配。

import 'dart:io';

import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:flutter_build/src/flutter_env.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WindowsFlavor 枚举', () {
    test('debug 模式 isAot 为 false', () {
      expect(WindowsFlavor.debug.isAot, isFalse);
    });

    test('profile 模式 isAot 为 true', () {
      expect(WindowsFlavor.profile.isAot, isTrue);
    });

    test('release 模式 isAot 为 true', () {
      expect(WindowsFlavor.release.isAot, isTrue);
    });

    test('仅 release 模式 isProduct 为 true', () {
      expect(WindowsFlavor.release.isProduct, isTrue);
      expect(WindowsFlavor.profile.isProduct, isFalse);
      expect(WindowsFlavor.debug.isProduct, isFalse);
    });

    test('cliName 返回小写字符串', () {
      expect(WindowsFlavor.debug.cliName, 'debug');
      expect(WindowsFlavor.profile.cliName, 'profile');
      expect(WindowsFlavor.release.cliName, 'release');
    });

    test('kernelModeDefines 与构建模式匹配', () {
      expect(WindowsFlavor.release.kernelModeDefines,
          containsAll(['dart.vm.product=true', 'dart.vm.profile=false']));
      expect(WindowsFlavor.profile.kernelModeDefines,
          containsAll(['dart.vm.product=false', 'dart.vm.profile=true']));
      expect(WindowsFlavor.debug.kernelModeDefines,
          containsAll(['dart.vm.product=false', 'dart.vm.profile=false']));
    });
  });

  group('EngineArtifactsProvisioner.isStale（SDK 升级版本错配检测）', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fb_engine_artifacts');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    (EngineArtifactsProvisioner, EngineArtifacts) makeFixture() {
      final env = FlutterEnv.forTesting(
        sdkRoot: tmp.path,
        flutterVersion: '3.47.2',
        dartSdkVersion: '3.13.2',
        engineCommitHash: 'a804b26',
        engineRealm: '',
        storageBaseUrl: 'https://storage.googleapis.com',
        dartExecutable: p.join(tmp.path, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'),
        // frontend_server 是 mtime 对账的参照物（kernel 生产者）。
        frontendServerSnapshot:
            p.join(tmp.path, 'frontend_server_aot.dart.snapshot'),
        hostEngineDir: p.join(tmp.path, 'engine', 'linux-x64'),
      );
      final prov = EngineArtifactsProvisioner(env: env);
      final art = EngineArtifacts(
        env: env,
        embedderDir: p.join(tmp.path, 'engine', 'windows-x64'),
        releaseArtifactsDir: p.join(tmp.path, 'engine', 'windows-x64-release'),
        profileArtifactsDir: p.join(tmp.path, 'engine', 'windows-x64-profile'),
        hostEngineDir: p.join(tmp.path, 'engine', 'linux-x64'),
      );
      return (prov, art);
    }

    File writeArtifact(String relPath, DateTime mtime) {
      final f = File(p.join(tmp.path, relPath))
        ..createSync(recursive: true)
        ..writeAsStringSync('stub');
      f.setLastModifiedSync(mtime);
      return f;
    }

    test('同批产物（mtime 相差小时级）→ 不 stale', () {
      final (prov, art) = makeFixture();
      final now = DateTime.now();
      writeArtifact('frontend_server_aot.dart.snapshot', now);
      writeArtifact(
          'engine/windows-x64-release/gen_snapshot.exe',
          now.subtract(const Duration(hours: 1)));
      writeArtifact('engine/windows-x64-profile/gen_snapshot.exe',
          now.subtract(const Duration(hours: 1)));
      writeArtifact('engine/windows-x64/flutter_windows.dll',
          now.subtract(const Duration(hours: 2)));

      expect(prov.isStale(art), isFalse);
    });

    test('gen_snapshot.exe 旧于 frontend_server 两个月（升级残留）→ stale', () {
      final (prov, art) = makeFixture();
      final now = DateTime.now();
      writeArtifact('frontend_server_aot.dart.snapshot', now);
      // 复现 2026-09 实测场景：gen_snapshot.exe 是 6 月 23 日的旧版产物，
      // frontend_server 已随 SDK 3.47.2 升级到 8 月 26 日。
      writeArtifact('engine/windows-x64-release/gen_snapshot.exe',
          now.subtract(const Duration(days: 64)));
      writeArtifact('engine/windows-x64-profile/gen_snapshot.exe',
          now.subtract(const Duration(days: 64)));
      writeArtifact('engine/windows-x64/flutter_windows.dll',
          now.subtract(const Duration(days: 64)));

      expect(prov.isStale(art), isTrue);
    });

    test('仅 release gen_snapshot 过期也判定 stale（profile 正常）', () {
      final (prov, art) = makeFixture();
      final now = DateTime.now();
      writeArtifact('frontend_server_aot.dart.snapshot', now);
      writeArtifact('engine/windows-x64-release/gen_snapshot.exe',
          now.subtract(const Duration(days: 30)));
      writeArtifact('engine/windows-x64-profile/gen_snapshot.exe',
          now.subtract(const Duration(hours: 1)));

      expect(prov.isStale(art), isTrue);
    });

    test('产物新于 frontend_server 很多（降级 SDK 残留）→ 同样 stale', () {
      final (prov, art) = makeFixture();
      final now = DateTime.now();
      writeArtifact('frontend_server_aot.dart.snapshot',
          now.subtract(const Duration(days: 30)));
      writeArtifact('engine/windows-x64-release/gen_snapshot.exe', now);

      expect(prov.isStale(art), isTrue);
    });

    test('frontend_server 缺失 → 保守放行（不阻塞构建）', () {
      final (prov, art) = makeFixture();
      final now = DateTime.now();
      // 不写 frontend_server_aot.dart.snapshot。
      writeArtifact('engine/windows-x64-release/gen_snapshot.exe',
          now.subtract(const Duration(days: 365)));

      expect(prov.isStale(art), isFalse);
    });

    test('产物文件缺失不算 stale（由 _allPresent 负责）', () {
      final (prov, art) = makeFixture();
      writeArtifact('frontend_server_aot.dart.snapshot', DateTime.now());
      // 只写 dll，gen_snapshot.exe 均缺失。
      writeArtifact('engine/windows-x64/flutter_windows.dll', DateTime.now());

      expect(prov.isStale(art), isFalse);
    });
  });
}
