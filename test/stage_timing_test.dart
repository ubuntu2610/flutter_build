// 计时数据与时长格式化单元测试。

import 'package:flutter_build/src/build/stage_timing.dart';
import 'package:test/test.dart';

void main() {
  group('formatDuration', () {
    test('< 1s 用毫秒', () {
      expect(formatDuration(Duration.zero), '0ms');
      expect(formatDuration(const Duration(milliseconds: 999)), '999ms');
    });

    test('1s ~ 60s 用秒（一位小数）', () {
      expect(formatDuration(const Duration(milliseconds: 1000)), '1.0s');
      expect(formatDuration(const Duration(milliseconds: 1500)), '1.5s');
      expect(formatDuration(const Duration(seconds: 30)), '30.0s');
    });

    test('≥ 60s 用 分+秒', () {
      expect(formatDuration(const Duration(milliseconds: 60000)), '1m 0.0s');
      expect(formatDuration(const Duration(milliseconds: 65500)), '1m 5.5s');
      expect(formatDuration(const Duration(minutes: 2, seconds: 30)), '2m 30.0s');
    });
  });

  group('StageTiming', () {
    test('保存 lane / name / elapsed', () {
      final t = StageTiming(
        lane: 'native',
        name: 'configure & build with CMake',
        elapsed: const Duration(milliseconds: 1234),
      );
      expect(t.lane, 'native');
      expect(t.name, 'configure & build with CMake');
      expect(t.elapsed, const Duration(milliseconds: 1234));
    });
  });
}
