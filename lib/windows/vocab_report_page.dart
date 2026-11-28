// 词汇检测报告页（检测页 → 报告页 → 明细/导出 三级中的第二级）。
//
// 只负责渲染 [VocabReportData]：所有数字由 shared/vocab_report.dart 统一组装，
// 与「导出高频」共用词族 / 分词 / 例句择优口径，页面与导出不会出现两套数字。
import 'package:flutter/material.dart';

import '../shared/vocab_report.dart';
import '../theme/app_theme.dart';
import '../theme/glass_theme.dart';

/// 渲染一条可点击的词行扁平项。
sealed class _ReportRow {
  const _ReportRow();
}

class _GroupRow extends _ReportRow {
  final VocabReportGroup group;
  const _GroupRow(this.group);
}

class _WordRow extends _ReportRow {
  final VocabReportWord word;
  final int index;
  const _WordRow(this.word, this.index);
}

class VocabReportPage extends StatelessWidget {
  const VocabReportPage({
    super.key,
    required this.data,
    required this.onBack,
    required this.onExport,
    required this.onOpenWord,
  });

  final VocabReportData data;
  final VoidCallback onBack;
  final VoidCallback onExport;
  final void Function(String word) onOpenWord;

  @override
  Widget build(BuildContext context) {
    final rows = _flatten(data);
    return Container(
      key: const ValueKey('region-vocab-report'),
      margin: const EdgeInsets.fromLTRB(kGap20, kGap8, kGap20, kGap16),
      decoration: BoxDecoration(
        color: const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(GlassTheme.rXl),
        border: Border.all(color: GlassTheme.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildHeader(),
          const Divider(height: 1, color: GlassTheme.line),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(kGap16, kGap12, kGap16, kGap12),
              itemCount: rows.length + 2,
              itemBuilder: (context, i) {
                if (i == 0) return _buildOverview();
                if (i == 1) return _buildTableHead();
                final row = rows[i - 2];
                return switch (row) {
                  _GroupRow g => _buildGroupHead(g.group),
                  _WordRow w => _buildWordRow(w),
                };
              },
            ),
          ),
        ],
      ),
    );
  }

  static List<_ReportRow> _flatten(VocabReportData d) {
    final rows = <_ReportRow>[];
    var idx = 0;
    for (final g in d.groups) {
      rows.add(_GroupRow(g));
      for (final w in g.words) {
        idx++;
        rows.add(_WordRow(w, idx));
      }
    }
    return rows;
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kGap12, kGap8, kGap12, kGap8),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 14),
            label: const Text('返回检测', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: GlassTheme.accentInk,
              padding: const EdgeInsets.symmetric(
                  horizontal: kGap8, vertical: kGap4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: kGap8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: GlassTheme.ink,
                  ),
                ),
                Text(
                  data.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: GlassTheme.ink2),
                ),
              ],
            ),
          ),
          const SizedBox(width: kGap8),
          FilledButton.icon(
            onPressed: onExport,
            icon: const Icon(Icons.file_download_outlined, size: 15),
            label: const Text('导出报告', style: TextStyle(fontSize: 11)),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: kGap12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverview() {
    final total = data.totalTokens == 0 ? 1 : data.totalTokens;
    final avg = data.distinctTypes == 0
        ? '0'
        : (data.totalTokens / data.distinctTypes).toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.only(bottom: kGap8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _kpi('词符总数 TOKENS', _fmt(data.totalTokens), '含重复，全文切词口径'),
              const SizedBox(width: kGap8),
              _kpi('去重词形 TYPES', _fmt(data.distinctTypes), '平均每词形复现 $avg 次'),
              const SizedBox(width: kGap8),
              Expanded(
                child: _kpiHero(
                  '课标词覆盖率',
                  (data.coverage * 100).toStringAsFixed(1),
                  '%',
                  '课标词 ${_fmt(data.standardTokens + data.extendTokens)} 次 · 超标 ${_fmt(data.overTokens)} 次',
                  data.coverage,
                ),
              ),
              const SizedBox(width: kGap8),
              _kpi(
                '超标词',
                _fmt(data.overTokens),
                '占 ${(data.overRatio * 100).toStringAsFixed(1)}% · 表外实词',
                unit: '次',
              ),
            ],
          ),
          const SizedBox(height: kGap8),
          _buildComposition(total),
          const SizedBox(height: kGap8),
          _buildLevelRow(),
          const SizedBox(height: kGap8),
          _buildConclusion(),
        ],
      ),
    );
  }

  Widget _kpi(String label, String value, String foot, {String? unit}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6F8),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 9.5, color: GlassTheme.ink2)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: GlassTheme.ink,
                    height: 1.15,
                  ),
                ),
                if (unit != null)
                  Text(
                    unit,
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: GlassTheme.ink2,
                    ),
                  ),
              ],
            ),
            Text(foot,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, color: GlassTheme.ink2)),
          ],
        ),
      ),
    );
  }

  Widget _kpiHero(String label, String value, String unit, String foot,
      double ratio) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: GlassTheme.accentSoft,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: GlassTheme.accentLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 9.5, color: GlassTheme.ink2)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: GlassTheme.accentInk,
                  height: 1.15,
                ),
              ),
              Text(
                unit,
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: GlassTheme.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: const Color(0x244462F2),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(GlassTheme.accent),
            ),
          ),
          const SizedBox(height: 3),
          Text(foot,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9.5, color: GlassTheme.ink2)),
        ],
      ),
    );
  }

  Widget _buildComposition(int total) {
    final segments = <(String, int, Color)>[
      ('课标', data.standardTokens, const Color(0xFF2F6BDF)),
      ('拓展', data.extendTokens, const Color(0xFF2F9E44)),
      ('超标', data.overTokens, const Color(0xFFE03131)),
      ('专有', data.properTokens, const Color(0xFF6B7280)),
      ('未筛选', data.unfilteredTokens, const Color(0xFF7048E8)),
    ].where((e) => e.$2 > 0).toList();
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  for (final s in segments)
                    Expanded(
                      flex: (s.$2 * 1000 / total).round().clamp(1, 1000000).toInt(),
                      child: ColoredBox(color: s.$3),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: kGap12),
        Flexible(
          flex: 3,
          child: Wrap(
            spacing: kGap8,
            runSpacing: 3,
            children: [
              for (final s in segments)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: s.$3,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${s.$1} ${(s.$2 * 100 / total).toStringAsFixed(1)}%',
                      style: const TextStyle(
                          fontSize: 9.5, color: GlassTheme.ink2),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLevelRow() {
    Widget item(String label, int n) => RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 10, color: GlassTheme.ink2),
            children: [
              TextSpan(text: '$label '),
              TextSpan(
                text: _fmt(n),
                style: const TextStyle(
                  color: GlassTheme.accentInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(text: ' 次'),
            ],
          ),
        );
    return Wrap(
      spacing: kGap12,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text(
          '课标词分级',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: GlassTheme.ink,
          ),
        ),
        item('初中', data.levelCounts['初中'] ?? 0),
        item('必修', data.levelCounts['必修'] ?? 0),
        item('选修', data.levelCounts['选修'] ?? 0),
        item('拓展变体', data.extendTokens),
        const Text(
          '分级只统计课标词，拓展变体单列，避免双重计数',
          style: TextStyle(fontSize: 9, color: GlassTheme.ink3),
        ),
      ],
    );
  }

  Widget _buildConclusion() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: GlassTheme.accentSoft,
        border: Border(
          left: BorderSide(color: GlassTheme.accent, width: 3),
        ),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            data.conclusion,
            style: const TextStyle(
              fontSize: 11.2,
              height: 1.6,
              color: Color(0xFF2A2E3A),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            data.advice,
            style: const TextStyle(
              fontSize: 10.8,
              height: 1.5,
              color: GlassTheme.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHead() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: kGap6, horizontal: kGap6),
      decoration: const BoxDecoration(
        color: Color(0xFFF1F2F5),
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      child: const Row(
        children: [
          Expanded(flex: 1, child: _TH('#')),
          Expanded(flex: 3, child: _TH('词条')),
          Expanded(flex: 3, child: _TH('真题频次')),
          Expanded(flex: 3, child: _TH('教材覆盖')),
          Expanded(flex: 7, child: _TH('例句（真题 / 教材）')),
          Expanded(flex: 3, child: _TH('处理建议')),
        ],
      ),
    );
  }

  Widget _buildGroupHead(VocabReportGroup g) {
    final color = Color(g.colorValue);
    return Container(
      margin: const EdgeInsets.only(top: kGap8),
      padding: const EdgeInsets.fromLTRB(kGap8, kGap6, kGap8, kGap6),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFBFD),
        border: Border(
          left: BorderSide(color: color, width: 3),
          top: BorderSide(color: GlassTheme.line),
          bottom: BorderSide(color: GlassTheme.line),
        ),
      ),
      child: Row(
        children: [
          Text(
            g.name,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Container(
            margin: const EdgeInsets.only(left: 7),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: GlassTheme.line),
            ),
            child: Text(
              '${g.wordCount} 个词 · 本篇 ${g.tokenCount} 次',
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: GlassTheme.ink,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              g.note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9.5, color: GlassTheme.ink2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWordRow(_WordRow row) {
    final w = row.word;
    final color = _badgeColor(w);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpenWord(w.word),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: kGap6, horizontal: kGap6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: GlassTheme.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 序号
            Expanded(
              flex: 1,
              child: Text(
                '${row.index}',
                style: const TextStyle(fontSize: 9, color: GlassTheme.ink3),
              ),
            ),
            // 词条
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    children: [
                      Text(
                        w.word,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: GlassTheme.ink,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 3, vertical: 0.5),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          w.badge,
                          style: TextStyle(
                            fontSize: 8.4,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (w.familyFreq > w.textFreq)
                    Text(
                      '词族 ${_fmt(w.familyFreq)} 次',
                      style: const TextStyle(
                          fontSize: 9, color: GlassTheme.ink3),
                    ),
                ],
              ),
            ),
            // 真题频次
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _fmt(w.corpusFreq),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: GlassTheme.ink,
                        ),
                      ),
                      const Text(
                        '次',
                        style:
                            TextStyle(fontSize: 8.6, color: GlassTheme.ink2),
                      ),
                    ],
                  ),
                  Text(
                    '${w.yearHits} 年命中 · 本篇 ${w.textFreq} 次',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, color: GlassTheme.ink2),
                  ),
                  if (w.yearCounts.isNotEmpty) _spark(w.yearCounts),
                ],
              ),
            ),
            // 教材覆盖
            Expanded(flex: 3, child: _bookCell(w)),
            // 例句
            Expanded(flex: 7, child: _exampleCell(w)),
            // 处理建议
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _suggestTag(w),
                  const SizedBox(height: 3),
                  Text(
                    w.suggestionWhy,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 8.8, height: 1.3, color: GlassTheme.ink2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _spark(List<int> counts) {
    final maxV = counts.fold<int>(0, (m, v) => v > m ? v : m);
    return Container(
      height: 18,
      margin: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in counts)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 1),
                child: Container(
                  height: v <= 0 || maxV == 0 ? 2.0 : 3.0 + (v / maxV * 14),
                  decoration: BoxDecoration(
                    color: v <= 0
                        ? const Color(0x1F18181B)
                        : GlassTheme.accent.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bookCell(VocabReportWord w) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 2.5,
          runSpacing: 2.5,
          children: [
            for (var i = 0; i < w.textbookCounts.length; i++)
              Tooltip(
                message:
                    '${i < data.textbookNames.length ? data.textbookNames[i] : '教材'} ${w.textbookCounts[i]} 次',
                waitDuration: const Duration(milliseconds: 400),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: w.textbookCounts[i] > 0
                        ? const Color(0xFF22C55E)
                        : const Color(0x1A18181B),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${w.textbookHits}/${w.textbookCounts.length} 版本 · ${w.textbookTotal} 次',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 9, color: GlassTheme.ink2),
        ),
      ],
    );
  }

  Widget _exampleCell(VocabReportWord w) {
    final q = w.questionExample;
    final t = w.textbookExample;
    final o = w.textExample;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _exampleLine(
          kind: '原句',
          text: o?.text,
          source: null,
          empty: '原文未定位到该词形',
          isOriginal: true,
        ),
        const SizedBox(height: 3),
        _exampleLine(
          kind: '真题',
          text: q?.text,
          source: q?.source,
          empty: '真题语料未收录该词形',
        ),
        const SizedBox(height: 3),
        _exampleLine(
          kind: '教材',
          text: t?.text,
          source: t?.source,
          empty: '${w.textbookCounts.length} 套教材均未覆盖 —— 可作为教学缺口信号',
          isTextbook: true,
        ),
      ],
    );
  }

  Widget _exampleLine({
    required String kind,
    required String? text,
    required String? source,
    required String empty,
    bool isTextbook = false,
    bool isOriginal = false,
  }) {
    final color = isOriginal
        ? const Color(0xFFB45309)
        : (isTextbook ? const Color(0xFF0F766E) : GlassTheme.accentInk);
    final bg = isOriginal
        ? const Color(0x14B45309)
        : (isTextbook ? const Color(0x140F766E) : GlassTheme.accentSoft);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                kind,
                style: TextStyle(
                  fontSize: 8.2,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
            if (source != null && source.isNotEmpty) ...[
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 8.2, color: color),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 1),
        Text(
          text ?? empty,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 9.6,
            height: 1.35,
            color: text == null ? GlassTheme.ink3 : const Color(0xFF33363E),
          ),
        ),
      ],
    );
  }

  Widget _suggestTag(VocabReportWord w) {
    late Color bg;
    late Color fg;
    switch (w.suggestionKind) {
      case 'key':
        bg = GlassTheme.accentInk;
        fg = Colors.white;
        break;
      case 'mid':
        bg = GlassTheme.accentSoft;
        fg = GlassTheme.accentInk;
        break;
      case 'warn':
        bg = const Color(0x1AB45309);
        fg = const Color(0xFFB45309);
        break;
      default:
        bg = const Color(0x0F18181B);
        fg = GlassTheme.ink2;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        w.suggestionTag,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }

  static Color _badgeColor(VocabReportWord w) {
    switch (w.category) {
      case '课标词':
        return AppTheme.primaryBlue;
      case '拓展词':
        return AppTheme.green;
      case '超标词':
        return AppTheme.red;
      case '专有词':
        return AppTheme.grey;
      default:
        return AppTheme.purple;
    }
  }

  static String _fmt(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}

class _TH extends StatelessWidget {
  const _TH(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 9.6,
        fontWeight: FontWeight.w600,
        color: GlassTheme.ink2,
      ),
    );
  }
}
