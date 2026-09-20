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

  test('VersionHelpers.h 垫片转发到小写 versionhelpers.h', () async {
    final out = p.join(tmp.path, 'compat');
    await materializeMingwCompat(
        outDir: out, mingwLibDir: p.join(tmp.path, 'nolib'));

    final f = File(p.join(out, 'VersionHelpers.h'));
    expect(f.existsSync(), isTrue);
    final content = f.readAsStringSync();
    // 转发目标是小写系统头（避免与垫片自身形成递归包含）。
    expect(content, contains('#include <versionhelpers.h>'));
    expect(content, isNot(contains('#include <VersionHelpers.h>')));
  });

  test('sal.h 垫片经 include_next 放行系统头并补齐 SAL2 注解', () async {
    final out = p.join(tmp.path, 'compat');
    await materializeMingwCompat(
        outDir: out, mingwLibDir: p.join(tmp.path, 'nolib'));

    final content = File(p.join(out, 'sal.h')).readAsStringSync();
    // 放行系统 sal.h（include_next 不会递归回垫片自身）。
    expect(content, contains('#include_next <sal.h>'));
    expect(RegExp(r'#include\s+<sal\.h>').hasMatch(content), isFalse);
    // 补齐 MinGW sal.h 缺失的 MSVC SAL2 注解（空展开 + #ifndef 防重定义）。
    expect(content, contains('#define _Frees_ptr_opt_'));
    expect(content, contains('#define _Frees_ptr_'));
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
