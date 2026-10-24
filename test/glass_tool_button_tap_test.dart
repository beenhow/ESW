// 回归测试：GlassToolButton 必须真正响应点击。
//
// 历史 bug：修改前 GlassToolButton 只实现了“按下缩放”视觉反馈，
// 没有把 onPressed 接入任何点击手势（对比同文件 GlassChip / GlassGhostButton 均有
// GestureDetector(onTap:)），导致主界面工具栏 region-toolbar 内
// “使用说明 / 同步词库 / 导出高频”三个按钮点击完全无反应。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/theme/glass_theme.dart';

void main() {
  testWidgets('GlassToolButton 点击必须触发 onPressed', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassToolButton(
              label: '同步词库',
              icon: Icons.sync,
              onPressed: () => taps++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('同步词库'));
    await tester.pumpAndSettle();

    expect(taps, 1,
        reason: '点击工具栏按钮（如“同步词库”）必须触发 onPressed，否则即为“点击无反应”缺陷');
  });

  testWidgets('GlassToolButton 禁用态（onPressed=null）点击不触发且不抛异常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassToolButton(label: '同步词库', onPressed: null),
          ),
        ),
      ),
    );

    await tester.tap(find.text('同步词库'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
