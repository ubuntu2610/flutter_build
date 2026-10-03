// 流水线调度模型单元测试：验证 planSchedule 在并行/顺序两种模式下把固定的 7 阶段
// 清单切成的 lane 分组与次序，尤其确认 copy_flutter_bundle（资源轨）在并行模式下
// 独立成一条可并发 lane、在顺序模式下排在 CMake 之后、组装之前。

import 'package:flutter_build/src/build/build_context.dart';
import 'package:flutter_build/src/build/build_schedule.dart';
import 'package:flutter_build/src/build/stages/build_stage.dart';
import 'package:test/test.dart';

/// 用名字区分身份的假阶段，仅用于验证分组，不执行任何真实逻辑。
class _NamedStage extends BuildStage {
  _NamedStage(this._name);
  final String _name;

  @override
  String get name => _name;

  @override
  Future<void> run(BuildContext ctx) async {}
}

/// 按 [BuildPipeline._stages] 约定的固定顺序构造 7 个假阶段。
List<BuildStage> _stages() => <BuildStage>[
      _NamedStage('staging'),
      _NamedStage('translate'),
      _NamedStage('kernel'),
      _NamedStage('aot'),
      _NamedStage('cmake'),
      _NamedStage('assets'),
      _NamedStage('assemble'),
    ];

List<String> _names(List<BuildStage> s) => s.map((e) => e.name).toList();

void main() {
  group('planSchedule · 并行', () {
    final schedule = planSchedule(_stages(), parallel: true);

    test('三条并发 lane：native / dart / assets', () {
      expect(schedule.concurrent.map((l) => l.label).toList(),
          <String>['native', 'dart', 'assets']);
    });

    test('原生轨 = 暂存→翻译→CMake', () {
      final native = schedule.concurrent.firstWhere((l) => l.label == 'native');
      expect(_names(native.stages), <String>['staging', 'translate', 'cmake']);
    });

    test('Dart 轨 = kernel→AOT', () {
      final dart = schedule.concurrent.firstWhere((l) => l.label == 'dart');
      expect(_names(dart.stages), <String>['kernel', 'aot']);
    });

    test('资源轨独立成一条并发 lane，但门控在 kernel 之后（保守）', () {
      final assets = schedule.concurrent.firstWhere((l) => l.label == 'assets');
      expect(_names(assets.stages), <String>['assets']);
      // 避开两个 host Dart 进程（flutter assemble vs frontend_server）同时跑。
      expect(assets.gateOnStageName, 'kernel');
    });

    test('native / dart lane 无门控，启动即并行', () {
      for (final label in <String>['native', 'dart']) {
        final lane = schedule.concurrent.firstWhere((l) => l.label == label);
        expect(lane.gateOnStageName, isNull);
      }
    });

    test('组装阶段是唯一串行汇合 lane', () {
      expect(schedule.serial.map((l) => l.label).toList(), <String>['join']);
      expect(_names(schedule.serial.single.stages), <String>['assemble']);
    });
  });

  group('planSchedule · 顺序回退', () {
    final schedule = planSchedule(_stages(), parallel: false);

    test('无并发 lane，全部落到串行组', () {
      expect(schedule.concurrent, isEmpty);
    });

    test('串行展开后与原始执行次序一致', () {
      final flat = schedule.serial
          .expand((l) => l.stages)
          .map((e) => e.name)
          .toList();
      expect(flat, <String>[
        'staging',
        'translate',
        'kernel',
        'aot',
        'cmake',
        'assets',
        'assemble',
      ]);
    });

    test('资源打包排在 CMake 之后、组装之前', () {
      final labels = schedule.serial.map((l) => l.label).toList();
      expect(labels, <String>['native', 'dart', 'native', 'assets', 'join']);
    });

    test('串行模式下无 lane 需门控（依次执行天然隔开 Dart 进程）', () {
      for (final lane in schedule.serial) {
        expect(lane.gateOnStageName, isNull);
      }
    });
  });

  group('planSchedule · 输入守卫', () {
    test('阶段数不是 7 抛 ArgumentError', () {
      expect(
        () => planSchedule(_stages().sublist(0, 6), parallel: true),
        throwsArgumentError,
      );
    });
  });
}
