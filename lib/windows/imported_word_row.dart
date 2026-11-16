// 导入文档词表的一行（原 _buildImportedWordList 内嵌 itemBuilder 拆分）。
//
// 纯渲染组件：分类判定所需的最小上下文（当前筛选列、是否手工专有词）与
// 三个动作（打开/归类/移出）由父级下发，词库与筛选状态仍归 _MainWindowState。
import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';

class ImportedWordRow extends StatelessWidget {
  const ImportedWordRow({
    super.key,
    required this.word,
    required this.category,
    required this.frequency,
    required this.activeFilter,
    required this.color,
    required this.isEven,
    required this.showRemoveExtra,
    required this.onOpen,
    required this.onClassify,
    required this.onRemoveExtra,
    required this.onRemoveChaoGang,
  });

  final String word;
  final String category;
  final int frequency;

  /// 当前筛选列（真题词 / 未筛选 / 课标词 / 拓展词 / 超标词 / 专有词）
  final String activeFilter;
  final Color color;
  final bool isEven;

  /// 专有词且存在于手工专有词表时，显示「移出」而不是归类按钮
  final bool showRemoveExtra;

  final VoidCallback onOpen;
  final VoidCallback onClassify;
  final VoidCallback onRemoveExtra;
  final VoidCallback onRemoveChaoGang;

  @override
  Widget build(BuildContext context) {
    // 真题词列为叠加列：词库类别的词在语料中出现过时也会进入本列，
    // 此时只展示归属标签与频次，不出现筛选/移出入口
    final isZhentiColumn = activeFilter == '真题词';
    final isUnfilteredColumn = activeFilter == '未筛选';
    final isChaoGang = category == '超标词' && !isZhentiColumn;
    final isExtraCorpus = category == '专有词' && !isZhentiColumn;
    // 未归入任何词库的词（含语料中出现过的）：在未筛选列提供手动归类入口
    final isUnclassified = category == '未筛选' || category == '真题词';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: kGap8, vertical: kGap1),
      decoration: BoxDecoration(
        color: isEven ? const Color(0x0A18181B) : GlassTheme.panel,
        borderRadius: BorderRadius.circular(6),
      ),
      child: GlassPressable(
        radius: GlassTheme.rMd,
        hoverColor: const Color(0x0A18181B),
        pressColor: const Color(0x294462F2),
        enabled: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: isExtraCorpus ? null : onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: kGap10, vertical: kGap8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 分类彩色标签
                Container(
                  width: 2,
                  height: 22,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: kGap10),
                SizedBox(
                  width: 130,
                  child: Text(
                    word,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: GlassTheme.ink,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                const Spacer(),
                // ---- 未筛选：频次 + 筛选按钮 ----
                if (isUnfilteredColumn) ...[
                  _freqColumn(frequency, color),
                  const SizedBox(width: kGap6),
                  _classifyButton(),
                ]
                // ---- 专有词：标签 + 频次/筛选按钮 ----
                else if (isExtraCorpus) ...[
                  if (showRemoveExtra) ...[
                    _categoryTag('专有词', color),
                    const Spacer(),
                    _removeChip(color, onRemoveExtra),
                  ] else ...[
                    const Spacer(),
                    _classifyButton(),
                  ],
                ]
                // ---- 超标词：标签 + 频次 + 移出按钮 ----
                else if (isChaoGang) ...[
                  _categoryTag('超标词', color),
                  const Spacer(),
                  _removeChip(color, onRemoveChaoGang),
                  const Spacer(),
                  _freqColumn(frequency, color),
                ]
                // ---- 课标词 / 拓展词：标签 + 频次 ----
                else if (!isUnclassified) ...[
                  _categoryTag(category, color),
                  const Spacer(),
                  _freqColumn(frequency, color),
                ]
                // ---- 真题词列中的未归类词：仅频次（归类入口在未筛选列）----
                else ...[
                  _freqColumn(frequency, color),
                  const Spacer(),
                ],
                const SizedBox(width: kGap4),
                const Icon(
                  Icons.chevron_right,
                  size: 14,
                  color: GlassTheme.line,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _categoryTag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kGap8, vertical: kGap4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _freqColumn(int frequency, Color color) {
    return SizedBox(
      width: 56,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text(
            '频次',
            style: TextStyle(fontSize: 9, color: GlassTheme.ink3),
          ),
          Text(
            '$frequency',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _classifyButton() {
    return GlassPressable(
      radius: GlassTheme.rMd,
      hoverColor: const Color(0x0A18181B),
      pressColor: const Color(0x294462F2),
      enabled: true,
      child: InkWell(
        onTap: onClassify,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: kGap8, vertical: kGap4),
          decoration: BoxDecoration(
            color: GlassTheme.accentSoft,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: GlassTheme.accent.withValues(alpha: 0.4),
            ),
          ),
          child: const Text(
            '筛选',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: GlassTheme.accentInk,
            ),
          ),
        ),
      ),
    );
  }

  Widget _removeChip(Color color, VoidCallback onTap) {
    return GlassPressable(
      radius: GlassTheme.rSm,
      hoverColor: const Color(0x0A18181B),
      pressColor: const Color(0x294462F2),
      enabled: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '移出',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
