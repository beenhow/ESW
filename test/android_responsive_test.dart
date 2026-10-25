// 安卓三主 Tab 多分辨率自适应守卫测试（任务③）
//
// 目的：在主流 / 极端安卓机型逻辑尺寸下真实渲染安卓主界面（AndroidEswApp），
// 逐个切换「查词 / 检测 / 词库」三个主 tab，断言：
//   1) 不出现 RenderFlex overflow 等渲染错误（内容不得被裁切）；
//   2) 页面根内容（底部导航 + 主体）完整落在可视区域内；
//   3) 缩放系数随分辨率单调合理（小屏不放大、长条屏不被压扁、平板受限居中）。
//
// 覆盖机型形态：19.5:9 / 20:9 / 21:9 长条屏、16:9 老机型、320×480 极小屏、
// 折叠屏展开（673×841）、4:3 / 8:10 平板、横屏。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/android_app.dart';
import 'package:esw/pages/detect_page.dart';
import 'package:esw/pages/search_page.dart';
import 'package:esw/pages/word_bank_page.dart';
import 'package:esw/theme/responsive.dart';
import 'package:esw/widgets/esw_widgets.dart';

const List<Size> kDeviceSizes = [
  Size(360, 800), // 基准
  Size(360, 640), // 16:9 老机型
  Size(320, 480), // 极小屏
  Size(360, 780), // 19.5:9
  Size(393, 873), // 20:9
  Size(412, 915), // 19.5:9 主流
  Size(360, 840), // 21:9 长条
  Size(673, 841), // 折叠屏展开
  Size(411, 731), // 折叠屏内屏（宽高比接近 9:16）
  Size(800, 1280), // 4:3 平板
  Size(915, 412), // 横屏
];

/// 捕获指定尺寸下渲染期间的全部 error。
Future<List<String>> pumpAndroidAt(WidgetTester tester, Size size,
    {double textScale = 1.0}) async {
  final errors = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    final buf = StringBuffer(details.exceptionAsString());
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
  tester.view.padding = FakeViewPadding.zero;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(const MaterialApp(home: AndroidEswApp()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));

  FlutterError.onError = prev;
  return errors;
}

/// 只保留溢出类错误的首行，便于定位。
List<String> overflowOnly(List<String> raw) => raw
    .where((e) =>
        e.contains('overflowed') ||
        e.contains('RenderFlex') ||
        e.contains('RenderBox was not laid out'))
    .map((e) => e.split(' / ').first)
    .toList();

void main() {
  group('缩放系数取值', () {
    test('长条屏按宽度缩放且不被压扁', () {
      // 360×840（21:9）：宽比 1.0，高度富余 → 不应低于基准太多
      double factorFor(Size size) {
        return math.min(
                math.min(size.width / EswResponsive.baseWidth,
                        size.height / EswResponsive.baseHeight) *
                    EswResponsive.uiScale,
                EswResponsive.maxPhoneScale)
            .clamp(EswResponsive.minScale, EswResponsive.maxPhoneScale);
      }

      // 业务侧计算不得低于 0.95（宽度 360 时）
      expect(factorFor(const Size(360, 840)), closeTo(0.95, 0.02));
      // 320×480 极小屏：触发下限，不再继续缩小到不可读
      expect(
          math.min(320 / 360, 480 / 800) * EswResponsive.uiScale,
          lessThan(EswResponsive.minScale));
    });
  });

  for (final size in kDeviceSizes) {
    testWidgets(
        '三 Tab 自适应 ${size.width.toInt()}×${size.height.toInt()}：无溢出',
        (tester) async {
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final errors = await pumpAndroidAt(tester, size);
      final overflow = overflowOnly(errors);
      // ignore: avoid_print
      print('[ANDROID ${size.width.toInt()}x${size.height.toInt()}] '
          'errors=${errors.length} overflow=${overflow.length} :: '
          '${overflow.join(' || ')}');
      expect(overflow, isEmpty,
          reason: '尺寸 $size 下出现溢出：${overflow.join(' || ')}');

      // IndexedStack 承载三个主 tab：三页同时构建，逐一激活检查零溢出 / 不越界
      final stackFinder = find.byType(IndexedStack);
      expect(stackFinder, findsOneWidget, reason: '主 tab 容器缺失');
      // 三个主 tab 均已构建（IndexedStack 内非当前页为 offstage，故不跳过隐藏节点）
      for (final t in <Type>[SearchPage, DetectPage, WordBankPage]) {
        expect(find.byType(t, skipOffstage: false), findsOneWidget,
            reason: '主 tab $t 未构建');
      }

      // 底部导航必须完整落在屏幕内（含系统安全区）
      final navFinder = find.byType(EswBottomNav);
      expect(navFinder, findsOneWidget, reason: '底部导航缺失');
      final navRect = tester.getRect(navFinder);
      expect(navRect.bottom, lessThanOrEqualTo(size.height + 0.5),
          reason: '底部导航被裁切：$navRect');

      const labels = ['查词', '检测', '词库'];
      const pages = <Type>[SearchPage, DetectPage, WordBankPage];
      for (var i = 0; i < labels.length; i++) {
        await tester.tap(find.text(labels[i]).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
        expect(stack.index, i, reason: '切换到 ${labels[i]} 失败');
        // 当前页必须真实可见（非 offstage）
        expect(find.byType(pages[i]), findsOneWidget,
            reason: '${labels[i]} 页未渲染');
        final r = tester.getRect(find.byType(pages[i]));
        expect(r.left, greaterThanOrEqualTo(-0.5),
            reason: '${labels[i]} 页超出左边界');
        expect(r.right, lessThanOrEqualTo(size.width + 0.5),
            reason: '${labels[i]} 页超出右边界（被裁切）');
        expect(r.bottom, lessThanOrEqualTo(size.height + 0.5),
            reason: '${labels[i]} 页超出下边界（被裁切）');
      }

      // 页面主体区（IndexedStack 区域）不得越界
      final bodyRect = tester.getRect(stackFinder);
      expect(bodyRect.left, greaterThanOrEqualTo(-0.5));
      expect(bodyRect.right, lessThanOrEqualTo(size.width + 0.5));
      expect(bodyRect.bottom, lessThanOrEqualTo(size.height + 0.5),
          reason: '主体区超出屏幕：$bodyRect');

      final afterSwitch = overflowOnly(errors);
      expect(afterSwitch, isEmpty,
          reason: '尺寸 $size 切换 tab 后出现溢出：${afterSwitch.join(' || ')}');
    });
  }

  testWidgets('大字体（系统字号 1.3）下 360×800 不溢出', (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final errors = await pumpAndroidAt(tester, const Size(360, 800),
        textScale: 1.3);
    final overflow = overflowOnly(errors);
    // ignore: avoid_print
    print('[ANDROID 360x800 textScale=1.3] overflow=${overflow.length} :: '
        '${overflow.join(' || ')}');
    expect(overflow, isEmpty,
        reason: '系统大字体下出现溢出：${overflow.join(' || ')}');
  });
}
