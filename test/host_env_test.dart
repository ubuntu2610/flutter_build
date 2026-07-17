// 宿主环境净化逻辑测试
//
// 验证 sanitizedCrossBuildEnv 会剥离会污染交叉编译的宿主构建标志
// （CFLAGS/CXXFLAGS/LDFLAGS 等），同时保留无关变量并正确应用 overrides。

import 'package:flutter_build/src/build/host_env.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizedCrossBuildEnv', () {
    test('剥离 snap 注入的编译/链接标志变量', () {
      final base = {
        'CXXFLAGS': '-B/snap/flutter/current/usr/lib -lepoxy',
        'LDFLAGS': '-L/snap/flutter/current/usr/lib -lfontconfig',
        'CFLAGS': '-B/snap/...',
        'CPPFLAGS': '-I/snap/...',
        'LIBRARY_PATH': '/snap/flutter/current/usr/lib',
        'PKG_CONFIG_PATH': '/snap/flutter/current/usr/lib/pkgconfig',
        'PATH': '/usr/bin:/bin',
        'HOME': '/home/user',
      };
      final result = sanitizedCrossBuildEnv(base);

      // 污染变量被移除。
      for (final key in kHostBuildFlagVars) {
        expect(result.containsKey(key), isFalse, reason: '$key 应被剥离');
      }
      // 无关变量保留。
      expect(result['PATH'], '/usr/bin:/bin');
      expect(result['HOME'], '/home/user');
    });

    test('LD_LIBRARY_PATH 等运行时变量不被剥离', () {
      final base = {
        'LD_LIBRARY_PATH': '/snap/flutter/current/usr/lib',
        'CXXFLAGS': '-lepoxy',
      };
      final result = sanitizedCrossBuildEnv(base);
      // snap 的 cmake/ninja 依赖 LD_LIBRARY_PATH 才能运行，必须保留。
      expect(result['LD_LIBRARY_PATH'], '/snap/flutter/current/usr/lib');
      expect(result.containsKey('CXXFLAGS'), isFalse);
    });

    test('overrides 在剥离之后应用，可覆盖保留变量', () {
      final base = {'CXXFLAGS': '-lepoxy', 'WINEPREFIX': '/old'};
      final result = sanitizedCrossBuildEnv(
        base,
        overrides: {'WINEPREFIX': '/new', 'WINEDEBUG': '-all'},
      );
      expect(result['WINEPREFIX'], '/new');
      expect(result['WINEDEBUG'], '-all');
      expect(result.containsKey('CXXFLAGS'), isFalse);
    });

    test('不修改传入的 base map', () {
      final base = {'CXXFLAGS': '-lepoxy', 'PATH': '/bin'};
      sanitizedCrossBuildEnv(base, overrides: {'X': '1'});
      expect(base, {'CXXFLAGS': '-lepoxy', 'PATH': '/bin'});
    });
  });
}
