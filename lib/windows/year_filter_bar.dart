// 内容区「词频年份 / 教材分布」筛选栅格（原 _buildYearDistribution，578 行巨型方法拆分）。
//
// 只做渲染：所有筛选状态与数据仍由 _MainWindowState 持有，通过参数与回调下发，
// 因此拆分不改变任何筛选语义。region-freq 与 hWordPanel 高度语义保持不变。
import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';

class YearFilterBar extends StatelessWidget {
  const YearFilterBar({
    super.key,
    required this.textbookItems,
    required this.textbookCounts,
    required this.years,
    required this.yearCounts,
    required this.yearTotal,
    required this.textbookTotal,
    required this.word,
    required this.wordFreq,
    required this.textbookWordFreq,
    required this.selectedYear,
    required this.selectedTextbook,
    required this.selectedTextbookName,
    required this.onSelectYear,
    required this.onSelectTextbook,
    required this.onClearYear,
    required this.onClearTextbook,
  });

  /// 已勾选参与的教材（path + 原始文件名）
  final List<({String path, String name})> textbookItems;

  /// 当前单词在各教材中的命中数（key = 教材路径）
  final Map<String, int> textbookCounts;

  /// 年份（降序）与各年份命中数
  final List<int> years;
  final Map<int, int> yearCounts;

  /// 标题里的总次数：真题命中总数 / 教材命中总数
  final int yearTotal;
  final int textbookTotal;

  /// 当前被查词本身（不含变体）与其真题命中次数。
  /// 与 [yearTotal] 同一合并口径（含短语覆盖合并，不做字面重复叠加），
  /// 因此两处数字一致。
  final String word;
  final int wordFreq;

  /// 教材侧命中数，与 [textbookTotal] 同口径。
  final int textbookWordFreq;

  final int? selectedYear;
  final String? selectedTextbook;
  final String selectedTextbookName;

  final void Function(int year) onSelectYear;
  final void Function(String path) onSelectTextbook;
  final VoidCallback onClearYear;
  final VoidCallback onClearTextbook;

  @override
  Widget build(BuildContext context) {
    final hasBoxes = textbookItems.isNotEmpty || years.isNotEmpty;
    if (years.isEmpty && !hasBoxes) {
      // ④-4 词频面板：必须存在（规范 §4.7 偏差 10），空态也保留玻璃面板。
      // 高度由父级按可用空间分配（不再写死 hWordPanel，避免小窗口下压住下方表格）。
      return SizedBox(
        key: const ValueKey('region-freq'),
        child: GlassPanel(
          radius: GlassTheme.rXl,
          padding: const EdgeInsets.symmetric(horizontal: kGap16),
          child: const Center(
            child: Text(
              '请点击真题导入按钮，导入真题数据',
              style: TextStyle(fontSize: 13, color: GlassTheme.ink3),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      key: const ValueKey('region-freq'),
      child: GlassPanel(
        radius: GlassTheme.rXl,
        sigma: 0, // 常驻大面板：模糊不可见，关掉省光栅开销
        padding: const EdgeInsets.fromLTRB(kGap16, kGap12, kGap16, kGap8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: kGap8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      word.isEmpty
                          ? '年份词频（共 $yearTotal 次）'
                          : '年份词频（共 $yearTotal 次，$word 本词 $wordFreq 次）',
                      textAlign: TextAlign.left,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: GlassTheme.fBody,
                        fontWeight: FontWeight.w600,
                        color: GlassTheme.ink,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      word.isEmpty
                          ? '教材分布（共 $textbookTotal 次）'
                          : '教材分布（共 $textbookTotal 次，$word 本词 $textbookWordFreq 次）',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: GlassTheme.fBody,
                        fontWeight: FontWeight.w600,
                        color: GlassTheme.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (hasBoxes)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = kGap6;
                    const minCellW = 40.0;
                    const maxCellW = 120.0;
                    const minCellH = 22.0;
                    const naturalCellH = 42.0;
                    final maxW = constraints.maxWidth;
                    final maxH = constraints.maxHeight;
                    if (maxW <= 0 || maxH <= 0) return const SizedBox.shrink();

                    final n = textbookItems.length + years.length;
                    if (n <= 0) return const SizedBox.shrink();

                    // 年份与教材各自成段（教材永远从新行开始），因此列数按
                    // 两段共同的行数预算求解，保证总行数不超过面板可用高度。
                    int rowsFor(int cols) {
                      final ry =
                          years.isEmpty ? 0 : (years.length + cols - 1) ~/ cols;
                      final rt = textbookItems.isEmpty
                          ? 0
                          : (textbookItems.length + cols - 1) ~/ cols;
                      return ry + rt;
                    }

                    // 宽度能给到的最大列数（每格不小于最小可读宽度）
                    final colsMax =
                        ((maxW + gap) / (minCellW + gap)).floor().clamp(1, n).toInt();
                    // 高度能容纳的最大行数（每格不小于最小可读高度）
                    final rowsMax =
                        ((maxH + gap) / (minCellH + gap)).floor().clamp(1, n).toInt();

                    // 目标：年份段、教材段各自尽量压成一行（列数取两段中较长者），
                    // 列数越多行数越少；若行数仍超出高度预算，再向右加列。
                    final longestSection = years.length > textbookItems.length
                        ? years.length
                        : textbookItems.length;
                    var cols = colsMax < longestSection ? colsMax : longestSection;
                    while (cols < colsMax && rowsFor(cols) > rowsMax) {
                      cols++;
                    }
                    final rows = rowsFor(cols);
                    // 列数确定后按列均分宽度（含格间距）
                    // 高度按 rows 均分（下限 22、上限 42），保证整块收进面板

                    final cellW = ((maxW - (cols - 1) * gap) / cols)
                        .clamp(minCellW, maxCellW)
                        .toDouble();
                    // 行高按可用高度均分，并限制在「最小可读 ~ 设计自然高」之间；
                    // 高度充裕时保持自然高并整体居中（不拉成巨型方块）。
                    final cellH = ((maxH - (rows - 1) * gap) / rows)
                        .clamp(minCellH, naturalCellH)
                        .toDouble();

                    final yearCells = <Widget>[
                      for (final y in years)
                        KeyedSubtree(
                          key: ValueKey('year-cell-$y'),
                          child: _yearCell(
                            year: y,
                            count: yearCounts[y] ?? 0,
                            selected: selectedYear == y,
                            cellW: cellW,
                            cellH: cellH,
                            onTap: () => onSelectYear(y),
                          ),
                        ),
                    ];
                    final textbookCells = <Widget>[
                      for (final t in textbookItems)
                        KeyedSubtree(
                          key: ValueKey('textbook-cell-${t.path}'),
                          child: _textbookCell(
                            name: t.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
                            count: textbookCounts[t.path] ?? 0,
                            selected: selectedTextbook == t.path,
                            cellW: cellW,
                            cellH: cellH,
                            onTap: () => onSelectTextbook(t.path),
                          ),
                        ),
                    ];

                    // 用 Wrap 自动换行：宽度变化、年份/教材数量增加时按列数预算
                    // 自动折行，不需要手动切分行数组。
                    final grid = SizedBox(
                      width: maxW,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (yearCells.isNotEmpty)
                            Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              alignment: WrapAlignment.center,
                              children: yearCells,
                            ),
                          if (yearCells.isNotEmpty && textbookCells.isNotEmpty)
                            const SizedBox(height: gap),
                          if (textbookCells.isNotEmpty)
                            Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              alignment: WrapAlignment.center,
                              children: textbookCells,
                            ),
                        ],
                      ),
                    );

                    // 正常情况 rows*cellH 已收进面板高度，无需滚动；
                    // 仅在极端尺寸（如数百个教材格 + 极矮面板）且已缩到最小
                    // 可读格高时，才退回面板内滚动，绝不溢出到筛选行/结果表。
                    final contentHeight =
                        rows * cellH + (rows > 0 ? (rows - 1) * gap : 0);
                    return _ScrollableGrid(
                      viewportHeight: maxH,
                      scrollable: contentHeight > maxH + 0.5,
                      child: grid,
                    );
                  },
                ),
              ),
            if (selectedYear != null || selectedTextbook != null)
              Padding(
                padding: const EdgeInsets.only(top: kGap4),
                child: Wrap(
                  spacing: kGap12,
                  runSpacing: kGap4,
                  alignment: WrapAlignment.center,
                  children: [
                    if (selectedYear != null)
                      _clearChip(
                        '取消筛选· ${(selectedYear! % 100).toString().padLeft(2, '0')}年',
                        onClearYear,
                      ),
                    if (selectedTextbook != null)
                      _clearChip('取消筛选· $selectedTextbookName', onClearTextbook),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _textbookCell({
    required String name,
    required int count,
    required bool selected,
    required double cellW,
    required double cellH,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: GlassPressable(
        radius: GlassTheme.rMd,
        hoverColor: GlassTheme.accentSoft,
        pressColor: const Color(0x294462F2),
        enabled: count > 0,
        child: InkWell(
          onTap: count > 0 ? onTap : null,
          borderRadius: BorderRadius.circular(GlassTheme.rMd),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: cellW,
            height: cellH,
            padding: EdgeInsets.symmetric(
              horizontal: kGap4,
              vertical: _cellVerticalPadding(cellH),
            ),
            decoration: BoxDecoration(
              color: selected ? GlassTheme.accent : const Color(0x0F18181B),
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
              border: Border.all(color: Colors.transparent),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      name,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                        color: selected ? Colors.white : GlassTheme.ink2,
                      ),
                    ),
                  ),
                  SizedBox(height: _cellInnerGap(cellH)),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      color: selected ? Colors.white : GlassTheme.ink2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _yearCell({
    required int year,
    required int count,
    required bool selected,
    required double cellW,
    required double cellH,
    required VoidCallback onTap,
  }) {
    final label = (year % 100).toString().padLeft(2, '0');
    return Material(
      color: Colors.transparent,
      child: GlassPressable(
        radius: GlassTheme.rMd,
        hoverColor: GlassTheme.accentSoft,
        pressColor: const Color(0x294462F2),
        enabled: true,
        child: InkWell(
          onTap: count > 0 ? onTap : null,
          borderRadius: BorderRadius.circular(GlassTheme.rMd),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: cellW,
            height: cellH,
            padding: EdgeInsets.symmetric(
              horizontal: kGap6,
              vertical: _cellVerticalPadding(cellH),
            ),
            decoration: BoxDecoration(
              // 渐变只允许主按钮 / 徽标 / 选中胶囊三处，年份格有数据态用纯色淡靛蓝
              color: selected
                  ? GlassTheme.accent
                  : (count > 0 ? GlassTheme.accentSoft : const Color(0x73FFFFFF)),
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : (count > 0 ? const Color(0x334462F2) : Colors.transparent),
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      color: selected
                          ? Colors.white
                          : (count > 0 ? GlassTheme.accentInk : GlassTheme.ink2),
                    ),
                  ),
                  SizedBox(height: _cellInnerGap(cellH)),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      color: selected
                          ? Colors.white
                          : (count > 0 ? GlassTheme.accentInk : GlassTheme.ink2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 单元格高度收紧时同步压缩上下内边距，保证两行文字仍放得下且不溢出。
  double _cellVerticalPadding(double cellH) =>
      ((cellH - 23) / 2).clamp(0.5, kGap6);

  /// 行高不足 30 时进一步收紧标签与计数的间距。
  double _cellInnerGap(double cellH) => cellH >= 38 ? kGap4 : (cellH >= 30 ? 2 : 1);

  Widget _clearChip(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: GlassPressable(
        radius: 6,
        hoverColor: GlassTheme.accentSoft,
        pressColor: const Color(0x294462F2),
        enabled: true,
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: GlassTheme.accentInk),
        ),
      ),
    );
  }
}

/// 词频/教材筛选栅格的滚动容器。
///
/// 内容不足一屏时垂直居中且不显示滚动条；格子多到超出面板高度时
/// 显示常驻滚动条（教材整册/整文件夹导入时格子可达上百个）。
class _ScrollableGrid extends StatefulWidget {
  const _ScrollableGrid({
    required this.viewportHeight,
    required this.scrollable,
    required this.child,
  });

  final double viewportHeight;
  final bool scrollable;
  final Widget child;

  @override
  State<_ScrollableGrid> createState() => _ScrollableGridState();
}

class _ScrollableGridState extends State<_ScrollableGrid> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: widget.scrollable,
      child: SingleChildScrollView(
        controller: _controller,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: widget.viewportHeight),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}
