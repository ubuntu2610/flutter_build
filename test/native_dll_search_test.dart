// 预构建 DLL 广度搜索的容错测试（回归 [join] 组装阶段的真实崩溃）。
//
// 搜索根默认是「项目根的祖父目录」（常见即 $HOME），实测其中必然存在列举不了的
// 子目录：
//   - 目录名不是合法 UTF-8：Dart 用原始字节能 stat 通（existsSync 为 true），但
//     opendir 走的是解码后无法回编码的路径，必然 ENOENT；
//   - 权限不足（其他用户 / root 私有目录）：EACCES。
// 此前 `_findDlls` 直接 `listSync`，任一目录失败就抛
// `PathNotFoundException: Directory listing failed`，整条流水线在产物组装阶段
// 崩溃。现在按目录容错：跳过该子树并聚合告警，其余位置的 DLL 照常搜到。

import 'dart:io';

import 'package:flutter_build/src/build/native_dll.dart';
import 'package:flutter_build/src/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 非法 UTF-8 字节序列（`printf` 八进制转义），复刻线上目录名。
const String _brokenOctal = r'\016\306\324\360\212\173';

/// 用 bash 在 [parent] 下创建名字含非法 UTF-8 字节的目录；不支持则返回 false。
bool _createBrokenUtf8Dir(String parent) =>
    _bashIn(parent, 'mkdir "\$(printf "\$NAME_BYTES")"').exitCode == 0;

ProcessResult _bashIn(String dir, String script) => Process.runSync(
      'bash',
      <String>['-c', 'cd "\$TARGET_DIR" && $script'],
      environment: <String, String>{
        'TARGET_DIR': dir,
        'NAME_BYTES': _brokenOctal,
      },
    );

/// 目录是否可列举（root 用户下 000 目录也能列举，用于跳过此类用例）。
bool _listable(Directory dir) {
  try {
    dir.listSync(followLinks: false);
    return true;
  } on FileSystemException {
    return false;
  }
}

void main() {
  late Directory root;
  late Directory outDir;
  final quiet = Logger(verbose: false, color: false);

  setUp(() {
    root = Directory.systemTemp.createTempSync('dll_search_');
    outDir = Directory.systemTemp.createTempSync('dll_search_out_');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    outDir.deleteSync(recursive: true);
  });

  group('copyPrebuiltDlls', () {
    test('目录名非合法 UTF-8 时跳过该子树，其余 DLL 照常搜到', () async {
      File(p.join(root.path, 'libs', 'opencv_world490.dll'))
        ..createSync(recursive: true)
        ..writeAsStringSync('PE');
      if (!_createBrokenUtf8Dir(root.path)) {
        markTestSkipped('需要 bash 才能造出非法 UTF-8 目录名');
        return;
      }
      // addTearDown 先于 tearDown 执行：先把坏名目录删掉，root 才能整体删除。
      addTearDown(() =>
          _bashIn(root.path, 'rmdir "\$(printf "\$NAME_BYTES")"'));

      await NativeDllScanner(logger: quiet).copyPrebuiltDlls(
        outDir: outDir.path,
        searchRoot: root.path,
        maxDepth: 3,
      );

      expect(File(p.join(outDir.path, 'opencv_world490.dll')).existsSync(), isTrue);
    });

    test('权限不足的目录被跳过，不影响其它子树搜索', () async {
      File(p.join(root.path, 'libs', 'libcimbar.dll'))
        ..createSync(recursive: true)
        ..writeAsStringSync('PE');
      final blocked = Directory(p.join(root.path, 'locked'))..createSync();
      File(p.join(blocked.path, 'secret.dll')).writeAsStringSync('PE');
      Process.runSync('chmod', <String>['000', blocked.path]);
      addTearDown(() => Process.runSync('chmod', <String>['755', blocked.path]));
      if (_listable(blocked)) {
        markTestSkipped('当前用户可列举 000 目录（root 场景），无法验证容错');
        return;
      }

      await NativeDllScanner(logger: quiet).copyPrebuiltDlls(
        outDir: outDir.path,
        searchRoot: root.path,
        maxDepth: 3,
      );

      expect(File(p.join(outDir.path, 'libcimbar.dll')).existsSync(), isTrue);
      expect(File(p.join(outDir.path, 'secret.dll')).existsSync(), isFalse);
    });

    test('搜索根本身不存在时静默返回', () async {
      await NativeDllScanner(logger: quiet).copyPrebuiltDlls(
        outDir: outDir.path,
        searchRoot: p.join(root.path, 'nope'),
      );
      expect(outDir.listSync(), isEmpty);
    });
  });
}
