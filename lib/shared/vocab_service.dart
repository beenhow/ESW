import 'package:flutter/services.dart' show rootBundle;
import 'dart:convert';
import 'dart:io';

/// 单词分类常量
const wordCategories = ['真题词', '课标词', '拓展词', '超标词', '专有词'];

/// 平台无关的词汇服务：加载课标词库、反向索引、查询、分类
class VocabService {
  static final VocabService _instance = VocabService._();
  factory VocabService() => _instance;
  VocabService._();

  /// 课标词数据：{word: {category, pos, def}}
  Map<String, Map<String, String>> standardWords = {};
  /// 大小写不敏感索引：{lowercase → [原始大小写...]}
  Map<String, List<String>> standardWordsLower = {};
  /// 小写 key 集合（快速查找）
  Set<String> standardWordsLowerKeySet = {};
  /// 拓展词反向索引：{extension_word → base_word}
  Map<String, String> extendReverseIndex = {};
  /// 首字母索引
  Map<String, List<String>> wordsByFirstChar = {};
  /// 拓展词首字母索引（加速 searchSuggestions）
  final Map<String, List<String>> _extendWordsByFirstChar = {};
  /// 用户添加的拓展词列表
  final List<String> extendWords = [];
  /// 拓展词小写索引（O(1) 查找）
  final Set<String> extendWordsLowerSet = {};
  /// 拓展词→基础课标词映射
  final Map<String, String> extendBaseMap = {};
  /// 手动超标词
  final Set<String> manualChaoGangWords = {};
  /// 手动超标词小写索引
  final Set<String> chaoGangLowerSet = {};
  /// 手动专有词
  final Set<String> manualExtraWords = {};
  /// 手动专有词小写索引
  final Set<String> extraLowerSet = {};
  /// 分类记忆：{lowercase → category}
  final Map<String, String> classificationMemory = {};
  /// 搜索历史
  final List<String> wordHistory = [];

  bool _loaded = false;

  /// 加载课标词库
  Future<void> loadStandardWords() async {
    if (_loaded) return;
    try {
      final jsonStr = await rootBundle.loadString('assets/standard_words.json');
      final raw = json.decode(jsonStr) as Map<String, dynamic>;
      extendReverseIndex.clear();
      standardWords = raw.map((k, v) {
        final m = v as Map<String, dynamic>;
        final exts = m['extensions'];
        if (exts is List) {
          for (final ext in exts) {
            final extLower = ext.toString().toLowerCase();
            if (extLower.isNotEmpty) {
              extendReverseIndex[extLower] = k.toLowerCase();
            }
          }
        }
        return MapEntry(k, {
          'category': (m['category'] as String?) ?? '',
          'pos': (m['pos'] as String?) ?? '',
          'def': (m['def'] as String?) ?? '',
        });
      });
      standardWordsLower.clear();
      for (final key in standardWords.keys) {
        final lk = key.toLowerCase();
        standardWordsLower.putIfAbsent(lk, () => []);
        standardWordsLower[lk]!.add(key);
      }
      standardWordsLowerKeySet = standardWordsLower.keys.toSet();
      wordsByFirstChar.clear();
      for (final key in standardWords.keys) {
        if (key.isEmpty) continue;
        final firstChar = key[0].toLowerCase();
        wordsByFirstChar.putIfAbsent(firstChar, () => []);
        wordsByFirstChar[firstChar]!.add(key);
      }
      _loaded = true;
    } catch (_) {
      standardWords = {};
      _loaded = true;
    }
  }

  /// 查询单词信息
  Map<String, String?> lookup(String word) {
    final lower = word.toLowerCase();
    // 精确匹配
    if (standardWords.containsKey(word)) {
      return standardWords[word]!;
    }
    // 大小写不敏感
    final matches = standardWordsLower[lower];
    if (matches != null && matches.isNotEmpty) {
      return standardWords[matches.first]!;
    }
    return {};
  }

  /// 判断是否课标词
  bool isStandard(String word) {
    return standardWordsLowerKeySet.contains(word.toLowerCase());
  }

  /// 判断是否拓展词
  bool isExtend(String word) {
    return extendWordsLowerSet.contains(word.toLowerCase());
  }

  /// 判断是否超标词
  bool isChaoGang(String word) {
    return chaoGangLowerSet.contains(word.toLowerCase());
  }

  /// 判断是否专有词
  bool isExtra(String word) {
    return extraLowerSet.contains(word.toLowerCase());
  }

  /// 获取单词的分类记忆
  String? getClassification(String word) {
    return classificationMemory[word.toLowerCase()];
  }

  /// 设置分类记忆
  void setClassification(String word, String category) {
    classificationMemory[word.toLowerCase()] = category;
  }

  /// 添加拓展词
  /// 分类互斥：加入前先从超标词/专有词集合移除该词，
  /// 保证同一单词只归属一个手动分类，查词页/词库页分类显示一致。
  void addExtendWord(String word, {String? baseWord}) {
    final lower = word.toLowerCase();
    manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
    chaoGangLowerSet.remove(lower);
    manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
    extraLowerSet.remove(lower);
    if (!extendWordsLowerSet.contains(lower)) {
      extendWords.add(word);
      extendWordsLowerSet.add(lower);
    }
    if (baseWord != null) {
      extendBaseMap[word] = baseWord;
      extendReverseIndex[word.toLowerCase()] = baseWord.toLowerCase();
    }
    classificationMemory[word.toLowerCase()] = '拓展词';
  }

  /// 添加超标词
  /// 分类互斥：加入前先从拓展词/专有词集合移除该词。
  void addChaoGangWord(String word) {
    final lower = word.toLowerCase();
    extendWords.removeWhere((e) => e.toLowerCase() == lower);
    extendWordsLowerSet.remove(lower);
    extendBaseMap.remove(word);
    extendReverseIndex.remove(lower);
    manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
    extraLowerSet.remove(lower);
    manualChaoGangWords.add(word);
    chaoGangLowerSet.add(lower);
    classificationMemory[word.toLowerCase()] = '超标词';
  }

  /// 添加专有词
  /// 分类互斥：加入前先从拓展词/超标词集合移除该词。
  void addExtraWord(String word) {
    final lower = word.toLowerCase();
    extendWords.removeWhere((e) => e.toLowerCase() == lower);
    extendWordsLowerSet.remove(lower);
    extendBaseMap.remove(word);
    extendReverseIndex.remove(lower);
    manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
    chaoGangLowerSet.remove(lower);
    manualExtraWords.add(word);
    extraLowerSet.add(lower);
    classificationMemory[word.toLowerCase()] = '专有词';
  }

  /// 重新归类：先从旧分类移除，再加入新分类。
  /// 返回新分类标签（'拓展词'/'超标词'/'专有词'），如果新旧相同则返回 null。
  String? reclassifyWord(String word, String newCategory) {
    final lower = word.toLowerCase();
    final oldCat = _classify(lower);

    // 先从旧分类中移除
    if (oldCat == '拓展词') {
      extendWords.removeWhere((e) => e.toLowerCase() == lower);
      extendWordsLowerSet.remove(lower);
      extendBaseMap.remove(word);
      extendReverseIndex.remove(lower);
    } else if (oldCat == '超标词') {
      manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
      chaoGangLowerSet.remove(lower);
    } else if (oldCat == '专有词') {
      manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
      extraLowerSet.remove(lower);
    }

    // 加入新分类
    switch (newCategory) {
      case '拓展词':
        if (!extendWordsLowerSet.contains(lower)) {
          extendWords.add(word);
          extendWordsLowerSet.add(lower);
        }
        classificationMemory[lower] = '拓展词';
        return '拓展词';
      case '超标词':
        manualChaoGangWords.add(word);
        chaoGangLowerSet.add(lower);
        classificationMemory[lower] = '超标词';
        return '超标词';
      case '专有词':
        manualExtraWords.add(word);
        extraLowerSet.add(lower);
        classificationMemory[lower] = '专有词';
        return '专有词';
      default:
        return null;
    }
  }

  /// 修改单词拼写：将 oldWord 改名为 newWord，保持原有分类与拓展词基础词关系不变。
  ///
  /// 规则：
  /// - 仅大小写变化（oldLower == newLower）→ 仅更新集合中的显示大小写；
  /// - 目标词为课标词、或已存在于任一手动分类 → 返回 false；
  /// - 源词不在任一手动分类中 → 返回 false。
  /// 返回是否修改成功。
  bool renameWord(String oldWord, String newWord) {
    final oldLower = oldWord.toLowerCase();
    final newLower = newWord.toLowerCase();
    if (oldLower == newLower) {
      return _renameCaseOnly(oldWord, newWord);
    }
    if (newWord.isEmpty) return false;
    // 目标不能是课标词，也不能已存在于任一手动分类
    if (standardWordsLowerKeySet.contains(newLower)) return false;
    if (extendWordsLowerSet.contains(newLower) ||
        chaoGangLowerSet.contains(newLower) ||
        extraLowerSet.contains(newLower)) {
      return false;
    }
    final oldCat = _classifyManually(oldLower);
    if (oldCat == null) return false; // 源词不在手动词库中

    // 从旧分类移除
    extendWords.removeWhere((e) => e.toLowerCase() == oldLower);
    extendWordsLowerSet.remove(oldLower);
    manualChaoGangWords.removeWhere((e) => e.toLowerCase() == oldLower);
    chaoGangLowerSet.remove(oldLower);
    manualExtraWords.removeWhere((e) => e.toLowerCase() == oldLower);
    extraLowerSet.remove(oldLower);
    final base = extendBaseMap.remove(oldWord) ?? extendBaseMap.remove(oldLower);
    extendReverseIndex.remove(oldLower);
    classificationMemory.remove(oldLower);

    // 按原分类加入新词
    if (oldCat == '拓展词') {
      if (!extendWordsLowerSet.contains(newLower)) {
        extendWords.add(newWord);
        extendWordsLowerSet.add(newLower);
      }
      if (base != null) {
        extendBaseMap[newWord] = base;
        extendReverseIndex[newLower] = base.toLowerCase();
      }
      classificationMemory[newLower] = '拓展词';
    } else if (oldCat == '超标词') {
      manualChaoGangWords.add(newWord);
      chaoGangLowerSet.add(newLower);
      classificationMemory[newLower] = '超标词';
    } else if (oldCat == '专有词') {
      manualExtraWords.add(newWord);
      extraLowerSet.add(newLower);
      classificationMemory[newLower] = '专有词';
    }

    _rebuildLowerSets();
    return true;
  }

  /// 仅大小写变化的改名：更新集合中的显示大小写，不改变分类结构。
  bool _renameCaseOnly(String oldWord, String newWord) {
    bool changed = false;
    for (var i = 0; i < extendWords.length; i++) {
      if (extendWords[i].toLowerCase() == oldWord.toLowerCase()) {
        extendWords[i] = newWord;
        changed = true;
      }
    }
    if (extendBaseMap.containsKey(oldWord)) {
      final base = extendBaseMap.remove(oldWord)!;
      extendBaseMap[newWord] = base;
      changed = true;
    } else if (extendBaseMap.containsKey(oldWord.toLowerCase())) {
      final base = extendBaseMap.remove(oldWord.toLowerCase())!;
      extendBaseMap[newWord] = base;
      changed = true;
    }
    final chao = <String>{};
    var chaoChanged = false;
    for (final w in manualChaoGangWords) {
      if (w.toLowerCase() == oldWord.toLowerCase()) {
        chao.add(newWord);
        chaoChanged = true;
      } else {
        chao.add(w);
      }
    }
    if (chaoChanged) manualChaoGangWords..clear()..addAll(chao);
    final extra = <String>{};
    var extraChanged = false;
    for (final w in manualExtraWords) {
      if (w.toLowerCase() == oldWord.toLowerCase()) {
        extra.add(newWord);
        extraChanged = true;
      } else {
        extra.add(w);
      }
    }
    if (extraChanged) manualExtraWords..clear()..addAll(extra);
    _rebuildLowerSets();
    return changed;
  }

  /// 重建三个手动词表的小写索引（在加载/合并数据后调用）
  void _rebuildLowerSets() {
    extendWordsLowerSet.clear();
    _extendWordsByFirstChar.clear();
    for (final w in extendWords) {
      final lw = w.toLowerCase();
      extendWordsLowerSet.add(lw);
      final fc = w.isNotEmpty ? w[0].toLowerCase() : '_';
      _extendWordsByFirstChar.putIfAbsent(fc, () => []);
      _extendWordsByFirstChar[fc]!.add(w);
    }
    chaoGangLowerSet.clear();
    for (final w in manualChaoGangWords) {
      chaoGangLowerSet.add(w.toLowerCase());
    }
    extraLowerSet.clear();
    for (final w in manualExtraWords) {
      extraLowerSet.add(w.toLowerCase());
    }
  }

  /// 判断单词当前的手动分类（不含课标词/其他）
  String? _classifyManually(String lower) {
    if (extendWordsLowerSet.contains(lower)) return '拓展词';
    if (chaoGangLowerSet.contains(lower)) return '超标词';
    if (extraLowerSet.contains(lower)) return '专有词';
    return null;
  }

  /// 综合分类
  String? _classify(String lower) {
    final man = _classifyManually(lower);
    if (man != null) return man;
    if (standardWordsLowerKeySet.contains(lower)) return '课标词';
    return null;
  }

  /// 搜索建议（课标词 + 拓展词）
  List<String> searchSuggestions(String query, {int limit = 10}) {
    if (query.isEmpty) return [];
    final lower = query.toLowerCase();
    final results = <String>[];

    // 首字母快速匹配
    final firstChar = lower[0];
    final candidates = wordsByFirstChar[firstChar] ?? [];
    for (final w in candidates) {
      if (w.toLowerCase().startsWith(lower) && results.length < limit) {
        results.add(w);
      }
    }
    // 补充拓展词匹配（首字母索引，O(1) 分桶）
    final extCandidates = _extendWordsByFirstChar[firstChar] ?? [];
    for (final w in extCandidates) {
      if (w.toLowerCase().startsWith(lower) && !results.contains(w) && results.length < limit) {
        results.add(w);
      }
    }
    return results;
  }

  /// 添加搜索历史
  void addHistory(String word) {
    wordHistory.remove(word);
    wordHistory.insert(0, word);
    if (wordHistory.length > 20) {
      wordHistory.removeRange(20, wordHistory.length);
    }
  }

  /// 查找最佳课标词匹配（编辑距离启发式）
  String? findBestSyllabusMatch(String word) {
    final lower = word.toLowerCase();
    if (standardWordsLowerKeySet.contains(lower)) return word;
    if (extendReverseIndex.containsKey(lower)) return extendReverseIndex[lower];

    // 前缀匹配
    final firstChar = lower.isNotEmpty ? lower[0] : '';
    final candidates = wordsByFirstChar[firstChar] ?? [];
    String? best;
    int bestScore = 999;

    for (final c in candidates) {
      final cl = c.toLowerCase();
      // 前 3 个字符相同
      if (cl.length >= 3 && lower.length >= 3 && cl.substring(0, 3) == lower.substring(0, 3)) {
        final score = (cl.length - lower.length).abs();
        if (score < bestScore) {
          bestScore = score;
          best = c;
        }
      }
    }
    return best;
  }

  /// 导出配置为 JSON
  Map<String, dynamic> toJson() {
    return {
      'extendWords': extendWords,
      'extendBaseMap': extendBaseMap,
      'manualChaoGangWords': manualChaoGangWords.toList(),
      'manualExtraWords': manualExtraWords.toList(),
      'classificationMemory': classificationMemory,
      'wordHistory': wordHistory,
    };
  }

  /// 从 JSON 加载配置（覆盖式）
  void fromJson(Map<String, dynamic> json) {
    final ew = json['extendWords'];
    if (ew is List) {
      for (final w in ew) {
        if (!extendWordsLowerSet.contains(w.toString().toLowerCase())) {
          extendWords.add(w.toString());
          extendWordsLowerSet.add(w.toString().toLowerCase());
        }
      }
    }
    final ebm = json['extendBaseMap'];
    if (ebm is Map) {
      ebm.forEach((k, v) {
        if (!extendBaseMap.containsKey(k.toString())) {
          extendBaseMap[k.toString()] = v.toString();
          extendReverseIndex[k.toString().toLowerCase()] = v.toString().toLowerCase();
        }
      });
    }
    final mcg = json['manualChaoGangWords'];
    if (mcg is List) manualChaoGangWords.addAll(mcg.map((e) => e.toString()));
    final mex = json['manualExtraWords'];
    if (mex is List) manualExtraWords.addAll(mex.map((e) => e.toString()));
    final cm = json['classificationMemory'];
    if (cm is Map) {
      cm.forEach((k, v) {
        classificationMemory[k.toString()] = v.toString();
      });
    }
    final wh = json['wordHistory'];
    if (wh is List) {
      for (final w in wh) {
        if (!wordHistory.contains(w.toString())) {
          wordHistory.add(w.toString());
        }
      }
    }
    // 迁移旧分类名"超纲词" → "超标词"
    classificationMemory.forEach((k, v) {
      if (v == '超纲词') classificationMemory[k] = '超标词';
    });
    // 回填分类记忆
    for (final w in extendWords) {
      classificationMemory[w.toLowerCase()] = '拓展词';
    }
    for (final w in manualChaoGangWords) {
      classificationMemory[w.toLowerCase()] = '超标词';
    }
    for (final w in manualExtraWords) {
      classificationMemory[w.toLowerCase()] = '专有词';
    }
    _rebuildLowerSets();
  }

  /// 从 JSON 合并词库数据（追加式，不覆盖已有）。
  /// 使用统一本地查重（三类词合并），与 Windows _mergeRemoteIntoLocal 逻辑一致：
  /// 同一个词只要已在本地任一分类中存在，就不会重复加入其他分类。
  /// [remoteFirst] 为 true 时以远程分类为准：本地与远程都有的词，先清出本地再按远程分类重新加入。
  /// 适应场景：安卓作为跟随端，以 Windows 分类为权威，避免两端分类变更互相回滚。
  void mergeFromJson(Map<String, dynamic> json, {bool remoteFirst = false}) {
    if (remoteFirst) {
      // 收集所有远程词
      final remoteLower = <String>{};
      for (final cat in ['extendWords', 'manualChaoGangWords', 'manualExtraWords']) {
        final list = json[cat];
        if (list is List) {
          for (final w in list) { remoteLower.add(w.toString().toLowerCase()); }
        }
      }
      // 从所有本地分类中移除"远程也有的词"（即交由远程分类决定归属）
      extendWords.removeWhere((w) => remoteLower.contains(w.toLowerCase()));
      manualChaoGangWords.removeWhere((w) => remoteLower.contains(w.toLowerCase()));
      manualExtraWords.removeWhere((w) => remoteLower.contains(w.toLowerCase()));
      _rebuildLowerSets();
    }

    // 统一本地已有词集合（三类合并，大小写不敏感）
    final localLowerAll = <String>{};
    for (final w in extendWords) { localLowerAll.add(w.toLowerCase()); }
    for (final w in manualChaoGangWords) { localLowerAll.add(w.toLowerCase()); }
    for (final w in manualExtraWords) { localLowerAll.add(w.toLowerCase()); }

    final ew = json['extendWords'];
    if (ew is List) {
      for (final w in ew) {
        if (!localLowerAll.contains(w.toString().toLowerCase())) {
          extendWords.add(w.toString());
          localLowerAll.add(w.toString().toLowerCase());
        }
      }
    }
    final ebm = json['extendBaseMap'];
    if (ebm is Map) {
      ebm.forEach((k, v) {
        if (!extendBaseMap.containsKey(k.toString())) {
          extendBaseMap[k.toString()] = v.toString();
          extendReverseIndex[k.toString().toLowerCase()] = v.toString().toLowerCase();
        }
      });
    }
    final mcg = json['manualChaoGangWords'];
    if (mcg is List) {
      for (final w in mcg) {
        final lower = w.toString().toLowerCase();
        if (!localLowerAll.contains(lower)) {
          manualChaoGangWords.add(w.toString());
          localLowerAll.add(lower);
        }
      }
    }
    final mex = json['manualExtraWords'];
    if (mex is List) {
      for (final w in mex) {
        final lower = w.toString().toLowerCase();
        if (!localLowerAll.contains(lower)) {
          manualExtraWords.add(w.toString());
          localLowerAll.add(lower);
        }
      }
    }
    final cm = json['classificationMemory'];
    if (cm is Map) {
      cm.forEach((k, v) {
        final key = k.toString().toLowerCase();
        if (!classificationMemory.containsKey(key)) {
          classificationMemory[key] = v.toString();
        }
      });
    }
    // 迁移旧分类名"超纲词" → "超标词"
    classificationMemory.forEach((k, v) {
      if (v == '超纲词') classificationMemory[k] = '超标词';
    });
    // 回填分类记忆（仅对新增词条）
    for (final w in extendWords) {
      if (!classificationMemory.containsKey(w.toLowerCase())) {
        classificationMemory[w.toLowerCase()] = '拓展词';
      }
    }
    for (final w in manualChaoGangWords) {
      if (!classificationMemory.containsKey(w.toLowerCase())) {
        classificationMemory[w.toLowerCase()] = '超标词';
      }
    }
    for (final w in manualExtraWords) {
      if (!classificationMemory.containsKey(w.toLowerCase())) {
        classificationMemory[w.toLowerCase()] = '专有词';
      }
    }
    _rebuildLowerSets();
  }

  /// 从真题语料目录统计单词词频与逐年分布。
  /// [corpusDirPath] 为已解压的 corpus 目录绝对路径。
  /// 返回 { "total": 总次数, "byYear": { "2023全国卷I": [{"text":..., "filePath":..., "offset":...}, ...], ... } }；
  /// 每个例句携带来源文件路径 filePath 与关键词在原文中的字符偏移 offset，供点击跳转定位。
  /// 若目录不存在或读取失败返回 null。
  Future<Map<String, dynamic>?> getWordFrequency(String word, String corpusDirPath) async {
    final dir = Directory(corpusDirPath);
    if (!await dir.exists()) return null;

    final wordPattern = RegExp(r'\b' + RegExp.escape(word) + r'\b', caseSensitive: false);
    final byYear = <String, List<Map<String, dynamic>>>{};
    int total = 0;

    try {
      final txtFiles = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.txt'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final file in txtFiles) {
        final yearKey = file.uri.pathSegments.last
            .replaceAll(RegExp(r'\.txt$', caseSensitive: false), '');
        final content = await file.readAsString();
        final matches = wordPattern.allMatches(content).toList();
        if (matches.isNotEmpty) {
          byYear.putIfAbsent(yearKey, () => []);
          for (final m in matches) {
            final start = (m.start - 50).clamp(0, content.length);
            final end = (m.end + 50).clamp(0, content.length);
            byYear[yearKey]!.add({
              'text': content.substring(start, end).replaceAll('\n', ' ').trim(),
              'filePath': file.path,
              'offset': m.start,
            });
          }
          total += matches.length;
        }
      }
    } catch (_) {
      return null;
    }

    if (total == 0) return null;
    return {'total': total, 'byYear': byYear};
  }
}
