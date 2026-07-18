// 远程部署配置解析与远程路径映射测试（纯逻辑，不触网）。

import 'package:flutter_build/src/deploy.dart';
import 'package:flutter_build/src/exceptions.dart';
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
      final c = DeployConfig.parse(
          'host: h\nremote_dir: C:/flutter_build/\n', baseDir: '/repo');
      expect(c.remotePathFor('/repo/a/b'), 'C:/flutter_build/b');
    });
  });
}
