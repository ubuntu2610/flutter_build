// 原生 DLL 打包缺失检查的单元测试。
//
// 覆盖 `BuildPipeline.referencedDllPaths` 纯函数：从插件 windows/CMakeLists.txt
// 里提取“声明要随产物打包的预编译 DLL”字面路径，用于编译期校验这些 DLL 是否
// 真的进了产物（缺失则告警，避免留到运行时才报 DynamicLibrary.open 失败）。

import 'package:flutter_build/src/build/pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('referencedDllPaths', () {
    test('提取 libcimbar 风格 CMakeLists 里引用的预编译 DLL', () {
      const content = r'''
set(PLUGIN_NAME "libcimbar_plugin")
add_library(${PLUGIN_NAME} SHARED "libcimbar_plugin.cpp")
# Pre-built native DLLs compiled separately via native/build_windows.bat
set(LIBCIMBAR_NATIVE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../native/build_windows/Release/libcimbar.dll")
set(OPENCV_DLL "C:/project/paddle_ocr/windows/third_party/opencv/lib/opencv_world490.dll")
set(BUNDLED_LIBS "$<TARGET_FILE:${PLUGIN_NAME}>")
''';
      final refs = BuildPipeline.referencedDllPaths(content);
      final names = refs.map((r) => r.split('/').last).toSet();

      expect(
          names, containsAll(<String>['libcimbar.dll', 'opencv_world490.dll']));
      // 生成器表达式目标（$<TARGET_FILE:...>）不应被当作字面 DLL 提取。
      expect(refs.any((r) => r.contains(r'$<')), isFalse);
    });

    test('忽略注释里的 .dll', () {
      const content = '# 参见文档里的 foo.dll\nset(X "bar.dll")';
      final names = BuildPipeline.referencedDllPaths(content)
          .map((r) => r.split('/').last);

      expect(names, contains('bar.dll'));
      expect(names, isNot(contains('foo.dll')));
    });

    test('无 .dll 引用时返回空', () {
      const content = 'add_library(foo SHARED "foo.cpp")\n'
          'target_link_libraries(foo PRIVATE flutter)';
      expect(BuildPipeline.referencedDllPaths(content), isEmpty);
    });
  });
}
