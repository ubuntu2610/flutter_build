// 共享文件系统工具测试：并行目录复制的正确性、链接保留、单文件复制、目录体积。

import 'dart:io';

import 'package:flutter_build/src/io/fs_utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fs_utils_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('copyTree', () {
    test('并发复制嵌套目录下所有文件且内容一致', () async {
      final src = Directory(p.join(tmp.path, 'src'))..createSync();
      // 造足够多的文件以覆盖并发池（> 默认并发度）。
      for (var i = 0; i < 50; i++) {
        File(p.join(src.path, 'sub$i', 'file$i.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('content-$i');
      }
      final dst = p.join(tmp.path, 'dst');

      await copyTree(src.path, dst);

      for (var i = 0; i < 50; i++) {
        final f = File(p.join(dst, 'sub$i', 'file$i.txt'));
        expect(f.existsSync(), isTrue, reason: 'file$i 应被复制');
        expect(f.readAsStringSync(), 'content-$i');
      }
    });

    test('源不存在时静默返回，不创建目标', () async {
      final dst = p.join(tmp.path, 'dst');
      await copyTree(p.join(tmp.path, 'nope'), dst);
      expect(Directory(dst).existsSync(), isFalse);
    });

    test('空目录也会被创建', () async {
      final src = Directory(p.join(tmp.path, 'empty'))..createSync();
      final dst = p.join(tmp.path, 'dst_empty');
      await copyTree(src.path, dst);
      expect(Directory(dst).existsSync(), isTrue);
    });

    test('保留符号链接（改写为真实绝对目标）', () async {
      final target = Directory(p.join(tmp.path, 'target'))..createSync();
      File(p.join(target.path, 'a.txt')).writeAsStringSync('hi');

      final src = Directory(p.join(tmp.path, 'src'))..createSync();
      // 相对链接指向 target。
      Link(p.join(src.path, 'link'))
          .createSync(p.relative(target.path, from: src.path));

      final dst = p.join(tmp.path, 'dst');
      await copyTree(src.path, dst);

      final copied = p.join(dst, 'link');
      expect(
        FileSystemEntity.typeSync(copied, followLinks: false),
        FileSystemEntityType.link,
      );
      // 改写为真实绝对目标，避免相对链接搬家后变坏链。
      expect(Link(copied).targetSync(), target.path);
    });
  });

  group('copyFileIfExists', () {
    test('源存在则复制并按需建父目录', () async {
      final src = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('data');
      final dst = p.join(tmp.path, 'nested', 'b.txt');
      await copyFileIfExists(src.path, dst);
      expect(File(dst).readAsStringSync(), 'data');
    });

    test('源不存在则静默跳过', () async {
      final dst = p.join(tmp.path, 'out.txt');
      await copyFileIfExists(p.join(tmp.path, 'missing.txt'), dst);
      expect(File(dst).existsSync(), isFalse);
    });
  });

  group('dirSize', () {
    test('累加所有普通文件字节', () {
      final d = Directory(p.join(tmp.path, 'd'))..createSync();
      File(p.join(d.path, 'a')).writeAsBytesSync(List.filled(10, 0));
      File(p.join(d.path, 'sub', 'b'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(5, 0));
      expect(dirSize(d), 15);
    });
  });
}
