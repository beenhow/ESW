// 自适应守卫测试（任务②：各板块 / 提示文字 / 按钮随窗口大小自动缩放）
//
// 目的：在多种窗口尺寸下渲染真实主界面（WinEswApp → MainWindow），断言
//   1) 不产生任何 RenderFlex overflow / 渲染异常（缩小窗口不得显示不全）；
//   2) 9 个 region 全部存在、尺寸为正、且完全落在窗口可视区内（不被裁掉）；
//   3) 缩放系数 GlassTheme.uiScale 与窗口尺寸的换算关系正确（基准 1200×680、
//      下限 0.75、超过基准不放大）。
// 生产可达尺寸区间为 900×600 ~ 任意大（window_manager 最小窗口尺寸 900×600），
// 另加 820×560 / 700×520 两个压力尺寸，用于确认极端缩小下也不出现溢出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/theme/glass_theme.dart';
import 'package:esw/windows_app.dart';

const List<String> kRegionKeys = [
  'region-titlebar',
  'region-toolbar',
  'region-side',
  'region-content',
  'region-srow',
  'region-stats',
  'region-filters',
  'region-freq',
  'region-table',
];

/// 在一个指定尺寸下全量重挂载真实主界面，返回本尺寸渲染期间捕获的错误文本。
Future<List<String>> pumpAppAt(WidgetTester tester, Size size) async {
  final errors = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    final buf = StringBuffer(details.exceptionAsString());
    final ctx = details.context;
    if (ctx != null) buf.write(' | ${ctx.toString()}');
    final info = details.informationCollector;
    if (info != null) {
      for (final node in info()) {
        buf.write(' | ${node.toStringDeep(minLevel: DiagnosticLevel.info)}');
      }
    }
    errors.add(buf.toString().replaceAll('\n', ' / '));
  };

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;

  // 先卸载再挂载：保证以新尺寸完整重建（避免 const widget 复用导致跳过重建）。
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(const WinEswApp());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  FlutterError.onError = prev;
  return errors;
}

/// 只保留溢出/渲染类错误的关键行，便于定位。
List<String> summarize(List<String> raw) => raw
    .map((e) {
      final first = e.split(' / ').first;
      final loc = RegExp(r'windows_app\.dart:\d+:\d+').firstMatch(e);
      return loc == null ? first : '$first @ ${loc.group(0)}';
    })
    .toList();

String describeRegions(WidgetTester tester) {
  final sb = StringBuffer();
  for (final k in kRegionKeys) {
    final f = find.byKey(ValueKey(k));
    if (f.evaluate().isEmpty) {
      sb.write('$k=MISSING; ');
      continue;
    }
    final r = tester.getRect(f);
    sb.write(
        '$k=(${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)},'
        '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}); ');
  }
  return sb.toString();
}

void main() {
  setUp(() {
    kEswStructureGuardTestMode = true;
    addTearDown(() => kEswStructureGuardTestMode = false);
    addTearDown(() => GlassTheme.uiScale = 1.0);
  });

  // 生产可达尺寸（含最小窗口 900×600），要求零溢出、零裁切。
  for (final size in const [
    Size(1200, 680),
    Size(1100, 640),
    Size(1000, 620),
    Size(900, 600),
  ]) {
    testWidgets('自适应守卫 ${size.width.toInt()}×${size.height.toInt()}：无溢出且 9 区域完整可见',
        (tester) async {
      addTearDown(tester.view.reset);
      final errors = await pumpAppAt(tester, size);
      // ignore: avoid_print
      print('[SIZE ${size.width.toInt()}x${size.height.toInt()}] '
          'scale=${GlassTheme.uiScale.toStringAsFixed(3)} '
          'errors=${errors.length} :: ${summarize(errors).join(' || ')}');
      // ignore: avoid_print
      print('[REGIONS ${size.width.toInt()}x${size.height.toInt()}] '
          '${describeRegions(tester)}');

      expect(errors, isEmpty,
          reason: '尺寸 $size 下出现渲染错误：${summarize(errors)}');

      for (final k in kRegionKeys) {
        final f = find.byKey(ValueKey(k));
        expect(f, findsOneWidget, reason: '尺寸 $size 下缺少区域 $k');
        final r = tester.getRect(f);
        expect(r.width, greaterThan(0), reason: '$k 宽度必须为正');
        expect(r.height, greaterThan(0), reason: '$k 高度必须为正');
        expect(r.left, greaterThanOrEqualTo(-0.01), reason: '$k 超出窗口左边界');
        expect(r.top, greaterThanOrEqualTo(-0.01), reason: '$k 超出窗口上边界');
        expect(r.right, lessThanOrEqualTo(size.width + 0.01),
            reason: '$k 超出窗口右边界（被裁掉）');
        expect(r.bottom, lessThanOrEqualTo(size.height + 0.01),
            reason: '$k 超出窗口下边界（被裁掉）');
      }
    });
  }

  // 压力尺寸（低于生产最小窗口）：同样要求零溢出，避免极端缩小下悄悄裁切。
  for (final size in const [
    Size(820, 560),
    Size(700, 520),
  ]) {
    testWidgets('自适应压力测试 ${size.width.toInt()}×${size.height.toInt()}：无溢出',
        (tester) async {
      addTearDown(tester.view.reset);
      final errors = await pumpAppAt(tester, size);
      // ignore: avoid_print
      print('[STRESS ${size.width.toInt()}x${size.height.toInt()}] '
          'scale=${GlassTheme.uiScale.toStringAsFixed(3)} '
          'errors=${errors.length} :: ${summarize(errors).join(' || ')}');
      // ignore: avoid_print
      print('[REGIONS ${size.width.toInt()}x${size.height.toInt()}] '
          '${describeRegions(tester)}');
      expect(errors, isEmpty,
          reason: '尺寸 $size 下出现渲染错误：${summarize(errors)}');
    });
  }

  testWidgets('缩放系数换算：基准/下限/上限', (tester) async {
    addTearDown(tester.view.reset);
    GlassTheme.uiScale = 1.0;
    expect(GlassTheme.updateUiScale(const Size(1200, 680)), isFalse);
    expect(GlassTheme.uiScale, 1.0);
    expect(GlassTheme.updateUiScale(const Size(2400, 1400)), isFalse,
        reason: '超过基准窗口不放大');
    expect(GlassTheme.uiScale, 1.0);
    expect(GlassTheme.updateUiScale(const Size(900, 600)), isTrue);
    expect(GlassTheme.uiScale, closeTo(0.75, 0.001));
    expect(GlassTheme.updateUiScale(const Size(600, 400)), isFalse);
    expect(GlassTheme.uiScale, closeTo(0.75, 0.001), reason: '触底不再缩小');
    expect(GlassTheme.dp(100), closeTo(75.0, 0.001));
  });
}
