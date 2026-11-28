// 词形归一的唯一实现：检测页词频、高频导出、查词统计都必须走这里，
// 保证同一批语料在软件页面与导出表中的数字完全一致。
//
// 归并分三层：
//  1. 分词口径：统一用 text_normalize.wordTokenRegExp（连字符/撇号整体成词）；
//  2. 英美拼写：color/colour、center/centre、organise/organize、practise/practice 等；
//  3. 词形拓展：按词库 extendBaseMap 归并到课标原词（practices → practice）。
import 'text_normalize.dart';

/// 规则推导不到的不规则英美拼写（英 → 美）。仅当两种写法都在课标词库时生效。
const Map<String, String> irregularUkUs = <String, String>{
  'grey': 'gray',
  'practise': 'practice',
};

/// 英美拼写规范化键：colour → color、centre → center、organise → organize。
String usSpellingKey(String w) {
  var s = w;
  if (s.endsWith('ogue')) s = '${s.substring(0, s.length - 4)}og';
  if (s.length >= 5) s = s.replaceAll('our', 'or');
  if (s.endsWith('tre')) s = '${s.substring(0, s.length - 3)}ter';
  s = s.replaceAll('ise', 'ize').replaceAll('yse', 'yze');
  if (s.endsWith('ence')) s = '${s.substring(0, s.length - 4)}ense';
  if (s.endsWith('mme')) s = '${s.substring(0, s.length - 3)}m';
  return s.replaceAll('ll', 'l');
}

/// 英美拼写归并表（英式 → 规范形）。
///
/// 按规范化键分组，只有课标词库中同时存在两种写法才合并（如 color / colour），
/// 单独出现的词形不会被规则改写，避免把无关词误合。
/// [extraVariants] 为数据侧合并后补入的「变体 → 主条」映射
/// （变体已挂到主条 extensions、不再单列词条）。
Map<String, String> buildSpellingAliases(Iterable<String> words,
    {Map<String, String> extraVariants = const {}}) {
  final lower = <String>{};
  for (final w in words) {
    final lw = w.toLowerCase();
    if (RegExp(r'^[a-z]+$').hasMatch(lw)) lower.add(lw);
  }
  final groups = <String, Set<String>>{};
  for (final lw in lower) {
    groups.putIfAbsent(usSpellingKey(lw), () => <String>{}).add(lw);
  }
  final out = <String, String>{};
  groups.forEach((key, set) {
    if (set.length < 2) return;
    final canonical = set.contains(key) ? key : (set.toList()..sort()).first;
    for (final w in set) {
      if (w != canonical) out[w] = canonical;
    }
  });
  irregularUkUs.forEach((uk, us) {
    if (lower.contains(uk) && lower.contains(us)) out[uk] = us;
  });
  extraVariants.forEach((variant, canonical) {
    if (variant != canonical) out[variant] = canonical;
  });
  return out;
}

bool _isSpellingPair(String a, String b) {
  if (usSpellingKey(a) == usSpellingKey(b)) return true;
  for (final e in irregularUkUs.entries) {
    if ((e.key == a && e.value == b) || (e.key == b && e.value == a)) {
      return true;
    }
  }
  return false;
}

/// 从课标库 extensions 中识别英美拼写变体（变体 → 主条）。
///
/// 数据侧已把英美拼写对合并为一条、变体挂到主条 extensions 里；
/// 这里把「变体 → 主条」补回统计口径，保证查词、页面词频、导出高频
/// 三处仍按同一条计数。
Map<String, String> buildExtensionSpellingAliases(
    Map<String, Iterable<String>> extensionsByBase) {
  final out = <String, String>{};
  extensionsByBase.forEach((base, exts) {
    final lb = base.toLowerCase();
    if (!RegExp(r'^[a-z]+$').hasMatch(lb)) return;
    for (final raw in exts) {
      final le = raw.toLowerCase();
      if (!RegExp(r'^[a-z]+$').hasMatch(le) || le == lb) continue;
      if (_isSpellingPair(le, lb)) out.putIfAbsent(le, () => lb);
    }
  });
  return out;
}

/// 内置补充映射：用户词库缺失但已确认的词形归并（不写用户配置）。
const Map<String, String> builtinExtendBase = <String, String>{
  'practises': 'practice',
};

/// 内置同义词：缩写与全称视为同一个词。
const Map<String, String> builtinWordAliases = <String, String>{
  'tv': 'television',
  'tvs': 'television',
};

/// 课标库 extensions 的归并表（检测页与高频导出共用同一实现）。
///
/// 只收录「本身不是课标词条」的词形：形同义不同的词形（found 建立 / left 左边 /
/// born / lay 放置 / lost / rose / thought / would / should / might）本身就是
/// 独立词条，并入主条会抬高主条频次、也让页面无法单独统计它们。
Map<String, String> buildLibraryExtensionBaseMap({
  required Iterable<String> standardKeys,
  required Map<String, Iterable<String>> extensionsByBase,
}) {
  final keys = <String>{
    for (final k in standardKeys) foldWordText(k).trim().toLowerCase(),
  };
  final out = <String, String>{};
  extensionsByBase.forEach((base, exts) {
    final lb = foldWordText(base).trim().toLowerCase();
    if (lb.isEmpty) return;
    for (final raw in exts) {
      final le = foldWordText(raw).trim().toLowerCase();
      if (le.isEmpty || le == lb || keys.contains(le)) continue;
      out.putIfAbsent(le, () => lb);
    }
  });
  return out;
}

/// 检测页与高频导出共用的统计键：折叠（弯撇号/连字/全角/变音）后小写，
/// 再套用同义词别名（TV / TVs → television）。
///
/// 两侧必须都经本函数取键，否则 TV 在页面与导出会落到不同词条。
String analysisWordKey(String raw) {
  final lower = foldToken(raw);
  return builtinWordAliases[lower] ?? lower;
}

/// 拓展映射规范化（检测页与高频导出共用，避免大小写重复键各取一份）。
///
/// 用户词库 extendBaseMap 中存在大量「仅大小写不同」的重复键，且归属不同
/// （如 members→member 与 Members→membership）。界面词库按小写键查表，
/// 因此这里以「本身就是小写形式的键」为最高优先级，大小写混合键仅在缺位时补上，
/// 保证同一份数据在页面与导出两侧得到同一张映射表。
Map<String, String> normalizeExtendBaseMap(Map<String, String> raw) {
  final out = <String, String>{};
  void add(MapEntry<String, String> e, {required bool lowerOnly}) {
    final k = e.key.trim();
    final v = e.value.trim();
    if (k.isEmpty || v.isEmpty) return;
    final lk = k.toLowerCase();
    if (lowerOnly != (k == lk)) return;
    out.putIfAbsent(lk, () => v.toLowerCase());
  }

  for (final e in raw.entries) {
    add(e, lowerOnly: true);
  }
  for (final e in raw.entries) {
    add(e, lowerOnly: false);
  }
  return out;
}

/// 构建拓展词→课标原词映射的唯一实现（词库页、检测页、高频导出共用）。
///
/// 规则：词形必须纯小写字母、不能自映射、归属必须是课标词库内的原词；
/// 最后补入内置映射（practises→practice 等），保证页面与导出取同一张表。
Map<String, String> buildExtendBaseMap({
  required Map<String, String> raw,
  required Iterable<String> standardKeys,
}) {
  final stdLower = standardKeys.map((e) => e.toLowerCase()).toSet();
  final out = <String, String>{};
  for (final e in normalizeExtendBaseMap(raw).entries) {
    final ext = e.key;
    final base = e.value;
    if (!RegExp(r'^[a-z]+$').hasMatch(ext)) continue;
    if (ext == base) continue;
    if (!stdLower.contains(base)) continue;
    out.putIfAbsent(ext, () => base);
  }
  for (final e in builtinExtendBase.entries) {
    if (stdLower.contains(e.value)) out.putIfAbsent(e.key, () => e.value);
  }
  return out;
}

/// 一个词形所属的词族根（课标原词的英美规范形）。
String familyRoot(
  String word,
  Map<String, String> aliases,
  Map<String, String> extBaseMap,
) {
  final lw = word.toLowerCase();
  if (builtinWordAliases.containsKey(lw)) {
    final t = builtinWordAliases[lw]!;
    return aliases[t] ?? t;
  }
  final base = extBaseMap[lw] ?? builtinExtendBase[lw] ?? lw;
  return aliases[base] ?? base;
}

/// 同一个词的完整词族，按显示优先级排列：
/// 被查词 → 英美对应拼写/课标原词 → 其他拓展变形（字典序）。
class WordFamily {
  final String root;
  final List<String> forms;

  const WordFamily(this.root, this.forms);
}

WordFamily wordFamily(
  String word, {
  required Iterable<String> standardKeys,
  required Iterable<String> extendWords,
  required Map<String, String> extBaseMap,
  Map<String, String> extensionAliases = const {},
}) {
  final lw = word.trim().toLowerCase();
  final aliases =
      buildSpellingAliases(standardKeys, extraVariants: extensionAliases);
  final root = familyRoot(lw, aliases, extBaseMap);

  final priority = <String>[lw];
  // 英美对应拼写（practise ↔ practice、colour ↔ color）
  if (root != lw) priority.add(root);
  final partners = <String>{};
  aliases.forEach((uk, us) {
    if (us == lw) partners.add(uk);
    if (uk == lw) partners.add(us);
  });
  for (final p in partners.toList()..sort()) {
    if (!priority.contains(p)) priority.add(p);
  }
  // 归属同一词族根的拓展词（practices / practising / practised ...）
  final others = <String>{};
  for (final e in extendWords) {
    final el = e.toLowerCase();
    if (!RegExp(r'^[a-z]+$').hasMatch(el)) continue;
    if (el == lw) continue;
    if (familyRoot(el, aliases, extBaseMap) == root) others.add(el);
  }
  others.removeAll(priority);
  for (final e in builtinExtendBase.keys) {
    if (e == lw) continue;
    if (familyRoot(e, aliases, extBaseMap) == root) others.add(e);
  }
  for (final e in builtinWordAliases.keys) {
    if (e == lw) continue;
    if (familyRoot(e, aliases, extBaseMap) == root) others.add(e);
  }
  priority.addAll(others.toList()..sort());
  return WordFamily(root, priority);}
