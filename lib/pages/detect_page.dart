import 'package:flutter/material.dart';
import 'dart:collection';
import '../theme/esw_tokens.dart';
import '../widgets/esw_widgets.dart';

/// 检测页历史条目（由父组件基于 _detectHistory 构造）。
class DetectHistoryItem {
  final String fileName;
  final String subtitle;
  final VoidCallback onTap;

  const DetectHistoryItem({
    required this.fileName,
    required this.subtitle,
    required this.onTap,
  });
}

/// 语料命中明细词条：单词 + 词性 + 分类（课标词 / 拓展词 / 超标词 / 专有词）。
/// 由父组件在后台 isolate 统计后经 DetectPage 透传，供年份格 / 教材格点击展开。
class CorpusHitWord {
  final String word;

  /// 词性（如 n. / v.）；拓展词 / 超标词 / 专有词无词性时为空串。
  final String pos;

  /// 分类：课标词 / 拓展词 / 超标词 / 专有词。
  final String category;

  const CorpusHitWord({
    required this.word,
    this.pos = '',
    this.category = '',
  });
}

/// 检测页：文本检测（分段导入 + 语料统计卡 + 文本域 + 开始分析）。
/// 纯视觉层重做，导入 / 分析业务逻辑由父组件回调驱动。
class DetectPage extends StatefulWidget {
  /// 已导入真题 / 教材数量；null 表示加载中。
  final int? corpusCount;
  final int? textbookCount;

  /// 按年份统计的真题语料词库命中单词数（{年份: 命中次数}）。
  /// null 表示统计中 / 加载中；空 Map 表示无年份数据。
  final Map<int, int>? yearHits;

  /// 按教材文件统计的教材语料词库命中单词数（{教材名(去扩展名): 命中次数}）。
  /// null 表示统计中 / 加载中；空 Map 表示无教材数据。
  final Map<String, int>? textbookHits;

  /// 按年份统计的真题命中明细（{年份: [单词 + 词性/分类]}），供年份格展开。
  final Map<int, List<CorpusHitWord>>? yearHitWords;

  /// 按教材统计的教材命中明细（{教材名(去扩展名): [单词 + 词性/分类]}）。
  final Map<String, List<CorpusHitWord>>? textbookHitWords;

  /// 四类词占比数据：[课标词, 拓展词, 超标词, 专有词]。
  final List<int> categoryCounts;

  final Future<void> Function() onImportCorpus;
  final Future<void> Function() onImportTextbook;
  final VoidCallback onImportFile;
  final TextEditingController pasteController;
  final FocusNode pasteFocus;
  final ValueChanged<String> onAnalyze;
  final List<DetectHistoryItem> history;
  final VoidCallback onClearHistory;

  const DetectPage({
    super.key,
    required this.corpusCount,
    required this.textbookCount,
    required this.yearHits,
    required this.textbookHits,
    required this.yearHitWords,
    required this.textbookHitWords,
    required this.categoryCounts,
    required this.onImportCorpus,
    required this.onImportTextbook,
    required this.onImportFile,
    required this.pasteController,
    required this.pasteFocus,
    required this.onAnalyze,
    required this.history,
    required this.onClearHistory,
  });

  @override
  State<DetectPage> createState() => _DetectPageState();
}

class _DetectPageState extends State<DetectPage> {
  int _segment = 0;

  /// 当前选中的年份格 / 教材格（互斥，null 表示未选中、明细收起）。
  int? _selectedYear;
  String? _selectedTextbook;

  /// 点击年份格：同一格再次点击取消选中，点击其它格切换。
  void _toggleYear(int year) {
    setState(() {
      _selectedYear = _selectedYear == year ? null : year;
      _selectedTextbook = null;
    });
  }

  /// 点击教材格：同一格再次点击取消选中，点击其它格切换。
  void _toggleTextbook(String name) {
    setState(() {
      _selectedTextbook = _selectedTextbook == name ? null : name;
      _selectedYear = null;
    });
  }

  void _clearHitSelection() {
    setState(() {
      _selectedYear = null;
      _selectedTextbook = null;
    });
  }

  void _onSegmentChanged(int index) {
    setState(() => _segment = index);
    if (index == 0) {
      widget.onImportCorpus();
    } else {
      widget.onImportTextbook();
    }
  }

  @override
  Widget build(BuildContext context) {
    final corpus = widget.corpusCount ?? 0;
    final textbook = widget.textbookCount ?? 0;
    final ready = (widget.corpusCount ?? -1) >= 0 &&
        (widget.textbookCount ?? -1) >= 0 &&
        (corpus > 0 || textbook > 0);
    final loading = widget.corpusCount == null || widget.textbookCount == null;

    return SafeArea(
      child: Column(
        children: [
          const EswPageHeader(
            title: '文本检测',
            subtitle: '粘贴或导入，自动比对你的词库',
          ),
          // 主内容固定布局（不再整页滚动）：分段 / 统计卡 / 文件按钮 / 粘贴框 /
          // 格式提示 / 主按钮始终完整可见，仅「最近检测」历史区在剩余空间内独立滚动。
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                EswSpace.lg,
                0,
                EswSpace.lg,
                EswSpace.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  EswSegmented(
                    options: const ['真题导入', '教材导入'],
                    selectedIndex: _segment,
                    onChanged: _onSegmentChanged,
                  ),
                  const SizedBox(height: EswSpace.sm),
                  _CorpusStatCard(
                    corpus: corpus,
                    textbook: textbook,
                    yearHits: widget.yearHits,
                    textbookHits: widget.textbookHits,
                    yearHitWords: widget.yearHitWords,
                    textbookHitWords: widget.textbookHitWords,
                    selectedYear: _selectedYear,
                    selectedTextbook: _selectedTextbook,
                    onSelectYear: _toggleYear,
                    onSelectTextbook: _toggleTextbook,
                    onCloseDetail: _clearHitSelection,
                    loading: loading,
                    ready: ready,
                  ),
                  const SizedBox(height: EswSpace.sm),
                  EswDashedButton(
                    label: '选择文件检测',
                    icon: Icons.folder_open_rounded,
                    onPressed: widget.onImportFile,
                  ),
                  const SizedBox(height: EswSpace.sm),
                  // 粘贴框按剩余空间弹性伸缩（小屏自动收缩，不溢出）
                  Expanded(
                    flex: 3,
                    child: _PasteCard(
                      controller: widget.pasteController,
                      focusNode: widget.pasteFocus,
                    ),
                  ),
                  const SizedBox(height: EswSpace.xs),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '格式：.txt / .doc / .docx / .pdf',
                        style: EswText.bodySmall,
                      ),
                      Text(
                        '大小上限：200MB',
                        style: EswText.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: EswSpace.md),
                  EswPrimaryButton(
                    label: '开始分析',
                    icon: Icons.analytics_outlined,
                    onPressed: () =>
                        widget.onAnalyze(widget.pasteController.text),
                  ),
                  if (widget.history.isNotEmpty) ...[
                    const SizedBox(height: EswSpace.md),
                    EswSectionHeader(
                      title: '最近检测',
                      actionLabel: '清空',
                      onAction: widget.onClearHistory,
                    ),
                    const SizedBox(height: EswSpace.xs),
                    // 历史区是唯一可滚动区域，长度超出时在自身区域内滚动
                    Expanded(
                      flex: 4,
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: widget.history.length,
                        itemBuilder: (context, index) {
                          final item = widget.history[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: EswSpace.sm),
                            child: EswCard(
                              padding: EdgeInsets.zero,
                              onTap: item.onTap,
                              child: EswListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: EswColors.primarySoft,
                                    borderRadius: BorderRadius.circular(
                                      EswRadius.small,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.description_outlined,
                                    size: 20,
                                    color: EswColors.primary,
                                  ),
                                ),
                                title: item.fileName,
                                subtitle: item.subtitle,
                                trailing: Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: EswColors.textSecondary,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 语料统计卡：标签 + 状态胶囊 + 按年份命中单词数年份框 + 教材命中格
/// （参考桌面版年份格：教材格在前、年份格在后等宽排列）。
class _CorpusStatCard extends StatelessWidget {
  final int corpus;
  final int textbook;
  final Map<int, int>? yearHits;
  final Map<String, int>? textbookHits;
  final Map<int, List<CorpusHitWord>>? yearHitWords;
  final Map<String, List<CorpusHitWord>>? textbookHitWords;
  final int? selectedYear;
  final String? selectedTextbook;
  final ValueChanged<int> onSelectYear;
  final ValueChanged<String> onSelectTextbook;
  final VoidCallback onCloseDetail;
  final bool loading;
  final bool ready;

  const _CorpusStatCard({
    required this.corpus,
    required this.textbook,
    required this.yearHits,
    required this.textbookHits,
    required this.yearHitWords,
    required this.textbookHitWords,
    required this.selectedYear,
    required this.selectedTextbook,
    required this.onSelectYear,
    required this.onSelectTextbook,
    required this.onCloseDetail,
    required this.loading,
    required this.ready,
  });

  @override
  Widget build(BuildContext context) {
    final totalHits = yearHits == null
        ? 0
        : yearHits!.values.fold<int>(0, (a, b) => a + b);
    final totalTextbookHits = textbookHits == null
        ? 0
        : textbookHits!.values.fold<int>(0, (a, b) => a + b);

    // 当前展开的明细：年份格优先，其次教材格；标题带命中单词数（去重后）。
    final selectedWords = selectedYear != null
        ? (yearHitWords?[selectedYear!] ?? const <CorpusHitWord>[])
        : (selectedTextbook != null
              ? (textbookHitWords?[selectedTextbook!] ?? const <CorpusHitWord>[])
              : null);
    final detailTitle = selectedYear != null
        ? '$selectedYear 年命中单词（${selectedWords!.length}）'
        : (selectedTextbook != null
              ? '$selectedTextbook 命中单词（${selectedWords!.length}）'
              : null);
    final detailEmptyHint = selectedYear != null
        ? '该年份暂无命中单词'
        : '该教材暂无命中单词';

    return EswCard(
      padding: const EdgeInsets.all(EswSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '已导入语料',
                style: EswText.bodyMedium.copyWith(color: EswColors.textPrimary),
              ),
              const Spacer(),
              if (loading)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: EswSpace.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: EswColors.primarySoft,
                    borderRadius: BorderRadius.circular(EswRadius.small),
                  ),
                  child: Text(
                    '加载中…',
                    style: EswText.chip.copyWith(color: EswColors.primary),
                  ),
                )
              else if (ready)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: EswSpace.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: EswColors.green.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(EswRadius.small),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: EswColors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: EswSpace.xs),
                      Text(
                        '已就绪',
                        style: EswText.chip.copyWith(color: EswColors.green),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: EswSpace.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: EswColors.primarySoft,
                    borderRadius: BorderRadius.circular(EswRadius.small),
                  ),
                  child: Text(
                    '待导入',
                    style: EswText.chip.copyWith(color: EswColors.primary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: EswSpace.sm),
          Text(
            '共 $corpus 份真题 · $textbook 份教材 · 真题命中 $totalHits 次 · 教材命中 $totalTextbookHits 次',
            style: EswText.caption.copyWith(color: EswColors.textSecondary),
          ),
          const SizedBox(height: EswSpace.sm),
          // 年份格区限高 + 内部滚动：年份/教材较多时不把整页撑高
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 104),
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: _YearHitGrid(
                yearHits: yearHits,
                textbookHits: textbookHits,
                selectedYear: selectedYear,
                selectedTextbook: selectedTextbook,
                onSelectYear: onSelectYear,
                onSelectTextbook: onSelectTextbook,
              ),
            ),
          ),
          // 选中格后在卡片下方展开明细区（限高 160，内部滚动，不撑高整页）
          if (detailTitle != null) ...[
            const SizedBox(height: EswSpace.sm),
            _HitDetailPanel(
              title: detailTitle,
              words: selectedWords!,
              emptyHint: detailEmptyHint,
              onClose: onCloseDetail,
            ),
          ],
        ],
      ),
    );
  }
}

/// 命中数格子区：教材格在前 + 年份格在后，等宽 56 排列
/// （参考桌面版"词频年份 + 教材分布"样式：圆角 4、浅蓝底 + 蓝边框，
/// 格内两行显示名称/年份后两位与命中次数；加载中 / 无数据显示空态提示）。
class _YearHitGrid extends StatelessWidget {
  final Map<int, int>? yearHits;
  final Map<String, int>? textbookHits;
  final int? selectedYear;
  final String? selectedTextbook;
  final ValueChanged<int> onSelectYear;
  final ValueChanged<String> onSelectTextbook;

  const _YearHitGrid({
    required this.yearHits,
    required this.textbookHits,
    required this.selectedYear,
    required this.selectedTextbook,
    required this.onSelectYear,
    required this.onSelectTextbook,
  });

  @override
  Widget build(BuildContext context) {
    if (yearHits == null || textbookHits == null) {
      return const _YearGridEmpty(text: '正在统计真题与教材命中单词数…');
    }
    if (yearHits!.isEmpty && textbookHits!.isEmpty) {
      return const _YearGridEmpty(
        text: '暂无年份数据，请导入以年份开头的真题文件（如 2023全国卷.txt）或教材文件',
      );
    }
    final sortedYears = SplayTreeMap<int, int>.from(yearHits!).keys.toList();
    return Wrap(
      spacing: EswSpace.sm,
      runSpacing: EswSpace.sm,
      children: [
        // 教材格在前（按教材名排序，稳定展示）
        for (final entry in textbookHits!.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
          _HitGridCell(
            label: entry.key,
            count: entry.value,
            selected: selectedTextbook == entry.key,
            onTap: () => onSelectTextbook(entry.key),
          ),
        for (final y in sortedYears)
          _HitGridCell(
            label: (y % 100).toString().padLeft(2, '0'),
            count: yearHits![y] ?? 0,
            selected: selectedYear == y,
            onTap: () => onSelectYear(y),
          ),
      ],
    );
  }
}

/// 单个命中格（年份 / 教材通用）：圆角 4，未选中浅蓝底 + 蓝边框，
/// 选中态蓝底白字（对齐桌面版选中样式）；两行显示名称/年份后两位与命中次数。
/// 点击回调由父组件切换选中态，再次点击同一格取消。
class _HitGridCell extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _HitGridCell({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = count > 0;
    final fgColor = selected
        ? EswColors.card
        : (hasData ? EswColors.primary : EswColors.textSecondary);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 56,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? EswColors.primary
              : (hasData
                    ? EswColors.primary.withValues(alpha: 0.08)
                    : EswColors.grey.withValues(alpha: 0.08)),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? EswColors.primary
                : (hasData ? EswColors.primary : EswColors.border),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: EswText.caption.copyWith(color: fgColor),
            ),
            const SizedBox(height: 3),
            Text(
              '$count',
              style: EswText.bodyMedium.copyWith(
                fontWeight: FontWeight.w600,
                color: fgColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 命中明细展开区（年份格 / 教材格共用）：标题 + 逐行「单词 + 词性/分类」。
/// 明细列表限高 160 并在内部滚动，保证整页仍是一屏布局。
class _HitDetailPanel extends StatelessWidget {
  final String title;
  final List<CorpusHitWord> words;
  final String emptyHint;
  final VoidCallback onClose;

  const _HitDetailPanel({
    required this.title,
    required this.words,
    required this.emptyHint,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(EswSpace.sm),
      decoration: BoxDecoration(
        color: EswColors.page,
        borderRadius: BorderRadius.circular(EswRadius.small),
        border: Border.all(color: EswColors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EswText.chip.copyWith(color: EswColors.primary),
                ),
              ),
              GestureDetector(
                onTap: onClose,
                behavior: HitTestBehavior.opaque,
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: EswColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: EswSpace.xs),
          if (words.isEmpty)
            Text(
              emptyHint,
              style: EswText.bodySmall.copyWith(
                color: EswColors.textSecondary,
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: words.length,
                itemBuilder: (context, index) => _HitWordRow(item: words[index]),
              ),
            ),
        ],
      ),
    );
  }
}

/// 明细行：左侧单词 + 词性，右侧分类胶囊。
class _HitWordRow extends StatelessWidget {
  final CorpusHitWord item;

  const _HitWordRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    item.word,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EswText.bodySmall.copyWith(
                      color: EswColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (item.pos.isNotEmpty) ...[
                  const SizedBox(width: EswSpace.xs),
                  Text(
                    item.pos,
                    style: EswText.caption.copyWith(
                      color: EswColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (item.category.isNotEmpty) ...[
            const SizedBox(width: EswSpace.sm),
            _CategoryChip(label: item.category),
          ],
        ],
      ),
    );
  }
}

/// 分类胶囊：按词性分类着色（课标 / 拓展 / 超标 / 专有），颜色全部走 EswTokens。
class _CategoryChip extends StatelessWidget {
  final String label;

  const _CategoryChip({required this.label});

  Color get _color {
    switch (label) {
      case '拓展词':
        return EswColors.blue;
      case '超标词':
        return EswColors.orange;
      case '专有词':
        return EswColors.grey;
      default:
        return EswColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: EswSpace.xs, vertical: 1),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: EswText.caption.copyWith(
          color: _color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 年份框空态 / 加载态提示。
class _YearGridEmpty extends StatelessWidget {
  final String text;

  const _YearGridEmpty({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: EswSpace.md,
        vertical: EswSpace.lg,
      ),
      decoration: BoxDecoration(
        color: EswColors.page,
        borderRadius: BorderRadius.circular(EswRadius.small),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
      ),
    );
  }
}

/// 粘贴文本域卡片：白底圆角 + 实时计数 0 / 20000。
/// 高度由外层 Expanded 决定，输入区随剩余空间弹性伸缩（小屏不溢出）。
class _PasteCard extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  const _PasteCard({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        EswSpace.md,
        EswSpace.sm,
        EswSpace.md,
        EswSpace.xs,
      ),
      decoration: BoxDecoration(
        color: EswColors.card,
        borderRadius: BorderRadius.circular(EswRadius.card),
        border: Border.all(color: EswColors.border, width: 1),
        boxShadow: EswShadow.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
              minLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: EswText.bodyMedium.copyWith(color: EswColors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: '粘贴需要检测的文本，或使用上方「选择文件检测」导入…',
                hintStyle: EswText.bodySmall.copyWith(
                  color: EswColors.textSecondary,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: EswSpace.xs),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final len = value.text.length;
              return Align(
                alignment: Alignment.bottomRight,
                child: Text(
                  '$len / 20000',
                  style: EswText.bodySmall.copyWith(
                    color: len >= 20000
                        ? EswColors.red
                        : EswColors.textSecondary,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
