// 本轮四点改造的验收测试：
//  ① 筛选归类弹窗底部两个归类按钮水平居中 + 悬停变蓝（widget 级）
//  ② 选「拓展词」不再跳出独立弹窗（源码守卫：归类弹窗已选课标词 → 直接转类）
//  ③ 导出汇总 / 原文标注七类配色字重（由 export_summary_test 覆盖）+ 此处校验标注样式七类齐备
//  ④ 真题词无筛选按钮、未筛选带筛选按钮（源码守卫：列表分支结构）
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/theme/dialog_kit.dart';
import 'package:esw/word_filter_rules.dart';

const _kGhostIdle = Color(0x8CFFFFFF); // 玻璃白底（未悬停）
const _kHoverBlue = Color(0xFF2F6BFF); // 悬停纯蓝
const _kHoverBlueEnd = Color(0xFF1E5BE0);

String _read(String rel) => File(rel).readAsStringSync();

Widget _host() => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 420,
        child: EswDialogActions(
          // 归类弹窗：底部两个按钮整体水平居中
          alignment: MainAxisAlignment.center,
          children: [
            EswDialogGhostAction(
              label: '专有词',
              hoverBlue: true,
              onPressed: () {},
            ),
            EswDialogPrimaryAction(
              label: '超标词',
              hoverBlue: true,
              onPressed: () {},
            ),
          ],
        ),
      ),
    ),
  ),
);

BoxDecoration _deco(WidgetTester tester, Finder button) {
  final c = tester.widget<AnimatedContainer>(
    find.descendant(of: button, matching: find.byType(AnimatedContainer)),
  );
  return c.decoration! as BoxDecoration;
}

void main() {
  // ───────────────────────── ① 居中 + 悬停变蓝 ─────────────────────────
  testWidgets('归类弹窗底部两按钮整体水平居中，左右留白对称', (tester) async {
    await tester.pumpWidget(_host());

    final actions = tester.getRect(find.byType(EswDialogActions));
    final ghost = tester.getRect(find.byType(EswDialogGhostAction));
    final primary = tester.getRect(find.byType(EswDialogPrimaryAction));

    final groupCenter = (ghost.left + primary.right) / 2;
    expect(
      (groupCenter - actions.center.dx).abs(),
      lessThan(1.0),
      reason: '两个归类按钮组成的按钮组必须相对弹窗内容区水平居中',
    );
    expect(
      ((ghost.left - actions.left) - (actions.right - primary.right)).abs(),
      lessThan(1.0),
      reason: '按钮组左侧留白与右侧留白必须对称（原实现靠 Spacer 贴右）',
    );
  });

  testWidgets('鼠标悬停到哪个按钮哪个按钮即变蓝，移出恢复', (tester) async {
    await tester.pumpWidget(_host());
    final ghostF = find.byType(EswDialogGhostAction);
    final primaryF = find.byType(EswDialogPrimaryAction);

    // 初始：次要按钮为玻璃白底、主按钮为蓝紫渐变
    expect(_deco(tester, ghostF).color, _kGhostIdle);
    expect(_deco(tester, primaryF).gradient, isNotNull);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    // 悬停「专有词」→ 该按钮纯蓝，另一个保持原样
    await gesture.moveTo(tester.getCenter(ghostF));
    await tester.pump(const Duration(milliseconds: 200));
    final ghostHover = _deco(tester, ghostF);
    expect(ghostHover.color, _kHoverBlue, reason: '悬停按钮必须整块变蓝');
    expect(ghostHover.gradient, isNull);
    expect(
      (_deco(tester, primaryF).gradient! as LinearGradient).colors.first,
      isNot(_kHoverBlue),
      reason: '未悬停的按钮不得变蓝',
    );

    // 悬停「超标词」→ 蓝变到该按钮上，前一个恢复
    await gesture.moveTo(tester.getCenter(primaryF));
    await tester.pump(const Duration(milliseconds: 200));
    final primaryHover = _deco(tester, primaryF).gradient! as LinearGradient;
    expect(primaryHover.colors, [_kHoverBlue, _kHoverBlueEnd]);
    expect(_deco(tester, ghostF).color, _kGhostIdle, reason: '移出后必须恢复玻璃白底');

    // 全部移出 → 主按钮回到默认渐变
    await gesture.moveTo(const Offset(2, 2));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      (_deco(tester, primaryF).gradient! as LinearGradient).colors.first,
      isNot(_kHoverBlue),
    );
  });

  // ───────────────────── ② 选拓展词不再跳出独立弹窗 ─────────────────────
  test('归类弹窗内选拓展词直接转类：不再弹出「转为拓展词」独立弹窗', () {
    final src = _read('lib/windows_app.dart');

    // 统一拦截入口：调用方已给出有效课标词时短路，直接完成转类
    expect(
      src.contains('第二点：归类弹窗内已选定课标词原词'),
      isTrue,
      reason: '缺少归类弹窗内直接转类的短路分支',
    );
    expect(
      src.contains("if (presetBase.isNotEmpty &&") &&
          src.contains('_standardWordsLowerKeySet.contains(presetBase)) {'),
      isTrue,
      reason: '短路条件必须是「已预设且为有效课标词」',
    );
    // 归类弹窗底部不得再出现无课标词的「拓展词」提交路径
    expect(
      src.contains("_submitButton('拓展词')"),
      isFalse,
      reason: '归类弹窗不应再有让用户跳过课标词选择的拓展词提交按钮',
    );
    // 主界面独立「添加拓展词」入口的弹窗仍保留
    expect(src.contains('Future<bool?> _showExtendWordDialog('), isTrue);
  });

  // ──────────────────────── ④ 真题词 / 未筛选列表按钮 ────────────────────────
  test('列表分支：未筛选列带筛选按钮，真题词列中的未归类词无按钮', () {
    final src = _read('lib/windows_app.dart');

    const unfilteredMark = '// ---- 未筛选：频次 + 筛选按钮';
    const zhentiMark = '// ---- 真题词列中的未归类词：仅频次，无筛选按钮';
    final ui = src.indexOf(unfilteredMark);
    final zi = src.indexOf(zhentiMark);
    expect(ui, greaterThan(-1), reason: '缺少未筛选列表分支');
    expect(zi, greaterThan(ui), reason: '未筛选分支必须出现在真题词分支之前');

    // 未筛选列：四个词库都不收录的词（含语料出现过的）一律带筛选按钮，
    // 且不再用 isInCorpus 做二次拦截
    final unfilteredBranch = src.substring(
      ui,
      ui + 420 > src.length ? src.length : ui + 420,
    );
    expect(
      unfilteredBranch.contains('isUnfilteredColumn'),
      isTrue,
      reason: '未筛选分支必须按筛选列判定，不再按 isInCorpus 拦截',
    );
    expect(
      unfilteredBranch.contains('_buildClassifyButton'),
      isTrue,
      reason: '未筛选列必须带筛选按钮',
    );

    // 真题词列中的未归类词：只显示频次，归类入口留在未筛选列
    final zhentiBranch = src.substring(
      zi,
      zi + 300 > src.length ? src.length : zi + 300,
    );
    expect(
      zhentiBranch.contains('_buildFreqColumn'),
      isTrue,
      reason: '真题词列必须显示频次',
    );
    expect(
      zhentiBranch.contains('_buildClassifyButton'),
      isFalse,
      reason: '真题词列不得出现筛选按钮',
    );
    // 真题词点击行 → 查看真题例句；非语料词点击行 → 打开原文定位该词
    expect(src.contains('_showImportedInRightReader(iw.word)'), isTrue);
    expect(src.contains("_importedActiveFilter = '真题词'"), isTrue);
  });

  // ───────────── ⑤ 归属规则：语料有但四库无 → 未筛选 + 真题词叠加 ─────────────
  test('规则层：语料有但四库无的词同进真题词列与未筛选列', () {
    final cat = resolveFilterCategory(
      inCorpus: true,
      inStandard: false,
      inExtend: false,
      inChaoGang: false,
      inProper: false,
    );
    expect(cat, kFilterUnfiltered);
    expect(
      matchesFilterColumn(
          filter: kFilterZhenti, category: cat, isInCorpus: true),
      isTrue,
    );
    expect(
      matchesFilterColumn(
          filter: kFilterUnfiltered, category: cat, isInCorpus: true),
      isTrue,
    );
    expect(
      canAssignManually(WordFilterState(category: cat, isInCorpus: true)),
      isTrue,
    );

    final counts = buildFilterCounts([
      const WordFilterState(category: kFilterUnfiltered, isInCorpus: true),
      const WordFilterState(category: kFilterUnfiltered, isInCorpus: false),
    ]);
    expect(counts[kFilterZhenti], 1);
    expect(counts[kFilterUnfiltered], 2);
  });

  // ───────────────────── ③ 原文标注样式七类齐备（源码守卫） ─────────────────────
  test('原文标注样式覆盖七类规范配色与字重', () {
    final src = _read('lib/shared/inplace_docx_annotator.dart');
    for (final cat in const [
      '初中课标词',
      '必修课标词',
      '选修课标词',
      '拓展词',
      '超标词',
      '专有词',
      '未筛选',
    ]) {
      expect(src.contains('$cat\':'), isTrue, reason: '原文标注缺少分类：$cat');
    }
    // 规范配色（与导出汇总一致）：初中黑 / 必修深蓝 / 选修浅蓝 /
    // 拓展深绿 / 超标红 / 专有紫 / 未筛选土红
    for (final hex in const [
      '000000',
      '0B3D91',
      '00B0F0',
      '006400',
      'FF0000',
      '800080',
      'A0522D',
    ]) {
      expect(src.contains(hex), isTrue, reason: '原文标注缺少规范配色 #$hex');
    }
    // 字重：课标词（初中/必修）与拓展词加粗；选修/超标/专有/未筛选不加粗（省略即 false）
    final boldTrue = RegExp(r'bold:\s*true').allMatches(src).length;
    expect(boldTrue, greaterThanOrEqualTo(3), reason: '初中/必修/拓展三类必须加粗');
    for (final cat in const ['选修课标词', '超标词', '专有词', '未筛选']) {
      expect(
        RegExp("'$cat':\\s*AnnotateStyle\\(color: '[0-9A-F]{6}'\\)")
            .hasMatch(src),
        isTrue,
        reason: '$cat 应只给字色、不加粗',
      );
    }
    // 去底纹守卫：Word 导出通道不得再“写入”底纹/高亮（保留“清除源文档已有标记”的判定）
    expect(src.contains("'w:shd'"), isFalse, reason: 'Word 导出不得再写入 w:shd');
    expect(
      src.contains("'w:highlight'"),
      isFalse,
      reason: 'Word 导出不得再写入 w:highlight',
    );
    expect(
      RegExp("tag == 'highlight'").hasMatch(src),
      isTrue,
      reason: '仍需清除命中 run 上已有的 highlight 底纹',
    );
    expect(
      RegExp("tag == 'shd'").hasMatch(src),
      isTrue,
      reason: '仍需清除命中 run 上已有的 shd 底纹',
    );
  });
}
