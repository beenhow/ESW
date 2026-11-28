// 提取文本的统一规范化（运行时与构建脚本共用，避免两处行为分叉）。
//
// 背景：旧实现只拼接 w:t，把 w:tab 与 w:br 当作不存在，
// 于是 Word 里靠制表符/软换行排成四列的选项被压成 `A. itB. thatC. whoseD. which`，
// 分词后产出 itB / ofB / toC / AsC 这类假词。
//
// 规则：
//  1. w:tab → 空格（有效分隔，不能丢）；
//  2. w:br / w:cr → 换行（软换行就是断行）；
//  3. 每行做空白规范化，再按选项标记断行（A/B/C/D 各自独立成行）；
//  4. 只增删空白与换行，不改动任何非空白字符。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// 选项标记：A. / B．等（只认大写 A-H）
final RegExp _markerRe = RegExp(r'([A-H])[.．]');

bool _isUpperLetter(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x41 && u <= 0x5A;
}

bool _isAsciiLetter(String c) {
  if (c.isEmpty) return false;
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
}

/// 单行空白规范化：制表符/不换行空格/全角空格 → 空格，连续空格压成一个。
String normalizeLineText(String raw) {
  var s = raw.replaceAll('\u00A0', ' ').replaceAll('\u3000', ' ');
  s = s.replaceAll(RegExp(r'[\t\r\n]+'), ' ');
  s = s.replaceAll(RegExp(r' {2,}'), ' ');
  return s.trim();
}

/// 按选项标记断行：把 `A. itB. thatC. whoseD. which` 拆成四行。
///
/// 误伤防线：
///  - 只认大写 A-H + 点号，且必须是「连续递增序列」（A→B→C→D）；
///  - 排除缩写（`U.S.A.`：标记前是「大写字母 + .」）、全大写单词句点
///    （`WILD.` / `NBA.`：标记前紧邻大写字母）、`A..` 这类叠点；
///  - 只有 2 个标记时要求首个标记在行首或前缀是纯题号，
///    避免 `Dr. A. Smith and B. Jones`、`Corrado A. G. Piccoli` 被误拆。
List<String> splitOptionMarkers(String line) {
  final starts = <int>[];
  final letters = <String>[];
  for (final m in _markerRe.allMatches(line)) {
    final i = m.start;
    if (i >= 2 && line[i - 1] == '.' && _isUpperLetter(line[i - 2])) continue;
    if (i >= 1 && _isUpperLetter(line[i - 1])) continue;
    if (i + 2 < line.length && line[i + 2] == '.') continue;
    // 注：不排除「标记后紧跟数字」，否则 B.90. / C.118. 这类数字选项无法识别
    starts.add(i);
    letters.add(m.group(1)!);
  }

  // 补齐缺少点号的选项标记（`B. satisfaction C bitterness D. politeness`）。
  // 只在整行确实是选项列表时推断，避免误伤正文：
  //  - 同一行至少已有 2 个带点标记；
  //  - 第一个带点标记必须在行首 / 纯题号之后，或行首本身就是「A 文本」这种
  //    缺失点号的首个选项（2020 浙江「A At 8:30. B. ...」）；
  //  - 缺号字母必须正好落在前后带点标记的连续序列里（B → C → D）；
  //  - 缺号字母后必须跟空格 + 字母，`A 8:30`、`D.C.`、`A. M.` 不会命中。
  // 只记录位置用于断行，不回写标点，保持「只增删空白与换行」的约定。
  if (starts.length >= 2) {
    final head0 = line.substring(0, starts[0]).trim();
    final head0IsNumber = RegExp(r'^\d{1,3}[.．、]?$').hasMatch(head0);
    final bareAtZero = line.length >= 3 &&
        line[0].codeUnitAt(0) >= 0x41 &&
        line[0].codeUnitAt(0) <= 0x48 &&
        line[1] == ' ' &&
        _isAsciiLetter(line[2]) &&
        line[0].codeUnitAt(0) + 1 == letters[0].codeUnitAt(0);
    final allowInfer = starts[0] == 0 || head0IsNumber || bareAtZero;
    if (allowInfer) {
      final extras = <int>[];
      final extraLetters = <String>[];
      for (var i = 0; i < line.length; i++) {
        final c = line[i];
        final u = c.codeUnitAt(0);
        if (u < 0x41 || u > 0x48) continue; // 只认大写 A-H
        if (i > 0 && line[i - 1] != ' ') continue; // 前面必须是行首或空格
        if (starts.contains(i)) continue; // 已是带点标记
        var j = i + 1;
        if (j >= line.length || line[j] != ' ') continue;
        while (j < line.length && line[j] == ' ') {
          j++;
        }
        // 选项正文以字母开头；`A 8:30` 这类时间不拆
        if (j >= line.length || !_isAsciiLetter(line[j])) continue;
        final before = starts.where((s) => s < i).toList();
        final after = starts.where((s) => s > i).toList();
        final beforeOk = before.isNotEmpty &&
            letters[starts.indexOf(before.last)].codeUnitAt(0) + 1 == u;
        final afterOk = after.isNotEmpty &&
            u + 1 == letters[starts.indexOf(after.first)].codeUnitAt(0);
        final isLeadingBare = before.isEmpty && afterOk;
        final isMiddle = beforeOk && afterOk;
        final isTrailing = beforeOk && after.isEmpty && starts.length >= 2;
        if (isLeadingBare || isMiddle || isTrailing) {
          extras.add(i);
          extraLetters.add(c);
        }
      }
      for (var k = 0; k < extras.length; k++) {
        var at = starts.indexWhere((s) => s > extras[k]);
        if (at < 0) at = starts.length;
        starts.insert(at, extras[k]);
        letters.insert(at, extraLetters[k]);
      }
    }
  }

  if (starts.length < 2) return <String>[line];

  var bestStart = 0, bestLen = 1;
  var s = 0;
  while (s < letters.length) {
    var e = s;
    while (e + 1 < letters.length &&
        letters[e + 1].codeUnitAt(0) == letters[e].codeUnitAt(0) + 1) {
      e++;
    }
    final len = e - s + 1;
    if (len > bestLen) {
      bestLen = len;
      bestStart = s;
    }
    s = e + 1;
  }

  final pos = starts.sublist(bestStart, bestStart + bestLen);
  final head = line.substring(0, pos.first).trim();
  final headIsNumber = RegExp(r'^\d{1,3}[.．、]?$').hasMatch(head);
  if (bestLen < 3 && starts[bestStart] != 0 && !headIsNumber) {
    return <String>[line];
  }

  final out = <String>[];
  if (head.isNotEmpty && !headIsNumber) out.add(head);
  for (var k = 0; k < pos.length; k++) {
    final end = k + 1 < pos.length ? pos[k + 1] : line.length;
    var seg = line.substring(pos[k], end).trim();
    if (k == 0 && headIsNumber) seg = '$head $seg';
    if (seg.isNotEmpty) out.add(seg);
  }
  return out;
}

/// 整段文本规范化（幂等）：制表符当分隔、软换行当断行、选项标记断行、空行折叠。
String normalizeText(String raw) {
  if (raw.isEmpty) return raw;
  final out = <String>[];
  for (final line in raw.split(RegExp(r'\r\n|\r|\n'))) {
    final norm = normalizeLineText(line);
    if (norm.isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }
    out.addAll(splitOptionMarkers(norm));
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  while (out.isNotEmpty && out.first.isEmpty) {
    out.removeAt(0);
  }
  return out.join('\n');
}

/// 分词用字符折叠：只影响“词”的识别，不改动展示原文。
///
/// 解决的问题：
///  - PDF 常见连字（ﬁ/ﬂ）被正则当成非字母，导致 find → nd 这类缺字母 token；
///  - café / naïve / résumé 等带变音符号的词被截成 caf / na / sum；
///  - 全角英文（Ｔｈｅ）完全匹配不到；
///  - 软连字符、零宽字符把单词劈成两半。
String foldWordText(String raw) {
  if (raw.isEmpty) return raw;
  final buf = StringBuffer();
  for (final rune in raw.runes) {
    // 不可见字符：BOM / 零宽 / 软连字符 / 方向控制符
    if (rune == 0x00AD ||
        rune == 0xFEFF ||
        rune == 0x2060 ||
        (rune >= 0x200B && rune <= 0x200F) ||
        (rune >= 0x202A && rune <= 0x202E)) {
      continue;
    }
    // 组合变音符号：é 被拆成 e + U+0301 时只保留 e
    if (rune >= 0x0300 && rune <= 0x036F) continue;
    // 全角 ASCII（！..～）折叠为半角
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buf.writeCharCode(rune - 0xFEE0);
      continue;
    }
    // 常见连字
    switch (rune) {
      case 0xFB00:
        buf.write('ff');
        continue;
      case 0xFB01:
        buf.write('fi');
        continue;
      case 0xFB02:
        buf.write('fl');
        continue;
      case 0xFB03:
        buf.write('ffi');
        continue;
      case 0xFB04:
        buf.write('ffl');
        continue;
      case 0xFB05:
      case 0xFB06:
        buf.write('st');
        continue;
      case 0x2018:
      case 0x2019:
      case 0x02BC:
        buf.write("'");
        continue;
    }
    buf.write(_foldLatin1[rune] ?? String.fromCharCode(rune));
  }
  return buf.toString();
}

/// 语料统一预处理：全角标点转半角、弯引号转直引号。
///
/// 与 [foldWordText] 分工：本函数只改标点/引号（全部为 1:1 替换，不改变
/// 字符串长度，因此既有的字符偏移仍可用于原文定位/高亮），不改单词字符；
/// 单词级折叠由 [foldToken] 负责。检测页与高频导出必须共用本函数，
/// 否则同一语料在页面与导出表会得到不同的切句/分词结果。
String normalizeCorpusText(String raw) {
  if (raw.isEmpty) return raw;
  return raw
      .replaceAll('\uFF0C', ',')
      .replaceAll('\uFF0E', '.')
      .replaceAll('\uFF1B', ';')
      .replaceAll('\uFF1A', ':')
      .replaceAll('\uFF01', '!')
      .replaceAll('\uFF1F', '?')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"');
}

/// 统一 token 折叠：先小写，再做 [foldWordText] 的字符折叠。
///
/// 检测页、短语覆盖判定与高频导出都用它，保证 café / o’clock / 全角字母
/// 在页面与导出表得到同一个键。
String foldToken(String raw) => foldWordText(raw.toLowerCase());

/// Latin-1 常见变音字母 → ASCII（大小写保持）。
const Map<int, String> _foldLatin1 = {
  0xC0: 'A', 0xC1: 'A', 0xC2: 'A', 0xC3: 'A', 0xC4: 'A', 0xC5: 'A',
  0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a',
  0xC7: 'C', 0xE7: 'c',
  0xC8: 'E', 0xC9: 'E', 0xCA: 'E', 0xCB: 'E',
  0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e',
  0xCC: 'I', 0xCD: 'I', 0xCE: 'I', 0xCF: 'I',
  0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i',
  0xD1: 'N', 0xF1: 'n',
  0xD2: 'O', 0xD3: 'O', 0xD4: 'O', 0xD5: 'O', 0xD6: 'O', 0xD8: 'O',
  0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o', 0xF8: 'o',
  0xD9: 'U', 0xDA: 'U', 0xDB: 'U', 0xDC: 'U',
  0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u',
  0xDD: 'Y', 0xFD: 'y', 0xFF: 'y',
  0xC6: 'AE', 0xE6: 'ae', 0x152: 'OE', 0x153: 'oe',
  0xDF: 'ss', 0xD0: 'D', 0xF0: 'd', 0xDE: 'TH', 0xFE: 'th',
};

/// 撇号字符：直撇号 `'`、弯撇号 `‘ ’`、修饰字母撇号 `ʼ`。
///
/// 缩略形式（couldn't / it's / o'clock）里的撇号是**词内字符**，不是分隔符。
/// 当成分隔符会切出 `couldn` + `t`，单字母 `t` 再被 minLength 过滤掉，
/// 检测结果里就只剩 `couldn`，撇号后的 `'t` 整段丢失。
const String apostropheChars = "'\u2018\u2019\u02BC";

/// 带内部点的缩写词元（a.m. / U.S. / e.g. / D.C.）。
///
/// 至少两段字母、段间必须有句点，末尾句点可选。要求「至少两段」是为了
/// 不把普通单词后的句号（was. / It.）吞进词元；`a.m. It` 中的句末点
/// 仍只属于 a.m.，不会把后一个词并进来。
const String _dottedAbbrBody = r'[A-Za-z]+(?:\.[A-Za-z]+)+\.?';
const String _plainWordBody = "[A-Za-z]+(?:[$apostropheChars-][A-Za-z]+)*";

/// 统一词 token：ASCII 字母串（允许内部含撇号或连字符）或带内部点的缩写，
/// 前后不得紧邻字母/数字。作用在 foldWordText 折叠后的文本上，因此
/// 直撇号即可覆盖弯撇号。
final RegExp wordTokenRegExp = RegExp(
  "(?<![A-Za-z0-9])(?:$_dottedAbbrBody|$_plainWordBody)(?![A-Za-z0-9])",
);

/// 标注/高亮用词边界：与 [wordTokenRegExp] 同源（保留撇号缩略形式与
/// 带点缩写），但不带前后断言、可直接作用于**未折叠**原文，便于在 docx
/// run、表格单元格、PDF 单行等片段内逐词遍历着色。
final RegExp annotatedWordRegExp = RegExp(
  "(?:$_dottedAbbrBody|$_plainWordBody)",
);

/// 查表键：先折叠（弯撇号→直撇号、连字/变音/全角），再小写。
///
/// 词表与分类映射都以折叠后的小写为键；原文里的 `couldn’t` 必须与词表里的
/// `couldn't` 命中同一条，否则会落到「未筛选」。
String wordLookupKey(String token) => foldWordText(token).toLowerCase();

/// 词频/整词统计口径：与分词器一致，连字符、撇号整体成词，大小写不敏感。
///
/// 用于替代 `\b关键词\b`：后者会把 `the-based`、`he's` 里的片段单独计数，
/// 与导出高频表（按 [wordTokenRegExp] 切词）产生差异。
Iterable<RegExpMatch> wordTokenMatches(String text, String keyword) {
  final kw = keyword.toLowerCase();
  return wordTokenRegExp
      .allMatches(text)
      .where((m) => m.group(0)!.toLowerCase() == kw);
}

/// 原文定位/高亮用的关键词正则（与 [wordTokenRegExp] 同一口径）。
///
/// 与旧的 `\b关键词\b` 字面量匹配相比：
///  - 撇号等价：原文是弯撇号（couldn’t / couldn‘t / couldnʼt）也能命中直撇号关键词；
///  - 按完整词形匹配：前后不得紧邻字母/数字，不会命中更长单词的内部片段；
///  - 大小写不敏感。
///
/// [keyword] 先经 [foldWordText] 折叠，因此全角字符、连字、变音字母与非标准
/// 撇号都会归一；关键词为空时返回永不匹配的正则。
RegExp keywordMatchRegExp(String keyword) {
  final kw = foldWordText(keyword).trim();
  if (kw.isEmpty) return RegExp(r'(?!)');
  // 带内部点的缩写允许省略末尾点：a.m. 与 a.m、Mr. 与 Mr 走同一正则。
  final isDotted = kw.contains('.');
  final core = isDotted && kw.endsWith('.')
      ? kw.substring(0, kw.length - 1)
      : kw;
  var body = core
      .split(RegExp('[$apostropheChars-]'))
      .map(RegExp.escape)
      .join('[-$apostropheChars]');
  if (isDotted) body = '$body\\.?';
  return RegExp(
    '(?<![A-Za-z0-9])$body(?![A-Za-z0-9])',
    caseSensitive: false,
  );
}

/// 关键词在 [text] 中第 [occurrence] 次完整词形命中的起始下标（0 起）。
///
/// 找不到返回 -1；与 [keywordMatchRegExp] 同口径（撇号等价、整词匹配）。
int keywordMatchOffset(String text, String keyword, {int occurrence = 0}) {
  var i = 0;
  for (final m in keywordMatchRegExp(keyword).allMatches(text)) {
    if (i == occurrence) return m.start;
    i++;
  }
  return -1;
}

/// 无法按后缀规则推出的缩略基形。
const Map<String, String> _irregularBases = <String, String>{
  "can't": 'can',
  "won't": 'will',
  "shan't": 'shall',
};

/// 缩写基形不是词表头词时，回退到对应的原形（课标词库只收原形：do / be / have）。
///
/// 否则 doesn't → does、wasn't → was、didn't → did 在原形缺失时查不到课标，
/// 常见缩写会被判成未筛选或沿用错误的历史分类。
const Map<String, String> _contractionLemmas = <String, String>{
  'does': 'do',
  'did': 'do',
  'done': 'do',
  'was': 'be',
  'were': 'be',
  'had': 'have',
  'goes': 'go',
  'won': 'win',
};

/// 查词表用的候选键。
///
/// 普通词首个元素是完整词形本身；带点缩写先尝试省略末尾点的形式
/// （a.m. → a.m，a.m → a.m. 均回退到词库实际写法）。
///
/// 分词按用户要求保留完整词形（couldn't / China's），而四个词库收录的都是基形
/// （could / China）。若只用完整词形查表，所有格与缩略形式会整段丢失分类，
/// 课标词命中数会凭空减少（如 China's 找不到 China），故按后缀回退到基形。
List<String> wordLookupKeys(String token) {
  final full = wordLookupKey(token);
  final keys = <String>[];
  // 末尾点可省略：a.m. 与 a.m 视为同一词条。带点形式先尝试去点后的词形，
  // 这样 Mr. 会归到词表头词 Mr（若两者都存在），a.m. 则会回退到 a.m.。
  if (full.endsWith('.')) {
    final trimmed = full.substring(0, full.length - 1);
    if (trimmed.length >= 2) keys.add(trimmed);
  }
  if (!keys.contains(full)) keys.add(full);
  if (!full.endsWith('.') && full.contains('.')) keys.add('$full.');
  final irregular = _irregularBases[full];
  if (irregular != null) keys.add(irregular);
  for (final suffix in const <String>[
    "'s", "n't", "'re", "'ve", "'ll", "'d", "'m", "'",
  ]) {
    if (!full.endsWith(suffix)) continue;
    final base = full.substring(0, full.length - suffix.length);
    // 单字母基形只保留 I / a（I've → I），其余过短基形丢弃
    final shortOk = base.length == 1 &&
        (base == 'I' || base == 'i' || base == 'a' || base == 'A');
    if (base.length < 2 && !shortOk) continue;
    if (!keys.contains(base)) keys.add(base);
    final lemma = _contractionLemmas[base.toLowerCase()];
    if (lemma != null && !keys.contains(lemma)) keys.add(lemma);
  }
  return keys;
}

/// 在词表集合里按 [wordLookupKeys] 的顺序查找，返回命中的键（未命中为 null）。
String? matchWordListKey(Set<String> lowerKeySet, String token) {
  for (final key in wordLookupKeys(token)) {
    if (lowerKeySet.contains(key)) return key;
  }
  return null;
}

/// 大小写敏感的查表键：只做字符折叠（弯撇号、连字、变音、全角），保留原始大小写。
///
/// 课标词库按大小写区分词条（China 中国 / china 瓷器），查表必须保留大小写。
String wordLookupKeyExact(String token) => foldWordText(token);

/// 大小写敏感的候选键，规则与 [wordLookupKeys] 一致（末尾点省略、所有格/缩略回退），
/// 但保留原始大小写。
List<String> wordLookupKeysExact(String token) {
  final full = wordLookupKeyExact(token);
  final lower = full.toLowerCase();
  final keys = <String>[];
  if (full.endsWith('.')) {
    final trimmed = full.substring(0, full.length - 1);
    if (trimmed.length >= 2) keys.add(trimmed);
  }
  if (!keys.contains(full)) keys.add(full);
  if (!full.endsWith('.') && full.contains('.')) keys.add('$full.');
  final irregular = _irregularBases[lower];
  if (irregular != null) keys.add(irregular);
  for (final suffix in const <String>[
    "'s", "n't", "'re", "'ve", "'ll", "'d", "'m", "'",
  ]) {
    if (!lower.endsWith(suffix)) continue;
    final base = full.substring(0, full.length - suffix.length);
    // 单字母基形只保留 I / a（I've → I、a.m 之外的 a），其余过短基形丢弃
    final shortOk = base.length == 1 &&
        (base == 'I' || base == 'i' || base == 'a' || base == 'A');
    if (base.length < 2 && !shortOk) continue;
    if (!keys.contains(base)) keys.add(base);
    final lemma = _contractionLemmas[base.toLowerCase()];
    if (lemma != null && !keys.contains(lemma)) keys.add(lemma);
  }
  return keys;
}

/// 大小写敏感词库的取词规则：先精确匹配；未命中时，只允许回退到全小写词条。
///
/// 即小写词条可以被首字母大写、全大写写法命中（The → the，THE → the），
/// 反过来不成立：小写写法不会命中大写词条（china ↛ China），
/// 大小写词条同时存在时各自精确命中（China → China，china → china）。
String? findWordEntryKey(Map<String, Object?> entries, String token) {
  final keys = wordLookupKeysExact(token);
  for (final key in keys) {
    if (entries.containsKey(key)) return key;
  }
  for (final key in keys) {
    final lower = key.toLowerCase();
    if (lower == key) continue;
    if (entries.containsKey(lower)) return lower;
  }
  return null;
}

/// 与 [findWordEntryKey] 同一规则的集合版本。
String? matchWordEntryKey(Set<String> keys, String token) {
  final candidates = wordLookupKeysExact(token);
  for (final key in candidates) {
    if (keys.contains(key)) return key;
  }
  for (final key in candidates) {
    final lower = key.toLowerCase();
    if (lower == key) continue;
    if (keys.contains(lower)) return lower;
  }
  return null;
}

/// 专有词查询键集合：专有词按小写归档，词条之间大小写不敏感。
///
/// 词库存 `Messy` 或 `MESSY` 视为同一条；拼音词条（xinjiang）与
/// 全大写缩写（WTO）同样归入同一键。
Set<String> properNounKeySet(Iterable<String> words) =>
    words.map((w) => w.toLowerCase()).toSet();

bool _hasUppercaseLetter(String token) {
  for (final u in token.codeUnits) {
    if (u >= 0x41 && u <= 0x5A) return true;
  }
  return false;
}

/// 专有词自动命中：只认大写写法（首字母大写 / 全大写 / 驼峰专名）。
///
/// 全小写写法即使该词条也收在专有词库里，也不自动归为专有词 —— 分类由用户
/// 最终决定，这类词留在未筛选等用户确认。词条本身大小写不敏感（Messy /
/// MESSY / messy 词条等价），命中后仍按「完整词形 → 基形」回退。
bool isProperNounHit(Set<String> lowerEntries, String token) {
  if (!_hasUppercaseLetter(token)) return false;
  if (matchWordEntryKey(lowerEntries, token) != null) return true;
  return _compoundPartKeys(
        token,
        (p) => matchWordEntryKey(lowerEntries, p),
      ) !=
      null;
}

/// 带撇号的缩略/所有格（I've / He's / China's）是否应按基形归课标词。
///
/// 这类词元不能因为含大写字母（句首 I / He）就被专有词抢走：基形命中课标
/// 就按课标词算；只有基形不在课标里，才继续考虑专有词。
bool apostropheBaseInStandard(String token, bool standardHit) =>
    standardHit && wordLookupKeyExact(token).contains("'");

/// 连字符复合词按部分判定：整体未命中时拆开，所有组成部分都命中才算命中。
List<String>? _compoundPartKeys(
  String token,
  String? Function(String part) lookup,
) {
  if (!token.contains('-')) return null;
  final parts = token.split('-');
  if (parts.length < 2) return null;
  final hits = <String>[];
  for (final part in parts) {
    if (part.isEmpty) return null;
    final hit = lookup(part);
    if (hit == null) return null;
    hits.add(hit);
  }
  return hits;
}

/// 词条命中判定（含连字符复合词回退）。
///
/// 先按 [findWordEntryKey] 找整体词条；整体不存在时，若 `harbor-side`
/// 这类词按连字符拆开后的每一部分都命中词库，则整体视为命中。
bool isWordEntryHit(Map<String, Object?> entries, String token) {
  if (findWordEntryKey(entries, token) != null) return true;
  return _compoundPartKeys(token, (p) => findWordEntryKey(entries, p)) != null;
}

/// [isWordEntryHit] 的集合版本。
bool isWordSetHit(Set<String> keys, String token) {
  if (matchWordEntryKey(keys, token) != null) return true;
  return _compoundPartKeys(token, (p) => matchWordEntryKey(keys, p)) != null;
}

/// 在「小写词形 → 分类」映射里按 [wordLookupKeys] 查找分类，未命中为 null。
String? categoryOfWord(Map<String, String> lowerCategory, String token) {
  for (final key in wordLookupKeys(token)) {
    final cat = lowerCategory[key];
    if (cat != null) return cat;
  }
  return null;
}

/// 两个词形是否指向同一词条（大小写不敏感，带点缩写末尾点可省略）。
bool isSameLookupWord(String a, String b) {
  final kb = wordLookupKeys(b).toSet();
  return wordLookupKeys(a).any(kb.contains);
}

/// 选项字母粘连：≥2 字母 + A-H。
///
/// 旧规则要求前缀 ≥3 字母，导致 itB / ofB / toC / AsC 这类三字符粘连漏网；
/// 这里放宽到 2 字母，同时排除全大写缩写（MBA/GPA 等）与常见混合大小写缩写，
/// 避免把 PhD 这类正常缩写误切成 Ph。
final RegExp _optionGlueRe = RegExp(r'^([A-Za-z]{2,})([A-H])$');
const Set<String> _optionGlueExceptions = <String>{'PhD', 'EdD', 'McD'};

bool _isAllCaps(String token) {
  for (final u in token.codeUnits) {
    if (u >= 0x61 && u <= 0x7A) return false;
  }
  return true;
}

/// 末尾 A-H 是否属于缩写内部的大写块（如 MoMA 的 MA）。
///
/// 真缩写末尾字母前面也是大写，剥离会把 MoMA 切成 MoM；
/// 而 itB / ofB 这类选项粘连，末尾字母前面是小写，仍需剥离。
bool _hasUppercaseBeforeOptionLetter(String token) {
  if (token.length < 2) return false;
  final prev = token.codeUnitAt(token.length - 2);
  return prev >= 0x41 && prev <= 0x5A;
}

/// 选项字母粘连剥离（itB → it）。
///
/// 与 [extractWordTokens] 内部规则同源，供检测页与高频导出逐 token 复用，
/// 保证两侧对同一条粘连词得到同一个词形。
String stripOptionGlueFromToken(String token) {
  if (token.length < 3 ||
      _isAllCaps(token) ||
      _optionGlueExceptions.contains(token) ||
      // McA/McB/McC 这类三字母人名缩写不按选项粘连处理
      (token.length == 3 && token.startsWith('Mc')) ||
      // MoMA 这类真缩写：末尾 A-H 紧跟大写，属于缩写块，不能剥离
      _hasUppercaseBeforeOptionLetter(token)) {
    return token;
  }
  final glued = _optionGlueRe.firstMatch(token);
  return glued?.group(1) ?? token;
}

/// 检测页与高频导出共用的单 token 分析归一：
///  - 选项字母粘连剥离（与 [extractWordTokens] 同一规则，itB → it）；
///  - 单字母只保留 a / I（英语中仅这两个单字母词有实义），其余丢弃。
///
/// 返回 null 表示该 token 不参与统计。
String? normalizeAnalysisToken(String token) {
  final t = stripOptionGlueFromToken(token);
  if (t.isEmpty) return null;
  if (t.length == 1) {
    final lower = t.toLowerCase();
    if (lower != 'a' && lower != 'i') return null;
  }
  return t;
}

/// 检测页与高频导出共用的分析分词：与 [extractWordTokens] 完全同一实现
/// （字符折叠 + 撇号空格并回 + 选项字母剥离），并在其基础上保留单字母 a / I。
///
/// 两侧必须都调用本方法，否则 `a`/`I` 与 `itB` 这类粘连词在两处会得到不同词形。
List<String> extractAnalysisTokens(String raw) {
  if (raw.isEmpty) return const <String>[];
  final out = <String>[];
  for (final token in extractWordTokens(raw, minLength: 1)) {
    final normalized = normalizeAnalysisToken(token);
    if (normalized != null) out.add(normalized);
  }
  return out;
}

/// 从任意文本提取统一词 token（已折叠连字/变音/全角，并剥离选项字母粘连）。
///
/// 两端（Windows / Android）以及语料统计、年份命中统计都应使用本方法，
/// 避免同一份文档在不同功能里得到不同的词边界。
List<String> extractWordTokens(
  String raw, {
  int minLength = 2,
  bool stripOptionGlue = true,
}) {
  if (raw.isEmpty) return const <String>[];
  // 部分来源（PDF/OCR/复制粘贴）会把撇号与词根之间插进空格：
  // "haven 't" / "I ' ve" / "student 's"，先并回一个词，避免被切成
  // haven + 丢弃的 t、ve 这类残片。
  final folded = foldWordText(raw).replaceAllMapped(
    RegExp(r"([A-Za-z]+)\s+'\s*(s|t|re|ve|ll|d|m)\b", caseSensitive: false),
    (m) => "${m[1]}'${m[2]}",
  );
  final out = <String>[];
  for (final m in wordTokenRegExp.allMatches(folded)) {
    var token = m.group(0)!;
    if (token.length < minLength) continue;
    if (stripOptionGlue) token = stripOptionGlueFromToken(token);
    if (token.length >= minLength) out.add(token);
  }
  return out;
}

/// 段落原始文本：按文档顺序保留制表符（→ 空格）与软换行（→ 换行）。
String docxParagraphRaw(XmlElement p) {
  final buf = StringBuffer();
  void walk(XmlElement el) {
    for (final node in el.children) {
      if (node is! XmlElement) continue;
      switch (node.name.local) {
        case 't':
          buf.write(node.innerText);
        case 'tab':
        case 'ptab':
          buf.write(' '); // 有效分隔，不能压掉（ptab 为制表位，同样要留空）
        case 'br':
        case 'cr':
          buf.write('\n'); // 软换行 = 真实换行
        case 'noBreakHyphen':
          buf.write('-'); // 不换行连字符：丢掉会把 well-known 粘成 wellknown
        case 'softHyphen':
          break; // 可选连字符本身不可见，直接忽略
        case 'p':
          // 文本框等嵌套段落：外层段落不再重复收集，交给 findAllElements 单独处理，
          // 否则同一段文字会被统计两次。
          break;
        case 'pPr':
        case 'rPr':
          break;
        default:
          walk(node); // w:r / w:hyperlink / w:smartTag / w:ins ...
      }
    }
  }

  walk(p);
  return buf.toString();
}

/// 从 docx 字节提取规范化正文（运行时 docx 解析与构建脚本共用同一实现）。
String extractDocxText(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final entry = archive.findFile('word/document.xml');
  if (entry == null) return '';
  final content = entry.content;
  final Uint8List data = content is List<int>
      ? Uint8List.fromList(content)
      : content as Uint8List;
  final document = XmlDocument.parse(utf8.decode(data));
  final buf = StringBuffer();
  for (final p in document.findAllElements('w:p')) {
    buf.writeln(docxParagraphRaw(p));
  }
  return normalizeText(buf.toString());
}
