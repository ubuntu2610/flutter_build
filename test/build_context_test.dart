// BuildContext 路径派生逻辑测试
//
// 验证所有自动计算的目录/文件路径是否遵守预期的目录结构约定：
//   buildRoot/<mode>/
//     ├── windows_src/          (staged CMake source)
//     ├── cmake_build/          (CMake outputs)
//     ├── intermediates/        (kernel dill + aot elf)
//     └── <app_name>/           (final packaged output)
//           ├── <app>.exe
//           └── data/
//                 └── flutter_assets/

import 'package:flutter_build/src/build/build_context.dart';
import 'package:flutter_build/src/engine_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/stubs.dart';

void main() {
  late BuildContext ctx;

  setUp(() {
    ctx = stubContext(
      mode: WindowsFlavor.release,
      buildRoot: '/home/user/myapp/build/win_cross',
      dartDefines: ['APP_NAME=hello'],
    );
  });

  group('BuildContext 路径计算（release 模式）', () {
    test('modeDir = buildRoot/release', () {
      expect(ctx.modeDir, '/home/user/myapp/build/win_cross/release');
    });

    test('windowsStageDir 在 modeDir/windows_src', () {
      expect(ctx.windowsStageDir, endsWith('/release/windows_src'));
    });

    test('cmakeBuildDir 在 modeDir/cmake_build', () {
      expect(ctx.cmakeBuildDir, endsWith('/release/cmake_build'));
    });

    test('kernelDill 在 intermediates/app.dill', () {
      expect(p.basename(ctx.kernelDill), 'app.dill');
      expect(ctx.kernelDill, contains('/intermediates/'));
    });

    test('appAotElf 在 intermediates/app.so', () {
      expect(p.basename(ctx.appAotElf), 'app.so');
    });

    test('finalExe 使用 appName', () {
      expect(ctx.finalExe, endsWith('/myapp/myapp.exe'));
    });

    test('outputDir 为 finalExe 所在目录', () {
      expect(ctx.outputDir, endsWith('/myapp'));
      expect(ctx.outputDir, p.dirname(ctx.finalExe));
    });

    test('dataDir 在 outputDir/data', () {
      expect(ctx.dataDir, endsWith('/myapp/data'));
    });

    test('flutterAssetsDir 在 data/flutter_assets', () {
      expect(ctx.flutterAssetsDir, endsWith('/data/flutter_assets'));
    });

    test('mingwCompatDir 在 intermediates/mingw_compat', () {
      expect(ctx.mingwCompatDir, endsWith('/intermediates/mingw_compat'));
    });
  });

  group('BuildContext 不同模式', () {
    test('debug 模式路径包含 debug', () {
      final debugCtx = stubContext(mode: WindowsFlavor.debug, buildRoot: '/build');
      expect(debugCtx.modeDir, '/build/debug');
    });

    test('profile 模式路径包含 profile', () {
      final profileCtx =
          stubContext(mode: WindowsFlavor.profile, buildRoot: '/build');
      expect(profileCtx.modeDir, '/build/profile');
    });
  });

  group('BuildContext 默认开关', () {
    test('incremental 默认开启', () {
      expect(ctx.incremental, isTrue);
    });

    test('dllSearchRoot 默认为 null（使用祖父目录）', () {
      expect(ctx.dllSearchRoot, isNull);
    });
  });
}
