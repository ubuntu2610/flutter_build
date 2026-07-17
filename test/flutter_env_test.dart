// FlutterEnv 运行时选择逻辑测试
//
// 重点验证 frontend_server 快照与运行时的匹配：
//   - 现代 `frontend_server_aot.dart.snapshot` 是 AOT 快照，必须用
//     `dartaotruntime` 运行（否则 exit 255）。
//   - 旧版 `frontend_server.dart.snapshot` 用普通 `dart` 运行。

import 'package:flutter_build/src/flutter_env.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _dartExe = '/sdk/bin/cache/dart-sdk/bin/dart';
const _engineDir = '/sdk/bin/cache/artifacts/engine/linux-x64';

FlutterEnv _envWithSnapshot(String snapshot) => FlutterEnv.forTesting(
      sdkRoot: '/sdk',
      flutterVersion: '3.22.0',
      dartSdkVersion: '3.5.0',
      engineCommitHash: 'abc123',
      engineRealm: '',
      storageBaseUrl: 'https://storage.googleapis.com',
      dartExecutable: _dartExe,
      frontendServerSnapshot: snapshot,
      hostEngineDir: _engineDir,
    );

void main() {
  group('FlutterEnv frontend_server 运行时选择', () {
    test('AOT 快照 → dartaotruntime', () {
      final env = _envWithSnapshot(
        p.join(_engineDir, 'frontend_server_aot.dart.snapshot'),
      );
      expect(env.frontendServerIsAot, isTrue);
      expect(env.dartAotRuntimeExecutable,
          '/sdk/bin/cache/dart-sdk/bin/dartaotruntime');
      expect(env.frontendServerRuntime, env.dartAotRuntimeExecutable);
      // 关键回归：绝不能用 dart 去跑 AOT 快照。
      expect(env.frontendServerRuntime, isNot(env.dartExecutable));
    });

    test('旧版快照 → dart', () {
      final env = _envWithSnapshot(
        p.join(_engineDir, 'frontend_server.dart.snapshot'),
      );
      expect(env.frontendServerIsAot, isFalse);
      expect(env.frontendServerRuntime, env.dartExecutable);
    });

    test('dartaotruntime 与 dart 位于同一 bin 目录', () {
      final env = _envWithSnapshot(
        p.join(_engineDir, 'frontend_server_aot.dart.snapshot'),
      );
      expect(p.dirname(env.dartAotRuntimeExecutable),
          p.dirname(env.dartExecutable));
    });
  });
}
