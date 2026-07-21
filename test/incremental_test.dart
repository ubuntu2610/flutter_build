// 增量构建判定逻辑测试（depfile 解析、输入指纹、新鲜度判断）。

import 'dart:io';

import 'package:flutter_build/src/build/incremental.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('parseDepfileInputs', () {
    test('解析基础 depfile（单行）', () {
      const content = '/out/app.dill: /a/main.dart /a/util.dart';
      expect(parseDepfileInputs(content),
          ['/a/main.dart', '/a/util.dart']);
    });

    test('处理行续接（反斜杠 + 换行）', () {
      const content = '/out/app.dill: \\\n  /a/main.dart \\\n  /a/util.dart\n';
      expect(parseDepfileInputs(content),
          ['/a/main.dart', '/a/util.dart']);
    });

    test('还原转义空格', () {
      const content = r'/out/app.dill: /a/my\ file.dart';
      expect(parseDepfileInputs(content), ['/a/my file.dart']);
    });

    test('无冒号时返回空', () {
      expect(parseDepfileInputs('no colon here'), isEmpty);
    });
  });

  group('hashInputs', () {
    test('相同输入得到相同指纹', () {
      expect(hashInputs(['a', 'b']), hashInputs(['a', 'b']));
    });

    test('顺序不同指纹不同', () {
      expect(hashInputs(['a', 'b']), isNot(hashInputs(['b', 'a'])));
    });

    test('分隔安全：[ab] 与 [a,b] 不冲突', () {
      expect(hashInputs(['ab']), isNot(hashInputs(['a', 'b'])));
    });
  });

  group('isUpToDate', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('incr_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File write(String name, String content) =>
        File(p.join(tmp.path, name))..writeAsStringSync(content);

    test('产物不存在 → 需要重编', () {
      expect(
        isUpToDate(
            outputPath: p.join(tmp.path, 'missing.out'), inputPaths: const []),
        isFalse,
      );
    });

    test('产物比所有输入新 → 最新', () {
      final input = write('in.dart', 'x');
      final output = write('out.dill', 'y');
      final past = DateTime.now().subtract(const Duration(hours: 1));
      input.setLastModifiedSync(past);
      output.setLastModifiedSync(DateTime.now());
      expect(
        isUpToDate(outputPath: output.path, inputPaths: [input.path]),
        isTrue,
      );
    });

    test('输入比产物新 → 需要重编', () {
      final output = write('out.dill', 'y');
      final input = write('in.dart', 'x');
      output.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)));
      input.setLastModifiedSync(DateTime.now());
      expect(
        isUpToDate(outputPath: output.path, inputPaths: [input.path]),
        isFalse,
      );
    });

    test('输入缺失 → 需要重编', () {
      final output = write('out.dill', 'y');
      expect(
        isUpToDate(
            outputPath: output.path,
            inputPaths: [p.join(tmp.path, 'gone.dart')]),
        isFalse,
      );
    });

    test('指纹不匹配 → 需要重编', () {
      final output = write('out.dill', 'y');
      write('out.dill.stamp', 'OLD');
      expect(
        isUpToDate(
          outputPath: output.path,
          inputPaths: const [],
          stampPath: p.join(tmp.path, 'out.dill.stamp'),
          expectedStamp: 'NEW',
        ),
        isFalse,
      );
    });

    test('指纹匹配且无过期输入 → 最新', () {
      final output = write('out.dill', 'y');
      write('out.dill.stamp', 'MATCH');
      expect(
        isUpToDate(
          outputPath: output.path,
          inputPaths: const [],
          stampPath: p.join(tmp.path, 'out.dill.stamp'),
          expectedStamp: 'MATCH',
        ),
        isTrue,
      );
    });
  });
}
