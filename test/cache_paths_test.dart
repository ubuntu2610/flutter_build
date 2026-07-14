// CachePaths 路径解析逻辑测试
//
// 验证优先级：
//   1. 命令行参数 (cacheDirOverride)
//   2. 环境变量 FLUTTER_BUILD_CACHE
//   3. XDG_CACHE_HOME
//   4. $HOME/.flutter_build

import 'dart:io';

import 'package:flutter_build/src/cache_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CachePaths 路径解析', () {
    test('命令行参数覆盖优先级最高', () {
      final paths = CachePaths.resolve(cacheDirOverride: '/override/cache');
      expect(paths.root, '/override/cache');
    });

    test('root 下有 toolchains / engine / downloads', () {
      final paths = CachePaths.resolve(cacheDirOverride: '/tmp/test_cache');
      expect(paths.toolchainsDir, p.join('/tmp/test_cache', 'toolchains'));
      expect(paths.engineDir, p.join('/tmp/test_cache', 'engine'));
      expect(paths.downloadsDir, p.join('/tmp/test_cache', 'downloads'));
    });

    test('ensure() 应创建目录结构', () async {
      final tmp = Directory.systemTemp.createTempSync('cache_test_');
      try {
        final paths = CachePaths.resolve(cacheDirOverride: tmp.path);
        await paths.ensure();
        expect(Directory(paths.toolchainsDir).existsSync(), isTrue);
        expect(Directory(paths.engineDir).existsSync(), isTrue);
        expect(Directory(paths.downloadsDir).existsSync(), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('toolchainRoot 拼接子路径', () {
      final paths = CachePaths.resolve(cacheDirOverride: '/cache');
      expect(
        paths.toolchainRoot('llvm-mingw-20240619'),
        '/cache/toolchains/llvm-mingw-20240619',
      );
    });
  });
}
