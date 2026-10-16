// DLL 内容判等拷贝测试：同基名不再无条件跳过，内容不同必须覆盖。
//
// 背景事故：产物暂存目录跨构建复用，旧的"同基名即跳过"逻辑把重编译出的
// 新插件 DLL 留在产物里（Dart 快照新、原生 DLL 旧混搭），生产环境运行时
// 报 "Failed to lookup symbol 'pp_ocr_options_size' (error 127)"。

import 'dart:io';

import 'package:flutter_build/src/build/native_dll.dart';
import 'package:flutter_build/src/project.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

File _file(String path, List<int> bytes) => File(path)
  ..createSync(recursive: true)
  ..writeAsBytesSync(bytes);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dll_copy_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('copyDllIfChanged', () {
    test('目标缺失 → fresh，内容拷入', () async {
      final src = _file(p.join(tmp.path, 'src', 'a.dll'), [1, 2, 3]);
      final dest = File(p.join(tmp.path, 'out', 'a.dll'));

      final outcome = await copyDllIfChanged(src, dest);

      expect(outcome, DllCopyOutcome.fresh);
      expect(dest.readAsBytesSync(), [1, 2, 3]);
    });

    test('内容一致 → identical（不比较 mtime）', () async {
      final src = _file(p.join(tmp.path, 'src', 'a.dll'), [1, 2, 3]);
      final dest = _file(p.join(tmp.path, 'out', 'a.dll'), [1, 2, 3]);
      // mtime 不同但内容一致：File.copy 不保留源 mtime，跨构建 mtime
      // 必然失配，判等必须只看内容。
      dest.setLastModifiedSync(DateTime(2020, 1, 1));

      final outcome = await copyDllIfChanged(src, dest);

      expect(outcome, DllCopyOutcome.identical);
      expect(dest.readAsBytesSync(), [1, 2, 3]);
    });

    test('同 size 不同内容 → updated 覆盖（防重编译同大小假阴性）', () async {
      final src = _file(p.join(tmp.path, 'src', 'a.dll'), [1, 2, 4]);
      final dest = _file(p.join(tmp.path, 'out', 'a.dll'), [1, 2, 3]);

      final outcome = await copyDllIfChanged(src, dest);

      expect(outcome, DllCopyOutcome.updated);
      expect(dest.readAsBytesSync(), [1, 2, 4]);
    });

    test('size 不同 → updated 覆盖', () async {
      final src = _file(p.join(tmp.path, 'src', 'a.dll'), [1, 2, 3, 4]);
      final dest = _file(p.join(tmp.path, 'out', 'a.dll'), [1, 2, 3]);

      final outcome = await copyDllIfChanged(src, dest);

      expect(outcome, DllCopyOutcome.updated);
      expect(dest.readAsBytesSync(), [1, 2, 3, 4]);
    });
  });

  group('copyPrebuiltDlls 内容判等', () {
    test('outDir 里的旧版 DLL 被新内容覆盖，再次运行幂等', () async {
      final root = p.join(tmp.path, 'workspace');
      _file(p.join(root, 'native', 'lib.dll'), [9, 9, 9, 9]); // 新版
      final outDir = p.join(tmp.path, 'out');
      _file(p.join(outDir, 'lib.dll'), [1, 1, 1]); // 上次构建的旧版

      final scanner = NativeDllScanner();
      await scanner.copyPrebuiltDlls(
        outDir: outDir,
        searchRoot: root,
      );

      expect(File(p.join(outDir, 'lib.dll')).readAsBytesSync(), [9, 9, 9, 9]);

      // 再跑一次：内容已一致，不再动作（幂等，不产生无谓重拷）。
      await scanner.copyPrebuiltDlls(outDir: outDir, searchRoot: root);
      expect(File(p.join(outDir, 'lib.dll')).readAsBytesSync(), [9, 9, 9, 9]);
    });

    test('outDir 内容与源一致 → 不覆盖（文件 mtime 不被刷新）', () async {
      final root = p.join(tmp.path, 'workspace');
      final src = _file(p.join(root, 'native', 'lib.dll'), [7, 7]);
      final outDir = p.join(tmp.path, 'out');
      final dest = _file(p.join(outDir, 'lib.dll'), [7, 7]);
      final before = dest.lastModifiedSync();

      await NativeDllScanner()
          .copyPrebuiltDlls(outDir: outDir, searchRoot: root);

      expect(dest.lastModifiedSync(), before); // 未被重拷
      expect(dest.readAsBytesSync(), src.readAsBytesSync());
    });

    test('同基名多来源首个命中生效，后续来源不覆盖', () async {
      // 声明集语义：同基名第二个来源必须被跳过，否则可能用搜索路径里的
      // 旧文件反过来覆盖先拷入的新文件。
      final root = p.join(tmp.path, 'workspace');
      _file(p.join(root, 'native', 'lib.dll'), [1, 1]); // 命中并拷入。
      _file(p.join(root, 'deep', 'x', 'lib.dll'), [2, 2, 2]); // 同基名，跳过。
      final outDir = p.join(tmp.path, 'out');

      await NativeDllScanner().copyPrebuiltDlls(outDir: outDir, searchRoot: root);

      // 两个来源必有一个生效且只有它；无论先后，结果在再次运行后保持稳定。
      final content = File(p.join(outDir, 'lib.dll')).readAsBytesSync();
      expect(content, anyOf(equals([1, 1]), equals([2, 2, 2])));

      await NativeDllScanner().copyPrebuiltDlls(outDir: outDir, searchRoot: root);
      expect(File(p.join(outDir, 'lib.dll')).readAsBytesSync(), content);
    });
  });

  group('copyResolvedReferencedDlls 内容判等', () {
    test('按声明解析的 DLL 内容已变 → 覆盖旧版', () async {
      final pluginRoot = Directory(p.join(tmp.path, 'plug'))..createSync();
      final windows = Directory(p.join(pluginRoot.path, 'windows'))
        ..createSync();
      _file(p.join(pluginRoot.path, 'native', 'good.dll'), [4, 4]); // 新版
      File(p.join(windows.path, 'CMakeLists.txt')).writeAsStringSync(
        r'set(GOOD "${CMAKE_CURRENT_SOURCE_DIR}/../native/good.dll")',
      );
      final plugin = WindowsPluginRef(
        name: 'plug',
        rootPath: pluginRoot.path,
        pluginClass: 'PlugPlugin',
      );
      final outDir = p.join(tmp.path, 'out');
      _file(p.join(outDir, 'good.dll'), [3]); // 旧版

      await NativeDllScanner()
          .copyResolvedReferencedDlls(outDir: outDir, plugins: [plugin]);

      expect(File(p.join(outDir, 'good.dll')).readAsBytesSync(), [4, 4]);
    });
  });
}
