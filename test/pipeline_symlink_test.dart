import 'dart:io';

import 'package:flutter_build/src/build/build_context.dart';
import 'package:flutter_build/src/build/msvc_flag_translator.dart';
import 'package:flutter_build/src/build/pipeline.dart';
import 'package:flutter_build/src/build/plugin_source_patcher.dart';
import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:flutter_build/src/project.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/stubs.dart';

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

    final project = stubProject(
      root: p.join(tempDir.path, 'app'),
      appName: 'app',
      plugins: [
        WindowsPluginRef(
          name: 'sample_plugin',
          rootPath: pluginRoot.path,
          pluginClass: 'SamplePlugin',
        ),
      ],
    );
    final ctx = BuildContext(
      env: stubEnv(),
      project: project,
      artifacts: stubArtifacts(),
      toolchain: stubToolchain(),
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

  // ── PluginSourcePatcher（仅 EncodableMap 补丁）──────────────────

  group('patchHotkeyManagerPluginCpp', () {
    test('EncodableMap 初始化显式包装 EncodableValue', () {
      const input = 'args["data"] =\n'
          '    flutter::EncodableMap({{"identifier", identifier}});\n';
      final out = patchHotkeyManagerPluginCpp(input);
      expect(out, contains('flutter::EncodableValue("identifier")'));
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
}
