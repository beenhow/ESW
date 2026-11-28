/// 安卓端词汇检测报告页：消费与 Windows / 导出同一份 [VocabReportData]，
/// 只做移动端排版，不重新计算任何数字。
library;

import 'package:flutter/material.dart';

import '../shared/vocab_report.dart';
import '../theme/app_theme.dart';

class MobileVocabReportPage extends StatelessWidget {
  const MobileVocabReportPage({super.key, required this.data});

  final VocabReportData data;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceLight,
      appBar: AppBar(
        backgroundColor: AppTheme.surfaceLight,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('词汇检测报告', style: TextStyle(fontSize: 16)),
            Text(
              data.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _overview(),
          const SizedBox(height: 8),
          _conclusion(),
          const SizedBox(height: 12),
          for (final g in data.groups) ...[
            _groupHead(g),
            for (var i = 0; i < g.words.length; i++)
              _wordCard(g.words[i], i + 1),
            const SizedBox(height: 10),
          ],
          Text(
            '统计口径：词符按全文切词计数；「原句」为该词在本次导入原文中首次出现的句子，'
            '真题 / 教材例句与「导出高频」共用同一择优实现。',
            style: TextStyle(
              fontSize: 10.5,
              height: 1.5,
              color: AppTheme.textHint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _overview() {
    Widget kpi(String label, String value, String foot) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE4E4E7)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 10, color: AppTheme.textSecondary)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                Text(foot,
                    maxLines: 2,
                    style: const TextStyle(
                        fontSize: 9, color: AppTheme.textHint)),
              ],
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(data.title,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 6),
        Row(
          children: [
            kpi('词符 TOTAL', '${data.totalTokens}', '去重词形 ${data.distinctTypes}'),
            const SizedBox(width: 6),
            kpi('课标覆盖率', '${(data.coverage * 100).toStringAsFixed(1)}%',
                '课标+拓展 ${data.standardTokens + data.extendTokens} 次'),
            const SizedBox(width: 6),
            kpi('超标词', '${data.overTokens}',
                '占 ${(data.overRatio * 100).toStringAsFixed(1)}%'),
          ],
        ),
      ],
    );
  }

  Widget _conclusion() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F6FB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE0E5F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(data.conclusion,
              style: const TextStyle(
                  fontSize: 11.5, height: 1.55, color: AppTheme.textPrimary)),
          const SizedBox(height: 6),
          Text('建议：${data.advice}',
              style: const TextStyle(
                  fontSize: 11.5, height: 1.55, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _groupHead(VocabReportGroup g) {
    final color = Color(g.colorValue);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${g.name}（${g.wordCount} 个词 · 本篇 ${g.tokenCount} 次）',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: color)),
          const SizedBox(height: 2),
          Text(g.note,
              style: const TextStyle(
                  fontSize: 10, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _tag(String text, String kind) {
    Color bg;
    Color fg;
    switch (kind) {
      case 'key':
        bg = AppTheme.primaryBlue;
        fg = Colors.white;
        break;
      case 'mid':
        bg = const Color(0xFFE8F1FF);
        fg = AppTheme.primaryBlue;
        break;
      case 'warn':
        bg = const Color(0xFFFFEFEF);
        fg = const Color(0xFFC92A2A);
        break;
      default:
        bg = const Color(0xFFF1F3F5);
        fg = AppTheme.textSecondary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 9.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Widget _wordCard(VocabReportWord w, int index) {
    final o = w.textExample;
    final q = w.questionExample;
    final t = w.textbookExample;
    Widget line(String kind, String? text, String empty, Color color) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(kind,
                  style: TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w700, color: color)),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                text ?? empty,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: text == null ? AppTheme.textHint : AppTheme.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFE9E9EC)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Text('$index.',
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.textHint)),
            const SizedBox(width: 4),
            Text(w.word,
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F3F5),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(w.badge,
                  style: const TextStyle(
                      fontSize: 9, color: AppTheme.textSecondary)),
            ),
            const Spacer(),
            _tag(w.suggestionTag, w.suggestionKind),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '真题 ${w.corpusFreq} 次 · 本篇 ${w.textFreq} 次 · '
            '教材 ${w.textbookHits}/${w.textbookCounts.length} 版本',
            style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
          ),
        ),
        children: [
          line('原句', o?.text, '原文未定位到该词形', const Color(0xFFB45309)),
          line('真题', q?.text, '真题语料未收录该词形', AppTheme.primaryBlue),
          line('教材', t?.text, '${w.textbookCounts.length} 套教材均未覆盖',
              const Color(0xFF0F766E)),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text('建议依据：${w.suggestionWhy}',
                style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.45,
                    color: AppTheme.textSecondary)),
          ),
        ],
      ),
    );
  }
}
