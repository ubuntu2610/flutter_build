// Wine 包装脚本生成单元测试
//
// 验证 wine_wrapper.dart 生成的 bash 脚本内容是否正确：
//   1. shebang 行正确
//   2. 包含正确的 WINEPREFIX 路径
//   3. 包含 exec 语句调用正确的 wine 路径
//   4. 可多次调用（幂等性）

import 'dart:io';

import 'package:flutter_build/src/build/wine_wrapper.dart';
import 'package:flutter_build/src/toolchain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('wine_wrapper_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  /// 构造一个假的 Toolchain 用于测试脚本生成。
  Toolchain fakeToolchain({String wine = '/usr/bin/wine64'}) => Toolchain(
        llvmMingwRoot: '/opt/llvm-mingw',
        targetTriple: 'x86_64-w64-mingw32',
        wineExecutable: wine,
        cmakeExecutable: '/usr/bin/cmake',
        ninjaExecutable: '/usr/bin/ninja',
      );

  group('WineWrapper 脚本生成', () {
    test('生成的脚本包含正确的 shebang', () async {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(),
        buildRoot: tmpDir.path,
      );
      await wrapper.materialize();
      final content = File(wrapper.scriptPath).readAsStringSync();
      expect(content, startsWith('#!/usr/bin/env bash'));
    });

    test('脚本中包含 wine 可执行文件路径', () async {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(wine: '/custom/wine64'),
        buildRoot: tmpDir.path,
      );
      await wrapper.materialize();
      final content = File(wrapper.scriptPath).readAsStringSync();
      expect(content, contains('/custom/wine64'));
    });

    test('脚本中设置 WINEPREFIX 为 buildRoot 下', () async {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(),
        buildRoot: tmpDir.path,
      );
      await wrapper.materialize();
      final content = File(wrapper.scriptPath).readAsStringSync();
      expect(content, contains(p.join(tmpDir.path, '.wineprefix')));
    });

    test('脚本标记为可执行 (+x)', () async {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(),
        buildRoot: tmpDir.path,
      );
      await wrapper.materialize();
      final stat = FileStat.statSync(wrapper.scriptPath);
      // 检查 owner 可执行位
      expect(stat.mode & 0x40, isNonZero);
    });

    test('重复调用 materialize 不报错（幂等）', () async {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(),
        buildRoot: tmpDir.path,
      );
      await wrapper.materialize();
      await wrapper.materialize(); // 第二次
      final content = File(wrapper.scriptPath).readAsStringSync();
      expect(content, contains('exec'));
    });

    test('使用 exec 避免多余 bash 进程', () async {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(),
        buildRoot: tmpDir.path,
      );
      await wrapper.materialize();
      final content = File(wrapper.scriptPath).readAsStringSync();
      expect(content, contains('exec'));
    });
  });

  group('WineWrapper.environment()', () {
    test('返回 WINEDEBUG=-all', () {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(),
        buildRoot: tmpDir.path,
      );
      final env = wrapper.environment();
      expect(env['WINEDEBUG'], '-all');
    });

    test('WINEPREFIX 指向 buildRoot', () {
      final wrapper = WineWrapper(
        toolchain: fakeToolchain(),
        buildRoot: tmpDir.path,
      );
      final env = wrapper.environment();
      expect(env['WINEPREFIX'], contains(tmpDir.path));
    });
  });
}
