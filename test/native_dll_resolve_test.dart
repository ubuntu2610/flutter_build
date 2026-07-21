// 原生 DLL 引用解析测试：CMake 变量展开、Windows 绝对路径过滤、按声明解析实际
// 存在的预编译 DLL。

import 'dart:io';

import 'package:flutter_build/src/build/native_dll.dart';
import 'package:flutter_build/src/project.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('resolveReferencedDll', () {
    const cmakeDir = '/plug/windows';

    test('展开 CMAKE_CURRENT_SOURCE_DIR 并归一化', () {
      expect(
        resolveReferencedDll(
            r'${CMAKE_CURRENT_SOURCE_DIR}/../native/x.dll', cmakeDir),
        '/plug/native/x.dll',
      );
    });

    test('展开 CMAKE_CURRENT_LIST_DIR', () {
      expect(
        resolveReferencedDll(r'${CMAKE_CURRENT_LIST_DIR}/lib/y.dll', cmakeDir),
        '/plug/windows/lib/y.dll',
      );
    });

    test('纯相对路径相对 CMake 目录解析', () {
      expect(resolveReferencedDll('lib/w.dll', cmakeDir),
          '/plug/windows/lib/w.dll');
    });

    test('Windows 绝对路径无法解析 → null', () {
      expect(resolveReferencedDll(r'C:/opencv/opencv_world490.dll', cmakeDir),
          isNull);
    });

    test('含其它未知 CMake 变量 → null', () {
      expect(resolveReferencedDll(r'${SOME_OTHER_VAR}/z.dll', cmakeDir), isNull);
    });
  });

  group('resolveReferencedDllFiles', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('native_dll_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('返回实际存在、按声明解析的 DLL；跳过缺失', () {
      final pluginRoot = Directory(p.join(tmp.path, 'plug'))..createSync();
      final windows = Directory(p.join(pluginRoot.path, 'windows'))
        ..createSync();
      // 存在的预编译 DLL（相对 windows/ 的上级 native/ 目录）。
      final realDll = File(p.join(pluginRoot.path, 'native', 'good.dll'))
        ..createSync(recursive: true)
        ..writeAsStringSync('MZ');
      File(p.join(windows.path, 'CMakeLists.txt')).writeAsStringSync('''
set(GOOD "\${CMAKE_CURRENT_SOURCE_DIR}/../native/good.dll")
set(MISSING "\${CMAKE_CURRENT_SOURCE_DIR}/../native/missing.dll")
set(WINABS "C:/somewhere/other.dll")
''');

      final plugin = WindowsPluginRef(
        name: 'plug',
        rootPath: pluginRoot.path,
        pluginClass: 'PlugPlugin',
      );

      final files = NativeDllScanner().resolveReferencedDllFiles([plugin]);
      final paths = files.map((f) => p.normalize(f.path)).toSet();

      expect(paths, contains(p.normalize(realDll.path)));
      // 缺失文件与 Windows 绝对路径都不应出现。
      expect(paths.any((x) => x.contains('missing.dll')), isFalse);
      expect(paths.any((x) => x.contains('other.dll')), isFalse);
    });
  });
}
