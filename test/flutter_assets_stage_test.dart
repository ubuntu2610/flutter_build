// 资源打包阶段单元测试：验证阶段名，以及 copy_flutter_bundle 参数/环境这两个
// 纯函数的构造（脱离真实 flutter 进程）。

import 'package:flutter_build/src/build/stages/flutter_assets_stage.dart';
import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:test/test.dart';

import 'support/stubs.dart';

void main() {
  test('阶段名符合预期', () {
    expect(FlutterAssetsStage().name, 'bundle Flutter assets');
  });

  group('assembleBundleArgs', () {
    test('面向 windows-x64 / release，输出到 flutter_assets，target 收尾', () {
      final ctx = stubContext(buildRoot: '/b', mode: WindowsFlavor.release);
      final args = assembleBundleArgs(ctx);

      expect(args.first, 'assemble');
      expect(args, contains('-dTargetPlatform=windows-x64'));
      expect(args, contains('-dBuildMode=release'));
      expect(args.last, 'copy_flutter_bundle');

      final output = args.firstWhere((a) => a.startsWith('--output='));
      expect(output, endsWith('flutter_assets'));
    });

    test('debug 模式 build mode 随 flavor 变化', () {
      final ctx = stubContext(buildRoot: '/b', mode: WindowsFlavor.debug);
      expect(assembleBundleArgs(ctx), contains('-dBuildMode=debug'));
    });

    test('treeShakeIcons 透传（默认 true）', () {
      final ctx = stubContext(buildRoot: '/b');
      expect(assembleBundleArgs(ctx), contains('-dTreeShakeIcons=true'));
    });
  });

  group('assembleBundleEnv', () {
    test('置空 PROGRAMFILES(X86) 以绕过 VS 探测', () {
      expect(assembleBundleEnv()['PROGRAMFILES(X86)'], '');
    });

    test('默认不注入 FLUTTER_ALREADY_LOCKED（保守门控无需跳锁）', () {
      expect(
          assembleBundleEnv().containsKey('FLUTTER_ALREADY_LOCKED'), isFalse);
    });

    test('skipProjectLock 时注入 FLUTTER_ALREADY_LOCKED=true', () {
      expect(assembleBundleEnv(skipProjectLock: true)['FLUTTER_ALREADY_LOCKED'],
          'true');
    });
  });
}
