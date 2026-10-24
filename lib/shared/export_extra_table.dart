/// 导出结果文档末尾「拓展词表格」构建模块（双端共用）。
///
/// 功能：把检测出的拓展词按题型（听力/阅读/七选五/完形填空/语法填空/改错/写作）
/// 分组，并为每个拓展词从真题原文中提取一个较短例句（同一拓展词全局只列一次），
/// 最终生成 DOCX 表格 XML 或纯文本表格，供 Android / Windows 导出结果文档在末尾追加。
library;

/// 单行拓展词数据
class ExtendRowData {
  final String word; // 拓展词
  final String example; // 该拓展词在真题中的例句（选较短者）
  final String baseWord; // 对应课标原词
  const ExtendRowData({
    required this.word,
    required this.example,
    required this.baseWord,
  });
}

/// 单个题型区块
class ExtendSection {
  final String name; // 题型名
  final List<ExtendRowData> rows; // 该题型下的拓展词行
  const ExtendSection({required this.name, required this.rows});
}

/// 题型识别规则（有序，顺序即优先级与文档内典型出现顺序）。
///
/// 识别策略：按「单词所在段落前面的汉语要求（题型标题行）」定位题型边界。
/// 关键词取较具体的短语，避免与正文混淆：阅读只认“阅读理解”或行首“阅读（/阅读共”，
/// 七选五认“七选五/根据短文内容”，完形填空认“完形填空/完型”，
/// 语法填空认“语法填空/在空白处填入/用括号内”等。
class _SectionRule {
  final String name;
  final RegExp re;
  const _SectionRule(this.name, this.re);
}

final List<_SectionRule> _sectionRules = [
  _SectionRule('听力', RegExp(r'听力')),
  _SectionRule('阅读', RegExp(r'阅读理解|^\s*阅读[（(共]|阅读[（(共]')),
  _SectionRule('七选五', RegExp(r'七选五|根据短文内容')),
  _SectionRule('完形填空', RegExp(r'完形填空|完型填空|完形|完型')),
  _SectionRule('语法填空', RegExp(r'语法填空|短文填空|适当形式填空|在空白处填入|用括号内')),
  _SectionRule('改错', RegExp(r'短文改错|^\s*改错|改错[（(共]')),
  _SectionRule('写作', RegExp(r'书面表达|写作[（(共]|^\s*写作')),
];

/// 句子切分/选项碎片/汉字/词切分等正则均为模块级复用，避免在例句提取
/// 热路径中反复编译；单词匹配用 indexOf + 字母边界手工校验代替正则。
final RegExp _sentenceRe = RegExp(r'[^.!?。！？]+[.!?。！？]');
final RegExp _optionRe = RegExp(r'^\s*[A-Ha-h]\s*[.)．]');
final RegExp _wsRe = RegExp(r'\s+');
final RegExp _hanRe = RegExp(r'[\u4e00-\u9fa5]');
final RegExp _alphaSplitRe = RegExp(r'[^a-zA-Z]+');
final RegExp _subSplitRe = RegExp(r'[,;，；]');
/// 常见缩写保护：Dr. / No. / Jan. 等缩写点与数字点不被当作句尾标点。
/// 注意：Dart RegExp 不支持 (?i) 内联标志，必须用 caseSensitive: false。
final RegExp _abbrWordRe = RegExp(
    r'\b(?:dr|mr|mrs|ms|st|mt|prof|jr|sr|no|vs|etc|e\.g|i\.e|u\.s|u\.k|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\.',
    caseSensitive: false);
/// 半句截断开头：以逗号/分号或连词（and/but/or/while/although/though/because/so）开头的句子视为不完整。
final RegExp _leadConnectorRe =
    RegExp(r'^\s*(?:[,;，；]|and\b|but\b|or\b|while\b|although\b|though\b|because\b|so\b)');
/// 选项字母结尾：如 "researchers C." / "hosted B."（单个大写选项字母 + 句点，
/// 前面须有词边界，避免误伤 coming./with./each. 等以 a-h 结尾的普通单词）。
final RegExp _trailOptionRe = RegExp(r'\b[A-H]\.\s*$');
/// 题号残留结尾：如 "automatically 62." / "inspiration 51."。
final RegExp _trailNumRe = RegExp(r'\d+\.\s*$');
/// 完形选项粘连剥离：hostedB -> hosted；要求小写词干(>=3)+单个大写选项字母。
final RegExp _optionLetterRe = RegExp(r'^([a-z]{3,})([A-H])$');
/// 数字后句点（1.5 / 62. / 2026.）保护用。
final RegExp _digitDotRe = RegExp(r'(\d)\.');

/// 判断 [s]（小写文本）中是否包含单词 [w]（小写），且词两侧非字母（词边界）。


/// 例句偏好比较：不含汉字 > 不含下划线 > 词数档位 > 最短。
int _compareExample(String a, String b) {
  final hasHanA = _hanRe.hasMatch(a);
  final hasHanB = _hanRe.hasMatch(b);
  if (hasHanA != hasHanB) return hasHanA ? 1 : -1;
  if (a.contains('_') != b.contains('_')) return a.contains('_') ? 1 : -1;
  int wordRank(String s) {
    final n = s.split(_alphaSplitRe).where((x) => x.isNotEmpty).length;
    return n >= 3 ? 2 : (n >= 2 ? 1 : 0);
  }
  final ra = wordRank(a);
  final rb = wordRank(b);
  if (ra != rb) return rb - ra;
  return a.length.compareTo(b.length);
}

/// 保护缩写/数字中的句点，避免被切句正则误判为句尾标点：
/// 先将缩写点（Dr./No./Jan. 等）替换为私有占位符 \uE000，再保护数字后句点；
/// 调用方在切句后把 \uE000 还原为 '.'。
String _protectAbbrDots(String s) {
  var out = s.replaceAllMapped(
      _abbrWordRe, (m) => m.group(0)!.replaceAll('.', '\uE000'));
  out = out.replaceAllMapped(_digitDotRe, (m) => '${m.group(1)}\uE000');
  return out;
}

/// 判断句子是否不合格（宁缺毋滥：不合格句子一律不进入候选池）。
///
/// 任一命中即不合格：长度 <3；含汉字；以选项字母开头（A. / B) / C．）；
/// 词数 <4（会误伤少量 3 词以内的正常短句/祈使句，权衡取舍：例句质量优先、
/// 宁缺毋滥，短句宁可不输出）；以逗号/连词开头（半句截断）；以选项字母结尾；
/// 以题号残留结尾。
bool _isBadSentence(String s) {
  final t = s.trim();
  if (t.length < 3) return true;
  if (_hanRe.hasMatch(t)) return true;
  if (_optionRe.hasMatch(t)) return true;
  if (t.split(_alphaSplitRe).where((x) => x.isNotEmpty).length < 4) return true;
  if (_leadConnectorRe.hasMatch(t)) return true;
  if (_trailOptionRe.hasMatch(t)) return true;
  if (_trailNumRe.hasMatch(t)) return true;
  return false;
}

/// 剥离完形选项粘连字母：hostedB -> hosted；无粘连时返回原词。
String _stripOptionLetter(String w) {
  final m = _optionLetterRe.firstMatch(w);
  if (m != null) return m.group(1)!;
  return w;
}

/// 句中单词拆分用（保持与 buildExtendSections 的词切分一致）。
final RegExp _wordSplitRe = RegExp(r'[a-zA-Z]+');

/// 判断句子（保留原文大小写）是否包含目标单词（小写，已剥离选项字母）。
///
/// 逐词比较并剥离完形选项粘连（hostedB -> hosted 后与目标词相等即命中），
/// 解决"原文只有粘连形式、无独立词形时取不到例句"的问题。
bool _containsWordInSentence(String sentence, String wLower) {
  if (!sentence.toLowerCase().contains(wLower)) return false; // 快速预检
  for (final m in _wordSplitRe.allMatches(sentence)) {
    // 先剥离（保留原文大小写，hostedB -> hosted），再小写比较
    if (_stripOptionLetter(m.group(0)!).toLowerCase() == wLower) return true;
  }
  return false;
}

/// 句子索引：对同一大文本只做一次空格归一化 / 小写化 / 切句，
/// 供多次例句查询复用（避免每个词都对全文重复扫描）。
class SentenceIndex {
  final String flat; // 原文（空格归一化）
  final String flatLower; // 小写版
  final List<(int, int)> spans; // 已 trim 的句子区间 [start, end)
  const SentenceIndex(this.flat, this.flatLower, this.spans);
}

/// 构建 [text] 的句子索引。
SentenceIndex buildSentenceIndex(String text) {
  final flat = text.replaceAll(_wsRe, ' ');
  final flatLower = flat.toLowerCase();
  // 切句前保护缩写/数字句点，避免 Dr. / 62. 等被误判为句尾
  final protected = _protectAbbrDots(flat);
  final spans = <(int, int)>[];
  for (final m in _sentenceRe.allMatches(protected)) {
    final raw = m.group(0)!;
    final trimmedRaw = raw.trim();
    final t = trimmedRaw.replaceAll('\uE000', '.'); // 还原缩写点
    if (t.length < 3 || _isBadSentence(t)) continue; // 不合格句子不进索引
    final lead = raw.indexOf(trimmedRaw);
    spans.add((m.start + lead, m.start + lead + t.length));
  }
  return SentenceIndex(flat, flatLower, spans);
}

/// 在 [idx] 中查找同时包含 [words] 全部词的较短例句（词边界匹配）；
/// 找不到全部词且 [fallbackToFirst] 为 true 时，退化到仅包含第一个词的例句；
/// 仍无结果或 [requireAll] 且未开启退化时返回空串。
String pickExampleFromIndex(
  SentenceIndex idx,
  List<String> words, {
  bool requireAll = false,
  bool fallbackToFirst = false,
}) {
  final ws = words
      .map((w) => _stripOptionLetter(w).toLowerCase())
      .where((w) => w.isNotEmpty)
      .toSet()
      .toList();
  if (ws.isEmpty || idx.spans.isEmpty) return '';
  // 整文本快速预检：目标词不在语料中则直接返回（避免逐句拆词开销）
  if (!idx.flatLower.contains(ws.first)) return '';
  final candidates = <String>[];
  final firstCandidates = <String>[]; // 仅含首词的候选（退化兜底）
  final firstW = ws.first;
  for (final (s, e) in idx.spans) {
    final segLower = idx.flatLower.substring(s, e);
    if (!segLower.contains(firstW)) continue;
    final raw = idx.flat.substring(s, e); // 保留原始大小写
    if (!_containsWordInSentence(raw, firstW)) continue;
    firstCandidates.add(raw);
    var ok = true;
    for (var i = 1; i < ws.length; i++) {
      if (!_containsWordInSentence(raw, ws[i])) {
        ok = false;
        break;
      }
    }
    if (ok) candidates.add(raw);
  }
  var pool = candidates;
  if (pool.isEmpty && !requireAll && fallbackToFirst) pool = firstCandidates;
  if (pool.isEmpty) return '';

  String best = pool.first;
  for (final s in pool.skip(1)) {
    if (_compareExample(s, best) < 0) best = s;
  }

  // 过长时按逗号/分号细分兜底
  if (best.length > 100) {
    final parts = best.split(_subSplitRe);
    if (parts.length > 1) {
      String? subBest;
      final firstW2 = firstW;
      for (final part in parts) {
        final p = part.trim();
        if (p.length < 3) continue;
        if (_isBadSentence(p)) continue; // 子段不合格则跳过
        if (!_containsWordInSentence(p, firstW2)) continue;
        if (subBest == null || p.length < subBest.length) subBest = p;
      }
      if (subBest != null) best = subBest;
      // 全部子段不合格 → 保留整句（不再细分）
    }
  }
  return best;
}

/// 一次扫描句子索引，为所有目标词（小写，已剥离完形选项字母）收集候选例句。
///
/// 用于导出明细例句提速：原来“每个词 × 每个文件”都要全量扫描一遍句子，
/// 现在每个文件只切句扫描一次，所有目标词的整句候选一次收集完毕，
/// 再配合 [pickBestCandidate] 择优，语义与原 `pickExampleFromIndex` +
/// 跨文件汇总择优一致。
///
/// 返回 Map：词(小写) -> 候选句列表（保留原文大小写）。超长候选（>100 字符）
/// 已按逗号/分号细分取最短含词子段，与 [pickExampleFromIndex] 行为一致。
Map<String, List<String>> collectSentenceCandidates(
  SentenceIndex idx,
  Set<String> targets,
) {
  final result = <String, List<String>>{};
  if (targets.isEmpty || idx.spans.isEmpty) return result;
  for (final (s, e) in idx.spans) {
    final raw = idx.flat.substring(s, e);
    final hitWords = <String>{};
    for (final m in _wordSplitRe.allMatches(raw)) {
      final w = _stripOptionLetter(m.group(0)!).toLowerCase();
      if (targets.contains(w)) hitWords.add(w);
    }
    if (hitWords.isEmpty) continue;
    for (final w in hitWords) {
      (result[w] ??= <String>[]).add(raw);
    }
  }
  // 超长候选细分兜底（与 pickExampleFromIndex 一致）
  for (final w in result.keys) {
    final list = result[w]!;
    for (var i = 0; i < list.length; i++) {
      final s = list[i];
      if (s.length <= 100) continue;
      final parts = s.split(_subSplitRe);
      if (parts.length <= 1) continue;
      String? subBest;
      for (final part in parts) {
        final p = part.trim();
        if (p.length < 3) continue;
        if (_isBadSentence(p)) continue;
        if (!_containsWordInSentence(p, w)) continue;
        if (subBest == null || p.length < subBest.length) subBest = p;
      }
      if (subBest != null) list[i] = subBest;
    }
  }
  return result;
}

/// 从候选例句列表选出最优（择优口径与 [pickExampleFromIndex] 一致：
/// 不含汉字 > 不含下划线 > 词数>=3 > 最短），超长时再按逗号/分号细分兜底。
/// [wordLower] 须为小写、已剥离完形选项字母的目标词。
String pickBestCandidate(List<String> candidates, String wordLower) {
  if (candidates.isEmpty) return '';
  String best = candidates.first;
  for (final s in candidates.skip(1)) {
    if (_compareExample(s, best) < 0) best = s;
  }
  if (best.length > 100) {
    final parts = best.split(_subSplitRe);
    if (parts.length > 1) {
      String? subBest;
      for (final part in parts) {
        final p = part.trim();
        if (p.length < 3) continue;
        if (_isBadSentence(p)) continue;
        if (!_containsWordInSentence(p, wordLower)) continue;
        if (subBest == null || p.length < subBest.length) subBest = p;
      }
      if (subBest != null) best = subBest;
    }
  }
  return best;
}

/// 从一段文本中提取包含 [word] 的句子，优先返回较短的完整例句。
///
/// 规则：
/// a) 按句号/问号/感叹号切句（句尾标点 . ! ? 。！？）；
/// b) 候选句必须包含目标单词（词边界匹配）；
/// c) 排除以选项字母前缀开头（如 "A." / "B)" / "C．"）的碎片句；
/// d) 偏好排序（优先级从高到低）：不含汉字 > 不含下划线 > 词数>=3（降级 >=2 再 >=1），同级取最短；
/// e) 最优候选超过约 100 字符时，按逗号/分号细分，取包含目标单词的最短子段兜底；
/// f) [requireAll]=true 时（配合 [extraWords]），候选句必须同时包含 word 与全部 extraWords。
///
/// 性能说明：文本只小写化一次，句子子串用 indexOf + 字母边界手工校验，
/// 避免对每句重复编译/执行正则；对同一大文本做多次查询请改用
/// [buildSentenceIndex] + [pickExampleFromIndex]。
String pickShortExample(
  String text,
  String word, {
  List<String> extraWords = const [],
  bool requireAll = false,
}) {
  if (text.isEmpty || word.isEmpty) return '';
  final flat = text.replaceAll(_wsRe, ' ');
  final flatLower = flat.toLowerCase();
  // 词列表构建前剥离完形选项粘连字母（hostedB -> hosted）
  final coreWord = _stripOptionLetter(word);
  final allWords = <String>[coreWord, ...extraWords.map(_stripOptionLetter)]
      .map((w) => w.toLowerCase())
      .where((w) => w.isNotEmpty)
      .toSet()
      .toList();
  if (allWords.isEmpty) return '';
  // 整文本快速预检：目标词不在文本中则直接返回
  if (!flatLower.contains(allWords.first)) return '';

  final candidates = <String>[];
  // 切句前保护缩写/数字句点，避免 Dr. / 62. 等被误判为句尾
  final protected = _protectAbbrDots(flat);
  for (final m in _sentenceRe.allMatches(protected)) {
    final s = m.group(0)!.trim().replaceAll('\uE000', '.'); // 还原缩写点
    if (s.length < 3 || _isBadSentence(s)) continue; // c)+宁缺毋滥
    final seg = flat.substring(m.start, m.end); // 原文大小写
    var ok = true;
    for (final w in allWords) {
      if (!_containsWordInSentence(seg, w)) {
        ok = false;
        break;
      }
    }
    if (!ok) continue; // b)+f) 必须含全部目标词（词边界）
    candidates.add(s);
  }
  if (candidates.isEmpty) return '';

  // d) 多级偏好比较：不含汉字 > 不含下划线 > 词数档位 > 最短
  String best = candidates.first;
  for (final s in candidates.skip(1)) {
    if (_compareExample(s, best) < 0) best = s;
  }

  // e) 过长时按逗号/分号细分兜底
  if (best.length > 100) {
    final parts = best.split(_subSplitRe);
    if (parts.length > 1) {
      String? subBest;
      final firstW = allWords.first;
      for (final part in parts) {
        final p = part.trim();
        if (p.length < 3) continue;
        if (_isBadSentence(p)) continue; // 子段不合格则跳过
        if (!_containsWordInSentence(p, firstW)) continue;
        if (subBest == null || p.length < subBest.length) subBest = p;
      }
      if (subBest != null) best = subBest;
      // 全部子段不合格 → 保留整句（不再细分）
    }
  }
  return best;
}

/// 统计 [s] 中的单词数（字母串计数，与例句质量规则口径一致）。
int _wordCountOf(String s) =>
    s.split(_alphaSplitRe).where((x) => x.isNotEmpty).length;

/// 从 [sentence]（保留原文大小写）中以 [word]（小写、已剥离选项字母）为中心，
/// 截取一个 3-4 词的结构/词组（如 stylish -> "with its stylish design"）。
///
/// 窗口策略：先取前 1 后 1（3 词）；不足 4 词时优先向前扩展（保持右侧搭配完整）；
/// 句首/句尾边界词不足时向另一侧扩展；窗口结尾为介词/连词等虚词时向后补 1 词
/// 避免结构悬空（如 "overhead in" -> "overhead in the"）；整句词数不超过 5 时
/// 直接返回整句。
final Set<String> _phraseTrailingStopWords = {
  'a', 'an', 'the', 'of', 'in', 'on', 'at', 'to', 'with', 'for', 'from',
  'by', 'into', 'over', 'under', 'about', 'through', 'after', 'before',
  'between', 'without', 'along', 'around', 'behind', 'below', 'beyond',
  'despite', 'during', 'except', 'onto', 'upon', 'via', 'within', 'toward',
  'towards', 'and', 'but', 'or', 'so', 'as', 'because', 'while', 'although',
  'though', 'if', 'when', 'that',
};

String _phraseFromSentence(String sentence, String word) {
  final tokens = <String>[];
  final starts = <int>[];
  final ends = <int>[];
  for (final m in _wordSplitRe.allMatches(sentence)) {
    tokens.add(m.group(0)!);
    starts.add(m.start);
    ends.add(m.end);
  }
  if (tokens.isEmpty) return '';
  if (tokens.length <= 5) return sentence.trim();
  int? idx;
  for (var i = 0; i < tokens.length; i++) {
    if (_stripOptionLetter(tokens[i]).toLowerCase() == word) {
      idx = i;
      break;
    }
  }
  if (idx == null) return '';
  var s = idx, e = idx;
  if (s > 0) s--;
  if (e < tokens.length - 1) e++;
  if (e - s + 1 < 4 && s > 0) s--;
  if (e - s + 1 < 4 && e < tokens.length - 1) e++;
  // 结尾为虚词时向后补 1 词，避免介词/连词悬空收尾
  if (e - s + 1 <= 4 &&
      e < tokens.length - 1 &&
      _phraseTrailingStopWords.contains(tokens[e].toLowerCase())) {
    e++;
  }
  return sentence.substring(starts[s], ends[e]).trim();
}

/// 从整段文本 [text] 中提取包含 [word] 的词组/结构（整句提取失败/过长时的降级）。
/// 逐句定位目标词并截取 3-5 词窗口，多候选取最短；找不到目标词返回空串。
String pickPhrase(String text, String word) {
  if (text.isEmpty || word.isEmpty) return '';
  final core = _stripOptionLetter(word).toLowerCase();
  if (core.isEmpty) return '';
  final flat = text.replaceAll(_wsRe, ' ');
  final flatLower = flat.toLowerCase();
  if (!flatLower.contains(core)) return '';
  final protected = _protectAbbrDots(flat);
  String? best;
  for (final m in _sentenceRe.allMatches(protected)) {
    final seg = flat.substring(m.start, m.end); // 原文大小写
    if (!_containsWordInSentence(seg, core)) continue;
    // 跳过含中文的句子（试卷题干/汉语说明混入时宁缺毋滥），
    // 保证降级词组/结构也只会来自纯英文例句
    if (_hanRe.hasMatch(seg)) continue;
    final ph = _phraseFromSentence(seg, core);
    if (ph.isNotEmpty && (best == null || ph.length < best.length)) best = ph;
  }
  return best ?? '';
}

/// 从句子索引 [idx] 中提取包含 [words] 首词的词组/结构（整句提取失败/过长时的降级）。
/// 逻辑同 [pickPhrase]，但复用 [SentenceIndex] 避免对同一大文本重复切句。
String pickPhraseFromIndex(SentenceIndex idx, List<String> words) {
  final ws = words
      .map((w) => _stripOptionLetter(w).toLowerCase())
      .where((w) => w.isNotEmpty)
      .toSet()
      .toList();
  if (ws.isEmpty || idx.spans.isEmpty) return '';
  final firstW = ws.first;
  if (!idx.flatLower.contains(firstW)) return '';
  String? best;
  for (final (s, e) in idx.spans) {
    final segLower = idx.flatLower.substring(s, e);
    if (!segLower.contains(firstW)) continue;
    final raw = idx.flat.substring(s, e);
    if (!_containsWordInSentence(raw, firstW)) continue;
    final ph = _phraseFromSentence(raw, firstW);
    if (ph.isNotEmpty && (best == null || ph.length < best.length)) best = ph;
  }
  return best ?? '';
}

/// 从整段文本 [text] 中提取包含 [words]（首词必含）的完整句子，
/// 返回保留到句号/问号/感叹号等真正结束符的完整例句。
///
/// 与 [pickShortExample] / [pickExampleFromIndex] 的区别：不做词数上限、
/// 不做超过一定长度后的逗号/分号细分、不因句子以连词（and/but/so 等）或
/// 逗号开头而判为不合格——教材等正常英文语料中这类句子是完整句，
/// 细分/过滤只会得到被截断的半句。候选句必须不含中文。
/// [words] 为多个时优先取同时包含全部词的句子；[fallbackToFirst] 为 true
/// 且找不到全词句时退化到仅包含首词的句子。
String pickFullSentenceFromText(
  String text,
  List<String> words, {
  bool fallbackToFirst = false,
}) {
  final ws = words
      .map((w) => _stripOptionLetter(w).toLowerCase())
      .where((w) => w.isNotEmpty)
      .toSet()
      .toList();
  if (ws.isEmpty || text.isEmpty) return '';
  final flat = text.replaceAll(_wsRe, ' ');
  final flatLower = flat.toLowerCase();
  if (!flatLower.contains(ws.first)) return '';
  final protected = _protectAbbrDots(flat);
  final fullCandidates = <String>[];
  final firstCandidates = <String>[];
  for (final m in _sentenceRe.allMatches(protected)) {
    final s = m.group(0)!.trim().replaceAll('\uE000', '.');
    if (s.length < 3 || _hanRe.hasMatch(s)) continue; // 排除中文句/题干
    final seg = flat.substring(m.start, m.end);
    if (!_containsWordInSentence(seg, ws.first)) continue;
    firstCandidates.add(s);
    var ok = true;
    for (var i = 1; i < ws.length; i++) {
      if (!_containsWordInSentence(seg, ws[i])) {
        ok = false;
        break;
      }
    }
    if (ok) fullCandidates.add(s);
  }
  var pool = fullCandidates;
  if (pool.isEmpty && fallbackToFirst) pool = firstCandidates;
  if (pool.isEmpty) return '';
  String best = pool.first;
  for (final s in pool.skip(1)) {
    if (s.length < best.length) best = s; // 完整句优先取较短者
  }
  return best;
}

/// 教材"完整句"索引：与 [SentenceIndex] 不同，不做"宁缺毋滥"过滤
/// （不因连词开头/逗号开头/词数 <4 而剔除），只排除长度 <3 与含中文的句子，
/// 语义与 [pickFullSentenceFromText] 的候选池完全一致。
///
/// 存在的理由：原实现对每个拓展词都调用一次 [pickFullSentenceFromText]，
/// 每次都要对整篇教材文本做空格归一化 + 缩写保护 + 全量切句，
/// 成本是「词数 × 教材全文长度」，是导出明细最大的耗时来源。
/// 这里只建一次索引，之后每个词只做一次 O(句子数) 的轻量匹配。
class FullSentenceIndex {
  /// 已 trim、已还原缩写点的完整句（保留原文大小写）。
  final List<String> sentences;

  /// 与 [sentences] 一一对应的小写版，用于 contains 快速预检。
  final List<String> lowers;

  const FullSentenceIndex(this.sentences, this.lowers);

  bool get isEmpty => sentences.isEmpty;
  int get length => sentences.length;
}

/// 构建 [text] 的完整句索引（见 [FullSentenceIndex] 的说明）。
FullSentenceIndex buildFullSentenceIndex(String text) {
  if (text.isEmpty) return const FullSentenceIndex(<String>[], <String>[]);
  final flat = text.replaceAll(_wsRe, ' ');
  final protected = _protectAbbrDots(flat);
  final sentences = <String>[];
  final lowers = <String>[];
  for (final m in _sentenceRe.allMatches(protected)) {
    final s = m.group(0)!.trim().replaceAll('\uE000', '.');
    if (s.length < 3) continue;
    if (_hanRe.hasMatch(s)) continue; // 排除中文句/题干
    sentences.add(s);
    lowers.add(s.toLowerCase());
  }
  return FullSentenceIndex(sentences, lowers);
}

/// 在 [FullSentenceIndex] 上查找同时包含 [words] 全部词的完整句，
/// 返回其中最短的一句；[fallbackToFirst] 为 true 且无全词句时退化到仅含首词的句子。
/// 语义与 [pickFullSentenceFromText] 一致，但每个词只做一次轻量遍历。
String pickFullSentenceFromIndex(
  FullSentenceIndex idx,
  List<String> words, {
  bool fallbackToFirst = false,
}) {
  final ws = words
      .map((w) => _stripOptionLetter(w).toLowerCase())
      .where((w) => w.isNotEmpty)
      .toSet()
      .toList();
  if (ws.isEmpty || idx.isEmpty) return '';
  final firstW = ws.first;
  String? bestFull;
  String? bestFirst;
  for (var i = 0; i < idx.sentences.length; i++) {
    if (!idx.lowers[i].contains(firstW)) continue; // 快速预检
    final raw = idx.sentences[i];
    if (!_containsWordInSentence(raw, firstW)) continue;
    var ok = true;
    for (var k = 1; k < ws.length; k++) {
      if (!_containsWordInSentence(raw, ws[k])) {
        ok = false;
        break;
      }
    }
    if (ok) {
      if (bestFull == null || raw.length < bestFull.length) bestFull = raw;
    } else if (bestFirst == null || raw.length < bestFirst.length) {
      bestFirst = raw;
    }
    // 全词句已足够短时提前收敛，避免无谓遍历
    if (bestFull != null && bestFull.length <= 20) break;
  }
  final best = bestFull ?? (fallbackToFirst ? bestFirst : null);
  return best ?? '';
}

/// 用法文本统一解析：整句优先；[isNounAdj]（名词/形容词）且整句词数超过
/// [maxNounAdjWords] 时，或整句提取失败（为空）时，降级为词组/结构。
/// [text] 为整段原文（取词组降级用），[sentence] 为已提取的整句（可为空）。
String resolveUsageText(
  String text,
  String sentence,
  String word,
  bool isNounAdj, {
  int maxNounAdjWords = 12,
}) {
  final s = sentence.trim();
  if (s.isEmpty) return pickPhrase(text, word);
  if (isNounAdj && _wordCountOf(s) > maxNounAdjWords) return pickPhrase(text, word);
  return s;
}

/// 判断 [word] 是否为课标词的简单屈折变形（名词复数 / 第三人称单数 /
/// 规则过去式与过去分词 / -ing 进行体 / -est 最高级），配合不规则动词表。
///
/// 规则仅覆盖 -ing/-ied/-ed/-ies/-es/-s/-est，排除 -er/-ness/-ly/-tion 等派生后缀；
/// 任一候选词干命中课标词（[isStandardWord] 返回 true）即视为简单屈折变形。
bool isSimpleInflection(String word, bool Function(String) isStandardWord) {
  final s = word.toLowerCase();
  if (isStandardWord(s)) return false; // 本身就是课标词，不属于屈折变形
  final stems = <String>{};
  void addAll(Iterable<String> xs) {
    for (final x in xs) {
      if (x.length >= 3 && x != s) stems.add(x);
    }
  }

  if (s.endsWith('ing') && s.length >= 5) {
    final stem = s.substring(0, s.length - 3);
    addAll([stem, '${stem}e']);
    if (stem.length >= 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
      addAll([stem.substring(0, stem.length - 1)]); // running -> run
    }
  }
  if (s.endsWith('ied') && s.length > 4) {
    addAll(['${s.substring(0, s.length - 3)}y']); // studied -> study
  }
  if (s.endsWith('ed') && s.length > 4) {
    final stem = s.substring(0, s.length - 2);
    addAll([stem, '${stem}e']);
    if (stem.length >= 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
      addAll([stem.substring(0, stem.length - 1)]); // stopped -> stop
    }
  }
  if (s.endsWith('ies') && s.length > 4) {
    addAll(['${s.substring(0, s.length - 3)}y']); // cities -> city
  }
  if (s.endsWith('es') && s.length > 3) {
    addAll([s.substring(0, s.length - 2), s.substring(0, s.length - 1)]);
  } else if (s.endsWith('s') && s.length > 3) {
    addAll([s.substring(0, s.length - 1)]); // dogs -> dog
  }
  if (s.endsWith('est') && s.length > 5) {
    addAll([s.substring(0, s.length - 3)]); // biggest -> big
  }

  // 常见不规则动词表：变形 -> 原形
  // 含 be 系屈折（am/is/are/was/were/been），使 was/were 等不再进入拓展词明细
  const irregular = <String, String>{
    'am': 'be', 'is': 'be', 'are': 'be', 'was': 'be', 'were': 'be',
    'won': 'win', 'sat': 'sit', 'came': 'come', 'gave': 'give',
    'took': 'take', 'made': 'make', 'had': 'have', 'did': 'do',
    'went': 'go', 'saw': 'see', 'got': 'get', 'found': 'find',
    'thought': 'think', 'said': 'say', 'told': 'tell', 'knew': 'know',
    'grew': 'grow', 'drew': 'draw', 'threw': 'throw', 'flew': 'fly',
    'blew': 'blow', 'sang': 'sing', 'swam': 'swim', 'ran': 'run',
    'rang': 'ring', 'brought': 'bring', 'bought': 'buy', 'caught': 'catch',
    'taught': 'teach', 'built': 'build', 'sent': 'send', 'spent': 'spend',
    'lent': 'lend', 'meant': 'mean', 'felt': 'feel', 'left': 'leave',
    'kept': 'keep', 'slept': 'sleep', 'met': 'meet', 'fed': 'feed',
    'led': 'lead', 'read': 'read', 'heard': 'hear', 'held': 'hold',
    'stood': 'stand', 'understood': 'understand', 'lost': 'lose',
    'sold': 'sell', 'chose': 'choose', 'spoke': 'speak', 'woke': 'wake',
    'broke': 'break', 'wrote': 'write', 'rode': 'ride', 'drove': 'drive',
    'rose': 'rise', 'ate': 'eat', 'fell': 'fall', 'drank': 'drink',
    'wore': 'wear', 'tore': 'tear', 'bore': 'bear', 'froze': 'freeze',
    'forgot': 'forget', 'seen': 'see', 'been': 'be', 'gone': 'go',
    'done': 'do', 'taken': 'take', 'spoken': 'speak', 'written': 'write',
    'broken': 'break', 'chosen': 'choose', 'eaten': 'eat', 'fallen': 'fall',
    'driven': 'drive', 'ridden': 'ride', 'risen': 'rise', 'drunk': 'drink',
    'worn': 'wear', 'torn': 'tear', 'born': 'bear', 'frozen': 'freeze',
    'forgotten': 'forget', 'beaten': 'beat', 'bitten': 'bite',
    'hidden': 'hide',
  };
  final irr = irregular[s];
  if (irr != null) stems.add(irr);

  for (final cand in stems) {
    if (isStandardWord(cand)) return true;
  }
  return false;
}

/// 对英文单词做常见屈折变化还原，返回候选词干（小写、不含原词）。
///
/// 用于课标词映射回退：当拓展词（如 discussing/effectiveness）未直接收录时，
/// 依次尝试去掉 -ing/-ed/-s/-ies/-ness/-ly 等后缀得到词干，再查课标词库。
List<String> _stemCandidates(String word) {
  final s = word.toLowerCase();
  final out = <String>{};
  void addAll(Iterable<String> xs) {
    for (final x in xs) {
      if (x.length >= 3 && x != s) out.add(x);
    }
  }

  if (s.endsWith('ing') && s.length >= 5) {
    final stem = s.substring(0, s.length - 3);
    addAll([stem, '${stem}e']);
    if (stem.length >= 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
      addAll([stem.substring(0, stem.length - 1)]); // running -> run
    }
  }
  if (s.endsWith('ied') && s.length > 4) {
    addAll(['${s.substring(0, s.length - 3)}y']); // studied -> study
  }
  if (s.endsWith('ed') && s.length > 4) {
    final stem = s.substring(0, s.length - 2);
    addAll([stem, '${stem}e']);
    if (stem.length >= 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
      addAll([stem.substring(0, stem.length - 1)]); // stopped -> stop
    }
  }
  if (s.endsWith('ies') && s.length > 4) {
    addAll(['${s.substring(0, s.length - 3)}y']); // cities -> city
  }
  if (s.endsWith('es') && s.length > 3) {
    addAll([s.substring(0, s.length - 2), s.substring(0, s.length - 1)]);
  } else if (s.endsWith('s') && s.length > 3) {
    addAll([s.substring(0, s.length - 1)]); // dogs -> dog
  }
  if (s.endsWith('ness') && s.length > 5) {
    addAll([s.substring(0, s.length - 4)]); // effectiveness -> effective
  }
  if (s.endsWith('ly') && s.length > 4) {
    addAll([s.substring(0, s.length - 2)]); // quickly -> quick
  }
  if (s.endsWith('er') && s.length > 4) {
    addAll([s.substring(0, s.length - 2), s.substring(0, s.length - 1)]); // bigger -> big, player -> play
  }
  if (s.endsWith('est') && s.length > 5) {
    addAll([s.substring(0, s.length - 3)]); // biggest -> big
  }
  if (s.endsWith('tion') && s.length > 6) {
    addAll([s.substring(0, s.length - 3)]); // action -> act? action->act 需去e
    addAll([s.substring(0, s.length - 4)]); // creation -> creat? -> create
  }
  return out.toList();
}

/// 解析拓展词对应的课标词，带词形还原回退。
///
/// 先按原词查 [baseWordOf]；查不到时对常见屈折变形做词干还原后重查，
/// 任一命中即返回第一个非空结果。
String resolveBaseWord(String word, String Function(String word) baseWordOf) {
  final direct = baseWordOf(word);
  if (direct.isNotEmpty) return direct;
  for (final cand in _stemCandidates(word)) {
    final r = baseWordOf(cand);
    if (r.isNotEmpty) return r;
  }
  return '';
}

/// 按题型把拓展词分组。
///
/// [text]：被检测的原文全文
/// [extendWords]：检测出的全部拓展词（原始大小写列表）
/// [baseWordOf]：给定拓展词返回对应课标原词（原始大小写，无则返回空串）
/// 同一拓展词全局只列一次，归属其首次出现的题型区间；每行的例句取自该区间原文。
/// 同一句中出现的多个拓展词会自动合并为一行（拓展词、课标词均以空格连接）。
List<ExtendSection> buildExtendSections({
  required String text,
  required List<String> extendWords,
  required String Function(String word) baseWordOf,
  bool mergeSameSentenceRows = true,
}) {
  final lines = text.split('\n');

  // 扩展词小写 -> 原始大小写
  final extendByLower = <String, String>{};
  for (final w in extendWords) {
    extendByLower.putIfAbsent(w.toLowerCase(), () => w);
  }
  if (extendByLower.isEmpty) return const [];

  // 定位各题型标题行（按行匹配规则，记录每个题型首次出现位置）
  final markerByName = <String, int>{};
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i].trim().toLowerCase();
    if (l.isEmpty) continue;
    for (final rule in _sectionRules) {
      if (markerByName.containsKey(rule.name)) continue;
      if (rule.re.hasMatch(l)) {
        markerByName[rule.name] = i;
        break;
      }
    }
  }
  if (markerByName.isEmpty) return const [];

  // 按出现顺序排列题型
  final ordered = markerByName.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));

  final sections = <ExtendSection>[];
  final wordRe = RegExp(r'[a-zA-Z]+');
  final globalSeen = <String>{}; // 跨题型全局去重
  for (var k = 0; k < ordered.length; k++) {
    final name = ordered[k].key;
    final start = ordered[k].value;
    final end = k + 1 < ordered.length ? ordered[k + 1].value : lines.length;
    final sectionText = lines.sublist(start, end).join('\n');

    // 收集该题型区间内出现的拓展词（全局去重、按出现顺序）
    final found = <String>[];
    for (final m in wordRe.allMatches(sectionText)) {
      final lower = m.group(0)!.toLowerCase();
      final original = extendByLower[lower];
      if (original != null && globalSeen.add(lower)) {
        found.add(original);
      }
    }
    // 即使该题型区间内没有新增拓展词，也保留题型区块（题型名须完整呈现）
    // 后续 buildExtendTableXml / buildExtendTableText 会以空块/占位行输出

    // 每行：拓展词 + 该区间较短例句 + 课标词（含词形还原回退）
    final rows = found.map((w) {
      return ExtendRowData(
        word: w,
        example: pickShortExample(sectionText, w),
        // 课标词解析用剥离后词（hostedB -> hosted），单词列保持原文不变
        baseWord: resolveBaseWord(_stripOptionLetter(w), baseWordOf),
      );
    }).toList();

    // 同一句中出现多个拓展词时合并为一行（mergeSameSentenceRows=false 时每词独立成行）
    final merged = <ExtendRowData>[];
    if (!mergeSameSentenceRows) {
      merged.addAll(rows);
    } else {
      final byExample = <String, List<ExtendRowData>>{};
      for (final r in rows) {
        if (r.example.isEmpty) {
          merged.add(r); // 无例句的行不参与合并，保持原样
          continue;
        }
        byExample.putIfAbsent(r.example, () => []).add(r);
      }
      for (final list in byExample.values) {
        if (list.length == 1) {
          merged.add(list.single);
        } else {
          merged.add(ExtendRowData(
            word: list.map((e) => e.word).join(' '),
            example: list.first.example,
            baseWord: list
                .map((e) => e.baseWord)
                .where((b) => b.isNotEmpty)
                .join(' '),
          ));
        }
      }
    }
    sections.add(ExtendSection(name: name, rows: merged));
  }
  return sections;
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 生成拓展词表格的 DOCX `<w:tbl>` XML。
String buildExtendTableXml(List<ExtendSection> sections) {
  if (sections.isEmpty) return '';
  const grid = [1600, 2400, 3600, 2000]; // 题型/拓展词/真题例句/课标词 列宽 dxa
  final sb = StringBuffer();
  sb.write('<w:tbl><w:tblPr><w:tblW w:w="9600" w:type="dxa"/><w:tblBorders>');
  for (final s in const ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']) {
    sb.write('<w:$s w:val="single" w:sz="4" w:space="0" w:color="000000"/>');
  }
  sb.write('</w:tblBorders><w:tblLayout w:type="autofit"/></w:tblPr><w:tblGrid>');
  for (final g in grid) {
    sb.write('<w:gridCol w:w="$g"/>');
  }
  sb.write('</w:tblGrid>');

  // 表头
  sb.write('<w:tr>');
  for (var c = 0; c < 4; c++) {
    final header = const ['题型', '拓展词', '真题例句', '课标词'][c];
    sb.write(
        '<w:tc><w:tcPr><w:tcW w:w="${grid[c]}" w:type="dxa"/></w:tcPr>'
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(header)}</w:t></w:r></w:p></w:tc>');
  }
  sb.write('</w:tr>');

  // 数据行：题型名仅在所属区间的首行填写；无拓展词的题型块也输出占位行以保留题型名
  for (final sec in sections) {
    if (sec.rows.isEmpty) {
      final cells = [sec.name, '', '', ''];
      sb.write('<w:tr>');
      for (var c = 0; c < 4; c++) {
        sb.write(
            '<w:tc><w:tcPr><w:tcW w:w="${grid[c]}" w:type="dxa"/></w:tcPr>'
            '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r>'
            '<w:t xml:space="preserve">${_xmlEscape(cells[c])}</w:t></w:r></w:p></w:tc>');
      }
      sb.write('</w:tr>');
      continue;
    }
    for (var i = 0; i < sec.rows.length; i++) {
      final row = sec.rows[i];
      final cells = [i == 0 ? sec.name : '', row.word, row.example, row.baseWord];
      sb.write('<w:tr>');
      for (var c = 0; c < 4; c++) {
        sb.write(
            '<w:tc><w:tcPr><w:tcW w:w="${grid[c]}" w:type="dxa"/></w:tcPr>'
            '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r>'
            '<w:t xml:space="preserve">${_xmlEscape(cells[c])}</w:t></w:r></w:p></w:tc>');
      }
      sb.write('</w:tr>');
    }
  }
  sb.write('</w:tbl>');
  return sb.toString();
}

/// 生成拓展词表格的纯文本版本（TXT 导出用）。
String buildExtendTableText(List<ExtendSection> sections) {
  if (sections.isEmpty) return '';
  final sb = StringBuffer();
  sb.writeln('');
  sb.writeln('=' * 64);
  sb.writeln('【拓展词明细（按题型）】');
  sb.writeln('=' * 64);
  for (final sec in sections) {
    sb.writeln('');
    sb.writeln('■ ${sec.name}');
    sb.writeln('拓展词\t真题例句\t课标词');
    for (final r in sec.rows) {
      sb.writeln('${r.word}\t${r.example}\t${r.baseWord}');
    }
  }
  return sb.toString();
}
