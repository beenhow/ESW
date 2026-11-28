// 词频年份 / 教材分布栅格：自适应排布回归测试。
//
// 目标：在给定面板宽高内，年份格与教材格自动换行排布、按可用宽高自适应，
// 常规数据（12 个年份 + 少量教材）不需要滚动即可全部看全；即使数据量超出
// 最小可读尺寸允许的范围，也只能在面板内部滚动，不得产生溢出异常。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/theme/glass_theme.dart';
import 'package:esw/windows/year_filter_bar.dart';

Widget _host({
  required double width,
  required double height,
  required List<int> years,
  required List<({String path, String name})> textbooks,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: YearFilterBar(
            textbookItems: textbooks,
            textbookCounts: {for (final t in textbooks) t.path: 2},
            years: years,
            yearCounts: {for (final y in years) y: 3},
            yearTotal: years.length * 3,
            textbookTotal: textbooks.length * 2,
            word: 'taken',
            wordFreq: 7,
            textbookWordFreq: 3,
            selectedYear: null,
            selectedTextbook: null,
            selectedTextbookName: '',
            onSelectYear: (_) {},
            onSelectTextbook: (_) {},
            onClearYear: () {},
            onClearTextbook: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  // 设计基准：面板高 146（region-freq / hWordPanel），宽度按 1200 窗口内容区
  testWidgets('12 个年份 + 6 本教材：面板内全部可见且无需滚动', (tester) async {
    final years = List<int>.generate(12, (i) => 2026 - i);
    final textbooks = List<({String path, String name})>.generate(
      6,
      (i) => (path: '/book/$i', name: '教材$i.txt'),
    );
    await tester.pumpWidget(_host(
      width: 1040,
      height: GlassTheme.hWordPanel,
      years: years,
      textbooks: textbooks,
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('年份词频（共 36 次，taken 本词 7 次）'), findsOneWidget,
        reason: '左侧标题应显示年份词频合计与被查词自身次数');
    expect(find.text('教材分布（共 12 次，taken 本词 3 次）'), findsOneWidget,
        reason: '右侧标题应显示教材分布合计与教材侧被查词自身次数');

    final panel = tester.getRect(find.byKey(const ValueKey('region-freq')));
    for (final y in years) {
      final r = tester.getRect(find.byKey(ValueKey('year-cell-$y')));
      expect(r.bottom, lessThanOrEqualTo(panel.bottom + 0.01),
          reason: '年份格 $y 超出面板底部，需要滚动才能看到');
      expect(r.top, greaterThanOrEqualTo(panel.top - 0.01),
          reason: '年份格 $y 超出面板顶部');
    }
    for (final t in textbooks) {
      final r = tester.getRect(find.byKey(ValueKey('textbook-cell-${t.path}')));
      expect(r.bottom, lessThanOrEqualTo(panel.bottom + 0.01),
          reason: '教材格 ${t.name} 超出面板底部，需要滚动才能看到');
    }

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('region-freq')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, 0,
        reason: '12 个年份 + 6 本教材在基准面板高度下不应出现滚动');
  });

  // 最小窗口 900×600：面板按 0.34 分配后约 101 高，年份仍须一次看全
  testWidgets('900×600 面板高度下 12 年份全部可见', (tester) async {
    final years = List<int>.generate(12, (i) => 2026 - i);
    final textbooks = <({String path, String name})>[(path: '/a', name: '必修一.txt')];
    await tester.pumpWidget(_host(
      width: 800,
      height: 101,
      years: years,
      textbooks: textbooks,
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('年份词频（共 36 次，taken 本词 7 次）'), findsOneWidget,
        reason: '左侧标题应显示年份词频合计与被查词自身次数');
    expect(find.text('教材分布（共 2 次，taken 本词 3 次）'), findsOneWidget,
        reason: '右侧标题应显示教材分布合计与教材侧被查词自身次数');

    final panel = tester.getRect(find.byKey(const ValueKey('region-freq')));
    for (final y in years) {
      final r = tester.getRect(find.byKey(ValueKey('year-cell-$y')));
      expect(r.bottom, lessThanOrEqualTo(panel.bottom + 0.01),
          reason: '900×600 下年份格 $y 需要滚动才能看到');
    }
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('region-freq')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, 0);
  });

  // 极端数据量：允许面板内滚动，但绝不能溢出（溢出会顶坏下方筛选行/结果表）
  testWidgets('40 年份 + 40 教材：只在面板内滚动，不溢出', (tester) async {
    final years = List<int>.generate(40, (i) => 2039 - i);
    final textbooks = List<({String path, String name})>.generate(
      40,
      (i) => (path: '/b/$i', name: '教材$i.txt'),
    );
    await tester.pumpWidget(_host(
      width: 900,
      height: 120,
      years: years,
      textbooks: textbooks,
    ));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('region-freq')), findsOneWidget);
  });

  // 宽度自适应：窄面板下减少列数、自动换行，而不是横向裁切
  testWidgets('窄宽度 520：自动折行且不横向溢出', (tester) async {
    final years = List<int>.generate(12, (i) => 2026 - i);
    await tester.pumpWidget(_host(
      width: 520,
      height: 165,
      years: years,
      textbooks: const [],
    ));
    expect(tester.takeException(), isNull);
    final panel = tester.getRect(find.byKey(const ValueKey('region-freq')));
    for (final y in years) {
      final r = tester.getRect(find.byKey(ValueKey('year-cell-$y')));
      expect(r.right, lessThanOrEqualTo(panel.right + 0.01),
          reason: '年份格 $y 横向溢出面板');
      expect(r.bottom, lessThanOrEqualTo(panel.bottom + 0.01),
          reason: '年份格 $y 纵向溢出面板');
    }
  });
}
