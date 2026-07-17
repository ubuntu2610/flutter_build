import 'dart:io';

import 'package:flutter_build/src/build/build_context.dart';
import 'package:flutter_build/src/build/msvc_flag_translator.dart';
import 'package:flutter_build/src/build/pipeline.dart';
import 'package:flutter_build/src/build/plugin_source_patcher.dart';
import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:flutter_build/src/flutter_env.dart';
import 'package:flutter_build/src/project.dart';
import 'package:flutter_build/src/toolchain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

EngineArtifacts _stubArtifacts() => EngineArtifacts(
      env: _stubEnv(),
      embedderDir: '/sdk/bin/cache/artifacts/engine/windows-x64',
      releaseArtifactsDir:
          '/sdk/bin/cache/artifacts/engine/windows-x64-release',
      profileArtifactsDir:
          '/sdk/bin/cache/artifacts/engine/windows-x64-profile',
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
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flutter_build_symlink_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('copyTreePreservingLinks 保留 .plugin_symlinks 而不展开复制目标目录', () async {
    final pluginRoot = Directory(p.join(tempDir.path, 'libcimbar'))
      ..createSync(recursive: true);
    File(p.join(pluginRoot.path, 'windows', 'CMakeLists.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('add_library(libcimbar_plugin SHARED plugin.cpp)\n');
    File(
      p.join(
        pluginRoot.path,
        'example',
        'build',
        'win_cross',
        'release',
        'windows_src',
        'loop.txt',
      ),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('should stay outside staged tree\n');

    final source = Directory(p.join(tempDir.path, 'windows'))..createSync();
    File(p.join(source.path, 'CMakeLists.txt'))
        .writeAsStringSync('cmake_minimum_required(VERSION 3.14)\n');
    final symlinkDir = Directory(
        p.join(source.path, 'flutter', 'ephemeral', '.plugin_symlinks'))
      ..createSync(recursive: true);
    final relativePluginPath =
        p.relative(pluginRoot.path, from: symlinkDir.path);
    Link(p.join(symlinkDir.path, 'libcimbar')).createSync(relativePluginPath);

    final dest = p.join(tempDir.path, 'windows_src');
    await copyTreePreservingLinks(source.path, dest);

    final copiedLink =
        p.join(dest, 'flutter', 'ephemeral', '.plugin_symlinks', 'libcimbar');
    expect(
      FileSystemEntity.typeSync(copiedLink, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(Link(copiedLink).targetSync(), pluginRoot.path);
    expect(Directory(p.join(copiedLink, 'windows')).existsSync(), isTrue);

    final stagedEntries = Directory(dest)
        .listSync(recursive: true, followLinks: false)
        .map((e) => p.relative(e.path, from: dest))
        .toSet();
    expect(stagedEntries,
        contains('flutter/ephemeral/.plugin_symlinks/libcimbar'));
    expect(
      stagedEntries
          .any((path) => path.contains('.plugin_symlinks/libcimbar/example')),
      isFalse,
    );
  });

  test('MsvcFlagTranslator 不跟随 symlink 改写插件源码', () async {
    final pluginRoot = Directory(p.join(tempDir.path, 'plugin_root'))
      ..createSync(recursive: true);
    final linkedCmake =
        File(p.join(pluginRoot.path, 'windows', 'CMakeLists.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'target_compile_options(plugin PRIVATE /EHsc /W3)\n',
          );

    final stagedRoot = Directory(p.join(tempDir.path, 'windows_src'))
      ..createSync(recursive: true);
    final localCmake = File(p.join(stagedRoot.path, 'CMakeLists.txt'))
      ..writeAsStringSync(
        'target_compile_options(app PRIVATE /EHsc /W3)\n',
      );
    final symlinkDir = Directory(
      p.join(stagedRoot.path, 'flutter', 'ephemeral', '.plugin_symlinks'),
    )..createSync(recursive: true);
    final relativePluginPath =
        p.relative(pluginRoot.path, from: symlinkDir.path);
    Link(p.join(symlinkDir.path, 'plugin')).createSync(relativePluginPath);

    await const MsvcFlagTranslator().transformTree(stagedRoot.path);

    expect(localCmake.readAsStringSync(), isNot(contains('/EHsc')));
    expect(localCmake.readAsStringSync(), contains('-Wall'));
    expect(linkedCmake.readAsStringSync(), contains('/EHsc /W3'));
  });

  test('materializePluginSymlinks 在 ephemeral 下重建插件链接', () async {
    final pluginRoot = Directory(p.join(tempDir.path, 'plugin_root'))
      ..createSync(recursive: true);
    File(p.join(pluginRoot.path, 'windows', 'CMakeLists.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('add_library(plugin SHARED plugin.cpp)\n');

    final project = FlutterProject.forTesting(
      root: p.join(tempDir.path, 'app'),
      appName: 'app',
      entryPoint: p.join(tempDir.path, 'app', 'lib', 'main.dart'),
      windowsDir: p.join(tempDir.path, 'app', 'windows'),
      hasWindowsScaffold: true,
      plugins: [
        WindowsPluginRef(
          name: 'sample_plugin',
          rootPath: pluginRoot.path,
          pluginClass: 'SamplePlugin',
        ),
      ],
    );
    final ctx = BuildContext(
      env: _stubEnv(),
      project: project,
      artifacts: _stubArtifacts(),
      toolchain: _stubToolchain(),
      mode: WindowsFlavor.release,
      buildRoot: p.join(tempDir.path, 'app', 'build', 'win_cross'),
      dartDefines: const [],
    );

    final ephemeralDir = p.join(tempDir.path, 'staged', 'flutter', 'ephemeral');
    await Directory(p.join(ephemeralDir, '.plugin_symlinks')).create(
      recursive: true,
    );
    Link(p.join(ephemeralDir, '.plugin_symlinks', 'stale'))
        .createSync('/tmp/stale-target');

    await materializePluginSymlinks(ctx, ephemeralDir);

    final pluginLink =
        p.join(ephemeralDir, '.plugin_symlinks', 'sample_plugin');
    expect(
      FileSystemEntity.typeSync(pluginLink, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(Link(pluginLink).targetSync(), pluginRoot.path);
    expect(Directory(p.join(pluginLink, 'windows')).existsSync(), isTrue);
    expect(
      FileSystemEntity.typeSync(
        p.join(ephemeralDir, '.plugin_symlinks', 'stale'),
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
  });

  // ── PluginSourcePatcher 纯函数补丁 ──────────────────────────────

  group('patchWindowManagerCpp', () {
    test('移除 #pragma once 并修复 Windows.h 大小写', () {
      const input = '#include "window_manager_plugin.h"\n'
          '// This must be included before many other Windows headers.\n'
          '#pragma once\n'
          '#include <Windows.h>\n';
      final out = patchWindowManagerCpp(input);
      expect(out, isNot(contains('#pragma once')));
      expect(out, contains('#include <windows.h>'));
      expect(out, isNot(contains('Windows.h')));
    });

    test('移除类体内多余 WindowManager:: 限定但保留类外定义', () {
      const input = 'class WindowManager {\n'
          '  void WindowManager::ForceRefresh();\n'
          '  bool WindowManager::IsFocused();\n'
          '};\n'
          'void WindowManager::ForceRefresh() {}\n';
      final out = patchWindowManagerCpp(input);
      expect(out, contains('  void ForceRefresh();'));
      expect(out, contains('  bool IsFocused();'));
      // 类外定义保留限定
      expect(out, contains('void WindowManager::ForceRefresh() {}'));
    });

    test('幂等：重复调用不产生变化', () {
      const input = '#pragma once\n#include <Windows.h>\n'
          '  void WindowManager::Foo();\n';
      final once = patchWindowManagerCpp(input);
      final twice = patchWindowManagerCpp(once);
      expect(twice, once);
    });
  });

  group('patchHotkeyManagerPluginCpp', () {
    test('EncodableMap 初始化显式包装 EncodableValue', () {
      const input = 'args["data"] =\n'
          '    flutter::EncodableMap({{"identifier", identifier}});\n';
      final out = patchHotkeyManagerPluginCpp(input);
      expect(out,
          contains('flutter::EncodableValue("identifier")'));
      expect(out, contains('flutter::EncodableValue(identifier)'));
      expect(out,
          isNot(contains('EncodableMap({{"identifier", identifier}})')));
    });

    test('幂等', () {
      const input = 'flutter::EncodableMap({{"identifier", identifier}})';
      expect(patchHotkeyManagerPluginCpp(patchHotkeyManagerPluginCpp(input)),
          patchHotkeyManagerPluginCpp(input));
    });
  });

  group('patchScreenRetrieverPluginH', () {
    test('移除成员声明上的多余类名限定', () {
      const input = '  void ScreenRetrieverWindowsPlugin::GetCursorScreenPoint(\n'
          '  void ScreenRetrieverWindowsPlugin::GetPrimaryDisplay(\n'
          '  void ScreenRetrieverWindowsPlugin::GetAllDisplays(\n';
      final out = patchScreenRetrieverPluginH(input);
      expect(out, isNot(contains('ScreenRetrieverWindowsPlugin::')));
      expect(out, contains('void GetCursorScreenPoint('));
      expect(out, contains('void GetPrimaryDisplay('));
      expect(out, contains('void GetAllDisplays('));
    });

    test('幂等', () {
      const input = 'void ScreenRetrieverWindowsPlugin::GetAllDisplays(';
      expect(patchScreenRetrieverPluginH(patchScreenRetrieverPluginH(input)),
          patchScreenRetrieverPluginH(input));
    });
  });

  group('addNoDeprecatedDeclarations', () {
    test('在 apply_standard_settings 后追加 -Wno-deprecated-declarations', () {
      const input = 'apply_standard_settings(\${PLUGIN_NAME})\n'
          'set_target_properties(\${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)\n';
      final out = addNoDeprecatedDeclarations(input);
      expect(out, contains('-Wno-deprecated-declarations'));
      expect(out.indexOf('-Wno-deprecated-declarations'),
          greaterThan(out.indexOf('apply_standard_settings')));
    });

    test('幂等：不重复追加', () {
      const input = 'apply_standard_settings(\${PLUGIN_NAME})\n'
          'target_compile_options(\${PLUGIN_NAME} PRIVATE -Wno-deprecated-declarations)\n';
      expect(addNoDeprecatedDeclarations(input), input);
    });

    test('无 apply_standard_settings 时原样返回', () {
      const input = 'add_library(foo SHARED foo.cpp)\n';
      expect(addNoDeprecatedDeclarations(input), input);
    });
  });

  // ── PluginSourcePatcher 集成 ────────────────────────────────────

  test('PluginSourcePatcher 物化符号链接并应用补丁，不修改原件', () async {
    // 创建模拟的 window_manager 插件源码
    final pluginRoot =
        Directory(p.join(tempDir.path, 'window_manager'))..createSync();
    final pluginWindows = Directory(p.join(pluginRoot.path, 'windows'))
      ..createSync();
    File(p.join(pluginWindows.path, 'window_manager.cpp'))
        .writeAsStringSync('#pragma once\n#include <Windows.h>\n'
            'class WindowManager {\n'
            '  void WindowManager::Foo();\n'
            '};\n');
    File(p.join(pluginWindows.path, 'CMakeLists.txt'))
        .writeAsStringSync('apply_standard_settings(\${PLUGIN_NAME})\n');

    // 在 ephemeral/.plugin_symlinks 下创建符号链接
    final ephemeralDir = p.join(tempDir.path, 'ephemeral');
    final symlinkDir =
        Directory(p.join(ephemeralDir, '.plugin_symlinks'))
          ..createSync(recursive: true);
    Link(p.join(symlinkDir.path, 'window_manager'))
        .createSync(pluginRoot.path);

    await const PluginSourcePatcher().apply(ephemeralDir);

    // 符号链接应被替换为真实目录
    final pluginPath = p.join(symlinkDir.path, 'window_manager');
    expect(
      FileSystemEntity.typeSync(pluginPath, followLinks: false),
      FileSystemEntityType.directory,
    );

    // 补丁已应用到副本
    final cpp = File(p.join(pluginPath, 'windows', 'window_manager.cpp'))
        .readAsStringSync();
    expect(cpp, isNot(contains('#pragma once')));
    expect(cpp, contains('#include <windows.h>'));
    expect(cpp, contains('  void Foo();'));

    final cmake = File(p.join(pluginPath, 'windows', 'CMakeLists.txt'))
        .readAsStringSync();
    expect(cmake, contains('-Wno-deprecated-declarations'));

    // pub-cache 原件未被修改
    final original =
        File(p.join(pluginRoot.path, 'windows', 'window_manager.cpp'))
            .readAsStringSync();
    expect(original, contains('#pragma once'));
    expect(original, contains('#include <Windows.h>'));
    expect(original, contains('void WindowManager::Foo();'));
  });
}
