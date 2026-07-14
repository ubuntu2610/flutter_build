// WindowsFlavor 枚举行为测试
//
// 验证三种构建模式（debug / profile / release）的属性判定正确：
//   - isAot: debug=false, profile/release=true
//   - isProduct: 仅 release=true
//   - cliName: 字面量匹配

import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsFlavor 枚举', () {
    test('debug 模式 isAot 为 false', () {
      expect(WindowsFlavor.debug.isAot, isFalse);
    });

    test('profile 模式 isAot 为 true', () {
      expect(WindowsFlavor.profile.isAot, isTrue);
    });

    test('release 模式 isAot 为 true', () {
      expect(WindowsFlavor.release.isAot, isTrue);
    });

    test('仅 release 模式 isProduct 为 true', () {
      expect(WindowsFlavor.release.isProduct, isTrue);
      expect(WindowsFlavor.profile.isProduct, isFalse);
      expect(WindowsFlavor.debug.isProduct, isFalse);
    });

    test('cliName 返回小写字符串', () {
      expect(WindowsFlavor.debug.cliName, 'debug');
      expect(WindowsFlavor.profile.cliName, 'profile');
      expect(WindowsFlavor.release.cliName, 'release');
    });
  });
}
