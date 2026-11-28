/// ESW 词汇检测报告：数据模型 + 后台组装 + HTML 导出。
///
/// 口径约束（与检测页 / 「导出高频」一致，禁止第二套数字）：
///  - 词符 / 去重词形 / 各类词次数来自检测分析结果（_importedWords）；
///  - 年份分布、教材版本覆盖与例句由 [ExampleSentencePool] + [pickExamples]
///    产出，与导出表共用同一分词 / 切句 / 择优规则；
///  - 报告页与 HTML / Word 导出都消费同一份 [VocabReportData]。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;

import '../high_freq_export.dart' show ExampleSentencePool;
import 'export_extra_table.dart' show detectQuestionSections;
import 'text_normalize.dart'
    show foldToken, normalizeAnalysisToken, wordTokenRegExp;

/// 分组配色（与页面分类 chip 同一套色）。
const Map<String, int> kVocabReportGroupColors = <String, int>{
  '课标词': 0xFF2F6BDF,
  '拓展词': 0xFF2F9E44,
  '超标词': 0xFFE03131,
  '专有词': 0xFF6B7280,
  '未筛选': 0xFF7048E8,
};

/// 题型分组配色：报告按「该词所在题型」分组时使用。
const Map<String, int> kQuestionSectionColors = <String, int>{
  '听力': 0xFF0EA5E9,
  '阅读': 0xFF2F6BDF,
  '七选五': 0xFF7C3AED,
  '完形填空': 0xFF0F766E,
  '语法填空': 0xFFB45309,
  '改错': 0xFFBE123C,
  '写作': 0xFF15803D,
  '全文': 0xFF52525B,
  '其他': 0xFF71717A,
};

/// 一条例句（真题或教材）。
class VocabReportExample {
  final String text;
  final String source;

  const VocabReportExample({required this.text, required this.source});

  factory VocabReportExample.fromMap(Map m) => VocabReportExample(
        text: '${m['text'] ?? ''}',
        source: '${m['source'] ?? ''}',
      );
}

/// 报告明细中的一行词。
class VocabReportWord {
  final String word;

  /// 词条徽标：初中 / 必修 / 选修 / ← base / 超标 / 专有 / 未筛选
  final String badge;
  final String category;
  final String base;

  /// 真题语料中的全量频次
  final int corpusFreq;

  /// 本篇（被检测文本）出现次数
  final int textFreq;

  /// 本篇词族合并数
  final int familyFreq;

  /// 与报告年份轴对齐的逐年命中次数
  final List<int> yearCounts;
  final int yearHits;

  /// 与教材版本轴对齐的命中次数
  final List<int> textbookCounts;
  final int textbookHits;
  final int textbookTotal;

  final VocabReportExample? questionExample;
  final VocabReportExample? textbookExample;

  /// 本次导入原文中的所在句（优先取该词首次出现的句子）。
  final VocabReportExample? textExample;

  /// 该词在原文中首次出现所在题型（阅读 / 完形填空 / 语法填空 …），
  /// 原文未识别出题型区块时为空，报告按「全文」分组。
  final String section;

  final String suggestionTag;
  final String suggestionKind; // key / mid / low / warn
  final String suggestionWhy;

  const VocabReportWord({
    required this.word,
    required this.badge,
    required this.category,
    required this.base,
    required this.corpusFreq,
    required this.textFreq,
    required this.familyFreq,
    required this.yearCounts,
    required this.yearHits,
    required this.textbookCounts,
    required this.textbookHits,
    required this.textbookTotal,
    required this.questionExample,
    required this.textbookExample,
    this.textExample,
    this.section = '',
    required this.suggestionTag,
    required this.suggestionKind,
    required this.suggestionWhy,
  });

  factory VocabReportWord.fromMap(Map m) {
    final qe = m['questionExample'];
    final te = m['textbookExample'];
    final or = m['textExample'];
    return VocabReportWord(
      word: '${m['word'] ?? ''}',
      badge: '${m['badge'] ?? ''}',
      category: '${m['category'] ?? ''}',
      base: '${m['base'] ?? ''}',
      corpusFreq: (m['corpusFreq'] as num?)?.toInt() ?? 0,
      textFreq: (m['textFreq'] as num?)?.toInt() ?? 0,
      familyFreq: (m['familyFreq'] as num?)?.toInt() ?? 0,
      yearCounts: [for (final v in (m['yearCounts'] as List? ?? const [])) (v as num).toInt()],
      yearHits: (m['yearHits'] as num?)?.toInt() ?? 0,
      textbookCounts: [
        for (final v in (m['textbookCounts'] as List? ?? const []))
          (v as num).toInt()
      ],
      textbookHits: (m['textbookHits'] as num?)?.toInt() ?? 0,
      textbookTotal: (m['textbookTotal'] as num?)?.toInt() ?? 0,
      questionExample: qe is Map ? VocabReportExample.fromMap(qe) : null,
      textbookExample: te is Map ? VocabReportExample.fromMap(te) : null,
      textExample: or is Map ? VocabReportExample.fromMap(or) : null,
      section: '${m['section'] ?? ''}',
      suggestionTag: '${m['suggestionTag'] ?? ''}',
      suggestionKind: '${m['suggestionKind'] ?? 'low'}',
      suggestionWhy: '${m['suggestionWhy'] ?? ''}',
    );
  }
}

/// 一种词性分组（课标词 / 拓展词 / 超标词 / 专有词 / 未筛选）。
class VocabReportGroup {
  final String name;
  final String note;
  final int colorValue;
  final int wordCount;
  final int tokenCount;
  final List<VocabReportWord> words;

  const VocabReportGroup({
    required this.name,
    required this.note,
    required this.colorValue,
    required this.wordCount,
    required this.tokenCount,
    required this.words,
  });

  factory VocabReportGroup.fromMap(Map m) => VocabReportGroup(
        name: '${m['name'] ?? ''}',
        note: '${m['note'] ?? ''}',
        colorValue: (m['colorValue'] as num?)?.toInt() ??
            (kVocabReportGroupColors[m['name']] ?? 0xFF2F6BDF),
        wordCount: (m['wordCount'] as num?)?.toInt() ?? 0,
        tokenCount: (m['tokenCount'] as num?)?.toInt() ?? 0,
        words: [
          for (final w in (m['words'] as List? ?? const []))
            VocabReportWord.fromMap(w as Map)
        ],
      );
}

/// 报告全量数据。
class VocabReportData {
  final String title;
  final String subtitle;
  final String fileName;
  final String generatedAt;
  final int corpusFileCount;
  final int textbookCount;

  final int totalTokens;
  final int distinctTypes;
  final int standardTokens;
  final int extendTokens;
  final int overTokens;
  final int properTokens;
  final int unfilteredTokens;
  final double coverage;
  final double overRatio;

  /// 初中 / 必修 / 选修 的课标词次数
  final Map<String, int> levelCounts;

  /// 年份轴（升序，缺年份时为空）
  final List<int> years;

  /// 教材版本轴（与每行 textbookCounts 对齐）
  final List<String> textbookNames;

  /// 分组（课标 → 拓展 → 超标 → 专有 → 未筛选）
  final List<VocabReportGroup> groups;

  final String conclusion;
  final String advice;

  const VocabReportData({
    required this.title,
    required this.subtitle,
    required this.fileName,
    required this.generatedAt,
    required this.corpusFileCount,
    required this.textbookCount,
    required this.totalTokens,
    required this.distinctTypes,
    required this.standardTokens,
    required this.extendTokens,
    required this.overTokens,
    required this.properTokens,
    required this.unfilteredTokens,
    required this.coverage,
    required this.overRatio,
    required this.levelCounts,
    required this.years,
    required this.textbookNames,
    required this.groups,
    required this.conclusion,
    required this.advice,
  });

  int get wordCount =>
      groups.fold<int>(0, (sum, g) => sum + g.words.length);

  factory VocabReportData.fromMap(Map m) => VocabReportData(
        title: '${m['title'] ?? ''}',
        subtitle: '${m['subtitle'] ?? ''}',
        fileName: '${m['fileName'] ?? ''}',
        generatedAt: '${m['generatedAt'] ?? ''}',
        corpusFileCount: (m['corpusFileCount'] as num?)?.toInt() ?? 0,
        textbookCount: (m['textbookCount'] as num?)?.toInt() ?? 0,
        totalTokens: (m['totalTokens'] as num?)?.toInt() ?? 0,
        distinctTypes: (m['distinctTypes'] as num?)?.toInt() ?? 0,
        standardTokens: (m['standardTokens'] as num?)?.toInt() ?? 0,
        extendTokens: (m['extendTokens'] as num?)?.toInt() ?? 0,
        overTokens: (m['overTokens'] as num?)?.toInt() ?? 0,
        properTokens: (m['properTokens'] as num?)?.toInt() ?? 0,
        unfilteredTokens: (m['unfilteredTokens'] as num?)?.toInt() ?? 0,
        coverage: (m['coverage'] as num?)?.toDouble() ?? 0,
        overRatio: (m['overRatio'] as num?)?.toDouble() ?? 0,
        levelCounts: {
          for (final e in (m['levelCounts'] as Map? ?? const {}).entries)
            '${e.key}': (e.value as num).toInt()
        },
        years: [for (final y in (m['years'] as List? ?? const [])) (y as num).toInt()],
        textbookNames: [
          for (final n in (m['textbookNames'] as List? ?? const [])) '$n'
        ],
        groups: [
          for (final g in (m['groups'] as List? ?? const []))
            VocabReportGroup.fromMap(g as Map)
        ],
        conclusion: '${m['conclusion'] ?? ''}',
        advice: '${m['advice'] ?? ''}',
      );
}

/// 不进入教学建议的功能词（冠词 / 介词 / 连词 / 代词 / 助动词与情态动词）。
///
/// 出现次数再高也只做统计，不产生「精讲 / 讲练」建议；这是「科学建议」的
/// 第一道过滤，避免 the / of / is 之类占据教学额度。
const Set<String> _kFunctionWords = <String>{
  // 冠词
  'a', 'an', 'the',
  // 介词
  'about', 'above', 'across', 'after', 'against', 'along', 'among', 'around',
  'as', 'at', 'before', 'behind', 'below', 'beneath', 'beside', 'between',
  'beyond', 'by', 'despite', 'down', 'during', 'except', 'for', 'from', 'in',
  'inside', 'into', 'like', 'near', 'of', 'off', 'on', 'onto', 'out', 'outside',
  'over', 'past', 'per', 'since', 'through', 'throughout', 'till', 'to',
  'toward', 'towards', 'under', 'until', 'up', 'upon', 'with', 'within',
  'without',
  // 连词
  'and', 'or', 'but', 'nor', 'yet', 'so', 'because', 'if', 'unless', 'though',
  'although', 'while', 'whereas', 'whether', 'than', 'that', 'when', 'where',
  'whenever', 'wherever', 'once', 'both', 'either', 'neither', 'plus',
  // 代词
  'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us',
  'them', 'my', 'your', 'his', 'its', 'our', 'their', 'mine', 'yours', 'hers',
  'ours', 'theirs', 'myself', 'yourself', 'himself', 'herself', 'itself',
  'ourselves', 'yourselves', 'themselves', 'who', 'whom', 'whose', 'which',
  'what', 'this', 'these', 'those', 'there', 'here', 'someone', 'somebody',
  'something', 'anyone', 'anybody', 'anything', 'everyone', 'everybody',
  'everything', 'nobody', 'nothing', 'none', 'each', 'other', 'others',
  'another', 'such', 'same', 'own', 'all', 'any', 'some', 'few',
  'many', 'much', 'more', 'most', 'several', 'enough', 'one', 'ones',
  // be / do / have / 情态动词与助动词
  'be', 'am', 'is', 'are', 'was', 'were', 'been', 'being', 'do', 'does',
  'did', 'done', 'doing', 'have', 'has', 'had', 'having', 'will', 'would',
  'shall', 'should', 'can', 'could', 'may', 'might', 'must', 'ought', 'need',
  'dare', 'used',
};

/// 数词与序数词：只统计，不进入教学建议。
const Set<String> _kNumberWords = <String>{
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty', 'thirty', 'forty',
  'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'thousand',
  'million', 'billion', 'dozen', 'first', 'second', 'third', 'fourth',
  'fifth', 'sixth', 'seventh', 'eighth', 'ninth', 'tenth', 'eleventh',
  'twelfth', 'thirteenth', 'fourteenth', 'fifteenth', 'sixteenth',
  'seventeenth', 'eighteenth', 'nineteenth', 'twentieth', 'thirtieth',
  'fortieth', 'fiftieth', 'sixtieth', 'seventieth', 'eightieth', 'ninetieth',
};

/// 星期 / 月份（含常见缩写）：只统计，不进入教学建议。
const Set<String> _kCalendarWords = <String>{
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
  'sunday', 'mon', 'tue', 'tues', 'wed', 'thu', 'thur', 'thurs', 'fri', 'sat',
  'sun', 'january', 'february', 'march', 'april', 'may', 'june', 'july',
  'august', 'september', 'october', 'november', 'december', 'jan', 'feb',
  'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
};

/// 原文首现索引：词形折叠键 → 所在句原文 / 句首字符偏移。
class _TextIndex {
  final Map<String, String> firstSentence = <String, String>{};
  final Map<String, int> firstPos = <String, int>{};
}

/// 建原文索引（只保留每词首次出现的句子，控制内存与耗时）。
_TextIndex _indexText(String text) {
  final idx = _TextIndex();
  if (text.trim().isEmpty) return idx;
  final sentenceRe = RegExp(r'[^.!?。！？]+[.!?。！？]');
  for (final m in sentenceRe.allMatches(text)) {
    final s = m.group(0)!.trim();
    if (s.length < 3) continue;
    for (final t in wordTokenRegExp.allMatches(s)) {
      final token = normalizeAnalysisToken(t.group(0)!);
      if (token == null) continue;
      final key = foldToken(token);
      idx.firstSentence.putIfAbsent(key, () => s);
      idx.firstPos.putIfAbsent(key, () => m.start);
    }
  }
  return idx;
}

/// 按题型区块起点定位某个字符偏移属于哪种题型。
String _sectionOf(
  int pos,
  List<({String name, int start})> sections,
) {
  if (sections.isEmpty) return '全文';
  if (pos < 0) return '其他';
  var name = '';
  for (final s in sections) {
    if (s.start > pos) break;
    name = s.name;
  }
  return name.isEmpty ? '其他' : name;
}

/// 后台组装报告（isolate 内完成，避免切句 / 建索引阻塞界面）。
Future<VocabReportData> buildVocabReport(Map<String, dynamic> args) async {
  final m = await compute(_vocabReportWorker, args);
  return VocabReportData.fromMap(m);
}

Map<String, dynamic> _vocabReportWorker(Map<String, dynamic> args) {
  final years = [for (final y in (args['years'] as List? ?? const [])) (y as num).toInt()];
  final textbookNames = [
    for (final n in (args['textbookNames'] as List? ?? const [])) '$n'
  ];
  final stdFolded = <String>{
    for (final k in (args['standardFolded'] as List? ?? const [])) '$k'
  };
  final rawWords = <Map>[
    for (final w in (args['words'] as List? ?? const [])) w as Map
  ];
  final targets = <String>{for (final m in rawWords) foldToken('${m['word']}')};

  // 原文索引（取每词首次出现的句子）与题型区块，用于「原文原句」与按题型分组。
  final sourceText = '${args['text'] ?? ''}';
  final textIdx = _indexText(sourceText);
  final sections = detectQuestionSections(sourceText);
  final reportKeys = <String>{...targets};

  final corpusPool = ExampleSentencePool(
    standardWords: stdFolded,
    onlyWords: targets,
  );
  for (final d in (args['corpus'] as List? ?? const [])) {
    final m = d as Map;
    corpusPool.addText(
      '${m['text'] ?? ''}',
      year: (m['year'] as num?)?.toInt() ?? 0,
      source: '${m['source'] ?? ''}',
    );
  }
  final tbPool = ExampleSentencePool(
    standardWords: stdFolded,
    onlyWords: targets,
  );
  for (final d in (args['textbooks'] as List? ?? const [])) {
    final m = d as Map;
    tbPool.addText(
      '${m['text'] ?? ''}',
      year: 0,
      source: '${m['source'] ?? ''}',
    );
  }

  var totalTokens = 0;
  var standardTokens = 0;
  var extendTokens = 0;
  var overTokens = 0;
  var properTokens = 0;
  var unfilteredTokens = 0;
  final levelCounts = <String, int>{'初中': 0, '必修': 0, '选修': 0};

  final stdGroup = <Map<String, dynamic>>[];
  final extGroup = <Map<String, dynamic>>[];
  final overGroup = <Map<String, dynamic>>[];
  final properGroup = <Map<String, dynamic>>[];
  final otherGroup = <Map<String, dynamic>>[];
  // 报告分组：按该词首次出现所在题型（阅读 / 完形填空 / 语法填空 …）。
  final sectionGroups = <String, List<Map<String, dynamic>>>{};

  for (final m in rawWords) {
    final word = '${m['word'] ?? ''}';
    if (word.isEmpty) continue;
    final category = '${m['category'] ?? ''}';
    final textFreq = (m['textFreq'] as num?)?.toInt() ?? 0;
    final passedCorpusFreq = (m['corpusFreq'] as num?)?.toInt() ?? 0;
    final familyFreq = (m['familyFreq'] as num?)?.toInt() ?? textFreq;
    final level = '${m['level'] ?? ''}';
    final base = '${m['base'] ?? ''}';
    // 安卓端只传本篇词频：真题频次回落到本次语料的实际计数（同一分词口径），
    // 避免报告出现「真题频次 0」这类与语料矛盾的数。
    final corpusFreq =
        passedCorpusFreq > 0 ? passedCorpusFreq : (corpusPool.freq[foldToken(word)] ?? 0);

    totalTokens += textFreq;
    switch (category) {
      case '课标词':
        standardTokens += textFreq;
        if (levelCounts.containsKey(level)) {
          levelCounts[level] = levelCounts[level]! + textFreq;
        }
        break;
      case '拓展词':
        extendTokens += textFreq;
        break;
      case '超标词':
        overTokens += textFreq;
        break;
      case '专有词':
        properTokens += textFreq;
        break;
      default:
        unfilteredTokens += textFreq;
    }

    final key = foldToken(word);
    // 该词在原文首次出现的位置 → 所在题型（无题型标题时为「全文」）。
    final sectionName = _sectionOf(textIdx.firstPos[key] ?? -1, sections);
    final ymap = corpusPool.yearCounts[key] ?? const <int, int>{};
    final yc = [for (final y in years) ymap[y] ?? 0];
    final yearHits = yc.where((v) => v > 0).length;
    final tmap = tbPool.sourceCounts[key] ?? const <String, int>{};
    final tc = [for (final n in textbookNames) tmap[n] ?? 0];
    final textbookHits = tc.where((v) => v > 0).length;
    final textbookTotal = tc.fold<int>(0, (a, b) => a + b);

    final qPicked = corpusPool.pick(word, max: 1);
    final tPicked = tbPool.pick(word, max: 1);

    String badge;
    switch (category) {
      case '课标词':
        badge = level.isEmpty ? '课标' : level;
        break;
      case '拓展词':
        badge = base.isEmpty ? '拓展' : '← $base';
        break;
      case '超标词':
        badge = '超标';
        break;
      case '专有词':
        badge = '专有';
        break;
      default:
        badge = '未筛选';
    }

    // 教学建议：先排除功能词 / 代词 / 助动词 / 数词 / 日期 / 专有词，
    // 再结合教材覆盖、词族合并与可执行动作，每条附判断依据。
    String tag;
    String kind;
    String why;
    final tbText = textbookTotal == 0
        ? '暂无教材语料'
        : '教材覆盖 $textbookHits/$textbookTotal 套';
    final familyText =
        familyFreq > textFreq ? '，词族合计 $familyFreq 次' : '';
    if (category == '专有词') {
      tag = '不处理';
      kind = 'low';
      why = '专有名词，只标注不教学';
    } else if (_kFunctionWords.contains(key) ||
        _kNumberWords.contains(key) ||
        _kCalendarWords.contains(key)) {
      tag = '不处理';
      kind = 'low';
      why = '功能词 / 数词 / 日期，只统计不单独教学';
    } else if (category == '拓展词') {
      if (base.isNotEmpty && reportKeys.contains(foldToken(base))) {
        tag = '并入词族';
        kind = 'mid';
        why = '归并到 $base（本篇合计 $familyFreq 次），不重复讲';
      } else {
        tag = '认读';
        kind = 'low';
        why = '课标词变体，$tbText → 认读即可';
      }
    } else if (category == '超标词') {
      if (textFreq >= 2) {
        tag = '随文注';
        kind = 'warn';
        why = '超标词，本篇 $textFreq 次 → 首现注中文，不要求掌握';
      } else {
        tag = '认识即可';
        kind = 'low';
        why = '超标词，本篇 1 次 → 留作难度梯度';
      }
    } else if (category != '课标词') {
      tag = '待归类';
      kind = 'low';
      why = '四库未收录，请人工归类后再定教学动作';
    } else {
      // 课标词：教材已覆盖一半以上视为「已讲过」，不再占精讲额度。
      final covered = textbookTotal > 0 && textbookHits * 2 >= textbookTotal;
      if (level == '初中') {
        if (textFreq >= 3 && !covered) {
          tag = '讲练';
          kind = 'mid';
          why = '本篇 $textFreq 次$familyText · $tbText → 讲搭配 + 造句，不占精讲额度';
        } else if (covered) {
          tag = '复现';
          kind = 'low';
          why = '$tbText → 听写复现即可';
        } else {
          tag = '认读';
          kind = 'low';
          why = '本篇 $textFreq 次 · $tbText → 认读，不追默写';
        }
      } else if (textFreq >= 3 && !covered) {
        tag = '精讲';
        kind = 'key';
        why = '本篇 $textFreq 次$familyText · $tbText → 精讲词块与搭配';
      } else if (textFreq >= 2) {
        if (covered) {
          tag = '复现';
          kind = 'low';
          why = '$tbText → 复现听写，不重复讲';
        } else {
          tag = '讲练';
          kind = 'mid';
          why = '本篇 $textFreq 次$familyText · $tbText → 随文讲 1 次 + 造句';
        }
      } else if (covered) {
        tag = '复现';
        kind = 'low';
        why = '$tbText → 复现即可';
      } else {
        tag = '认读';
        kind = 'low';
        why = '本篇 1 次 · $tbText → 认读即可';
      }
    }

    final item = <String, dynamic>{
      'word': word,
      'badge': badge,
      'category': category,
      'base': base,
      'corpusFreq': corpusFreq,
      'textFreq': textFreq,
      'familyFreq': familyFreq,
      'yearCounts': yc,
      'yearHits': yearHits,
      'textbookCounts': tc,
      'textbookHits': textbookHits,
      'textbookTotal': textbookTotal,
      'questionExample': qPicked.isEmpty
          ? null
          : {'text': qPicked.first.text, 'source': qPicked.first.source},
      'textbookExample': tPicked.isEmpty
          ? null
          : {'text': tPicked.first.text, 'source': tPicked.first.source},
      'textExample': textIdx.firstSentence.containsKey(key)
          ? {'text': textIdx.firstSentence[key], 'source': ''}
          : null,
      'section': sectionName,
      'suggestionTag': tag,
      'suggestionKind': kind,
      'suggestionWhy': why,
    };

    if (category == '课标词') {
      stdGroup.add(item);
    } else if (category == '拓展词') {
      extGroup.add(item);
    } else if (category == '超标词') {
      overGroup.add(item);
    } else if (category == '专有词') {
      properGroup.add(item);
    } else {
      otherGroup.add(item);
    }
    (sectionGroups[sectionName] ??= <Map<String, dynamic>>[]).add(item);
  }

  int levelRank(String level) {
    switch (level) {
      case '初中':
        return 0;
      case '必修':
        return 1;
      case '选修':
        return 2;
      default:
        return 3;
    }
  }

  int byCorpusDesc(Map<String, dynamic> a, Map<String, dynamic> b) {
    final c = (b['corpusFreq'] as int).compareTo(a['corpusFreq'] as int);
    if (c != 0) return c;
    final t = (b['textFreq'] as int).compareTo(a['textFreq'] as int);
    if (t != 0) return t;
    return '${a['word']}'
        .toLowerCase()
        .compareTo('${b['word']}'.toLowerCase());
  }

  // 课标词：初中 → 必修 → 选修，组内再按真题频次降序
  stdGroup.sort((a, b) {
    final lr = levelRank('${a['badge']}').compareTo(levelRank('${b['badge']}'));
    if (lr != 0) return lr;
    return byCorpusDesc(a, b);
  });
  extGroup.sort(byCorpusDesc);
  overGroup.sort(byCorpusDesc);
  properGroup.sort(byCorpusDesc);
  otherGroup.sort(byCorpusDesc);

  // 题型分组排序：精讲 → 讲练 → 随文注 → 复现 → 认读 → 其他，
  // 同档再按本篇次数、真题频次降序，保证教师先看到该讲的词。
  int suggestionRank(String tag) {
    switch (tag) {
      case '精讲':
        return 0;
      case '讲练':
        return 1;
      case '随文注':
        return 2;
      case '复现':
        return 3;
      case '认读':
        return 4;
      case '认识即可':
        return 5;
      default:
        return 6;
    }
  }

  int bySuggestion(Map<String, dynamic> a, Map<String, dynamic> b) {
    final r = suggestionRank('${a['suggestionTag']}')
        .compareTo(suggestionRank('${b['suggestionTag']}'));
    if (r != 0) return r;
    final t = (b['textFreq'] as int).compareTo(a['textFreq'] as int);
    if (t != 0) return t;
    return byCorpusDesc(a, b);
  }

  Map<String, dynamic> makeGroup(
    String name,
    String note,
    List<Map<String, dynamic>> words,
  ) =>
      <String, dynamic>{
        'name': name,
        'note': note,
        'colorValue':
            kQuestionSectionColors[name] ?? kVocabReportGroupColors[name],
        'wordCount': words.length,
        'tokenCount': words.fold<int>(
            0, (sum, w) => sum + (w['textFreq'] as int)),
        'words': words,
      };

  String sectionNote(List<Map<String, dynamic>> words) {
    int c(String t) => words.where((w) => w['suggestionTag'] == t).length;
    final parts = <String>[];
    void add(String label, int n) {
      if (n > 0) parts.add('$label $n');
    }

    add('精讲', c('精讲'));
    add('讲练', c('讲练'));
    add('随文注', c('随文注'));
    add('复现', c('复现'));
    add('认读', c('认读') + c('认识即可'));
    add('不处理', c('不处理') + c('并入词族') + c('待归类'));
    return '${words.length} 个词 · ${parts.join(' / ')}';
  }

  // 题型顺序：按原文区块出现顺序；无区块时单列「全文」，「其他」置末。
  final sectionNames = <String>[];
  for (final s in sections) {
    if (!sectionNames.contains(s.name)) sectionNames.add(s.name);
  }
  if (sectionNames.isEmpty) sectionNames.add('全文');
  if (sectionGroups.containsKey('其他') && !sectionNames.contains('其他')) {
    sectionNames.add('其他');
  }
  final groups = <Map<String, dynamic>>[];
  for (final name in sectionNames) {
    final ws = sectionGroups[name];
    if (ws == null || ws.isEmpty) continue;
    ws.sort(bySuggestion);
    groups.add(makeGroup(name, sectionNote(ws), ws));
  }

  final coverage = totalTokens == 0
      ? 0.0
      : (standardTokens + extendTokens) / totalTokens;
  final overRatio = totalTokens == 0 ? 0.0 : overTokens / totalTokens;

  final topOver = [...overGroup]
    ..sort((a, b) {
      final c = (b['textFreq'] as int).compareTo(a['textFreq'] as int);
      return c != 0 ? c : byCorpusDesc(a, b);
    });

  String difficulty;
  if (coverage >= 0.9) {
    difficulty = '偏易';
  } else if (coverage >= 0.75) {
    difficulty = '中等';
  } else if (coverage >= 0.6) {
    difficulty = '中等偏难';
  } else {
    difficulty = '偏难';
  }

  final sb = StringBuffer();
  sb.write('判定：$difficulty。课标词（含拓展变体）覆盖 ${_pct(coverage)}');
  sb.write('，超出课标表的词共 $overTokens 次（${_pct(overRatio)}）');
  if (topOver.isNotEmpty) {
    final names = topOver
        .take(3)
        .map((w) => '${w['word']}（${w['textFreq']} 次）')
        .join('、');
    sb.write('，其中 $names 反复出现，属于读懂全篇的主题枢纽词。');
  } else {
    sb.write('。');
  }

  final advice = StringBuffer();
  final actions = <String>[];
  for (final g in groups) {
    final keyWords = [
      for (final w in (g['words'] as List<Map<String, dynamic>>))
        if (w['suggestionTag'] == '精讲') '${w['word']}'
    ];
    if (keyWords.isNotEmpty) {
      actions.add('${g['name']}精讲 ${keyWords.take(4).join('、')}');
    }
  }
  if (actions.isEmpty) {
    advice.write('① 本篇无高优先级精讲词，按「复现 / 认读」安排即可；');
  } else {
    advice.write('① ${actions.join('；')}；');
  }
  advice.write('② 讲练词随文讲 1 次并造句，认读词不占默写；');
  final skipCount = [
    ...stdGroup,
    ...extGroup,
    ...overGroup,
    ...properGroup,
    ...otherGroup,
  ].where((w) {
    final t = '${w['suggestionTag']}';
    return t == '不处理' || t == '并入词族';
  }).length;
  advice.write('③ $skipCount 个功能词 / 专有词 / 变体只统计不教学，拓展词按词族合并不重复讲；');
  final gapCount = [
    ...stdGroup,
    ...extGroup,
    ...overGroup,
  ].where((w) => (w['textbookHits'] as int) == 0).length;
  advice.write('④ $gapCount 个词 ${textbookNames.length} 套教材均未覆盖，可列为教学缺口。');

  final fileName = '${args['fileName'] ?? '文本检测'}';
  final yearRange = years.isEmpty ? '' : '${years.first}–${years.last}';
  final subtitle =
      '检测对象：$fileName　全文 ${_num(totalTokens)} 词符 · ${_num(rawWords.length)} 词形';

  return <String, dynamic>{
    'title': '$fileName · 词汇检测报告',
    'subtitle': subtitle,
    'fileName': fileName,
    'generatedAt': '${args['generatedAt'] ?? ''}',
    'corpusFileCount': (args['corpusFileCount'] as num?)?.toInt() ?? 0,
    'textbookCount': textbookNames.length,
    'totalTokens': totalTokens,
    'distinctTypes': rawWords.length,
    'standardTokens': standardTokens,
    'extendTokens': extendTokens,
    'overTokens': overTokens,
    'properTokens': properTokens,
    'unfilteredTokens': unfilteredTokens,
    'coverage': coverage,
    'overRatio': overRatio,
    'levelCounts': levelCounts,
    'years': years,
    'yearRange': yearRange,
    'textbookNames': textbookNames,
    'groups': groups,
    'conclusion': sb.toString(),
    'advice': advice.toString(),
  };
}

String _num(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 生成与报告页同一份数据的自包含 HTML（可直接打印 / 分享）。
String buildVocabReportHtml(VocabReportData d) {
  final buffer = StringBuffer();
  String hex(int v) => '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  final stdColor = hex(kVocabReportGroupColors['课标词']!);
  final extColor = hex(kVocabReportGroupColors['拓展词']!);
  final overColor = hex(kVocabReportGroupColors['超标词']!);
  final properColor = hex(kVocabReportGroupColors['专有词']!);
  final otherColor = hex(kVocabReportGroupColors['未筛选']!);
  final total = d.totalTokens == 0 ? 1 : d.totalTokens;
  final stdPct = (d.standardTokens / total * 100);
  final extPct = (d.extendTokens / total * 100);
  final overPct = (d.overTokens / total * 100);
  final properPct = (d.properTokens / total * 100);
  final otherPct = (d.unfilteredTokens / total * 100);

  buffer.writeln('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8">');
  buffer.writeln('<meta name="viewport" content="width=device-width, initial-scale=1">');
  buffer.writeln('<title>${_esc(d.title)}</title><style>');
  buffer.writeln('''
:root{--ink:#18181B;--muted:#71717A;--rule:rgba(24,24,27,.09);--accent:#4462F2;--accent2:#3348CF;--accent-soft:rgba(68,98,242,.07)}
*{box-sizing:border-box}
body{margin:0;background:#EDEFF3;color:var(--ink);font:13px/1.55 "Microsoft YaHei","PingFang SC",sans-serif}
.sheet{max-width:1100px;margin:14px auto;background:#fff;border:1px solid var(--rule);box-shadow:0 10px 34px rgba(24,24,27,.07);padding:28px 30px}
.mast{display:flex;justify-content:space-between;gap:24px;border-bottom:1px solid var(--rule);padding-bottom:11px}
.eyebrow{font-size:10px;letter-spacing:.16em;color:var(--accent2);font-weight:700;margin-bottom:4px}
h1{margin:0;font-size:22px;line-height:1.25}
.sub{margin-top:4px;font-size:11.5px;color:var(--muted)}
.meta{display:grid;grid-template-columns:auto auto;gap:2px 20px;font-size:10px;text-align:right;color:var(--muted)}
.meta b{display:block;font-size:11px;color:var(--ink);font-weight:600}
.ov{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-top:12px}
.kpi{background:#F5F6F8;border-radius:8px;padding:9px 11px 10px;border:1px solid transparent}
.kpi .lab{font-size:9.5px;color:var(--muted)}
.kpi .val{font-size:23px;font-weight:700;line-height:1.22;margin-top:1px}
.kpi .val em{font-size:10px;font-weight:600;color:var(--muted);font-style:normal;margin-left:3px}
.kpi .foo{font-size:10px;color:var(--muted);margin-top:2px}
.kpi.hero{background:var(--accent-soft);border-color:rgba(68,98,242,.16)}
.kpi.hero .val{color:var(--accent2)}
.bar{height:4px;border-radius:2px;background:rgba(68,98,242,.14);overflow:hidden;margin-top:6px}
.bar i{display:block;height:100%;background:var(--accent)}
.comp{margin-top:9px;display:flex;align-items:center;gap:11px}
.stacked{flex:1;height:8px;border-radius:4px;overflow:hidden;display:flex;background:#F5F6F8}
.stacked i{display:block;height:100%}
.legend{display:flex;gap:11px;font-size:10px;color:var(--muted);flex:none}
.legend u{width:6px;height:6px;border-radius:2px;display:inline-block;text-decoration:none;margin-right:3px}
.lvrow{margin-top:7px;display:flex;gap:9px;font-size:10px;color:var(--muted);align-items:center;flex-wrap:wrap}
.lvrow b{color:var(--accent2)}
.concl{margin-top:9px;border-left:3px solid var(--accent);background:var(--accent-soft);padding:8px 11px;border-radius:0 7px 7px 0;font-size:11.2px;line-height:1.6}
.concl .acts{margin-top:3px}
table{width:100%;border-collapse:collapse;table-layout:fixed;margin-top:8px}
thead th{background:#F1F2F5;font-size:9.6px;font-weight:600;color:var(--muted);text-align:left;padding:5px 6px;border-bottom:1px solid var(--rule)}
td{border-bottom:1px solid var(--rule);padding:7px 6px;vertical-align:top;font-size:10.5px}
tr.g-head td{background:#FBFBFD;padding:6px 7px;border-top:1px solid var(--rule)}
.g-name{font-size:11px;font-weight:700;margin-left:3px}
.g-count{font-size:10px;font-weight:600;margin-left:7px;padding:1px 6px;border-radius:8px;background:#fff;border:1px solid var(--rule)}
.g-note{font-size:9.6px;color:var(--muted);margin-left:8px}
.w{font-size:13px;font-weight:600}
.lv{font-size:8.6px;font-weight:600;padding:1px 4px;border-radius:3px;margin-left:4px;background:rgba(68,98,242,.10);color:var(--accent2)}
.big{font-size:16px;font-weight:700}
.big em{font-size:9px;font-weight:600;color:var(--muted);font-style:normal;margin-left:2px}
.mini{font-size:9.2px;color:var(--muted);margin-top:1px}
.spark{display:flex;align-items:flex-end;gap:1.5px;height:17px;margin-top:4px}
.spark i{width:3px;border-radius:1px;background:var(--accent)}
.spark i.off{background:rgba(24,24,27,.12);height:2px!important}
.dots{display:flex;gap:2.5px;margin-bottom:4px}
.dots i{width:6.5px;height:6.5px;border-radius:2px;background:rgba(24,24,27,.10)}
.dots i.on{background:#2F9E44}
.ex{margin:0 0 3px;font-size:10.2px;line-height:1.5;color:#33363E}
.kind{font-size:8.4px;font-weight:700;color:var(--accent2);background:var(--accent-soft);padding:0 4px;border-radius:3px;margin-right:4px}
.kind.tb{color:#0F766E;background:rgba(15,118,110,.08)}
.kind.orig{color:#B45309;background:rgba(180,83,9,.09)}
.cloud-wrap{margin:14px 0 16px}
.cloud-title{font-size:11px;font-weight:700;color:var(--ink);margin:0 0 8px}
.cloud-title em{font-style:normal;font-weight:400;color:#A1A1AA;font-size:10px;margin-left:6px}
.cloud-group{margin-bottom:12px}
.cloud-gname{font-size:10.5px;font-weight:700;margin:0 0 6px}
.cloud{display:flex;flex-wrap:wrap;gap:6px;align-items:flex-start}
.chipw{max-width:100%}
.chipw>summary{list-style:none;cursor:pointer;display:inline-flex;align-items:baseline;gap:4px;padding:3px 9px;border-radius:999px;border:1px solid #E4E4E7;background:#fff;font-weight:600;color:#18181B}
.chipw>summary::-webkit-details-marker{display:none}
.chipw>summary em{font-style:normal;font-size:9.5px;color:#A1A1AA;font-weight:500}
.chipw[open]>summary{border-color:var(--accent2);color:var(--accent2);background:var(--accent-soft)}
.chipw .pop{width:100%;margin-top:6px;padding:8px 10px;border-radius:8px;background:#FAFAFB;border:1px solid #EEE;font-size:10.5px;line-height:1.6}
.pop .lab2{font-weight:700;color:#52525B;margin-right:4px}
.src{float:right;font-size:8.4px;color:var(--accent2);background:var(--accent-soft);padding:0 3px;border-radius:2px;margin-left:5px}
.src.tb{color:#0F766E;background:rgba(15,118,110,.08)}
.tag{display:inline-block;font-size:9.2px;font-weight:700;padding:2px 5px;border-radius:3px}
.p-key{background:var(--accent2);color:#fff}.p-mid{background:rgba(68,98,242,.12);color:var(--accent2)}
.p-low{background:rgba(24,24,27,.06);color:var(--muted)}.p-warn{background:rgba(180,83,9,.10);color:#B45309}
.why{display:block;font-size:9px;color:var(--muted);margin-top:3px}
.foot{margin-top:12px;border-top:1px solid var(--rule);padding-top:7px;font-size:9.4px;color:var(--muted)}
@media print{body{background:#fff}.sheet{border:none;box-shadow:none;max-width:none;margin:0;padding:8mm}@page{size:A4 landscape;margin:0}}
''');
  buffer.writeln('</style></head><body><section class="sheet">');

  buffer.writeln('<header class="mast"><div><div class="eyebrow">ESW · 词汇检测报告</div>');
  buffer.writeln('<h1>${_esc(d.title)}</h1><div class="sub">${_esc(d.subtitle)}</div></div>');
  buffer.writeln('<div class="meta"><span>词表基准<b>2025 修订课标词表</b></span>');
  buffer.writeln('<span>真题语料<b>${d.corpusFileCount} 套</b></span>');
  buffer.writeln('<span>教材语料<b>${d.textbookCount} 套</b></span>');
  buffer.writeln('<span>生成时间<b>${_esc(d.generatedAt)}</b></span></div></header>');

  buffer.writeln('<div class="ov">');
  buffer.writeln('<div class="kpi"><div class="lab">词符总数 TOKENS</div>'
      '<div class="val">${_num(d.totalTokens)}</div>'
      '<div class="foo">含重复，全文切词口径</div></div>');
  final avg = d.distinctTypes == 0
      ? '0'
      : (d.totalTokens / d.distinctTypes).toStringAsFixed(1);
  buffer.writeln('<div class="kpi"><div class="lab">去重词形 TYPES</div>'
      '<div class="val">${_num(d.distinctTypes)}</div>'
      '<div class="foo">平均每词形复现 $avg 次</div></div>');
  buffer.writeln('<div class="kpi hero"><div class="lab">课标词覆盖率</div>'
      '<div class="val">${(d.coverage * 100).toStringAsFixed(1)}<em>%</em></div>'
      '<div class="foo">课标词 ${_num(d.standardTokens + d.extendTokens)} 次 · 超标 ${_num(d.overTokens)} 次</div>'
      '<div class="bar"><i style="width:${(d.coverage * 100).toStringAsFixed(1)}%"></i></div></div>');
  buffer.writeln('<div class="kpi"><div class="lab">超标词</div>'
      '<div class="val">${_num(d.overTokens)}<em>次 / ${(d.overRatio * 100).toStringAsFixed(1)}%</em></div>'
      '<div class="foo">表外实词，需判断是否注释</div></div></div>');

  buffer.writeln('<div class="comp"><div class="stacked">');
  buffer.writeln('<i style="width:${stdPct.toStringAsFixed(1)}%;background:$stdColor"></i>');
  if (extPct > 0) {
    buffer.writeln('<i style="width:${extPct.toStringAsFixed(1)}%;background:$extColor"></i>');
  }
  buffer.writeln('<i style="width:${overPct.toStringAsFixed(1)}%;background:$overColor"></i>');
  if (properPct > 0) {
    buffer.writeln('<i style="width:${properPct.toStringAsFixed(1)}%;background:$properColor"></i>');
  }
  if (otherPct > 0) {
    buffer.writeln('<i style="width:${otherPct.toStringAsFixed(1)}%;background:$otherColor"></i>');
  }
  buffer.writeln('</div><div class="legend">');
  buffer.writeln('<span><u style="background:$stdColor"></u>课标 ${stdPct.toStringAsFixed(1)}%</span>');
  if (extPct > 0) {
    buffer.writeln('<span><u style="background:$extColor"></u>拓展 ${extPct.toStringAsFixed(1)}%</span>');
  }
  buffer.writeln('<span><u style="background:$overColor"></u>超标 ${overPct.toStringAsFixed(1)}%</span>');
  if (properPct > 0) {
    buffer.writeln('<span><u style="background:$properColor"></u>专有 ${properPct.toStringAsFixed(1)}%</span>');
  }
  if (otherPct > 0) {
    buffer.writeln('<span><u style="background:$otherColor"></u>未筛选 ${otherPct.toStringAsFixed(1)}%</span>');
  }
  buffer.writeln('</div></div>');

  buffer.writeln('<div class="lvrow"><span style="font-weight:600;color:var(--ink)">课标词分级</span>');
  for (final lv in const ['初中', '必修', '选修']) {
    buffer.writeln('<span>$lv <b>${_num(d.levelCounts[lv] ?? 0)}</b> 次</span><span>·</span>');
  }
  buffer.writeln('<span>拓展变体 <b>${_num(d.extendTokens)}</b> 次</span>');
  buffer.writeln('<span style="margin-left:auto;color:#A1A1AA">分级只统计课标词，拓展变体单列，避免双重计数</span></div>');

  buffer.writeln('<div class="concl">${_esc(d.conclusion)}');
  buffer.writeln('<div class="acts"><b>建议</b> ${_esc(d.advice)}</div></div>');

  // 重点词汇云：先按题型聚合需要讲的词（精讲 / 讲练 / 随文注），
  // 点击词条在原地展开该词的原句、真题 / 教材例句与处理建议。
  buffer.writeln('<div class="cloud-wrap"><div class="cloud-title">'
      '重点词汇云 · 按题型<em>点击词条展开讲解</em></div>');
  var cloudCount = 0;
  for (final g in d.groups) {
    final picks = [
      for (final w in g.words)
        if (w.suggestionTag == '精讲' ||
            w.suggestionTag == '讲练' ||
            w.suggestionTag == '随文注')
          w
    ];
    if (picks.isEmpty) continue;
    cloudCount += picks.length;
    final gc = hex(g.colorValue);
    buffer.writeln('<div class="cloud-group">'
        '<div class="cloud-gname" style="color:$gc">${_esc(g.name)}'
        '<em style="font-style:normal;font-weight:400;color:#A1A1AA;margin-left:6px">'
        '${picks.length} 个重点词</em></div><div class="cloud">');
    for (final w in picks) {
      final size = w.textFreq >= 4 ? 15.0 : (w.textFreq >= 2 ? 13.0 : 11.5);
      final q = w.questionExample;
      final t = w.textbookExample;
      final o = w.textExample;
      buffer.writeln(
          '<details class="chipw"><summary style="font-size:${size.toStringAsFixed(1)}px">'
          '${_esc(w.word)}<em>×${w.textFreq}</em></summary><div class="pop">');
      buffer.writeln('<div class="prow"><span class="lab2">词条</span>'
          '${_esc(w.word)}（${_esc(w.badge)}） · 真题 ${w.corpusFreq} 次 · '
          '本篇 ${w.textFreq} 次 · 教材 ${w.textbookHits}/${w.textbookCounts.length} 版本</div>');
      buffer.writeln('<div class="prow"><span class="lab2">原句</span>'
          '${o == null ? '原文未定位到该词形' : _esc(o.text)}</div>');
      buffer.writeln('<div class="prow"><span class="lab2">真题</span>'
          '${q == null ? '真题语料未收录该词形' : '${q.source.isEmpty ? '' : '『${_esc(q.source)}』'}${_esc(q.text)}'}</div>');
      buffer.writeln('<div class="prow"><span class="lab2">教材</span>'
          '${t == null ? '${w.textbookCounts.length} 套教材均未覆盖' : '${t.source.isEmpty ? '' : '『${_esc(t.source)}』'}${_esc(t.text)}'}</div>');
      buffer.writeln('<div class="prow"><span class="lab2">建议</span>'
          '<span class="tag p-${w.suggestionKind}">${_esc(w.suggestionTag)}</span>'
          '${_esc(w.suggestionWhy)}</div>');
      buffer.writeln('</div></details>');
    }
    buffer.writeln('</div></div>');
  }
  if (cloudCount == 0) {
    buffer.writeln('<div style="font-size:10.5px;color:#A1A1AA">'
        '本篇没有需要集中讲解的重点词（功能词 / 专有词 / 教材已覆盖词不计入）。</div>');
  }
  buffer.writeln('</div>');

  buffer.writeln('<div class="cloud-title">全部词条明细</div>');
  buffer.writeln('<table><colgroup><col style="width:4%"><col style="width:14%">'
      '<col style="width:13%"><col style="width:13%"><col style="width:40%">'
      '<col style="width:16%"></colgroup>');
  buffer.writeln('<thead><tr><th>#</th><th>词条</th><th>真题频次</th><th>教材覆盖</th>'
      '<th>例句（原句 / 真题 / 教材）</th><th>处理建议</th></tr></thead><tbody>');

  var n = 0;
  for (final g in d.groups) {
    final color = hex(g.colorValue);
    buffer.writeln('<tr class="g-head"><td colspan="6" style="border-left:3px solid $color">'
        '<span class="g-name" style="color:$color">${_esc(g.name)}</span>'
        '<span class="g-count">${g.wordCount} 个词 · 本篇 ${g.tokenCount} 次</span>'
        '<span class="g-note">${_esc(g.note)}</span></td></tr>');
    for (final w in g.words) {
      final yMax = w.yearCounts.isEmpty
          ? 1
          : w.yearCounts.reduce((a, b) => a > b ? a : b);
      final bars = StringBuffer();
      for (var i = 0; i < w.yearCounts.length; i++) {
        final v = w.yearCounts[i];
        if (v <= 0) {
          bars.write('<i class="off"></i>');
        } else {
          final h = 3 + (yMax == 0 ? 0 : (v / yMax * 15)).round();
          bars.write('<i style="height:${h}px"></i>');
        }
      }
      final dots = StringBuffer();
      for (var i = 0; i < w.textbookCounts.length; i++) {
        final name = i < d.textbookNames.length ? d.textbookNames[i] : '教材${i + 1}';
        dots.write('<i class="${w.textbookCounts[i] > 0 ? 'on' : ''}" '
            'title="${_esc(name)} ${w.textbookCounts[i]} 次"></i>');
      }
      final q = w.questionExample;
      final t = w.textbookExample;
      final o = w.textExample;
      n++;
      buffer.writeln('<tr><td style="color:#A1A1AA;font-size:9.5px">$n</td>'
          '<td><div class="w">${_esc(w.word)}'
          '<span class="lv">${_esc(w.badge)}</span></div></td>');
      buffer.writeln('<td><div class="big">${w.corpusFreq}<em>次</em></div>'
          '<div class="mini">${w.yearHits} 年命中 · 本篇 ${w.textFreq} 次</div>'
          '<span class="spark">$bars</span></td>');
      buffer.writeln('<td><span class="dots">$dots</span>'
          '<div class="mini">${w.textbookHits}/${w.textbookCounts.length} 版本 · ${w.textbookTotal} 次</div></td>');
      buffer.writeln('<td>');
      if (o != null) {
        buffer.writeln('<p class="ex"><span class="kind orig">原句</span>'
            '${_esc(o.text)}</p>');
      } else {
        buffer.writeln('<p class="ex"><span class="kind orig">原句</span>'
            '<span class="mini">原文未定位到该词形</span></p>');
      }
      if (q != null) {
        buffer.writeln('<p class="ex"><span class="kind">真题</span>'
            '<span class="src">${_esc(q.source)}</span>${_esc(q.text)}</p>');
      } else {
        buffer.writeln('<p class="ex"><span class="kind">真题</span>'
            '<span class="mini">真题语料未收录该词形</span></p>');
      }
      if (t != null) {
        buffer.writeln('<p class="ex"><span class="kind tb">教材</span>'
            '<span class="src tb">${_esc(t.source)}</span>${_esc(t.text)}</p>');
      } else {
        buffer.writeln('<p class="ex"><span class="kind tb">教材</span>'
            '<span class="mini">${w.textbookCounts.length} 套教材均未覆盖 —— 可作为教学缺口信号</span></p>');
      }
      buffer.writeln('</td>');
      buffer.writeln('<td><span class="tag p-${w.suggestionKind}">${_esc(w.suggestionTag)}</span>'
          '<span class="why">${_esc(w.suggestionWhy)}</span></td></tr>');
    }
  }
  buffer.writeln('</tbody></table>');

  buffer.writeln('<div class="foot"><b>统计口径</b>　'
      '词符按全文切词计数，去重后为词形；短语按整条统计，不拆词。'
      '课标词覆盖率＝（课标词 + 拓展变体）次数 / 词符总数。'
      '「原句」为本次导入原文中该词首次出现的句子；真题 / 教材例句与「导出高频」'
      '共用同一择优实现，每词各 1 条。'
      '</div></section></body></html>');
  return buffer.toString();
}

/// 供调用方解析用的编码工具（保持导出文件为 UTF-8）。
List<int> encodeVocabReportHtml(String html) => utf8.encode(html);

/// 生成 Word(docx) 版报告：与页面 / HTML 同一份 [VocabReportData]，
/// 逐词输出频次、教材覆盖、真题 / 教材例句与处理建议，不产生第二套数字。
Uint8List buildVocabReportDocx(VocabReportData d) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  // 剔除 XML 非法控制字符（与「导出高频」同一兜底，避免 Word 拒绝打开）。
  String clean(String s) {
    final buf = StringBuffer();
    for (final rune in s.runes) {
      if (rune == 0x9 ||
          rune == 0xA ||
          rune == 0xD ||
          (rune >= 0x20 && rune <= 0xD7FF) ||
          (rune >= 0xE000 && rune <= 0xFFFD) ||
          (rune >= 0x10000 && rune <= 0x10FFFF)) {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  String para(
    String text, {
    bool bold = false,
    bool center = false,
    int size = 20,
    String? colorHex,
  }) {
    final color =
        (colorHex == null || colorHex.isEmpty) ? '' : '<w:color w:val="$colorHex"/>';
    final rpr = bold
        ? '<w:rPr><w:b/>$color<w:sz w:val="$size"/></w:rPr>'
        : '<w:rPr>$color<w:sz w:val="$size"/></w:rPr>';
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="40" w:after="40"/></w:pPr>'
        '<w:r>$rpr<w:t xml:space="preserve">${esc(clean(text))}</w:t></w:r></w:p>';
  }

  String hexOf(int v) => (v & 0xFFFFFF).toRadixString(16).padLeft(6, '0');

  final body = StringBuffer();
  body.write(para(d.title, bold: true, center: true, size: 36));
  body.write(para(d.subtitle, center: true, size: 20));
  body.write(para(
    '词表基准：2025 修订课标词表 · 真题语料 ${d.corpusFileCount} 套 · '
    '教材语料 ${d.textbookCount} 套 · 生成时间：${d.generatedAt}',
    size: 18,
  ));
  body.write(para(
    '词符总数 ${d.totalTokens} · 去重词形 ${d.distinctTypes} · '
    '课标词覆盖率 ${_pct(d.coverage)} · 超标词 ${d.overTokens} 次（${_pct(d.overRatio)}）',
    size: 18,
  ));
  body.write(para(
    '课标词分级：初中 ${d.levelCounts['初中'] ?? 0} 次 · 必修 ${d.levelCounts['必修'] ?? 0} 次 · '
    '选修 ${d.levelCounts['选修'] ?? 0} 次 · 拓展变体 ${d.extendTokens} 次',
    size: 18,
  ));
  body.write(para(d.conclusion, size: 19));
  body.write(para('建议：${d.advice}', size: 19));
  body.write(para(''));

  for (final g in d.groups) {
    body.write(para(
      '${g.name}（${g.wordCount} 个词 · 本篇 ${g.tokenCount} 次）',
      bold: true,
      size: 24,
      colorHex: hexOf(g.colorValue),
    ));
    for (var i = 0; i < g.words.length; i++) {
      final w = g.words[i];
      body.write(para(
        '${i + 1}. ${w.word}（${w.badge}） 真题频次：${w.corpusFreq} 次 · '
        '本篇 ${w.textFreq} 次 · 教材覆盖 ${w.textbookHits}/${w.textbookCounts.length} 版本',
        bold: true,
        size: 20,
      ));
      final o = w.textExample;
      body.write(para(
        '　原文原句：${o == null ? '原文未定位到该词形' : o.text}',
        size: 18,
      ));
      final q = w.questionExample;
      body.write(para(
        '　真题例句：${q == null ? '真题语料未收录该词形' : '${q.source.isEmpty ? '' : '『${q.source}』'}${q.text}'}',
        size: 18,
      ));
      final t = w.textbookExample;
      body.write(para(
        '　教材例句：${t == null ? '${w.textbookCounts.length} 套教材均未覆盖' : '${t.source.isEmpty ? '' : '『${t.source}』'}${t.text}'}',
        size: 18,
      ));
      body.write(para(
        '　处理建议：${w.suggestionTag}（${w.suggestionWhy}）',
        size: 18,
      ));
    }
    body.write(para(''));
  }
  body.write(para(
    '统计口径：词符按全文切词计数，去重后为词形；短语按整条统计，不拆词。'
    '课标词覆盖率＝（课标词 + 拓展变体）次数 / 词符总数。'
    '「原文原句」为该词在本次导入原文中首次出现的句子；真题 / 教材例句与'
    '「导出高频」共用同一择优实现。',
    size: 17,
  ));

  final documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>'
      '</w:body></w:document>';

  const contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';

  const rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';

  final archive = Archive();
  final ctBytes = utf8.encode(contentTypes);
  final relBytes = utf8.encode(rels);
  final docBytes = utf8.encode(documentXml);
  archive.addFile(ArchiveFile('[Content_Types].xml', ctBytes.length, ctBytes));
  archive.addFile(ArchiveFile('_rels/.rels', relBytes.length, relBytes));
  archive.addFile(
      ArchiveFile('word/document.xml', docBytes.length, docBytes));
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw Exception('Word 报告生成失败');
  return Uint8List.fromList(encoded);
}
