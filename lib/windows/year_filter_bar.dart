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
        padding: const EdgeInsets.fromLTRB(kGap16, kGap12, kGap16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: kGap8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '词频年份 ($yearTotal 次) 与教材分布($textbookTotal 次)',
                      textAlign: TextAlign.left,
                      style: const TextStyle(
                        fontSize: GlassTheme.fBody,
                        fontWeight: FontWeight.w600,
                        color: GlassTheme.ink,
                      ),
                    ),
                  ),
                  const Text(
                    '检测后自动标注高频年份',
                    style: TextStyle(
                      fontSize: GlassTheme.fMicro,
                      color: GlassTheme.ink3,
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
                    final maxW = constraints.maxWidth;
                    final maxH = constraints.maxHeight;
                    if (maxW <= 0 || maxH <= 0) return const SizedBox.shrink();

                    final n = textbookItems.length + years.length;
                    if (n <= 0) return const SizedBox.shrink();

                    // 该宽度下最多能放几列（每格不小于最小可读格宽），再按设计基准 13 列封顶
                    final colsFit = ((maxW + gap) / (minCellW + gap)).floor();
                    final int colsRaw =
                        colsFit.clamp(1, n < 13 ? n : 13).toInt();
                    // 刚好需要两行时均分列数，避免出现「11+1」这种孤格、整体不对称
                    final int rowsNeeded = (n / colsRaw).ceil();
                    final int cols = (rowsNeeded == 2 && n > colsRaw)
                        ? (n / 2).ceil()
                        : colsRaw;
                    var cellW = ((maxW - (cols - 1) * gap) / cols)
                        .clamp(minCellW, maxCellW)
                        .toDouble();
                    // 极窄窗口单列时仍需保证不横向溢出
                    if (cellW > maxW) cellW = maxW;

                    // 年份格排在教材格之前：教材文件可能很多（整册/整文件夹导入），
                    // 年份作为主要筛选维度必须始终可见，不能被挤到滚动区下方。
                    final yearBoxes = <Widget>[
                      for (final y in years)
                        _yearCell(
                          year: y,
                          count: yearCounts[y] ?? 0,
                          selected: selectedYear == y,
                          cellW: cellW,
                          onTap: () => onSelectYear(y),
                        ),
                    ];
                    final textbookBoxes = <Widget>[
                      for (final t in textbookItems)
                        _textbookCell(
                          name: t.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
                          count: textbookCounts[t.path] ?? 0,
                          selected: selectedTextbook == t.path,
                          cellW: cellW,
                          onTap: () => onSelectTextbook(t.path),
                        ),
                    ];

                    // 年份与教材各自成行：教材格永远从新的一行开始，不与年份格混排
                    final rows = <Widget>[];
                    void addRows(List<Widget> cells) {
                      for (var i = 0; i < cells.length; i += cols) {
                        final end = (i + cols).clamp(i, cells.length);
                        rows.add(
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            spacing: gap,
                            children: cells.sublist(i, end),
                          ),
                        );
                      }
                    }

                    addRows(yearBoxes);
                    addRows(textbookBoxes);
                    final grid = Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const SizedBox(height: gap),
                          rows[i],
                        ],
                      ],
                    );
                    // 不再用 FittedBox 整体缩放：格子数量多时按比例缩到几个像素会
                    // 完全不可读（用户反馈「年份框都乱了」）。改为保持最小可读格宽，
                    // 超出可用高度时在面板内纵向滚动；内容不足一屏时垂直居中。
                    // 行高按两行文字 + 上下内边距估算（约 42），用于判断是否需要滚动条。
                    final rowsHeight = rows.length * 42.0 + (rows.length - 1) * gap;
                    return _ScrollableGrid(
                      viewportHeight: maxH,
                      scrollable: rowsHeight > maxH,
                      child: SizedBox(width: maxW, child: grid),
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
            padding: const EdgeInsets.symmetric(horizontal: kGap4, vertical: kGap6),
            decoration: BoxDecoration(
              color: selected ? GlassTheme.violet : const Color(0x0F18181B),
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
              border: Border.all(color: Colors.transparent),
            ),
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
                const SizedBox(height: kGap4),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : GlassTheme.ink2,
                  ),
                ),
              ],
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
            padding: const EdgeInsets.symmetric(horizontal: kGap6, vertical: kGap6),
            decoration: BoxDecoration(
              // 渐变只允许主按钮 / 徽标 / 选中胶囊三处，年份格有数据态用纯色淡靛蓝
              color: selected
                  ? GlassTheme.violet
                  : (count > 0 ? GlassTheme.accentSoft : const Color(0x73FFFFFF)),
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : (count > 0 ? const Color(0xFFC7D2FE) : Colors.transparent),
              ),
            ),
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
                const SizedBox(height: kGap4),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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
    );
  }

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
