// 测试共享桩：集中提供 env / project / artifacts / toolchain / BuildContext 的
// 最小可用实例，避免各测试文件重复定义相同的工厂。
//
// 这些桩不落盘、不探测磁盘，仅用于纯逻辑（路径派生、枚举、阶段判定等）测试。

import 'package:flutter_build/src/build/build_context.dart';
import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:flutter_build/src/flutter_env.dart';
import 'package:flutter_build/src/project.dart';
import 'package:flutter_build/src/toolchain.dart';

/// 最小 [FlutterEnv] 桩（linux-x64 AOT frontend_server 布局）。
FlutterEnv stubEnv() => FlutterEnv.forTesting(
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

/// 最小 [FlutterProject] 桩，字段可按需覆盖。
FlutterProject stubProject({
  String root = '/home/user/myapp',
  String appName = 'myapp',
  String? entryPoint,
  String? windowsDir,
  bool hasWindowsScaffold = true,
  List<WindowsPluginRef> plugins = const <WindowsPluginRef>[],
}) =>
    FlutterProject.forTesting(
      root: root,
      appName: appName,
      entryPoint: entryPoint ?? '$root/lib/main.dart',
      windowsDir: windowsDir ?? '$root/windows',
      hasWindowsScaffold: hasWindowsScaffold,
      plugins: plugins,
    );

/// 最小 [EngineArtifacts] 桩。
EngineArtifacts stubArtifacts() => EngineArtifacts(
      env: stubEnv(),
      embedderDir: '/sdk/bin/cache/artifacts/engine/windows-x64',
      releaseArtifactsDir:
          '/sdk/bin/cache/artifacts/engine/windows-x64-release',
      profileArtifactsDir:
          '/sdk/bin/cache/artifacts/engine/windows-x64-profile',
      hostEngineDir: '/sdk/bin/cache/artifacts/engine/linux-x64',
    );

/// 最小 [Toolchain] 桩。
Toolchain stubToolchain() => Toolchain(
      llvmMingwRoot: '/opt/llvm-mingw',
      targetTriple: 'x86_64-w64-mingw32',
      wineExecutable: '/usr/bin/wine64',
      cmakeExecutable: '/usr/bin/cmake',
      ninjaExecutable: '/usr/bin/ninja',
    );

/// 组合以上桩构造 [BuildContext]，用于路径派生 / 阶段判定等纯逻辑测试。
BuildContext stubContext({
  required String buildRoot,
  WindowsFlavor mode = WindowsFlavor.release,
  FlutterProject? project,
  List<String> dartDefines = const <String>[],
}) =>
    BuildContext(
      env: stubEnv(),
      project: project ?? stubProject(),
      artifacts: stubArtifacts(),
      toolchain: stubToolchain(),
      mode: mode,
      buildRoot: buildRoot,
      dartDefines: dartDefines,
    );
