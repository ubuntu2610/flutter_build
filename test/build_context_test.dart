// BuildContext 路径派生逻辑测试
//
// 验证所有自动计算的目录/文件路径是否遵守预期的目录结构约定：
//   buildRoot/<mode>/
//     ├── windows_src/          (staged CMake source)
//     ├── cmake_build/          (CMake outputs)
//     ├── intermediates/        (kernel dill + aot elf)
//     └── <app_name>/           (final packaged output)
//           ├── <app>.exe
//           └── data/
//                 └── flutter_assets/

import 'package:flutter_build/src/build/build_context.dart';
import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:flutter_build/src/flutter_env.dart';
import 'package:flutter_build/src/project.dart';
import 'package:flutter_build/src/toolchain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ─── 用最小 Stub 实现不落盘的 BuildContext 构造 ───

FlutterEnv _stubEnv() => FlutterEnv.forTesting(
      sdkRoot: '/sdk',
      flutterVersion: '3.22.0',
      dartSdkVersion: '3.5.0',
      engineCommitHash: 'abc123',
      engineRealm: '',
      storageBaseUrl: 'https://storage.googleapis.com',
      dartExecutable: '/sdk/bin/cache/dart-sdk/bin/dart',
      frontendServerSnapshot:
          '/sdk/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot',
      hostEngineDir: '/sdk/bin/cache/artifacts/engine/linux-x64',
    );

FlutterProject _stubProject() => FlutterProject.forTesting(
      root: '/home/user/myapp',
      appName: 'myapp',
      entryPoint: '/home/user/myapp/lib/main.dart',
      windowsDir: '/home/user/myapp/windows',
      hasWindowsScaffold: true,
      plugins: [],
    );

EngineArtifacts _stubArtifacts() => EngineArtifacts(
      env: _stubEnv(),
      embedderDir: '/sdk/bin/cache/artifacts/engine/windows-x64',
      releaseArtifactsDir: '/sdk/bin/cache/artifacts/engine/windows-x64-release',
      profileArtifactsDir: '/sdk/bin/cache/artifacts/engine/windows-x64-profile',
      hostEngineDir: '/sdk/bin/cache/artifacts/engine/linux-x64',
    );

Toolchain _stubToolchain() => Toolchain(
      llvmMingwRoot: '/opt/llvm-mingw',
      targetTriple: 'x86_64-w64-mingw32',
      wineExecutable: '/usr/bin/wine64',
      cmakeExecutable: '/usr/bin/cmake',
      ninjaExecutable: '/usr/bin/ninja',
    );

void main() {
  late BuildContext ctx;

  setUp(() {
    ctx = BuildContext(
      env: _stubEnv(),
      project: _stubProject(),
      artifacts: _stubArtifacts(),
      toolchain: _stubToolchain(),
      mode: WindowsFlavor.release,
      buildRoot: '/home/user/myapp/build/win_cross',
      dartDefines: ['APP_NAME=hello'],
    );
  });

  group('BuildContext 路径计算（release 模式）', () {
    test('modeDir = buildRoot/release', () {
      expect(ctx.modeDir, '/home/user/myapp/build/win_cross/release');
    });

    test('windowsStageDir 在 modeDir/windows_src', () {
      expect(ctx.windowsStageDir, endsWith('/release/windows_src'));
    });

    test('cmakeBuildDir 在 modeDir/cmake_build', () {
      expect(ctx.cmakeBuildDir, endsWith('/release/cmake_build'));
    });

    test('kernelDill 在 intermediates/app.dill', () {
      expect(p.basename(ctx.kernelDill), 'app.dill');
      expect(ctx.kernelDill, contains('/intermediates/'));
    });

    test('appAotElf 在 intermediates/app.so', () {
      expect(p.basename(ctx.appAotElf), 'app.so');
    });

    test('finalExe 使用 appName', () {
      expect(ctx.finalExe, endsWith('/myapp/myapp.exe'));
    });

    test('flutterAssetsDir 在 data/flutter_assets', () {
      expect(ctx.flutterAssetsDir, endsWith('/data/flutter_assets'));
    });
  });

  group('BuildContext 不同模式', () {
    test('debug 模式路径包含 debug', () {
      final debugCtx = BuildContext(
        env: _stubEnv(),
        project: _stubProject(),
        artifacts: _stubArtifacts(),
        toolchain: _stubToolchain(),
        mode: WindowsFlavor.debug,
        buildRoot: '/build',
        dartDefines: [],
      );
      expect(debugCtx.modeDir, '/build/debug');
    });

    test('profile 模式路径包含 profile', () {
      final profileCtx = BuildContext(
        env: _stubEnv(),
        project: _stubProject(),
        artifacts: _stubArtifacts(),
        toolchain: _stubToolchain(),
        mode: WindowsFlavor.profile,
        buildRoot: '/build',
        dartDefines: [],
      );
      expect(profileCtx.modeDir, '/build/profile');
    });
  });
}
