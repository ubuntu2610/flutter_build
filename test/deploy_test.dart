// 远程部署配置解析、远程路径映射与增量部署清单/差分测试（纯逻辑，不触网）。

import 'dart:io';

import 'package:flutter_build/src/deploy.dart';
import 'package:flutter_build/src/exceptions.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DeployConfig.parse', () {
    test('解析完整字段', () {
      final c = DeployConfig.parse('''
host: 100.65.70.35
username: ubuntu
password: xx1314520
port: 2222
auto_copy: true
remote_dir: C:/project/flutter_build
''', baseDir: '/repo');
      expect(c.host, '100.65.70.35');
      expect(c.username, 'ubuntu');
      expect(c.password, 'xx1314520');
      expect(c.port, 2222);
      expect(c.autoCopy, isTrue);
      expect(c.remoteDir, 'C:/project/flutter_build');
    });

    test('ip 作为 host 的别名', () {
      final c = DeployConfig.parse('ip: 10.0.0.1\nremote_dir: C:/x\n',
          baseDir: '/repo');
      expect(c.host, '10.0.0.1');
      expect(c.username, 'ubuntu'); // 默认
      expect(c.autoCopy, isFalse); // 默认
      expect(c.port, 22); // 默认
    });

    test('反斜杠 remote_dir 归一化为正斜杠', () {
      final c = DeployConfig.parse(
          r'host: h' '\n' r'remote_dir: C:\project\flutter_build' '\n',
          baseDir: '/repo');
      expect(c.remoteDir, 'C:/project/flutter_build');
    });

    test('空密码 → null（改用密钥）', () {
      final c = DeployConfig.parse('host: h\npassword: ""\nremote_dir: C:/x\n',
          baseDir: '/repo');
      expect(c.password, isNull);
    });

    test('缺 host / remote_dir 抛错', () {
      expect(() => DeployConfig.parse('remote_dir: C:/x\n', baseDir: '/r'),
          throwsA(isA<ToolException>()));
      expect(() => DeployConfig.parse('host: h\n', baseDir: '/r'),
          throwsA(isA<ToolException>()));
    });
  });

  group('DeployConfig.remotePathFor', () {
    DeployConfig cfg() => DeployConfig.parse(
          'host: h\nremote_dir: C:/flutter_build\n',
          baseDir: '/repo',
        );

    test('扁平结构：remote_dir/basename', () {
      final c = cfg();
      expect(
        c.remotePathFor('/repo/example/build/win_cross/release/hello'),
        'C:/flutter_build/hello',
      );
    });

    test('app 名作为远程目录名', () {
      expect(
        cfg().remotePathFor('/any/path/flutter_build_example'),
        'C:/flutter_build/flutter_build_example',
      );
    });

    test('remote_dir 末尾多余斜杠不影响结果', () {
      final c = DeployConfig.parse('host: h\nremote_dir: C:/flutter_build/\n',
          baseDir: '/repo');
      expect(c.remotePathFor('/repo/a/b'), 'C:/flutter_build/b');
    });

    test('incremental_deploy 默认开启，false 可关闭', () {
      expect(
          DeployConfig.parse('host: h\nremote_dir: C:/x\n', baseDir: '/r')
              .incrementalDeploy,
          isTrue);
      expect(
          DeployConfig.parse(
                  'host: h\nremote_dir: C:/x\nincremental_deploy: false\n',
                  baseDir: '/r')
              .incrementalDeploy,
          isFalse);
    });
  });

  group('deploy manifest · 扫描与差分', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fb_deploy_test_');
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });

    File put(String rel, String content) {
      final f = File(p.join(root.path, rel));
      f.parent.createSync(recursive: true);
      return f..writeAsStringSync(content);
    }

    test('扫描生成相对 POSIX 路径与指纹', () {
      put('a.dll', 'A' * 100);
      put('data/app.so', 'B' * 10);
      final m = scanDeployManifest(root);
      expect(m.keys.toList(), containsAll(<String>['a.dll', 'data/app.so']));
      expect(m['a.dll']!.size, 100);
      expect(m['data/app.so']!.size, 10);
      expect(m['a.dll']!.mtimeMicros, greaterThan(0));
    });

    test('size/mtime 未变 → 不算变化，且沿用历史哈希', () {
      put('a.dll', 'AAA');
      final first = scanDeployManifest(root);
      first['a.dll']!.sha256 = hashDeployFile(p.join(root.path, 'a.dll'));

      final diff = diffDeployManifests(root, first);
      expect(diff.changed, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.current['a.dll']!.sha256, first['a.dll']!.sha256);
    });

    test('内容变了 → 上传；mtime 假变化但内容同 → 免传输', () {
      final f = put('data/app.so', 'v1');
      final first = scanDeployManifest(root);
      first['data/app.so']!.sha256 = hashDeployFile(f.path);

      // mtime 变、内容同：免传输。
      File(f.path).writeAsStringSync('v1', mode: FileMode.append);
      f.writeAsStringSync('v1');
      final same = diffDeployManifests(root, first);
      expect(same.changed, isEmpty);

      // 内容真的变了：上传。（显式推后 mtime，避免同一时钟 tick 内
      // size 相同 + mtime 相同被误判为未变。）
      f.writeAsStringSync('v2');
      f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
      final diff = diffDeployManifests(root, first);
      expect(diff.changed, <String>['data/app.so']);
      expect(diff.removed, isEmpty);
    });

    test('新增与删除文件分别归入 changed / removed', () {
      put('keep.dll', 'K');
      put('old.dll', 'OLD');
      final prev = scanDeployManifest(root);
      prev['keep.dll']!.sha256 = hashDeployFile(p.join(root.path, 'keep.dll'));
      prev['old.dll']!.sha256 = hashDeployFile(p.join(root.path, 'old.dll'));

      File(p.join(root.path, 'old.dll')).deleteSync();
      put('new/data.bin', 'NEW');

      final diff = diffDeployManifests(root, prev);
      expect(diff.changed, <String>['new/data.bin']);
      expect(diff.removed, <String>['old.dll']);
    });

    test('清单写读回环（路径排序、损坏时返回 null）', () {
      put('z.dll', 'Z');
      put('a/b.so', 'B');
      final m = scanDeployManifest(root);
      m['z.dll']!.sha256 = 'deadbeef';

      saveDeployManifest(root.path, m);
      final loaded = loadDeployManifest(root.path)!;
      expect(loaded.keys.toList(), <String>['a/b.so', 'z.dll']);
      expect(loaded['z.dll']!.sha256, 'deadbeef');
      expect(loaded['a/b.so']!.sha256, isNull);

      // 清单路径在 bundle 目录同级、以 app 名命名，不在产物目录内。
      final manifestFile = File(deployManifestPathFor(root.path));
      expect(manifestFile.parent.path, root.parent.path);
      expect(p.basename(manifestFile.path),
          '.${p.basename(root.path)}.deploy_manifest.json');

      manifestFile.writeAsStringSync('not json');
      expect(loadDeployManifest(root.path), isNull);
    });
  });

  group('RemoteReconcile.compute · 远端指纹对账', () {
    final h1 = 'aa' * 32;
    final h2 = 'bb' * 32;

    test('缺文件、旧文件、无用文件、一致文件各归其类', () {
      final rec = RemoteReconcile.compute(
        {
          'same.dll': h1,
          'stale.dll': h1,
          'new/data/app.so': h2,
        },
        {
          'same.dll': h1, // 一致 → 跳过
          'stale.dll': h2, // hash 不同 → 过期（覆盖上传）
          'junk/leftover.txt': h2, // 本地没有 → 删除
          // 'new/data/app.so' 远端没有 → 缺失（上传）
        },
      );
      expect(rec.same, <String>['same.dll']);
      expect(rec.expired, <String>['stale.dll']);
      expect(rec.missing, <String>['new/data/app.so']);
      expect(rec.remove, <String>['junk/leftover.txt']);
      expect(rec.upload, containsAllInOrder(<String>['new/data/app.so', 'stale.dll']));
      expect(rec.needsTransfer, isTrue);
    });

    test('两端完全一致 → 无需传输；远端为空 → 全部缺失', () {
      final all = RemoteReconcile.compute({'a.dll': h1}, {'a.dll': h1});
      expect(all.needsTransfer, isFalse);

      final none = RemoteReconcile.compute({'a.dll': h1, 'b/c.so': h2}, {});
      expect(none.missing, unorderedEquals(<String>['a.dll', 'b/c.so']));
      expect(none.remove, isEmpty);
      expect(none.upload.length, 2);
    });
  });

  group('balanceUploadGroups · 并行上传分组', () {
    int sizeOf(String rel) => rel.hashCode & 0xff + 1;

    test('同一顶层条目的文件不跨组（避免并发 mkdir 竞争）', () {
      final files = <String>[
        'data/app.so',
        'data/icudtl.dat',
        'data/flutter_assets/one.bin',
        'libcimbar.dll',
        'app.exe',
      ];
      final groups = balanceUploadGroups(files, sizeOf, 4);
      String topOf(String rel) =>
          rel.contains('/') ? rel.split('/').first : rel;
      // 两两比较：不同组之间的顶层条目集合必须互不相交。
      for (var i = 0; i < groups.length; i++) {
        for (var j = i + 1; j < groups.length; j++) {
          final topsI = groups[i].map(topOf).toSet();
          final topsJ = groups[j].map(topOf).toSet();
          expect(topsI.intersection(topsJ), isEmpty,
              reason: '组 $i 与组 $j 共享顶层条目: $topsI.intersection($topsJ)');
        }
      }
      // 所有文件都在且只在一个组里。
      final all = groups.expand((g) => g).toList()..sort();
      expect(all, files.toList()..sort());
    });

    test('组数不超过上限，顶层条目少于上限时不产生空组', () {
      final groups = balanceUploadGroups(
          <String>['a.dll', 'data/x.so'], sizeOf, 4);
      final nonEmpty = groups.where((g) => g.isNotEmpty).toList();
      expect(nonEmpty.length, lessThanOrEqualTo(2));
      expect(nonEmpty.expand((g) => g).length, 2);
    });

    test('按字节贪心均衡：大条目分摊到不同组', () {
      final groups = balanceUploadGroups(
        <String>['big1.bin', 'big2.bin', 'small/a.bin', 'small/b.bin'],
        (rel) => rel.startsWith('big') ? 1000 : 10,
        2,
      );
      final big1 = groups.indexWhere((g) => g.contains('big1.bin'));
      final big2 = groups.indexWhere((g) => g.contains('big2.bin'));
      expect(big1, isNot(equals(big2))); // 两个大文件分到不同组
    });
  });
}
