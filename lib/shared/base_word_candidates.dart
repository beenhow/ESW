import '../porter_stemmer.dart';

/// 拓展词关联课标词：候选词生成（Windows / Android 双端统一逻辑）
///
/// 综合两端优点：
/// - 输入任意单词后，返回所有"相关"课标词候选，按相关度排序：
///   精确匹配 > 前缀匹配 > 课标词包含输入 > 输入包含课标词（拆词）> 最长公共前缀形态学匹配
/// - 输入为空时可传 [targetWord]（原始目标词），自动跳出拆词候选（如 undergo → under / go）

class _ScoredWord {
  final String word;
  final int score;
  final int pos;
  final int lcp;
  _ScoredWord(this.word, this.score, [this.pos = 0, this.lcp = 0]);
}

const _knownPrefixes = {
  'anti', 'un', 're', 'dis', 'pre', 'mis', 'over', 'under', 'out', 'up',
  'down', 'in', 'im', 'il', 'ir', 'non', 'ex', 'de', 'en', 'em', 'sub',
  'inter', 'trans', 'super', 'semi', 'mid', 'co', 'counter', 'extra',
  'hyper', 'micro', 'mini', 'multi', 'post', 'pro', 'auto', 'bio', 'geo',
  'tele', 'mono', 'poly', 'uni', 'bi', 'tri', 'self', 'fore', 'with',
  'per', 'a', 'ab', 'ad', 'be', 'com', 'con', 'ob', 'se',
};

const _knownSuffixes = {
  'ing', 'ed', 's', 'es', 'er', 'est', 'ly', 'tion', 'sion', 'ment',
  'ness', 'ful', 'less', 'able', 'ible', 'al', 'ive', 'ous', 'ize', 'ise',
  'en', 'ship', 'hood', 'ist', 'ism', 'ity', 'ify', 'ate', 'age', 'ance',
  'ence', 'ant', 'ent', 'ic', 'ish', 'ty', 'ure', 'ward', 'wise', 'y',
  'or', 'ee', 'ian',
};

int _lcpLength(String a, String b) {
  final len = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < len; i++) {
    if (a[i] != b[i]) return i;
  }
  return len;
}

/// 生成"拓展词 → 课标词"候选列表（双端统一）
List<String> baseWordCandidates(
  String query,
  List<String> allStandardWords, {
  String? targetWord,
  int limit = 30,
}) {
  final input = query.trim().toLowerCase();
  final lower = input.isEmpty ? (targetWord ?? '').toLowerCase() : input;

  // 任务④（运行速度）：小写词表一次性预计算 —— 原实现在每次输入时对全量
  // 词表反复调用 toLowerCase()（最长公共前缀那层是「输入长度 × 词表规模」次
  // 字符串分配），这里同序缓存后仅做数组取用，语义完全不变。
  final lcw = _lowerWordsOf(allStandardWords);
  final scored = <_ScoredWord>[];
  final seen = <String>{};

  // 1) 精确匹配：输入/目标词本身就是课标词（如输入 go → go）
  for (int i = 0; i < allStandardWords.length; i++) {
    final sw = allStandardWords[i];
    if (lcw[i] == lower) {
      scored.add(_ScoredWord(sw, 100000, 0, lower.length));
      seen.add(sw);
    }
  }

  if (lower.isNotEmpty) {
    // 2) 前缀匹配：课标词以输入开头（如输入 go → goal/goat/god/gone/goes...）
    for (int i = 0; i < allStandardWords.length; i++) {
      final sw = allStandardWords[i];
      if (seen.contains(sw)) continue;
      final swLower = lcw[i];
      if (swLower.length >= 2 && swLower.startsWith(lower)) {
        // 前缀组：短词优先，字母越多越靠后（长度负权重），组间仍高于子串组
        scored.add(_ScoredWord(sw, 80000 - swLower.length * 10, 0, lower.length));
        seen.add(sw);
      }
    }
    // 3) 课标词包含输入子串（如输入 go → ago / begin 等任意含 go 的课标词）
    for (int i = 0; i < allStandardWords.length; i++) {
      final sw = allStandardWords[i];
      if (seen.contains(sw)) continue;
      final swLower = lcw[i];
      if (swLower.length > lower.length && swLower.contains(lower)) {
        // 子串组：短词优先，字母越多越靠后（长度负权重）
        scored.add(_ScoredWord(sw, 50000 - swLower.length * 10, 0, lower.length));
        seen.add(sw);
      }
    }
    // 4) 输入包含课标词：前缀拆词（undergo → under）或后缀拆词（undergo → go），排除偶然中缀误配
    for (int i = 0; i < allStandardWords.length; i++) {
      final sw = allStandardWords[i];
      if (seen.contains(sw)) continue;
      final swLower = lcw[i];
      if (swLower.length >= 2 && lower.length > swLower.length &&
          (lower.startsWith(swLower) || lower.endsWith(swLower))) {
        scored.add(_ScoredWord(sw, 9000 + swLower.length * 100, 0, swLower.length));
        seen.add(sw);
      }
    }
  }

  // 5) 最长公共前缀（LCP）拆词匹配：覆盖形态学 / 词根派生（如 happiness → happy）
  for (int pos = 0; pos < lower.length; pos++) {
    final suffix = lower.substring(pos);
    for (int i = 0; i < allStandardWords.length; i++) {
      final sw = allStandardWords[i];
      final swLower = lcw[i];
      if (seen.contains(sw)) continue;

      final lcp = _lcpLength(suffix, swLower);
      if (lcp < 3) continue;

      if (pos == 0) {
        if (swLower == lower) {
          scored.add(_ScoredWord(sw, 10000, pos, lcp));
          seen.add(sw);
          continue;
        }
        if (swLower.length > lower.length && lcp < lower.length * 0.7) {
          continue;
        }

        if (lcp < 4) {
          if (lcp.toDouble() / lower.length < 0.4) continue;
        } else {
          if (lcp < swLower.length && lcp.toDouble() / lower.length < 0.45) continue;
        }

        int score = lcp * 200;
        final remainder = lower.substring(lcp);
        if (_knownSuffixes.contains(remainder)) {
          score += 300;
        }
        if (swLower.length - lcp <= 2) {
          score += 200;
        }
        scored.add(_ScoredWord(sw, score, pos, lcp));
      } else {
        final skipped = lower.substring(0, pos);

        if (lcp < 4) {
          if (!_knownPrefixes.contains(skipped)) continue;
          final maxLen = lower.length > swLower.length ? lower.length : swLower.length;
          if (lcp.toDouble() / maxLen < 0.5) continue;
          scored.add(_ScoredWord(sw, 5000 + lcp * 200, pos, lcp));
        } else {
          final maxLen = lower.length > swLower.length ? lower.length : swLower.length;

          if (lcp == swLower.length) {
            int score = 3000 + lcp * 200;
            if (_knownPrefixes.contains(skipped)) {
              score += 5000;
            }
            scored.add(_ScoredWord(sw, score, pos, lcp));
            seen.add(sw);
            continue;
          }

          if (pos < 2 && !_knownPrefixes.contains(skipped)) continue;

          if (lcp.toDouble() / maxLen < 0.4) continue;
          int score = lcp * 100 - pos * 5;
          if (_knownPrefixes.contains(skipped)) {
            score += 5000;
          }
          scored.add(_ScoredWord(sw, score, pos, lcp));
        }
      }
      seen.add(sw);
    }
  }

  // 5) 词干直接匹配：Porter Stemmer 词干相等即入选（happiness → happy），
  //    弥补 LCP 覆盖率门槛可能漏掉的长词根匹配
  final inputStem = porterStem(lower);
  if (lower.length >= 3 && inputStem.length >= 3) {
    for (int i = 0; i < allStandardWords.length; i++) {
        final sw = allStandardWords[i];
        if (seen.contains(sw)) continue;
        final swLower = lcw[i];
        if (swLower.length < 3) continue;
        final candStem = _stemOf(swLower);
        if (candStem == inputStem) {
          scored.add(_ScoredWord(sw, 7000 + inputStem.length * 200, 0, inputStem.length));
          seen.add(sw);
        }
      }
  }

  scored.sort((a, b) => b.score.compareTo(a.score));

  // 词干匹配提权：Porter Stemmer 识别词干相同的候选词
  for (int i = 0; i < scored.length; i++) {
    final sw = scored[i];
    final candStem = _stemOf(sw.word);
    if (inputStem == candStem) {
      scored[i] = _ScoredWord(sw.word, sw.score + 7000, sw.pos, sw.lcp);
    } else if (inputStem.length >= 4 && candStem.length >= 4) {
      final stemLcp = _lcpLength(inputStem, candStem);
      if (stemLcp >= 4) {
        scored[i] = _ScoredWord(sw.word, sw.score + stemLcp * 200, sw.pos, sw.lcp);
      }
    }
  }
  scored.sort((a, b) => b.score.compareTo(a.score));

  // 主候选抑制：若首位候选覆盖率≥75%，过滤同位置弱匹配
  if (scored.isNotEmpty) {
    final top = scored.first;
    if (top.pos == 0 && top.lcp > 0) {
      final coverage = top.lcp.toDouble() / lower.length;
      if (coverage >= 0.75) {
        scored.removeWhere((s) =>
            s.pos == 0 && s.lcp < top.lcp && s.lcp.toDouble() / lower.length < 0.5);
      }
    }
  }

  return scored.map((s) => s.word).take(limit).toList();
}


// ---------- 任务④（运行速度）性能缓存 ----------
// 候选生成是「边输入边过滤」的热路径：每次输入都会遍历全量课标词表。
// 小写词表与 Porter 词干都是纯函数结果，原实现每次输入都要重算数千次，
// 这里改为一次性预计算 + 复用（语义不变，结果逐词一致）。

List<String>? _lcSourceRef; // 上次预计算对应的词表对象（按引用判定是否复用）
List<String> _lcCache = const <String>[]; // 同序小写词表
final Map<String, String> _stemCache = <String, String>{}; // 单词 → 词干

/// 取词表对应的小写表：同一词表对象只计算一次。
List<String> _lowerWordsOf(List<String> words) {
  if (identical(words, _lcSourceRef) && _lcCache.length == words.length) {
    return _lcCache;
  }
  final lower = List<String>.generate(
    words.length,
    (i) => words[i].toLowerCase(),
    growable: false,
  );
  _lcSourceRef = words;
  _lcCache = lower;
  return lower;
}

/// Porter 词干记忆化：全量词表逐个跑词干是本路径最重的开销之一。
String _stemOf(String word) {
  final hit = _stemCache[word];
  if (hit != null) return hit;
  if (_stemCache.length > 60000) _stemCache.clear(); // 规模保护（词表远小于此）
  final stem = porterStem(word);
  _stemCache[word] = stem;
  return stem;
}

/// 优化前实现快照（逐字保留改造前的算法，含每次调用 toLowerCase() 与
/// 未缓存的 Porter 词干）。仅供 [EswPerf] 性能自测做「优化前 / 优化后」
/// 同机同轮对比，生产路径（windows_app / android_app）不调用。
/// 优化前实现快照（同 [baseWordCandidates]，逐字未改）
List<String> baseWordCandidatesLegacy(
  String query,
  List<String> allStandardWords, {
  String? targetWord,
  int limit = 30,
}) {
  final input = query.trim().toLowerCase();
  final lower = input.isEmpty ? (targetWord ?? '').toLowerCase() : input;
  final scored = <_ScoredWord>[];
  final seen = <String>{};

  // 1) 精确匹配：输入/目标词本身就是课标词（如输入 go → go）
  for (final sw in allStandardWords) {
    if (sw.toLowerCase() == lower) {
      scored.add(_ScoredWord(sw, 100000, 0, lower.length));
      seen.add(sw);
    }
  }

  if (lower.isNotEmpty) {
    // 2) 前缀匹配：课标词以输入开头（如输入 go → goal/goat/god/gone/goes...）
    for (final sw in allStandardWords) {
      if (seen.contains(sw)) continue;
      final swLower = sw.toLowerCase();
      if (swLower.length >= 2 && swLower.startsWith(lower)) {
        // 前缀组：短词优先，字母越多越靠后（长度负权重），组间仍高于子串组
        scored.add(_ScoredWord(sw, 80000 - swLower.length * 10, 0, lower.length));
        seen.add(sw);
      }
    }
    // 3) 课标词包含输入子串（如输入 go → ago / begin 等任意含 go 的课标词）
    for (final sw in allStandardWords) {
      if (seen.contains(sw)) continue;
      final swLower = sw.toLowerCase();
      if (swLower.length > lower.length && swLower.contains(lower)) {
        // 子串组：短词优先，字母越多越靠后（长度负权重）
        scored.add(_ScoredWord(sw, 50000 - swLower.length * 10, 0, lower.length));
        seen.add(sw);
      }
    }
    // 4) 输入包含课标词：前缀拆词（undergo → under）或后缀拆词（undergo → go），排除偶然中缀误配
    for (final sw in allStandardWords) {
      if (seen.contains(sw)) continue;
      final swLower = sw.toLowerCase();
      if (swLower.length >= 2 && lower.length > swLower.length &&
          (lower.startsWith(swLower) || lower.endsWith(swLower))) {
        scored.add(_ScoredWord(sw, 9000 + swLower.length * 100, 0, swLower.length));
        seen.add(sw);
      }
    }
  }

  // 5) 最长公共前缀（LCP）拆词匹配：覆盖形态学 / 词根派生（如 happiness → happy）
  for (int pos = 0; pos < lower.length; pos++) {
    final suffix = lower.substring(pos);
    for (final sw in allStandardWords) {
      final swLower = sw.toLowerCase();
      if (seen.contains(sw)) continue;

      final lcp = _lcpLength(suffix, swLower);
      if (lcp < 3) continue;

      if (pos == 0) {
        if (swLower == lower) {
          scored.add(_ScoredWord(sw, 10000, pos, lcp));
          seen.add(sw);
          continue;
        }
        if (swLower.length > lower.length && lcp < lower.length * 0.7) {
          continue;
        }

        if (lcp < 4) {
          if (lcp.toDouble() / lower.length < 0.4) continue;
        } else {
          if (lcp < swLower.length && lcp.toDouble() / lower.length < 0.45) continue;
        }

        int score = lcp * 200;
        final remainder = lower.substring(lcp);
        if (_knownSuffixes.contains(remainder)) {
          score += 300;
        }
        if (swLower.length - lcp <= 2) {
          score += 200;
        }
        scored.add(_ScoredWord(sw, score, pos, lcp));
      } else {
        final skipped = lower.substring(0, pos);

        if (lcp < 4) {
          if (!_knownPrefixes.contains(skipped)) continue;
          final maxLen = lower.length > swLower.length ? lower.length : swLower.length;
          if (lcp.toDouble() / maxLen < 0.5) continue;
          scored.add(_ScoredWord(sw, 5000 + lcp * 200, pos, lcp));
        } else {
          final maxLen = lower.length > swLower.length ? lower.length : swLower.length;

          if (lcp == swLower.length) {
            int score = 3000 + lcp * 200;
            if (_knownPrefixes.contains(skipped)) {
              score += 5000;
            }
            scored.add(_ScoredWord(sw, score, pos, lcp));
            seen.add(sw);
            continue;
          }

          if (pos < 2 && !_knownPrefixes.contains(skipped)) continue;

          if (lcp.toDouble() / maxLen < 0.4) continue;
          int score = lcp * 100 - pos * 5;
          if (_knownPrefixes.contains(skipped)) {
            score += 5000;
          }
          scored.add(_ScoredWord(sw, score, pos, lcp));
        }
      }
      seen.add(sw);
    }
  }

  // 5) 词干直接匹配：Porter Stemmer 词干相等即入选（happiness → happy），
  //    弥补 LCP 覆盖率门槛可能漏掉的长词根匹配
  final inputStem = porterStem(lower);
  if (lower.length >= 3 && inputStem.length >= 3) {
    for (final sw in allStandardWords) {
        if (seen.contains(sw)) continue;
        final swLower = sw.toLowerCase();
        if (swLower.length < 3) continue;
        final candStem = porterStem(swLower);
        if (candStem == inputStem) {
          scored.add(_ScoredWord(sw, 7000 + inputStem.length * 200, 0, inputStem.length));
          seen.add(sw);
        }
      }
  }

  scored.sort((a, b) => b.score.compareTo(a.score));

  // 词干匹配提权：Porter Stemmer 识别词干相同的候选词
  for (int i = 0; i < scored.length; i++) {
    final sw = scored[i];
    final candStem = porterStem(sw.word);
    if (inputStem == candStem) {
      scored[i] = _ScoredWord(sw.word, sw.score + 7000, sw.pos, sw.lcp);
    } else if (inputStem.length >= 4 && candStem.length >= 4) {
      final stemLcp = _lcpLength(inputStem, candStem);
      if (stemLcp >= 4) {
        scored[i] = _ScoredWord(sw.word, sw.score + stemLcp * 200, sw.pos, sw.lcp);
      }
    }
  }
  scored.sort((a, b) => b.score.compareTo(a.score));

  // 主候选抑制：若首位候选覆盖率≥75%，过滤同位置弱匹配
  if (scored.isNotEmpty) {
    final top = scored.first;
    if (top.pos == 0 && top.lcp > 0) {
      final coverage = top.lcp.toDouble() / lower.length;
      if (coverage >= 0.75) {
        scored.removeWhere((s) =>
            s.pos == 0 && s.lcp < top.lcp && s.lcp.toDouble() / lower.length < 0.5);
      }
    }
  }

  return scored.map((s) => s.word).take(limit).toList();
}


