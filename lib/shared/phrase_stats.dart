// 课标短语整条识别、短语覆盖关系与大小写异义词组。
//
// 检测页与高频导出共用本文件，三类口径必须一致：
//  1. 哪些课标词条算「短语」（含空格、纯词形）；
//  2. 短语与组成词何时按覆盖关系合并成一个词频；
//  3. 哪些词条是「仅大小写不同、词义不同」的异义词组
//     （March/march、May/may、Miss/miss、China/china、OK/ok）。
import 'text_normalize.dart';
import 'word_family.dart';

/// 课标短语表：折叠小写整条 -> 原始词形。
///
/// 只接受纯词形（字母/撇号/连字符/空格）；带大写专名或括号说明的词条
/// （New York、UNESCO (...) 等）不按短语整条统计，避免把专名/机构名
/// 当成普通搭配。
Map<String, String> buildStandardPhrases(Iterable<String> standardKeys) {
  final out = <String, String>{};
  for (final k in standardKeys) {
    final lk = foldWordText(k).trim().toLowerCase();
    if (lk.isEmpty || !lk.contains(' ')) continue;
    if (!RegExp(r"^[a-z][a-z'\- ]*$").hasMatch(lk)) continue;
    out.putIfAbsent(lk, () => k);
  }
  return out;
}

final Map<String, RegExp> _phraseRegexCache = <String, RegExp>{};

/// 短语整条匹配：词间允许空白/不换行空格/连字符，忽略大小写，前后词边界。
RegExp phraseRegExp(String phrase) {
  return _phraseRegexCache.putIfAbsent(phrase, () {
    final parts = phrase
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .map(RegExp.escape)
        .join(r'[\s\u00A0\-]+');
    return RegExp(
      '(?<![A-Za-z0-9])$parts(?![A-Za-z0-9])',
      caseSensitive: false,
    );
  });
}

/// 短语首词（折叠小写）。覆盖关系以首词为判据：
/// according to 只看 according 是否每次出现都落在短语内。
String phraseHead(String phrase) => phrase.split(' ').first;

/// 大小写异义词组：小写规范键 -> 原始的大小写写法。
///
/// 仅当「小写形」和「大写/混合大小写形」都作为独立课标词条存在时成立，
/// 避免把 I、London 这类只有一个写法的词误判成异义词组。
Map<String, List<String>> buildCaseVariantGroups(Iterable<String> standardKeys) {
  final keys = <String>{...standardKeys};
  final out = <String, List<String>>{};
  for (final k in keys) {
    final lk = foldWordText(k).trim().toLowerCase();
    if (lk.isEmpty || k == lk) continue;
    if (!keys.contains(lk)) continue;
    (out[lk] ??= <String>[]).add(k);
  }
  return out;
}

/// 非句首大写专有词判据（检测页与高频导出共用同一实现）。
///
/// 语义与导出侧原内联实现完全一致：
///  - 句首 token 不参与判定（句首大写是正常句法现象）；
///  - 全大写缩写若已按同义词归并（TV→television），不按专有词剔除；
///  - [properSet]：非句首出现 >= 3 次且大写占比 >= 0.75（长度 > 1）；
///  - [nonHeadCapsExcluded]：非句首出现 >= 2 次、大写占比 >= 0.5，且原文非全大写、
///    含小写字母且归一键不在课标词集合内（Londoners 这类派生专名）。
///
/// 用法：逐句按 token 顺序调用 [addToken]（首 token 传 isFirstInSentence: true），
/// 累计完成后取 [excluded]。
class ProperNounStats {
  ProperNounStats({required this.standardWords});

  /// 课标词统计键集合（折叠小写、不含专有词类别），与导出 stdSet 同口径。
  final Set<String> standardWords;

  final Map<String, int> _capNonHead = <String, int>{};
  final Map<String, int> _totalNonHead = <String, int>{};
  final Map<String, int> _nonHeadCaps = <String, int>{};

  static final RegExp _allCapsRe = RegExp(r'^[A-Z]+$');
  static final RegExp _upperStartRe = RegExp(r'^[A-Z]');
  static final RegExp _lowerRe = RegExp(r'[a-z]');

  /// 累计一个 token。[raw] 为原文词形，[word] 为归一后的统计键。
  void addToken(String raw, String word, {required bool isFirstInSentence}) {
    if (isFirstInSentence) return;
    final aliasCaps = _allCapsRe.hasMatch(raw) &&
        builtinWordAliases.containsKey(raw.toLowerCase());
    if (!aliasCaps && raw.isNotEmpty && _upperStartRe.hasMatch(raw)) {
      _capNonHead[word] = (_capNonHead[word] ?? 0) + 1;
      if (raw.length > 1 &&
          _lowerRe.hasMatch(raw) &&
          !standardWords.contains(word)) {
        _nonHeadCaps[word] = (_nonHeadCaps[word] ?? 0) + 1;
      }
    }
    _totalNonHead[word] = (_totalNonHead[word] ?? 0) + 1;
  }

  /// 非句首大写占比 >= 75%（至少 3 次）→ 专有词。
  Set<String> get properSet {
    final out = <String>{};
    for (final w in _totalNonHead.keys) {
      if (w.length <= 1) continue;
      final total = _totalNonHead[w]!;
      final cap = _capNonHead[w] ?? 0;
      if (total >= 3 && cap / total >= 0.75) out.add(w);
    }
    return out;
  }

  /// 非句首大写占比 >= 50%（至少 2 次）→ 表外专名候选（Londoners 等）。
  Set<String> get nonHeadCapsExcluded {
    final out = <String>{};
    for (final w in _nonHeadCaps.keys) {
      final total = _totalNonHead[w] ?? 0;
      final cap = _capNonHead[w] ?? 0;
      if (total >= 2 && cap / total >= 0.5) out.add(w);
    }
    return out;
  }

  /// 两者并集：导出侧整词排除、检测页自动归「专有词」的同一判据。
  Set<String> get excluded => <String>{...properSet, ...nonHeadCapsExcluded};
}

/// 查询词命中的短语键（用于页面/导出把「according」与「according to」
/// 归到同一目标）。查询本身是短语优先，其次查询是某短语首词。
String? phraseTargetFor(String word, Map<String, String> phrases) {
  final lw = foldToken(word.trim());
  if (phrases.containsKey(lw)) return lw;
  for (final p in phrases.keys) {
    if (phraseHead(p) == lw) return p;
  }
  return null;
}

/// 单个短语的覆盖统计。
class PhraseCoverage {
  PhraseCoverage(this.phrase, this.head);

  final String phrase;
  final String head;

  /// 短语整条出现次数。
  int phraseCount = 0;

  /// 首词出现在短语区间内的次数。
  int coveredHeadCount = 0;

  /// 首词每次出现都被该短语覆盖 → 合并为一个词频。
  bool merged = false;
}

/// 短语覆盖累计器：按文件逐个累计，最后统一判定是否合并。
///
/// 判据是覆盖关系（首词的每次出现都落在短语匹配区间内），不是
/// 「短语次数 == 首词次数」的数值巧合。
class PhraseCoverageTracker {
  PhraseCoverageTracker(Map<String, String> phrases)
      : _items = {
          for (final p in phrases.keys) p: PhraseCoverage(p, phraseHead(p)),
        };

  final Map<String, PhraseCoverage> _items;
  final Map<String, int> _headTotal = <String, int>{};

  /// 从一段已归一化文本累计（检测页便捷入口；内部自行分词）。
  void addText(String text) {
    final heads = {for (final c in _items.values) c.head};
    final headSpans = <String, List<(int, int)>>{};
    for (final m in wordTokenRegExp.allMatches(text)) {
      final lw = foldToken(m.group(0)!);
      if (!heads.contains(lw)) continue;
      (headSpans[lw] ??= <(int, int)>[]).add((m.start, m.end));
    }
    final phraseSpans = <String, List<(int, int)>>{};
    for (final p in _items.keys) {
      final spans = [
        for (final m in phraseRegExp(p).allMatches(text)) (m.start, m.end),
      ];
      if (spans.isNotEmpty) phraseSpans[p] = spans;
    }
    addPositions(headTokenSpans: headSpans, phraseSpans: phraseSpans);
  }

  /// 从已分词结果累计（导出复用已有 token 循环，避免重复分词）。
  void addPositions({
    required Map<String, List<(int, int)>> headTokenSpans,
    required Map<String, List<(int, int)>> phraseSpans,
  }) {
    final addedHeads = <String>{};
    for (final c in _items.values) {
      final toks = headTokenSpans[c.head] ?? const <(int, int)>[];
      final spans = phraseSpans[c.phrase] ?? const <(int, int)>[];
      c.phraseCount += spans.length;
      if (toks.isEmpty) continue;
      // 同一首词可能被多个短语共享：首词总数只累计一次。
      if (addedHeads.add(c.head)) {
        _headTotal[c.head] = (_headTotal[c.head] ?? 0) + toks.length;
      }
      for (final t in toks) {
        for (final s in spans) {
          if (t.$1 >= s.$1 && t.$2 <= s.$2) {
            c.coveredHeadCount++;
            break;
          }
        }
      }
    }
  }

  /// 结算覆盖关系（可在累计完成后重复调用）。
  Map<String, PhraseCoverage> result() {
    for (final c in _items.values) {
      final total = _headTotal[c.head] ?? 0;
      c.merged = total > 0 && c.coveredHeadCount == total;
    }
    return _items;
  }

  bool isMerged(String phrase) => result()[phrase]?.merged ?? false;
}
