// 结构守卫测试（《ESW玻璃效果UI设计规范.md》§3.3 原样 + 区域顺序/尺寸断言）
//
// 以 esw-ui-flutter骨架.dart 为结构模板：9 个 region key 必须全部存在，
// 顺序与尺寸严格一致。跑不过 = 结构没搭对，禁止进入样式阶段。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/theme/glass_theme.dart';
import 'package:esw/windows_app.dart';

/// 骨架 9 区域（顺序即骨架中的自上而下 / 自左而右顺序）
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

/// 以真实主界面（WinEswApp → MainWindow）渲染，保证结构守卫测的是生产 Widget 树。
Future<void> pumpRealApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 只跳过依赖平台能力的副作用（拖放轮询 / 窗口状态 / 启动提示 / 调试日志），
  // 不改变任何 Widget 结构与功能逻辑。
  kEswStructureGuardTestMode = true;
  addTearDown(() => kEswStructureGuardTestMode = false);

  await tester.pumpWidget(const WinEswApp());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

double _h(WidgetTester tester, String key) =>
    tester.getSize(find.byKey(ValueKey(key))).height;

double _w(WidgetTester tester, String key) =>
    tester.getSize(find.byKey(ValueKey(key))).width;

double _top(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(ValueKey(key))).dy;

double _left(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(ValueKey(key))).dx;

void main() {
  // ── §3.3 原样断言 ──
  testWidgets('布局结构守卫：9 个区域必须全部存在且可定位', (tester) async {
    await pumpRealApp(tester);
    for (final k in kRegionKeys) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: '缺少区域 $k');
    }
  });

  // ── 尺寸守卫：region-titlebar 42 / toolbar 44 / side 248 / srow 40 /
  //              stats 72 / filters 30 / freq 146 / table flex ──
  testWidgets('尺寸守卫：各区域高度/宽度与骨架一致', (tester) async {
    await pumpRealApp(tester);

    expect(_h(tester, 'region-titlebar'), GlassTheme.hTitleBar, // 42
        reason: '标题栏必须 h42');
    expect(_h(tester, 'region-toolbar'), GlassTheme.hToolbar, // 44
        reason: '工具栏必须 h44（独立一行，搜索行不属于这里）');
    expect(_w(tester, 'region-side'), 248.0, reason: '左栏必须宽 248');
    expect(_h(tester, 'region-srow'), GlassTheme.hSearchRow, // 40
        reason: '搜索行必须 h40');
    expect(_h(tester, 'region-stats'), GlassTheme.hStatCard, // 72
        reason: '统计卡必须 h72');
    expect(_h(tester, 'region-filters'), GlassTheme.hFilterRow, // 30
        reason: '筛选行必须 h30');
    expect(_h(tester, 'region-freq'), GlassTheme.hWordPanel, // 146
        reason: '词频面板必须 h146（规范 §4.7 偏差 10）');
    expect(_h(tester, 'region-table'), greaterThan(0),
        reason: '结果表必须是唯一 flex:1 区域');
  });

  // ── 顺序守卫：窗口第1行=标题栏，第2行=工具栏；右栏 5 块自上而下 ──
  testWidgets('顺序守卫：9 区域层级与从属关系正确', (tester) async {
    await pumpRealApp(tester);

    // 标题栏在工具栏上方，两者都在左栏/内容区上方
    expect(_top(tester, 'region-titlebar'), lessThan(_top(tester, 'region-toolbar')));
    expect(_top(tester, 'region-toolbar'), lessThan(_top(tester, 'region-side')));
    expect(_top(tester, 'region-toolbar'), lessThan(_top(tester, 'region-content')));

    // 左栏在内容区左侧
    expect(_left(tester, 'region-side'), lessThan(_left(tester, 'region-content')));

    // 内容区 5 块自上而下：srow → stats → filters → freq → table
    final order = [
      'region-srow',
      'region-stats',
      'region-filters',
      'region-freq',
      'region-table',
    ];
    for (var i = 0; i < order.length - 1; i++) {
      expect(_top(tester, order[i]), lessThan(_top(tester, order[i + 1])),
          reason: '${order[i]} 必须排在 ${order[i + 1]} 之前');
    }

    // 偏差 9：搜索行在右栏内容区第 1 块，严禁出现在工具栏内
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('region-toolbar')),
        matching: find.byKey(const ValueKey('region-srow')),
      ),
      findsNothing,
      reason: '搜索行不得放进工具栏',
    );
    for (final k in order) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('region-content')),
          matching: find.byKey(ValueKey(k)),
        ),
        findsOneWidget,
        reason: '$k 必须在 region-content 内',
      );
    }

    // 右栏 5 块必须真正位于右栏（左边界在左栏右侧）
    expect(_left(tester, 'region-srow'),
        greaterThan(_left(tester, 'region-side') + 248 - 1));
  });

  // ── 左栏守卫（偏差 12）：两张导入卡必须撑满栏高，底部不留白 ──
  testWidgets('左栏守卫：导入卡撑满栏高（无底部留白）', (tester) async {
    await pumpRealApp(tester);

    final side = tester.getRect(find.byKey(const ValueKey('region-side')));
    final cards = find.descendant(
      of: find.byKey(const ValueKey('region-side')),
      matching: find.byType(GlassPanel),
    );
    expect(cards, findsNWidgets(2), reason: '左栏应为真题导入卡 + 教材导入卡两张玻璃卡');

    final r1 = tester.getRect(cards.at(0));
    final r2 = tester.getRect(cards.at(1));
    expect(r1.top - side.top, lessThanOrEqualTo(20),
        reason: '第一张卡必须贴近栏顶，不得留白');
    expect(side.bottom - r2.bottom, lessThanOrEqualTo(20),
        reason: '第二张卡必须撑到栏底，不得底部留白');
  });
}
