// MinGW 兼容垫片物化测试：头文件写入、幂等、库大小写修正链接。

import 'dart:io';

import 'package:flutter_build/src/build/mingw_compat.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('mingw_compat_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('写入全部垫片头文件且内容与常量一致', () async {
    final out = p.join(tmp.path, 'compat');
    await materializeMingwCompat(outDir: out, mingwLibDir: p.join(tmp.path, 'nolib'));

    for (final entry in kMingwCompatHeaders.entries) {
      final f = File(p.join(out, entry.key));
      expect(f.existsSync(), isTrue, reason: '${entry.key} 应被写入');
      expect(f.readAsStringSync(), entry.value);
    }
  });

  test('幂等：内容未变时不重写（保持 mtime，避免触发 ninja 全量重编）', () async {
    final out = p.join(tmp.path, 'compat');
    final libDir = p.join(tmp.path, 'nolib');
    await materializeMingwCompat(outDir: out, mingwLibDir: libDir);

    final header = File(p.join(out, 'shobjidl_core.h'));
    final firstMtime = header.lastModifiedSync();
    // 回拨一小时以便检测是否被重写。
    header.setLastModifiedSync(
        firstMtime.subtract(const Duration(hours: 1)));
    final marked = header.lastModifiedSync();

    await materializeMingwCompat(outDir: out, mingwLibDir: libDir);
    // 内容未变 → 不应重写 → mtime 保持我们设置的值。
    expect(header.lastModifiedSync(), marked);
  });

  test('创建 libGdi32.a → libgdi32.a 大小写修正链接', () async {
    final out = p.join(tmp.path, 'compat');
    final libDir = Directory(p.join(tmp.path, 'lib'))..createSync();
    final gdi32 = File(p.join(libDir.path, 'libgdi32.a'))
      ..writeAsStringSync('archive');

    await materializeMingwCompat(outDir: out, mingwLibDir: libDir.path);

    final link = Link(p.join(out, 'libGdi32.a'));
    expect(link.existsSync(), isTrue);
    expect(link.targetSync(), gdi32.path);
  });

  test('无 libgdi32.a 时不创建链接', () async {
    final out = p.join(tmp.path, 'compat');
    await materializeMingwCompat(
        outDir: out, mingwLibDir: p.join(tmp.path, 'empty'));
    expect(Link(p.join(out, 'libGdi32.a')).existsSync(), isFalse);
  });
}
