// 「修改单词」弹窗布局校验（等价证据）
//
// 背景：该弹窗由原文面板选中文本 → 右键「修改」触发，依赖真实的
//   SelectionArea/长按菜单与平台窗口环境，不适合在 widget test 中完整
//   复现触发链路。因此本测试直接以「与实现完全同源」的构件渲染弹窗：
//   EswDialogShell + EswDialogActions + 同参数（minContent 360、标题、
//   「原文：」副标题、✕ trailing、TextField body、取消/保存），
//   断言视觉规范的硬指标，防止后续改动回退。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/theme/dialog_kit.dart';

const double kViewW = 1600;
const double kViewH = 1000;

Widget _buildDialog() {
  final ctrl = TextEditingController(text: 'abandon');
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: SizedBox(
            width: EswDialog.panelWidth(ctx, minContent: 360),
            child: EswDialogShell(
              icon: Icons.edit_outlined,
              title: '修改单词',
              subtitle: '原文：abandon',
              minContent: 360,
              trailing: Tooltip(
                message: '关闭',
                child: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {},
                ),
              ),
              body: TextField(
                controller: ctrl,
                maxLines: 3,
                style: EswDialog.bodyStyle,
                decoration: const InputDecoration(hintText: '输入替换后的单词'),
              ),
              actions: EswDialogActions(
                children: [
                  EswDialogTextAction(label: '取消', onPressed: () {}),
                  EswDialogPrimaryAction(label: '保存', onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('「修改单词」弹窗：宽 392、含✕/原词/右对齐按钮、间距合规', (tester) async {
    tester.view.physicalSize = const Size(kViewW, kViewH);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildDialog());
    await tester.pumpAndSettle();

    // ① 面板宽度：内容自适应 360 + 左右内边距 32 = 392，落在常规档 300~460 内
    final shellBox = tester.renderObject<RenderBox>(find.byType(EswDialogShell));
    expect(shellBox.size.width, closeTo(392, 0.6),
        reason: '面板宽应为 392（minContent 360 + padH*2），不再被窄框挤压');
    expect(shellBox.size.width,
        greaterThanOrEqualTo(EswDialog.wPanelMin));

    // ② 右上角 ✕（trailing）存在且在标题行右侧、与标题顶端对齐
    final closeFinder = find.byTooltip('关闭');
    expect(closeFinder, findsOneWidget, reason: '弹窗应有右上角 ✕ 关闭按钮');
    final closeBox = tester.getRect(closeFinder);
    final titleBox = tester.getRect(find.text('修改单词'));
    expect(closeBox.left, greaterThan(titleBox.right), reason: '✕ 应在标题右侧');
    expect((closeBox.top - titleBox.top).abs(), lessThan(6),
        reason: '✕ 与标题顶端对齐（crossAxisAlignment.start）');

    // ③ 原词参照文案存在（副标题），位于标题下方一行
    final origBox = tester.getRect(find.text('原文：abandon'));
    expect(find.text('原文：abandon'), findsOneWidget, reason: '应展示正在修改的原词');
    expect(origBox.top, greaterThan(titleBox.bottom - 1));
    expect(origBox.top - titleBox.bottom, closeTo(EswDialog.gapTitleSub, 0.6),
        reason: '标题 → 原词间距应为 gapTitleSub');

    // ④ 输入框：占满内容宽（不被挤压），与标题区间距 = gapHeaderBody
    final fieldBox = tester.getRect(find.byType(TextField));
    expect(fieldBox.width, closeTo(shellBox.size.width - EswDialog.padH * 2, 1.0),
        reason: '输入框应占满内容宽');
    expect(fieldBox.top - origBox.bottom, greaterThanOrEqualTo(0));

    // ⑤ 按钮区：右对齐、间距 = gapAction(10)、上下留白 = 内容→按钮 gapSection(18)
    final actionsFinder = find.byType(EswDialogActions);
    final actionsWidget = tester.widget<EswDialogActions>(actionsFinder);
    expect(actionsWidget.alignment, MainAxisAlignment.end, reason: '动作按钮应右对齐');

    final cancelBox = tester.getRect(find.byType(EswDialogTextAction));
    final saveBox = tester.getRect(find.byType(EswDialogPrimaryAction));
    final actionsRowBox = tester.getRect(actionsFinder);
    expect(saveBox.left - cancelBox.right, closeTo(EswDialog.gapAction, 0.6),
        reason: '取消/保存间距应为 gapAction');
    expect(fieldBox.bottom < actionsRowBox.top, isTrue);
    expect(actionsRowBox.top - fieldBox.bottom, closeTo(EswDialog.gapSection, 0.6),
        reason: '输入框 → 按钮区间距应为 gapSection');

    // ⑥ 底部留白：面板底到按钮行底 = padB(12)，不出现大片空白
    final shellRect = tester.getRect(find.byType(EswDialogShell));
    expect(shellRect.bottom - actionsRowBox.bottom,
        closeTo(EswDialog.padB, 0.6),
        reason: '按钮行下方留白应为 padB，消除原先 AlertDialog 的底部大块留白');
  });
}
