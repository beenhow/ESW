/// ESW Windows 版「导出高频」功能核心实现。
///
/// 功能：统计历年高考真题语料（corpus 目录全部 txt）中单词出现频率，
/// 取前 3000 高频词，按频率区间分组，导出 Excel(xlsx)：
///   - 单词（标注课标类型 初中/必修/选修；拓展词归并到课标原词）
///   - 词典释义（ecdict.db，去除 [v:43/n:57] 词性频率标记）
///   - 优选真题例句（默认 2 条、优先最近年份、同词例句年份不重复、标注年份；
///     候选含词条归并的拓展词/变体，并剥离原文中文括号注释，保证高频课标词有例句）
///   - 课标词表（3333）内的词一律参与统计，不再按专有词/星期月份/序数词/
///     人称代词/情态助动词剔除；专有词启发式仅用于表外词
///   - 课标短语（如 according to）按整条统计与展示，不拆成单词
///   - 同一课标原词的拓展词合并计频次（report/reporter/reporting 均以 report 记）
///   - 每词条标注"频次"（课标原词 + 归并拓展词合计）：真题语料为「真题频次」，
///     教材语料为「教材频次」；教材例句前缀用版本·册次（如「人教版 必修一」）
///   - 每词一行，列结构：序号/单词/类型/频次/音标/词性/释义/例句1-4/
///     拓展词列表（said(1122)）/拓展词例句（said(1122): 例句；says(480): 例句）
///   - 拓展词列不显示中文释义，改为各自的真题例句（无例句则留空）
///
/// 全程在后台 isolate（compute）中执行，避免阻塞 UI。
/// xlsx 使用工程已引入 excel 包生成（Sheet 行模型 + 列宽设置），不依赖 Office。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'shared/doc_extractor.dart';
import 'shared/export_word_style.dart';
import 'shared/phrase_stats.dart';
import 'shared/text_normalize.dart';
import 'shared/word_family.dart';

/// 「导出高频」年份窗口：0 = 全部年份，>0 = 近 N 年。
///
/// 只认用户在对话框里的显式选择：选了「全部年份」时必须返回 0，
/// 不能用输入框默认的 5 年兜底（否则全部年份会退化成近五年）。
int exportYearWindowFromSelection({
  required bool allYears,
  required int recentYears,
}) {
  if (allYears) return 0;
  return recentYears.clamp(1, 30);
}

/// 导出结果统计信息
class HighFreqExportResult {
  /// 导出格式（'xlsx' 或 'docx'），与 export(format:) 入参一致
  final String format;

  /// Excel(xlsx) 字节：format == 'xlsx' 时非空，docx 时为 null
  final Uint8List xlsxBytes;

  /// Word(docx) 字节：format == 'docx' 时非空，xlsx 时为 null
  final Uint8List? docxBytes;
  final int corpusFileCount;
  final int totalTokens;
  final int exportedWords;
  final List<String> groupSummary; // 每组 "组名: 词数"
  final List<String> cleanedExtWords; // 本次剔除的脏拓展词清单（缩略/机构/地名类）
  final List<String> nonHeadCapsExcluded; // 非句首大写专有词清单（Londoners 等，已排除）
  final List<String> calendarOrdinalExcluded; // 本次剔除的星期/月份/序数词清单（含缩写/词库拓展）
  const HighFreqExportResult({
    required this.xlsxBytes,
    this.docxBytes,
    this.format = 'xlsx',
    required this.corpusFileCount,
    required this.totalTokens,
    required this.exportedWords,
    required this.groupSummary,
    this.cleanedExtWords = const [],
    this.nonHeadCapsExcluded = const [],
    this.calendarOrdinalExcluded = const [],
  });
}

/// 词库导出类型元数据：UI 弹窗与导出器共用一份定义（防两处漂移）。
///
/// [key] 为导出器内部标识；[label] 为界面/文件名用语；[title] 为文档标题；
/// [category] 取 [ExportCategory] 常量（决定七类字色/字重规范），保证词库
/// 导出与「导出高频」的配色口径完全一致。
class WordBankKind {
  final String key;
  final String label;
  final String title;
  final String category;
  final String source;

  /// 表格/文档中是否附带「对应课标原词」列（仅拓展词库有归并原词）
  final bool withBaseStd;

  const WordBankKind({
    required this.key,
    required this.label,
    required this.title,
    required this.category,
    required this.source,
    this.withBaseStd = false,
  });
}

/// 三类词库导出定义（高频统计走 HighFreqExporter.export，不在此列）。
const List<WordBankKind> kWordBankKinds = <WordBankKind>[
  WordBankKind(
    key: 'extend',
    label: '拓展词库',
    title: '高考拓展词库',
    category: ExportCategory.extend,
    source: '软件词库「拓展词汇」列表 + 拓展词→课标原词映射（白名单合并）',
    withBaseStd: true,
  ),
  WordBankKind(
    key: 'overLimit',
    label: '超标词库',
    title: '高考超标词库',
    category: ExportCategory.overLimit,
    source: '软件词库「超标词汇」分类已归类词',
  ),
  WordBankKind(
    key: 'proper',
    label: '专有词库',
    title: '高考专有词库',
    category: ExportCategory.proper,
    source: '软件词库「专有词汇」分类已归类词',
  ),
];

/// 词库导出（拓展 / 超标 / 专有）结果。
class WordBankExportResult {
  /// 词库类型 key：extend / overLimit / proper
  final String kind;

  /// 导出格式：docx / xlsx / txt
  final String format;

  /// 文件字节
  final Uint8List bytes;

  /// 导出词条数
  final int wordCount;

  /// 命中词典释义的词条数（其余词条释义列留空，不臆造）
  final int dictHit;

  const WordBankExportResult({
    required this.kind,
    required this.format,
    required this.bytes,
    required this.wordCount,
    required this.dictHit,
  });
}

/// 单个词条
class _WordEntry {
  final String word; // 展示词形（规范大小写）
  final String? baseStd; // 课标原词（该词为拓展词时非空）
  final int freq; // 合并后总频次（含归并的拓展词）
  final bool isStd; // 是否课标词
  final String? category; // 课标级别类型（初中/必修/选修等，取自 standard_words.json category）
  final Map<String, String>? dict; // pos/definition/phonetic/exchange（pos 已净化）
  // 例句 + 年份 + 来源（真题卷别 / 教材版本；教材例句年份为 0，用来源标注）
  final List<({String text, int year, String source})> examples;
  // 归并的拓展成员：词形 + 释义 + 频次 + 各自的例句（无则留空）
  final List<
      ({
        String word,
        Map<String, String>? dict,
        int freq,
        List<({String text, int year, String source})> examples
      })> members;
  _WordEntry({
    required this.word,
    this.baseStd,
    required this.freq,
    required this.isStd,
    this.category,
    this.dict,
    required this.examples,
    required this.members,
  });
}

/// 顶层入口（UI isolate 调用）
class HighFreqExporter {
  /// 执行导出：在后台 isolate 完成统计与 xlsx 生成，返回结果字节。
  ///
  /// [corpusDir] 真题语料目录；[standardWordsRaw] standard_words.json 原文；
  /// [dbPath] ecdict.db 绝对路径（须已由 DictionaryService 部署）。
  /// [extendBaseMapRaw] 软件词库中的拓展词→课标原词映射（JSON 对象字符串，
  /// 由调用端从界面"拓展词汇"列表同一数据源 esw_config.json 的 extendWords
  /// + extendBaseMap 汇总而来：键已用 extendWords 白名单过滤，仅含界面词库
  /// 真实存在的拓展词）。拓展词归并严格以此为准（与 standard_words.json
  /// extensions 合并），不再从 ecdict exchange 全量反向引入未在词库中声明
  /// 的变体。
  /// [extendWordsRaw] 界面"拓展词汇"列表的完整词集合（JSON 数组字符串，
  /// 即 esw_config.json 的 extendWords 字段，与列表页同一数据源）。用于对
  /// standard_words.json extensions 做同样的白名单过滤：任何不在界面词库
  /// 拓展词集合内的词一律不进入导出词表（如 born/borne 等课标词库声明但
  /// 界面词库未收录的词形），保证导出词表拓展词 ⊆ 界面词库拓展词集合。
  static Future<HighFreqExportResult> export({
    required String corpusDir,
    required String standardWordsRaw,
    required String dbPath,
    String? extendBaseMapRaw,
    String? extendWordsRaw,
    String format = 'xlsx',
    Set<String>? onlyFileNames,
    int wordLimit = 3000,
    /// true 时导出「全部课标词」：补入语料中未出现的课标词条（频次 0），
    /// 且不做前 N 截断（wordLimit 不再生效）。
    bool allStdWords = false,
    /// true 表示语料来自教材：频次列改为「教材频次」，例句前缀用教材版本
    /// （如「人教版 必修一」）代替年份。
    bool textbookCorpus = false,
  }) async {
    // worker 返回纯 Map（Dart 3 自定义类默认不可跨 isolate 发送），
    // 在主 isolate 侧组装结果对象，彻底规避 "object is unsendable"。
    final m = await compute(_exportWorker, {
      'corpusDir': corpusDir,
      'standardWordsRaw': standardWordsRaw,
      'dbPath': dbPath,
      'extendBaseMapRaw': extendBaseMapRaw ?? '',
      'extendWordsRaw': extendWordsRaw ?? '',
      'format': format == 'docx' ? 'docx' : 'xlsx',
      'onlyFileNames': onlyFileNames?.toList(),
      'wordLimit': wordLimit,
      'allStdWords': allStdWords,
      'textbookCorpus': textbookCorpus,
    });
    return HighFreqExportResult(
      format: m['format'] as String,
      xlsxBytes: m['xlsxBytes'] as Uint8List,
      docxBytes: m['docxBytes'] as Uint8List?,
      corpusFileCount: m['corpusFileCount'] as int,
      totalTokens: m['totalTokens'] as int,
      exportedWords: m['exportedWords'] as int,
      groupSummary: (m['groupSummary'] as List).cast<String>(),
      cleanedExtWords: (m['cleanedExtWords'] as List).cast<String>(),
      nonHeadCapsExcluded: (m['nonHeadCapsExcluded'] as List).cast<String>(),
      calendarOrdinalExcluded:
          (m['calendarOrdinalExcluded'] as List).cast<String>(),
    );
  }

  /// 导出词库（拓展词库 / 超标词库 / 专有词库）。
  ///
  /// **复用高频统计的同一套排版实现**（[_buildDocx] / [_buildXlsx] / [_buildTxt]），
  /// 因此标题结构、说明行、字号字重、七类字色规范（[ExportCategory] /
  /// [kExportWordStyles]）、页边距与表头样式与「导出高频」完全一致，
  /// 唯一差异是数据来源换成对应词库（[words] 由调用端从界面词库真实取出），
  /// 不新增任何独立样式分支，也不臆造字段。
  ///
  /// [kind] 'extend' | 'overLimit' | 'proper'；[format] 'docx' | 'xlsx' | 'txt'。
  static Future<WordBankExportResult> exportWordBank({
    required String kind,
    required List<String> words,
    Map<String, String> baseMap = const {},
    required String dbPath,
    String format = 'docx',
    String corpusDir = '',
  }) async {
    final m = await compute(_wordBankWorker, {
      'kind': kind,
      'words': words,
      'baseMap': baseMap,
      'dbPath': dbPath,
      'format': format,
      'corpusDir': corpusDir,
    });
    return WordBankExportResult(
      kind: m['kind'] as String,
      format: m['format'] as String,
      bytes: m['bytes'] as Uint8List,
      wordCount: m['wordCount'] as int,
      dictHit: m['dictHit'] as int,
    );
  }
}

/// 词库导出 worker（isolate 内执行：查词典释义 + 调共用排版函数）。
///
/// 只做"取释义 + 转交共用构建器"，不复制任何排版逻辑，保证与高频统计
/// 逐像素同源。
Map<String, dynamic> _wordBankWorker(Map<String, dynamic> args) {
  final kind = args['kind'] as String;
  final meta = kWordBankKinds.firstWhere(
    (k) => k.key == kind,
    orElse: () => kWordBankKinds.first,
  );
  final rawWords = (args['words'] as List).cast<String>();
  final format = args['format'] as String;
  final dbPath = args['dbPath'] as String;

  final baseMap = <String, String>{};
  final bm = args['baseMap'];
  if (bm is Map) {
    bm.forEach((k, v) {
      final key = k.toString().trim().toLowerCase();
      final val = v.toString().trim();
      if (key.isNotEmpty && val.isNotEmpty) baseMap[key] = val;
    });
  }

  // 去重（大小写不敏感，保留首次出现的原大小写）+ A→Z 稳定排序，
  // 保证同一份词库多次导出结果一致（便于用户比对与增量更新）。
  final seen = <String>{};
  final words = <String>[];
  for (final w in rawWords) {
    final t = w.trim();
    if (t.isEmpty) continue;
    if (!seen.add(t.toLowerCase())) continue;
    words.add(t);
  }
  words.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  final entries = <_WordEntry>[];
  var dictHit = 0;
  sqlite3.Database? db;
  try {
    db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    _loadDictIndex(db);
    for (final w in words) {
      final dict = _lookupCached(db, w);
      if (dict != null) dictHit++;
      entries.add(_WordEntry(
        word: w,
        baseStd: meta.withBaseStd ? baseMap[w.toLowerCase()] : null,
        freq: 0,
        isStd: false,
        category: meta.category,
        dict: dict,
        examples: const <({String text, int year, String source})>[],
        members: const [],
      ));
    }
  } finally {
    db?.dispose();
  }

  final subtitle = '共 ${entries.length} 词 · 数据来源：${meta.source} · '
      '版式与「导出高频」一致（同标题/说明行/字号/页边距），正文常规黑色';

  final Uint8List bytes;
  switch (format) {
    case 'xlsx':
      bytes = _buildXlsx(
        entries,
        sheetName: meta.title,
        showFreq: false,
        showBaseStd: meta.withBaseStd,
      );
      break;
    case 'txt':
      bytes = _buildTxt(
        entries,
        title: meta.title,
        subtitle: subtitle,
        showFreq: false,
        showBaseStd: meta.withBaseStd,
      );
      break;
    default:
      bytes = _buildDocx(
        entries,
        title: meta.title,
        subtitle: subtitle,
        showFreq: false,
        showBaseStd: meta.withBaseStd,
        styleEntries: false,
      );
  }

  return {
    'kind': meta.key,
    'format': format,
    'bytes': bytes,
    'wordCount': entries.length,
    'dictHit': dictHit,
  };
}

// ----------------------------- 文本工具 -----------------------------

// 与检测/标注共用同一分词口径：带点缩写（a.m. / U.S.）视为一个词元
final RegExp _wordRe = wordTokenRegExp;
final RegExp _sentenceRe = RegExp(r'[^.!?。！？]+[.!?。！？]');

final RegExp _hanRe = RegExp(r'[\u4e00-\u9fa5]');
final RegExp _trailNumRe = RegExp(r'\d+\.\s*$');
final RegExp _yearRe = RegExp(r'(?:19|20)\d{2}');
/// 教材册次标题行（必修一第一单元 / 选择性必修二第三单元）：与界面教材
/// 单元切分同一正则，用于给教材例句标注「版本 册次」来源。
final RegExp _textbookModuleRe = RegExp(
  r'^[ \t]*((?:选择性)?必修[一二三四五六七八九十0-9]+)第[一二三四五六七八九十0-9]+单元[ \t]*$',
  multiLine: true,
);
/// 形如 [v:43/n:57] 的词性频率标记（词典 pos 字段为 "n:49/v:51" 原始形态，
/// 展示时解析为 "n./v."；此处正则用于兜底清理释义文本中的残留标记）
final RegExp _freqTagRe = RegExp(r'\[[a-zA-Z]+:\d+(?:/[a-zA-Z]+:\d+)*\]');

/// 频率区间分组名
String _groupName(int f) {
  if (f <= 0) return '0次（语料未出现）';
  if (f >= 5001) return '5000次以上';
  if (f >= 1001) return '1001-5000次';
  if (f >= 501) return '501-1000次';
  if (f >= 301) return '301-500次';
  if (f >= 201) return '201-300次';
  if (f >= 101) return '101-200次';
  if (f >= 51) return '51-100次';
  if (f >= 41) return '41-50次';
  if (f >= 31) return '31-40次';
  if (f >= 21) return '21-30次';
  if (f >= 11) return '11-20次';
  return '1-10次';
}


/// 词性频率标记净化：把 "n:49/v:51" → "n./v."；"j:1/n:99" → "adj./n."。
String _cleanPos(String pos) {
  if (pos.isEmpty) return '';
  const map = <String, String>{
    'n': 'n.', 'v': 'v.', 'vi': 'vi.', 'vt': 'vt.', 'adj': 'adj.',
    'a': 'adj.', 'j': 'adj.', 'adv': 'adv.', 'ad': 'adv.', 'pron': 'pron.',
    'prep': 'prep.', 'num': 'num.', 'm': 'num.', 'art': 'art.',
    'conj': 'conj.', 'interj': 'interj.', 'aux': 'aux.', 'abbr': 'abbr.',
    'u': 'u.', 'pl': 'pl.', 's': 's.',
  };
  final out = <String>[];
  for (final seg in pos.split('/')) {
    final code = seg.trim().split(':').first.trim().toLowerCase();
    if (code.isEmpty) continue;
    final mapped = map[code];
    // 仅保留映射表内已知词性；i/c/r/d/p/t 等 ecdict 私有代码（如 of 的
    // "i:100"、a 的 "a:99/t:1"、in 的 "i:95/c:1/r:3/j:1"）不具展示含义，
    // 一律过滤，避免释义行出现 "adj./t"、"i/c/r/adj." 类词性标签残留。
    if (mapped == null) continue;
    if (!out.contains(mapped)) out.add(mapped);
  }
  return out.join('/');
}

/// 从文件名提取年份（如 "2005 beijing.txt" → 2005），失败返回 -1。
/// 注意：只对 basename 匹配，避免上级目录名中的数字干扰。
int _yearFromName(String name) {
  final base = p.basenameWithoutExtension(name);
  final m = _yearRe.firstMatch(base);
  return m == null ? -1 : int.parse(m.group(0)!);
}

// ----------------------------- 词典（isolate 内直查 sqlite） -----------------------------

/// 预编译语句 + 查询缓存（同一 worker isolate 内复用，显著减少 SQL 编译与重复查询）
sqlite3.PreparedStatement? _stmtExact;

/// 内存词典索引：word 全集（判定是否收录）+ exchange 0:base 反向索引
/// （base -> 变形词列表，替代原先逐词 LIKE 全表扫描）
final _dictWordSet = <String>{};
/// 小写键 -> 词典中的原始拼写（China / OK 等大写词条）。
/// SQLite 的 `word = ?` 区分大小写，必须用原始拼写回查，否则小写键取不到释义。
final _dictWordOriginal = <String, String>{};
final _dictExchangeIndex = <String, List<String>>{};
final _dictBaseMap = <String, String>{}; // 变形词 -> 0:base（词库原始归属，如 noting->note）
final _dictCache = <String, Map<String, String>?>{};

/// 加载词典索引：一次全表扫描构建 word 集合、0:base 反向映射与正向归属映射。
void _loadDictIndex(sqlite3.Database db) {
  if (_dictWordSet.isNotEmpty) return;
  for (final row in db.select('SELECT word, exchange FROM dict')) {
    final original = row['word'] as String;
    final w = original.toLowerCase();
    _dictWordSet.add(w);
    _dictWordOriginal.putIfAbsent(w, () => original);
    final ex = row['exchange'] as String?;
    if (ex != null && ex.isNotEmpty) {
      for (final seg in ex.split('/')) {
        final parts = seg.split(':');
        if (parts.length == 2 && parts[0] == '0') {
          final base = parts[1].toLowerCase();
          (_dictExchangeIndex[base] ??= []).add(w);
          _dictBaseMap.putIfAbsent(w, () => base);
        }
      }
    }
  }
}

Map<String, String>? _rowToSimple(sqlite3.Row row) {
  final def = row['definition'];
  final pos = row['pos'];
  if ((def == null || (def as String).isEmpty) &&
      (pos == null || (pos as String).isEmpty)) {
    return null;
  }
  return {
    'pos': (pos as String?) ?? '',
    'definition': (def as String?) ?? '',
    'phonetic': (row['phonetic'] as String?) ?? '',
    'exchange': (row['exchange'] as String?) ?? '',
    'tag': (row['tag'] as String?) ?? '',
  };
}

/// 带缓存的词典查询：同词只查一次库。
Map<String, String>? _lookupCached(sqlite3.Database db, String word) {
  final lower = word.toLowerCase();
  if (_dictCache.containsKey(lower)) return _dictCache[lower];
  final result = _lookupLocal(db, lower);
  _dictCache[lower] = result;
  return result;
}

/// 查询单词释义；若为变形词（exchange 含 0:xxx）自动反查原形，未收录返回 null。
Map<String, String>? _lookupLocal(sqlite3.Database db, String word) {
  final lower = word.toLowerCase();
  _stmtExact ??= db.prepare('SELECT pos, definition, phonetic, tag, exchange '
      'FROM dict WHERE word = ? LIMIT 1');
  // 未收录词直接返回（避免 LIKE 全表扫描）；变体收录走内存反向索引
  if (!_dictWordSet.contains(lower)) {
    final variant = _dictExchangeIndex[lower];
    if (variant == null || variant.isEmpty) return null;
    final original = _dictWordOriginal[variant.first] ?? variant.first;
    final rows = _stmtExact!.select([original]).toList();
    return rows.isNotEmpty ? _rowToSimple(rows.first) : null;
  }
  // 用词典里的原始拼写回查（China / OK 等大写词条），避免小写键查不到。
  final original = _dictWordOriginal[lower] ?? lower;
  final rows = _stmtExact!.select([original]).toList();
  final result = rows.isNotEmpty ? _rowToSimple(rows.first) : null;
  if (result == null) return null;

  // 仅当自身行缺释义且缺音标时，才反查 exchange 0:base 行内容补位。
  // 自身行已有释义/音标（如 left 的"左边的/left"、also 的"也/ɒ:lsәu"）
  // 必须保留自身，避免独立词条的音标释义被原形行整体顶替
  // （also 显示 conjure 内容、left 显示 /li:v/ 的错位根因）。
  final hasSelfContent = ((result['definition'] ?? '').isNotEmpty ||
      (result['phonetic'] ?? '').isNotEmpty);
  if (!hasSelfContent) {
    final ex = result['exchange'] ?? '';
    for (final seg in ex.split('/')) {
      final parts = seg.split(':');
      if (parts.length == 2 && parts[0] == '0') {
        final baseLower = parts[1].toLowerCase();
        final baseWord = _dictWordOriginal[baseLower] ?? baseLower;
        final baseRows = _stmtExact!.select([baseWord]).toList();
        final baseResult =
            baseRows.isNotEmpty ? _rowToSimple(baseRows.first) : null;
        if (baseResult != null) return baseResult;
        break;
      }
    }
  }

  return result;
}

// ----------------------------- 例句优选 -----------------------------

/// 为 [target] 从倒排索引中挑选 [max] 条优选例句。
/// 打分规则：排除含中文/乱码/题号残留/过短过长句；难词数（非课标且词频<30）
/// 越少越优先；难词数相同时优先最近年份；同一词例句年份不重复。
/// [max] 由调用方决定（默认 2，义项多时放宽到 4）。
/// [altWords]：拼写/形态变体候选词（如归并进词条的拓展词）。当 target 本身
/// 在语料中无完整句（如 analyse 只出现在选项碎片、applaud 原形无正文句）时，
/// 用变体词的完整句补位，保证高频课标词都有真题例句。
/// [excludeYears]：需避开的年份（如同词条已占用的例句年份），保证年份不重复。
/// [sentSources]：与 [sentences] 同下标的来源标签（卷别 / 教材版本）；教材例句
/// 年份为 0，展示时用来源标签代替年份。
List<({String text, int year, String source})> pickExamples(
  String target,
  List<String> sentences,
  List<List<String>> sentTokens,
  Map<String, List<int>> sentIndex,
  Map<String, int> freq,
  Set<String> standardWords,
  List<int> sentYears,
  int max, {
  List<String> altWords = const [],
  Set<int> excludeYears = const {},
  List<String> sentSources = const [],
}) {
  // 候选池分层：target 自身词形句（倒排索引按 token 精确匹配）优先；
  // altWords（base/其它归并变体）的句子仅作补位，绝不与 target 句混选，
  // 保证拓展词例句必然精确包含拓展词自身词形（cannot/cans/wills/willed/
  // workforce/workshops/wrought 不再被 base 词例句顶替）。
  final targetIdx = <int>[];
  final altIdx = <int>[];
  final seenCand = <int>{};
  for (final i in sentIndex[target] ?? const <int>[]) {
    if (seenCand.add(i)) targetIdx.add(i);
  }
  for (final a in altWords) {
    if (a == target) continue;
    for (final i in sentIndex[a] ?? const <int>[]) {
      if (seenCand.add(i)) altIdx.add(i);
    }
  }
  if (targetIdx.isEmpty && altIdx.isEmpty) return const [];

  // 打分：按年份分组采样（每年最多 12 条）→ 清洗 → 难词少优先 →
  // 年份近优先 → 语料靠前优先。
  List<(int hard, int year, int pos, String text)> scoreIdx(
      List<int> idxs, {required bool isTarget}) {
    final byYear = <int, List<int>>{};
    for (final idx in idxs) {
      final y = sentYears[idx];
      final bucket = byYear.putIfAbsent(y, () => <int>[]);
      if (bucket.length >= 12) continue;
      bucket.add(idx);
    }
    final scored = <(int hard, int year, int pos, String text)>[];
    for (final idx in byYear.values.expand((b) => b)) {
      var s = sentences[idx].trim().replaceFirst(RegExp(r'^["“”‘’\s]+'), '')
          .replaceFirst(RegExp(r'["“”‘’\s]+$'), '')
          .replaceFirst(RegExp(r'^[A-D][．.、]\s*'), '') // 选项标记 A．/B.
          .replaceAll(RegExp(r'_{2,}'), ''); // 完形填空下划线残留
      // 剥离真题原文内嵌的中文括号注释（如 acid(酸性的）、（暴露）、（丢弃的)），
      // 避免整句因"含中文"被弃——这类注释不是题干，剥离后仍是完整英文句。
      // 替换为一个空格，防止相邻单词粘连（如 acid(酸性的）soil → acid soil）。
      s = s.replaceAll(RegExp(r'[（(][\u4e00-\u9fa5][^（）()]*[）)]'), ' ');
      s = s.replaceFirst(RegExp(r'\s+[A-D]\.\s*$'), ''); // 句尾选项标记（如 ... table C.）
      s = s.replaceAll(RegExp(r'\s+'), ' ').trim(); // 压缩内部空白/换行，避免词间换行破坏句读
      if (s.length < 15 || s.length > 400) continue;
      final low = s.toLowerCase();
      if (low.contains('\uFFFD')) continue; // GBK 解码失败的乱码（原中文题干）
      if (_hanRe.hasMatch(s)) continue; // 剥离注释后仍含中文（如中文题干）→ 弃
      if (_trailNumRe.hasMatch(s)) continue; // 题号残留
      if (RegExp(r'\bto\s*\.\s*$').hasMatch(low)) continue; // 完形/阅读题"to ___."残尾
      if (RegExp(r'^[a-z]').hasMatch(s)) continue; // 句首小写多为选项/从句残片，正文整句句首应大写
      // 例句精确词形校验：句子必须包含目标词（或补位词）的独立空白 token，
      // 复合词成分（如 low-income 中的 low）不算命中，杜绝 base 例句顶替。
      // 仅剥首尾纯标点，保留连字符/短横线词整体，避免 "-olds" 被误认作 olds。
      String stripPunct(String t) {
        const p = '.,:;?!"“”‘’()[]{}\u00b7*';
        var s = t;
        while (s.isNotEmpty && p.contains(s[0])) {
          s = s.substring(1);
        }
        while (s.isNotEmpty && p.contains(s[s.length - 1])) {
          s = s.substring(0, s.length - 1);
        }
        return s;
      }

      final toks = low
          .split(RegExp(r'\s+'))
          .map(stripPunct)
          .where((t) => t.isNotEmpty)
          .toSet();
      final ok = isTarget
          ? toks.contains(target)
          : altWords.any((a) => toks.contains(a));
      if (!ok) continue;
      final words = sentTokens[idx];
      var hard = 0;
      for (final w in words) {
        final f = freq[w] ?? 0;
        if (f < 30 && !standardWords.contains(w)) hard++;
      }
      scored.add((hard, sentYears[idx], -idx, s));
    }
    scored.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      final y = b.$2.compareTo(a.$2);
      if (y != 0) return y;
      return a.$3.compareTo(b.$3);
    });
    return scored;
  }

  // 贪心去重年份（含调用方指定需避开的年份）：先取含 target 自身词形的句，
  // 不足 max 条时才用变体词句补位。
  final out = <({String text, int year, String source})>[];
  final usedYears = <int>{...excludeYears};
  void greedy(List<(int hard, int year, int pos, String text)> scored) {
    for (final s in scored) {
      if (usedYears.contains(s.$2)) continue;
      usedYears.add(s.$2);
      final idx = -s.$3;
      out.add((
        text: s.$4,
        year: s.$2,
        source: idx >= 0 && idx < sentSources.length ? sentSources[idx] : '',
      ));
      if (out.length >= max) return;
    }
  }

  greedy(scoreIdx(targetIdx, isTarget: true));
  if (out.length < max) greedy(scoreIdx(altIdx, isTarget: false));
  return out;
}

/// 例句候选池：与「导出高频」完全同一分词 / 切句 / 年份口径。
///
/// 检测报告页直接复用本池与 [pickExamples]，保证报告与导出表不会出现
/// 两套例句或两套词频口径。每段文本追加一次，随后按词取优选例句。
class ExampleSentencePool {
  ExampleSentencePool({
    required Set<String> standardWords,
    Set<String>? onlyWords,
  })  : _standardWords = standardWords,
        _onlyWords = onlyWords;

  final Set<String> _standardWords;

  /// 只对这些词累计年份 / 来源分布（检测报告用，避免为全语料建大表）。
  final Set<String>? _onlyWords;

  final List<String> _sentences = <String>[];
  final List<List<String>> _sentTokens = <List<String>>[];
  final List<int> _sentYears = <int>[];
  final List<String> _sentSources = <String>[];
  final Map<String, List<int>> _sentIndex = <String, List<int>>{};

  /// 全量 token 词频（例句难度打分用，与导出口径一致）。
  final Map<String, int> freq = <String, int>{};

  /// token → 年份 → 次数（仅 [onlyWords]）。
  final Map<String, Map<int, int>> yearCounts = <String, Map<int, int>>{};

  /// token → 来源标签 → 次数（仅 [onlyWords]），标签为卷别或教材版本。
  final Map<String, Map<String, int>> sourceCounts = <String, Map<String, int>>{};

  final Map<String, String> _sentenceSource = <String, String>{};

  /// 追加一段文本。[year] 用于年份分布与「同词不重复年份」，
  /// [source] 用于例句来源标注（卷别 / 教材版本）。
  void addText(String rawText, {required int year, required String source}) {
    if (rawText.trim().isEmpty) return;
    final text = normalizeCorpusText(rawText);
    for (final m in _wordRe.allMatches(text)) {
      final token = normalizeAnalysisToken(m.group(0)!);
      if (token == null) continue;
      final w = foldToken(token);
      if (w == "'" || w == "''") continue;
      freq[w] = (freq[w] ?? 0) + 1;
      if (_onlyWords == null || _onlyWords.contains(w)) {
        final ym = yearCounts[w] ??= <int, int>{};
        ym[year] = (ym[year] ?? 0) + 1;
        final sm = sourceCounts[w] ??= <String, int>{};
        sm[source] = (sm[source] ?? 0) + 1;
      }
    }
    for (final m in _sentenceRe.allMatches(text)) {
      final s = m.group(0)!.trim();
      if (s.isEmpty) continue;
      final tokens = <String>[];
      for (final tm in _wordRe.allMatches(s)) {
        final token = normalizeAnalysisToken(tm.group(0)!) ?? tm.group(0)!;
        tokens.add(foldToken(token));
      }
      if (s.length < 15 ||
          s.length > 400 ||
          tokens.length < 5 ||
          tokens.length > 80) {
        continue;
      }
      final si = _sentences.length;
      final seen = <String>{};
      for (final t in tokens) {
        if (seen.add(t)) (_sentIndex[t] ??= <int>[]).add(si);
      }
      _sentences.add(s);
      _sentTokens.add(tokens);
      _sentYears.add(year);
      _sentSources.add(source);
      _sentenceSource.putIfAbsent(s, () => source);
    }
  }

  /// 按与导出一致的规则挑 [max] 条例句，并带出来源标签。
  List<({String text, int year, String source})> pick(
    String target, {
    List<String> altWords = const <String>[],
    int max = 1,
    Set<int> excludeYears = const <int>{},
  }) {
    final picked = pickExamples(
      foldToken(target),
      _sentences,
      _sentTokens,
      _sentIndex,
      freq,
      _standardWords,
      _sentYears,
      max,
      altWords: [for (final a in altWords) foldToken(a)],
      excludeYears: excludeYears,
      sentSources: _sentSources,
    );
    return [
      for (final e in picked)
        (
          text: e.text,
          year: e.year,
          source: e.source.isNotEmpty ? e.source : (_sentenceSource[e.text] ?? ''),
        ),
    ];
  }
}

/// 判断词条是否"义项较多"（词性数量 >=2 或释义含多行），用于放宽例句条数。
bool _multiSense(Map<String, String>? dict) {
  if (dict == null) return false;
  final pos = dict['pos'] ?? '';
  final def = dict['definition'] ?? '';
  var count = 0;
  for (final seg in pos.split('/')) {
    final code = seg.trim().split(':').first.trim().toLowerCase();
    if (code.isNotEmpty) count++;
  }
  return count >= 2 || def.contains('\n');
}

// ----------------------------- 后台 isolate 主流程 -----------------------------

Map<String, dynamic> _exportWorker(Map<String, dynamic> args) {
  final corpusDir = args['corpusDir'] as String;
  final standardWordsRaw = args['standardWordsRaw'] as String;
  final dbPath = args['dbPath'] as String;
  final extendBaseMapRaw = (args['extendBaseMapRaw'] as String?) ?? '';
  final format = (args['format'] as String?) ?? 'xlsx';
  final wordLimit = (args['wordLimit'] as int?) ?? 3000;
  final allStdWords = (args['allStdWords'] as bool?) ?? false;
  final textbookCorpus = (args['textbookCorpus'] as bool?) ?? false;
  final onlyRaw = args['onlyFileNames'];
  final Set<String>? onlyFileNames = onlyRaw is List
      ? onlyRaw.map((e) => '$e').toSet()
      : null;

  // 注：界面「拓展词汇」列表（args.extendWordsRaw）不再作为导出的拓展词白名单；
  // 课标库 extensions 与用户 extendBaseMap 声明的词形一律参与归并。

  // 课标词库：折叠规范（弯撇号→直撇号、全角/变音→ASCII）+ 小写集合。
  // 折叠保证词库里的 o’clock 与语料中的 o'clock 命中同一条。
  final stdJson = jsonDecode(standardWordsRaw) as Map<String, dynamic>;
  // 词库内全部词条参与排名：内置专有词（America / Monday / China 等）按
  // 用户要求进入高频表；用户自建专有词不在课标库里（只在用户词库），
  // 因此天然不参与排名。
  final stdKeys = stdJson.keys.toList();
  final stdSet = <String>{};
  final lowerToOrig = <String, String>{};
  final stdCategory = <String, String>{}; // 课标词(小写) -> 类型（初中/必修/选修等）
  for (final k in stdKeys) {
    final lk = foldWordText(k).trim().toLowerCase();
    if (lk.isEmpty) continue;
    final meta = stdJson[k] as Map<String, dynamic>?;
    final cat = (meta?['category'] as String?)?.trim();
    // 末尾点可省略：a.m. 与 a.m、Mr. 与 Mr 归同一条目；普通词不扩展
    final variants = <String>[lk];
    if (lk.endsWith('.')) {
      final trimmed = lk.substring(0, lk.length - 1);
      if (trimmed.length >= 2) variants.add(trimmed);
    } else if (lk.contains('.') && !lk.contains(' ')) {
      variants.add('$lk.');
    }
    for (final v in variants) {
      stdSet.add(v);
      lowerToOrig.putIfAbsent(v, () => k);
      if (cat != null && cat.isNotEmpty) {
        // 同名小写词条与专有词并存时（china / China），类型取普通词条，
        // 专有义项由 displayWord/categoryOf 按语料写法另行判定。
        final prev = stdCategory[v];
        if (prev == null || (prev == '专有词' && cat != '专有词')) {
          stdCategory[v] = cat;
        }
      }
    }
  }
  // 与普通小写词条同名的内置专有词（China/china、March/march、May/may）：
  // 保留小写统计键（大小写不敏感计数不变），只在展示时按语料实际写法
  // 判断该行以哪一义为主（China 122 : china 0 → 中国；May 42 : may 410 → 情态动词）。
  final stdKeySet = stdKeys.toSet();
  final properSpellings = <String, String>{
    for (final k in stdKeys)
      if (((stdJson[k] as Map<String, dynamic>?)?['category'] as String?)
                  ?.trim() ==
              '专有词' &&
          k != k.toLowerCase() &&
          stdKeySet.contains(k.toLowerCase()))
        k.toLowerCase(): k,
  };
  // 小写键下「与专有词写法完全一致」的出现次数，用于判定主导义项。
  final properCapitalFreq = <String, int>{};
  // 课标库 extensions → 主条（第二遍：stdSet 已完整，才能识别「形同义不同」的
  // 独立词条；found/left/born/lay/lost/rose/thought/would/should/might 不并入）。
  final extByBase = <String, Iterable<String>>{};
  for (final k in stdKeys) {
    final exts = (stdJson[k] as Map<String, dynamic>?)?['extensions'];
    if (exts is List && exts.isNotEmpty) {
      extByBase[k] = exts.map((x) => '$x');
    }
  }
  final stdExtMap = buildLibraryExtensionBaseMap(
    standardKeys: stdSet,
    extensionsByBase: extByBase,
  ); // 拓展词(小写) -> 课标原词

  // 课标短语表与检测页共用同一实现（含空格、纯词形的词条才整条统计）。
  final stdPhrases = buildStandardPhrases(stdKeys);
  // 大小写异义词组（Miss/miss 等）：只由普通词条构成，避免把同名专有词
  // （China / March / May）并成同一条目、改写词条名。
  final caseVariantGroups = buildCaseVariantGroups(<String>[
    for (final k in stdKeys)
      if (((stdJson[k] as Map<String, dynamic>?)?['category'] as String?)
              ?.trim() !=
          '专有词')
        k,
  ]);
  // 大写形在语料中的出现次数：仅用于成员展示，不重复计入词条频次。
  final caseVariantFreq = <String, int>{};
  // 英美拼写归并：color / colour、center / centre、organize / organise 等
  // 统计为同一个词；与 TV→television 的别名表合并使用。
  // 数据侧已把英美拼写对合并为一条、变体挂主条 extensions，
  // 这里从 extensions 还原「变体 → 主条」，保证与页面词频同口径。
  final extensionSpellingAliases =
      buildExtensionSpellingAliases(extByBase);
  final spellingAliases =
      buildSpellingAliases(stdKeys, extraVariants: extensionSpellingAliases);
  final wordAliases = <String, String>{...spellingAliases, ...builtinWordAliases};

  // 课标库 extensions 一律参与归并（不再按界面「拓展词汇」列表做白名单过滤）：
  // 词库声明的词形（borne/bled/sung/mice 等）即使未出现在用户拓展词列表，
  // 也属于该课标词的正常词形，频次必须计入对应课标词条。

  // 1) 读取全部真题 txt（兼容 UTF-8/GBK），逐文件切句记录年份，同时统计词频
  final files = Directory(corpusDir)
      .listSync()
      .whereType<File>()
      .where(
        (f) =>
            f.path.toLowerCase().endsWith('.txt') &&
            (onlyFileNames == null ||
                onlyFileNames.contains(f.uri.pathSegments.last)),
      )
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final freq = <String, int>{}; // 全 token 词频（归并规范形口径）
  // 原始词形词频（未做英美拼写/TV 别名归并）：仅供归并成员展示，
  // 如 programme(52) 跟在 program 后面、colour(1) 跟在 color 后面。
  final rawFreq = <String, int>{};
  // 非句首大写专有词判据（与检测页共用 phrase_stats.ProperNounStats）
  final properStats = ProperNounStats(standardWords: stdSet);
  final sentences = <String>[];
  final sentTokens = <List<String>>[];
  final sentYears = <int>[];
  /// 与 [sentences] 同下标的来源标签：教材语料为「版本 册次」，真题为 ''。
  final sentSources = <String>[];
  final sentIndex = <String, List<int>>{};
  // 短语首词集合与覆盖累计器（与检测页共用 phrase_stats 的判据）。
  final phraseHeads = {for (final p in stdPhrases.keys) phraseHead(p)};
  final coverageTracker = PhraseCoverageTracker(stdPhrases);

  for (final f in files) {
    final year = _yearFromName(f.path);
    String text;
    final bytes = f.readAsBytesSync();
    text = decodeTextBytes(bytes);
    // 统一预处理（与检测页共用 normalizeCorpusText）：全角标点/弯引号
    // 归一化，避免全角句点把整段粘成"超长句"、弯撇号漏计 o'clock。
    text = normalizeCorpusText(text);
    // 教材语料：例句来源标注为「版本 册次」（如「人教版 必修一」）。
    // 册次按单元标题行定位，句子的来源取其之前最近的一个册次标题。
    final fileLabel =
        p.basenameWithoutExtension(f.path).replaceAll('_', ' ').trim();
    final moduleStarts = <({int start, String name})>[];
    if (textbookCorpus) {
      for (final mm in _textbookModuleRe.allMatches(text)) {
        moduleStarts.add((start: mm.start, name: mm.group(1)!));
      }
    }
    // 词频统计（覆盖全部 token）
    final headSpans = <String, List<(int, int)>>{};
    for (final m in _wordRe.allMatches(text)) {
      final raw = m.group(0)!;
      // 与检测页同一分词口径：折叠（café → cafe）、选项字母粘连剥离（itB → it）、
      // 单字母只保留 a / I，再按别名归并（TV → television）。
      final token = normalizeAnalysisToken(raw);
      if (token == null) continue;
      final lw = foldToken(token);
      final w = wordAliases[lw] ?? lw;
      if (w == "'" || w == "''") continue;
      freq[w] = (freq[w] ?? 0) + 1;
      // 同名专有词写法（China / March / May）的精确计数，用于判定主导义项。
      final properForm = properSpellings[w];
      if (properForm != null && raw == properForm) {
        properCapitalFreq[w] = (properCapitalFreq[w] ?? 0) + 1;
      }
      if (lw != w) rawFreq[lw] = (rawFreq[lw] ?? 0) + 1;
      if (phraseHeads.contains(w)) {
        (headSpans[w] ??= <(int, int)>[]).add((m.start, m.end));
      }
      // 大小写异义词：记录大写形出现次数（仅成员展示，不重复计入）。
      final variants = caseVariantGroups[lw];
      if (variants != null && variants.contains(raw)) {
        caseVariantFreq[lw] = (caseVariantFreq[lw] ?? 0) + 1;
      }
    }
    // 课标短语按整条统计（不拆成单词条目），如 according to / ice cream；
    // 同时记录匹配区间，供覆盖关系判定（首词是否每次都在短语内）。
    final phraseSpans = <String, List<(int, int)>>{};
    for (final phrase in stdPhrases.keys) {
      final ms = phraseRegExp(phrase).allMatches(text).toList();
      if (ms.isEmpty) continue;
      freq[phrase] = (freq[phrase] ?? 0) + ms.length;
      phraseSpans[phrase] = [for (final m in ms) (m.start, m.end)];
    }
    coverageTracker.addPositions(
      headTokenSpans: headSpans,
      phraseSpans: phraseSpans,
    );
    // 逐句处理：句首判定（供专有词识别）+ 例句倒排索引
    for (final m in _sentenceRe.allMatches(text)) {
      final s = m.group(0)!.trim();
      if (s.isEmpty) continue;
      final tokens = <String>[];
      var first = true;
      for (final tm in _wordRe.allMatches(s)) {
        final raw = tm.group(0)!;
        final token = normalizeAnalysisToken(raw) ?? raw;
        final lw = foldToken(token);
        final w = wordAliases[lw] ?? lw;
        // 非句首大写专有词判据统计（与检测页共用 ProperNounStats）
        properStats.addToken(raw, w, isFirstInSentence: first);
        if (first) first = false;
        tokens.add(w);
      }
      // 长度/词数过滤仅作用于例句候选，不影响上述专有词统计
      if (s.length < 15 || s.length > 400 || tokens.length < 5 ||
          tokens.length > 80) {
        continue;
      }
      final si = sentences.length;
      final seen = <String>{};
      for (final t in tokens) {
        if (seen.add(t)) (sentIndex[t] ??= []).add(si);
      }
      sentences.add(s);
      sentTokens.add(tokens);
      sentYears.add(year);
      var source = '';
      if (textbookCorpus) {
        var moduleName = '';
        for (final ms in moduleStarts) {
          if (ms.start > m.start) break;
          moduleName = ms.name;
        }
        source = fileLabel;
        if (moduleName.isNotEmpty && !fileLabel.contains(moduleName)) {
          source = '$fileLabel $moduleName';
        }
      }
      sentSources.add(source);
    }
  }

  // 短语覆盖结算：首词（如 according）在语料中每次出现都落在短语
  // （according to）内 → 二者是同一个词频，只保留短语条目，删掉首词条目，
  // 避免短语与组成词各计一遍。未完全覆盖时维持原口径（短语、组成词各自统计）。
  final mergedPhraseHeads = <String>{
    for (final c in coverageTracker.result().values)
      if (c.merged) c.head,
  };
  for (final h in mergedPhraseHeads) {
    freq.remove(h);
    rawFreq.remove(h);
  }

  // 2) 专有词识别（判据与检测页共用 ProperNounStats）
  //    （人名/地名/机构/语言名等）。注意：课标词库中混有的大写专有词
  //    （如 Olympic/America/China/English/Mr 等）同样按此规则排除；
  //    单字母词（I/a/i 等）除外，避免误伤代词。
  final properSet = properStats.properSet;

  // 非句首大写专有词（Londoners 等）排除集：语料中凡前一 token 非句末标点
  // （即非句首位置）仍首字母大写，且占比显著（>=50% 且至少 2 次非句首出现），
  // 判定为专有名词（人名/地名/机构名等），整词不进入词频统计与词表。
  //   - Londoners：非句首出现 2 次全大写（ratio 1.0）→ 排除（原 properSet
  //     的 total>=3 门槛将其漏放，故此处放宽到 2 次）。
  //   - made：900 次中出现仅 3 次 Made（产品标签式大写，ratio 极低）→ 保留。
  final nhCapsExcluded = properStats.nonHeadCapsExcluded;

  // 非句首大写专有词（Londoners 等）完整清单：供导出结果回执与测试断言。
  final nonHeadCapsExcluded = nhCapsExcluded.toList()..sort();

  // 3) 词典
  //    以只读方式打开：导出只做查询，不该拿写锁——否则多个导出（或并行运行的
  //    测试进程）同时命中同一个 ecdict.db 时会报 database is locked。
  final db =
      sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  _loadDictIndex(db);

  // 4) 拓展词→课标原词映射（严格以软件词库数据为准，不引入自定义词形还原规则）：
  //    a) standard_words.json extensions（课标词库显式声明的拓展词，上方 stdExtMap）
  //    b) 软件词库 extendBaseMap（esw_config.json / shared_vocab.json 的
  //       extendBaseMap 字段，即拓展词列表页所见数据：拓展词→课标原词）
  //    不再从 ecdict exchange 0:base 全量反向引入未在词库中声明的变体
  //    （如 ins 被 ecdict 误标 0:in，导致 in 词条出现 ins 缩略词——词库未声明
  //    则不归并）。ecdict 的 0:base 仍仅用于词典查询时的变形词释义反查。
  final extBaseMap = <String, String>{};
  extBaseMap.addAll(stdExtMap);
  if (extendBaseMapRaw.isNotEmpty) {
    try {
      final rawBase = (jsonDecode(extendBaseMapRaw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v.toString()));
      // 与检测页共用同一张映射表（同样的过滤 + 内置补充）
      extBaseMap.addAll(buildExtendBaseMap(raw: rawBase, standardKeys: stdSet));
    } catch (_) {
      // 词库数据异常时静默降级：仅保留 standard_words.json extensions
    }
  } else {
    extBaseMap.addAll(buildExtendBaseMap(raw: const {}, standardKeys: stdSet));
  }
  // 短语不能作为归并根：若词库把 due 声明为 due to 的拓展词，会让短语条目
  // 把 due 的独立出现也计入，短语频次被抬高。短语条目只统计整条出现，
  // 单词仍按自身词条统计（页面同口径）。
  extBaseMap.removeWhere((k, v) => v.contains(' '));
  // 异常/古式变形剔除：wrought 是 work 的古式过去式（词典 exchange 0:work），
  // 非正常屈折变形，不得作为 work 的拓展词（work 保留 working/works/worked）。
  extBaseMap.remove('wrought');
  // 词典脏数据修正：also 行 exchange 错误标注为 0:conjurer（词典数据本身有误），
  // 从反向归属映射剔除，避免 also 被误归并。
  extBaseMap.remove('also');
  // 拓展词归并到英美规范形：colours → colour → color，保证两种拼写的
  // 变形形式频次都计入同一个词条
  if (spellingAliases.isNotEmpty) {
    for (final k in extBaseMap.keys.toList()) {
      final v = extBaseMap[k]!;
      final nv = spellingAliases[v] ?? v;
      if (nv != v) extBaseMap[k] = nv;
    }
    extBaseMap.removeWhere((k, v) => k == v);
  }
  // 词频按词族根归并发生在下方词条汇总处（保留 token 级计数，供拓展词成员展示）

  // 可疑拓展词全量剔除（词库脏数据，非正常屈折变形）：
  //   soes：ecdict 中独立词条为金融缩写（词性 t，股票期权），exchange 误标 0:so，
  //         导致 so 词条出现 "Why soes..." 假例句；so 的正常拓展不存在（副词/连词）。
  //   spotcheck：ecdict 将 spotcheck（名词/动词）误挂 0:spot。
  //   some：ecdict 将 some 误标 0:an（冠词脏映射，语料 freq≈1840）；an 本身是课标词，
  //         若 an 词条先命中会错误归并 some 及其频次，故剔除。
  //   's/'m/'ve/'em 等撇号缩写（be/have/they 的缩约形）不属于词形拓展。
  //   全量检查结论：其余语料中出现的 0:base 变体（abandoning/bought/bigger 等
  //   均为正常屈折（ing/ed/er/es 等）或已被停用词集排除（they→it、could 等），
  //   仅词性标注有误，予以保留。
  for (final w in [
    'soes', 'spotcheck', 'some', "'s", "'m", "'ve", "'em", 'p.m.s', 'mrss', 'mse',
  ]) {
    extBaseMap.remove(w);
  }
  // 缩略/机构/地名类脏拓展词剔除（用户口径：释义为缩略词/机构/地名类的脏拓展词
  // 一律不进入词表，已归并拓展词不再单独计入统计）：
  //   nots：用户词库 extendBaseMap 含 nots→not 脏映射；ecdict 释义为
  //         "Naval Ordnance Test Station <美国>海军军械实验站" 等纯机构/地名，
  //         非 not 的正常屈折（not 为副词无复数/三单），not 词条不得出现 nots。
  //   eco：词库映射 eco→economic，ecdict 释义全为 abbr 机构名（Electron-Coupled
  //         Oscillator / Environmental Control Organization 等），非 economic 的
  //         正常屈折（economic→economically），属缩略类脏数据。
  //   isn/wasn：词库映射 isn→be / wasn→be，释义全为 abbr 机构名（信息系统网络 /
  //         无线感测网路研讨会），是 isn't/wasn't 去撇号的缩约形而非 be 的屈折；
  //         base be 虽在停用词集已整体剔除，此处仍显式剔除并记录，双保险。
  //   tue/mon/tues/thu/fri/nov/oct/sept/wed：星期/月份等纯缩略词（词库缩略映射
  //         Tue→Tuesday/Fri→Friday/Nov→November 等）。ecdict 首义项均为
  //         "abbr. 星期二（Tuesday）" 类缩写标注，例句却来自 Tuesday 原词句
  //         （"Tuesdays and Fridays..."），缩略形并未在真题出现，属词库脏映射
  //         而非正常屈折（Tuesday 本身是课标词，独立计频不受影响）。
  //         合理月份缩写 Aug→August 保留：释义即 August 本身，非脏数据（用户未质疑）。
  //   全量扫描结论：其余 abbr 首义项词（acts/adds/ages/asks/bets/cars/cats/dams/
  //   ears/eats/gets/hats/helps/ideas/lets/maps/scans/sees/sofas/topics/uses/wins
  //   等）均为 base 的正常复数/三单屈折，真题中以正常词义出现，予以保留。
  final cleanedExtWords = <String>[];
  for (final w in [
    'nots', 'eco', 'isn', 'wasn',
    // 星期/月份缩写（fri/sept/oct/nov 等）不再按固定排除集剔除：
    // 它们是课标词的正常拓展形式，检测页也计入词根频次。
  ]) {
    if (extBaseMap.remove(w) != null) cleanedExtWords.add(w);
  }
  // 保险：凡含非小写字母字符（撇号/点号等）的变体一律不当作词形拓展
  extBaseMap.removeWhere((k, _) => !RegExp(r'^[a-z]+$').hasMatch(k));

  // 5.0) 固定的星期/月份/序数词、人称/物主代词、情态/助动词排除集已移除：
  //    这些词本身就在 3333 课标词表内，必须参与高频统计与展示。
  //    课标词表的 62 条短语（如 according to）已在词频阶段按整条计数，
  //    不再拆成单词。

  // 5) 词族归并：
  //    - 课标词出现 → 以其自身为词条（freq 含全部归并拓展词）
  //    - 课标词未出现、仅拓展词出现 → 仍以课标原词为词条，频次为全部
  //      拓展词之和（派生/变形形式一并计入该词的统计）
  //    - 表外词（超标词）与专有词仍按原口径排除
  final familyFreq = <String, int>{}; // 展示词 -> 总频
  final baseFreqRaw = <String, int>{}; // 课标原词本身的原始频次
  final extGroup = <String, List<String>>{}; // 课标原词 -> 归并过来的拓展词
  final extFreq = <String, int>{}; // 拓展词自身频次

  for (final w in freq.keys) {
    final f = freq[w]!;
    final r = familyRoot(w, spellingAliases, extBaseMap);
    // 课标词（含短语）一律保留：即使同时是专有名词（China/Monday/Mr/OK）、
    // 人称代词、情态/助动词或序数词，也必须参与统计。
    // 专有词启发式（properSet / nhCapsExcluded）仅对表外词生效，表外词
    // 由下方 stdSet 判定统一排除。
    if (!stdSet.contains(r) &&
        (properSet.contains(r) || nhCapsExcluded.contains(r))) {
      continue;
    }
    if (!stdSet.contains(r)) continue; // 表外词（超标/专有）→ 排除
    // 被短语完全覆盖的首词（according）已由短语条目代表；它的其他派生形
    // （如 accordingly 映射到 according）也不再单独成条，避免页面搜 according
    // 显示短语频次、导出却另有一条 according 的小数字。
    if (mergedPhraseHeads.contains(r) && w != r) continue;
    // 与检测页同一口径：按 familyRoot 汇总，practise/colour/TV 都归入原词
    familyFreq[r] = (familyFreq[r] ?? 0) + f;
    if (w == r) {
      baseFreqRaw[r] = (baseFreqRaw[r] ?? 0) + f;
    } else {
      (extGroup[r] ??= []).add(w);
      extFreq[w] = f;
    }
  }

  // 英美拼写/TV 等别名归并后，原始词形（programme/colour/tv 等）不再独立
  // 成条，但必须作为词根成员跟在词根后展示（频次不重复计入）。
  for (final e in rawFreq.entries) {
    final raw = e.key;
    if (!familyFreq.containsKey(familyRoot(raw, spellingAliases, extBaseMap))) {
      continue;
    }
    final base = familyRoot(raw, spellingAliases, extBaseMap);
    if (raw == base) continue;
    if (mergedPhraseHeads.contains(base)) continue;
    final members = extGroup[base] ??= <String>[];
    if (!members.contains(raw)) {
      members.add(raw);
      extFreq[raw] = e.value;
    }
  }

  // 课标短语例句：按整条短语在切句结果里匹配（与单词语料统计同一批句子）
  final phraseExamples =
      <String, List<({String text, int year, String source})>>{};
  for (final phrase in stdPhrases.keys) {
    if (!freq.containsKey(phrase)) continue;
    final re = phraseRegExp(phrase);
    final hits = <({String text, int year, String source})>[];
    for (var i = 0; i < sentences.length; i++) {
      if (re.hasMatch(sentences[i])) {
        hits.add((
          text: sentences[i],
          year: sentYears[i],
          source: sentSources[i],
        ));
      }
    }
    hits.sort((a, b) => b.year.compareTo(a.year));
    final picked = <({String text, int year, String source})>[];
    final years = <int>{};
    for (final h in hits) {
      if (picked.length >= 2) break;
      if (!years.add(h.year)) continue;
      picked.add(h);
    }
    phraseExamples[phrase] = picked;
  }

  // 展示词形：保留课标库原始大小写；弯撇号统一为直撇号（o’clock → o'clock）。
  // 大小写异义词组（March/march 等）按新口径统一用小写形作词条名，
  // 大写形作为成员跟在后面（见下方 members 追加）。
  bool properDominant(String key) =>
      (properCapitalFreq[key] ?? 0) * 2 > (freq[key] ?? 0);

  String displayWord(String key) {
    if (caseVariantGroups.containsKey(key)) {
      return key.replaceAll('\u2019', "'");
    }
    // 同名专有词：语料里专有写法占多数就用专有词条名，否则保留普通词条名。
    final properForm = properSpellings[key];
    if (properForm != null) {
      return (properDominant(key) ? properForm : key)
          .replaceAll('\u2019', "'");
    }
    final orig = lowerToOrig[key] ?? key;
    return orig.replaceAll('\u2019', "'");
  }

  /// 词条类型：专有写法主导的同名专有词按「专有词」展示，其余取词库类型。
  String wordCategory(String key) {
    final properForm = properSpellings[key];
    if (properForm != null && properDominant(key)) return '专有词';
    return stdCategory[key] ?? '';
  }

  // 「全部课标词」模式：语料中未出现的课标词条以频次 0 补入，
  // 在下方统一建词条（无例句/无成员）。
  if (allStdWords) {
    for (final v in stdSet) {
      if (v.contains(' ')) continue; // 短语按整条处理，不拆成单词词条
      if (v.endsWith('.')) continue; // a.m. 等缩写变体，保留无点形式
      final r = familyRoot(v, spellingAliases, extBaseMap);
      if (!stdSet.contains(r)) continue;
      if (mergedPhraseHeads.contains(r)) continue;
      if (familyFreq.containsKey(r)) continue;
      familyFreq[r] = 0;
    }
  }

  // 汇总：把拓展词频次并入原词；原词未出现时拓展词单独成词条
  final finalEntries = <_WordEntry>[];
  for (final base in familyFreq.keys) {
    // 归并成员跟在词根词后展示：按各自频次降序，频次相同按字母序
    final members = <String>[...?extGroup[base]]
      ..sort((a, b) {
        final c = (extFreq[b] ?? 0).compareTo(extFreq[a] ?? 0);
        return c != 0 ? c : a.compareTo(b);
      });
    // familyFreq 已按 familyRoot 汇总（含成员），这里不再重复相加
    final total = familyFreq[base]!;
    final baseDict = _lookupCached(db, base);
    final baseExamples = phraseExamples[base] ??
        pickExamples(base, sentences, sentTokens, sentIndex, freq, stdSet,
            sentYears, _multiSense(baseDict) ? 4 : 2,
            altWords: members, sentSources: sentSources);
    // 词条例句已占用的年份：成员例句避开，保证同词条年份不重复
    final usedYears = {for (final e in baseExamples) e.year};
    finalEntries.add(_WordEntry(
      word: displayWord(base),
      freq: total,
      isStd: true,
      category: wordCategory(base),
      dict: baseDict,
      examples: baseExamples,
      members: [
        for (final m in members)
          (
            word: displayWord(m),
            dict: _lookupCached(db, m),
            freq: extFreq[m] ?? 0,
            examples: pickExamples(m, sentences, sentTokens, sentIndex, freq,
                stdSet, sentYears, 1,
                excludeYears: usedYears),
          ),
        // 大小写异义词的大写形：只展示、不重复计入频次；
        // 例句不选（语料倒排索引按折叠小写建键，无法区分大小写义项）。
        for (final v in caseVariantGroups[base] ?? const <String>[])
          (
            word: v,
            dict: _lookupCached(db, v),
            freq: caseVariantFreq[base] ?? 0,
            examples: const <({String text, int year, String source})>[],
          ),
      ],
    ));
  }
  // 原词未出现、仅拓展词出现 → 仍以课标原词为词条，频次为全部拓展词之和
  final orphanGroups = <String, List<String>>{};
  for (final e in extGroup.entries) {
    final base = e.key;
    if (familyFreq.containsKey(base)) continue; // 原词已出现，已归并
    var sum = 0;
    for (final m in e.value) {
      sum += extFreq[m] ?? 0;
    }
    e.value.sort((a, b) => (extFreq[b] ?? 0).compareTo(extFreq[a] ?? 0));
    orphanGroups[base] = e.value;
    familyFreq[base] = sum;
  }
  for (final e in orphanGroups.entries) {
    final base = e.key;
    final members = e.value;
    final dict = _lookupCached(db, base);
    final examples = pickExamples(base, sentences, sentTokens, sentIndex, freq,
        stdSet, sentYears, _multiSense(dict) ? 4 : 2,
        altWords: members, sentSources: sentSources);
    final usedYears = {for (final ex in examples) ex.year};
    finalEntries.add(_WordEntry(
      word: displayWord(base),
      // 词条本身就是课标原词，无需再标「对应课标原词」
      baseStd: null,
      freq: familyFreq[base]!,
      isStd: true,
      category: wordCategory(base),
      dict: dict,
      examples: examples,
      members: [
        for (final m in members)
          (
            word: displayWord(m),
            dict: _lookupCached(db, m),
            freq: extFreq[m] ?? 0,
            examples: pickExamples(m, sentences, sentTokens, sentIndex, freq,
                stdSet, sentYears, 1,
                excludeYears: usedYears, sentSources: sentSources),
          ),
        for (final v in caseVariantGroups[base] ?? const <String>[])
          (
            word: v,
            dict: _lookupCached(db, v),
            freq: caseVariantFreq[base] ?? 0,
            examples: const <({String text, int year, String source})>[],
          ),
      ],
    ));
  }

  db.dispose();

  // 6) 排序取前 N（用户选择的 1000 / 2000 / 3000），按频率区间分组
  //    「全部课标词」模式：取全部词条（含频次 0），不做截断
  final entries = finalEntries.toList()
    ..sort((a, b) {
      final c = b.freq.compareTo(a.freq);
      if (c != 0) return c;
      return a.word.toLowerCase().compareTo(b.word.toLowerCase());
    });
  final top = allStdWords ? entries : entries.take(wordLimit).toList();

  final groups = <String, List<_WordEntry>>{};
  final groupOrder = <String>[];
  for (final e in top) {
    final gName = _groupName(e.freq);
    if (!groups.containsKey(gName)) {
      groups[gName] = [];
      groupOrder.add(gName);
    }
    groups[gName]!.add(e);
  }

  // 7) 生成目标格式文件（docx / xlsx）
  // 教材语料：频次列与文档标题、说明行统一改为教材口径（教材频次 /
  // 教材高频词表 / 例句标注教材版本），避免出现「真题」字样造成口径混淆。
  final totalTokens = freq.values.fold<int>(0, (a, b) => a + b);
  final isDocx = format == 'docx';
  final freqLabel = textbookCorpus ? '教材频次' : '真题频次';
  final docTitle = textbookCorpus ? '教材高频词表' : '高考高频词表';
  final subtitle = textbookCorpus
      ? '共 ${top.length} 个高频词 · 教材 ${files.length} 册 · 总词次 $totalTokens · '
          '例句标注教材版本，一般词 2 条、多义项 4 条'
      : null;
  final xlsxBytes = isDocx
      ? null
      : _buildXlsx(
          top,
          corpusFileCount: files.length,
          totalTokens: totalTokens,
          sheetName: docTitle,
          freqLabel: freqLabel,
        );
  final docxBytes = isDocx
      ? _buildDocx(
          top,
          corpusFileCount: files.length,
          totalTokens: totalTokens,
          title: docTitle,
          subtitle: subtitle,
          freqLabel: freqLabel,
        )
      : null;

  return {
    'format': isDocx ? 'docx' : 'xlsx',
    'xlsxBytes': xlsxBytes ?? Uint8List(0),
    'docxBytes': docxBytes,
    'corpusFileCount': files.length,
    'totalTokens': totalTokens,
    'exportedWords': top.length,
    'groupSummary': groupOrder.map((g) => '$g: ${groups[g]!.length}个').toList(),
    'cleanedExtWords': cleanedExtWords,
    'nonHeadCapsExcluded': nonHeadCapsExcluded,
    // 星期/月份/序数词不再剔除（均在课标词表内），保留字段兼容旧调用方
    'calendarOrdinalExcluded': const <String>[],
  };
}

// ----------------------------- xlsx 生成（excel 包） -----------------------------

/// 释义清理：去除形如 [v:43/n:57] 的词性频率残留标记。
String _cleanDefinition(String def) => def.replaceAll(_freqTagRe, '').trim();

/// 专业领域释义剔除：删除形如 "[计] 要点"、"［经管］ …" 的领域前缀标记及其后的
/// 专业释义内容（标签与内容同行连续，如 "[计] 关闭, 清屏命令"、"［机］ 重要, 重要性"）。
/// 仅保留基本释义（词性 + 中文释义），如 important 的 "[计] 要点" 整段删除。
/// 实现：只删除以中文开头的方括号标签（专业领域标记）及其后至行尾/分号的专业内容；
/// 英文标签如 "[the blue(s)]"（布鲁斯歌曲）等不属于领域标记，予以保留。
final RegExp _domainTagRe =
    RegExp(r'[\[［]([\u4e00-\u9fa5][^\]］]*)[\]］][^\n；;]*');

/// 剔除专业领域释义标记（含其后专业内容），并清理由此产生的孤立分隔符。
String _stripDomainDef(String def) {
  final cleaned = def.replaceAll(_domainTagRe, '');
  // 清理残留分隔：";[标签]"→"；"、"[标签]"→""；压缩连续分号；去行尾分号
  return cleaned
      .replaceAll(RegExp(r'\s*[；;]\s*'), '；')
      .replaceAll(RegExp(r'[；;]{2,}'), '；')
      .replaceAll(RegExp(r'[；;]\s*$'), '')
      .trim();
}

/// definition 内嵌词性标签清理：ecdict 的 definition 常自带词性前缀
/// （如 "art. 那"、"art. [计] ..."、"prep. 在...期间, ..."），而词性已由
/// pos 字段经 _cleanPos 单独展示，内嵌标签只会造成 "adj. art. 那"、
/// "art. art. 一" 类重复。这里删除行首 / 分号后的英文词性标签本身，
/// 保留其后中文释义内容；\r 换行统一折叠为换行。
final RegExp _embeddedPosRe = RegExp(
    r'(?:^|[\r\n；;])\s*(?:(?:vi|vt|adj|adv|pron|prep|num|conj|interj|aux|abbr|pl|art)\.?|[nvajmuds]\.)\s*');

/// 从 definition 内嵌词性标签提取词性列表（准确性优于 pos 频率代码猜测）：
/// ecdict 的 definition 每个义项前自带词性（"pron. 一些, ...\nadv. 大约\n..."），
/// 直接提取可得到准确词性（如 some→pron./adv./adj.、so→adv./conj./pron.）。
/// 返回标准词性标签（如 "pron./adv./adj."）；无内嵌词性时返回空串，
/// 由调用方回退到 _cleanPos（pos 频率代码）。
String _posFromDef(String def) {
  final buf = StringBuffer();
  final seen = <String>{};
  for (final m in _embeddedPosRe.allMatches(def)) {
    final g = m.group(0)!;
    final code = RegExp(r'[a-z]+').firstMatch(g)!.group(0)!;
    final map = <String, String>{
      'n': 'n.', 'v': 'v.', 'vi': 'vi.', 'vt': 'vt.', 'adj': 'adj.',
      'a': 'a.', 'j': 'adj.', 'adv': 'adv.', 'ad': 'adv.', 'pron': 'pron.',
      'prep': 'prep.', 'num': 'num.', 'm': 'num.', 'art': 'art.',
      'conj': 'conj.', 'interj': 'interj.', 'aux': 'aux.', 'abbr': 'abbr.',
      'u': 'u.', 'pl': 'pl.', 's': 's.',
    };
    final tag = map[code];
    if (tag == null || seen.contains(tag)) continue;
    seen.add(tag);
    if (buf.isNotEmpty) buf.write('/');
    buf.write(tag);
  }
  return buf.toString();
}

String _cleanEmbeddedPos(String def) {
  final folded = def.replaceAll('\r', '\n');
  final removed = folded.replaceAll(_embeddedPosRe, '\n');
  return removed
      .replaceAll(RegExp(r'\n{2,}'), '\n')
      .replaceAll(RegExp(r'^[\n；;,\s]+'), '')
      .replaceAll(RegExp(r'[\n；;,\s]+$'), '')
      .trim();
}

/// 释义中被截断/缺字母的单词名修复（防御性兜底）：
/// 词典数据偶发 "ake的过去式和过去分词"（应为 "make的过去式和过去分词"）
/// 类残缺——变形词释义尾注的过去式/过去分词说明中，原形名被截掉首字母。
/// 这里将 "[截断名]的过去式/过去分词" 修复为正确的原形名（取词条名与原形候选
/// 中长度更长且以截断名结尾的那个，如 ake→make / ll→will 等）。
/// 同时兜底历史 bug：旧版 _embeddedPosRe 会把 "see的过去分词" 行首的无点单
/// 字母 s 误当词性删除成 "ee的过去分词"，此处同样修复 ee→see。
String _fixTruncatedDefWord(String def, String word, String base) {
  if (!def.contains('的过去式') && !def.contains('的过去分词')) return def;
  final candidates = <String>{word.toLowerCase(), base.toLowerCase()};
  return def.replaceAllMapped(
      RegExp(r'([a-z]+)(?=的过去式(?:和过去分词)?|的过去分词)'), (m) {
    final truncated = m.group(1)!;
    for (final c in candidates) {
      // 候选名与截断名仅差首字母（截断名是候选名的后缀），且长度差为 1
      if (c.length == truncated.length + 1 &&
          c.endsWith(truncated) &&
          c != truncated) {
        return c;
      }
      // 尾字母 e 多余：截断名 = 候选名 + 'e'（词典偶发 appear→appeare、
      // prohibit→prohibite 类错拼原形），修复为候选原形名。
      if (truncated.length == c.length + 1 &&
          truncated.endsWith('e') &&
          truncated.startsWith(c) &&
          c != truncated) {
        return c;
      }
    }
    return truncated;
  });
}

/// 剔除 XML 非法控制字符（0x00-0x08、0x0B、0x0C、0x0E-0x1F 等）。
/// 真题语料残留的 US 控制符（如 approach\x1Fand\x1Fconfront）若不清理，
/// 会生成非法 XML 字符，导致 Excel/WPS/Word 拒绝打开（xlsx 与 docx 共用）。
String _sanitizeText(String s) {
  final buf = StringBuffer();
  for (final rune in s.runes) {
    if (rune == 0x9 || rune == 0xA || rune == 0xD ||
        (rune >= 0x20 && rune <= 0xD7FF) ||
        (rune >= 0xE000 && rune <= 0xFFFD) ||
        (rune >= 0x10000 && rune <= 0x10FFFF)) {
      buf.writeCharCode(rune);
    }
  }
  return buf.toString();
}

/// XML 文本转义（docx 正文用）。
String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 例句前缀标签：真题按年份（2022），教材按版本·册次（人教版 必修一），
/// 两者都取不到时退回「年份未知」。
String _exampleTag(int year, String source) {
  if (year > 0) return '（$year）';
  final s = source.trim();
  return s.isEmpty ? '（年份未知）' : '（$s）';
}

/// 构造行数据（xlsx / docx / txt 三格式共用，保证列与内容完全一致）。
///
/// [showFreq] true = 高频统计（序号/单词/类型/频次/音标/词性/释义/例句1~4/
/// 拓展词列表/拓展词例句，13 列）；false = 词库导出（序号/单词/类型/音标/
/// 词性/释义[+对应课标原词]，与高频统计同名列同宽，不另立版式）。
List<List<String>> _buildTableRows(
  List<_WordEntry> entries, {
  bool showFreq = true,
  bool showBaseStd = false,
}) {
  final rows = <List<String>>[];
  var idx = 0;
  for (final e in entries) {
    idx++;
    final dict = e.dict;
    final defRaw = dict == null
        ? ''
        : _stripDomainDef(_cleanDefinition(dict['definition'] ?? ''));
    final def = dict == null
        ? ''
        : _fixTruncatedDefWord(
            _cleanEmbeddedPos(defRaw), e.word, e.baseStd ?? e.word);
    final posFromDef = dict == null ? '' : _posFromDef(defRaw);
    final pos = dict == null
        ? ''
        : (posFromDef.isNotEmpty
            ? posFromDef
            : _cleanPos(dict['pos'] ?? ''));
    final ph = dict?['phonetic'] ?? '';
    // 类型列：优先用词条自身分类（初中/必修/选修/拓展词/超标词/专有词），
    // 缺失时回退"课标词"（课标词）或"拓展词"（非课标孤儿词）。
    final type = (e.category != null && e.category!.isNotEmpty)
        ? e.category!
        : (e.isStd ? '课标词' : '拓展词');

    // 词库导出：无真题语料，不出真题频次与例句列，仅保留词条基础信息列
    if (!showFreq) {
      rows.add(<String>[
        '$idx',
        e.word,
        type,
        ph,
        pos,
        def,
        if (showBaseStd) (e.baseStd ?? ''),
      ]);
      continue;
    }
    // 例句列：最多 4 条，标注年份 / 教材版本
    final exCols = <String>[
      for (var i = 0; i < 4; i++)
        i < e.examples.length
            ? '${_exampleTag(e.examples[i].year, e.examples[i].source)}${e.examples[i].text}'
            : '',
    ];
    // 拓展词列表：said(1122), says(480)；无拓展词则留空
    final extList = e.members.map((m) => '${m.word}(${m.freq})').join(', ');
    // 拓展词例句：said(1122): 例句；says(480): 例句；无例句则仅留词形占位
    final extExamples = e.members.map((m) {
      final head = '${m.word}(${m.freq})';
      if (m.examples.isEmpty) return '$head: ';
      final ex = m.examples.first;
      return '$head: ${_exampleTag(ex.year, ex.source)}${ex.text}';
    }).join('；');

    rows.add([
      '$idx',
      e.word,
      type,
      '${e.freq}',
      ph,
      pos,
      def,
      exCols[0],
      exCols[1],
      exCols[2],
      exCols[3],
      extList,
      extExamples,
    ]);
  }
  return rows;
}

/// 生成 Word(docx) 版本：恢复旧版"直接列举单词和例句"排版（不用表格）。
/// 词条行：序号. 词（初中/必修/选修）真题频次：N /音标/；释义另起一行；
/// 例句标注年份、按年份倒序（优先最近年份），一般词 2 条、多义项 4 条；
/// 有拓展词时"拓展词："独立一行、每个拓展词独立一行（word(频次): 例句）。
/// Excel(xlsx) / TXT 与本文档共用 [_buildTableRows]，列与内容完全一致。
///
/// 词库导出（[showFreq] = false）复用本函数：同一标题排版、同一字号字重、
/// 同一页边距与说明行结构，仅词条行去掉真题频次/例句、数据换成词库内容。
/// 词库 Word 不套用七类字色/加粗规范（[styleEntries] = false），正文统一常规黑色；
/// 七类字色只用于检测文档（原文标注）导出。
/// 结构与工程现有 _writeResultDocx 同模式：Content_Types + _rels + document。
Uint8List _buildDocx(
  List<_WordEntry> entries, {
  int corpusFileCount = 0,
  int totalTokens = 0,
  String title = '高考高频词表',
  String? subtitle,
  bool showFreq = true,
  bool showBaseStd = false,
  bool styleEntries = true,
  /// 频次标签：真题语料为「真题频次」，教材语料为「教材频次」。
  String freqLabel = '真题频次',
}) {

  // 段落 helper：词条行加粗，普通行常规字号；blank 用于词条间空行。
  // colorHex 取七类规范色（[kExportWordStyles]）：Word 不加底纹，只写字色。
  String para(String text,
      {bool bold = false, bool blank = false, String? colorHex}) {
    final color =
        (colorHex == null || colorHex.isEmpty) ? '' : '<w:color w:val="$colorHex"/>';
    final rpr = bold
        ? '<w:rPr><w:b/>$color<w:sz w:val="22"/></w:rPr>'
        : '<w:rPr>$color<w:sz w:val="20"/></w:rPr>';
    return '<w:p><w:pPr><w:spacing w:before="${blank ? 120 : 40}" w:after="40"/></w:pPr>'
        '<w:r>$rpr<w:t xml:space="preserve">${_xmlEscape(_sanitizeText(text))}</w:t></w:r>'
        '</w:p>';
  }

  // 直接列举排版：逐词输出词条行/释义行/例句行/拓展词行。
  final bodyText = StringBuffer();
  var idx = 0;
  for (final e in entries) {
    idx++;
    final dict = e.dict;
    final defRaw = dict == null
        ? ''
        : _stripDomainDef(_cleanDefinition(dict['definition'] ?? ''));
    final def = dict == null
        ? ''
        : _fixTruncatedDefWord(
            _cleanEmbeddedPos(defRaw), e.word, e.baseStd ?? e.word);
    final posFromDef = dict == null ? '' : _posFromDef(defRaw);
    final pos = dict == null
        ? ''
        : (posFromDef.isNotEmpty
            ? posFromDef
            : _cleanPos(dict['pos'] ?? ''));
    final ph = dict?['phonetic'] ?? '';
    final type = (e.category != null && e.category!.isNotEmpty)
        ? e.category!
        : (e.isStd ? '课标词' : '拓展词');

    // 词条行：序号. 词（类别）真题频次：N /音标/
    // 字色/字重严格取七类规范（与导出标注同一张表 kExportWordStyles），
    // 未命中规范七类的词条不加色（spec 为空即黑白原样）。
    // styleEntries = false（词库导出）时整行强制常规字重 + 不写 <w:color>，
    // 即正文统一常规黑色：七类规范只服务检测文档导出。
    final spec = styleEntries ? exportWordStyleOf(_entryExportCategory(e)) : null;
    final colorHex = styleEntries ? spec?.colorHex : null;
    final bold = styleEntries ? (spec?.bold ?? true) : false;
    final headBuf = StringBuffer('$idx. ${e.word}');
    if (type.isNotEmpty) headBuf.write('（$type）');
    if (showFreq) headBuf.write('$freqLabel：${e.freq}');
    if (ph.isNotEmpty) headBuf.write(' /$ph/');
    bodyText.write(para(headBuf.toString(), bold: bold, colorHex: colorHex));

    // 释义行：另起一行
    if (def.isNotEmpty) {
      bodyText.write(para('释义：${pos.isNotEmpty ? '$pos ' : ''}$def'));
    }

    // 拓展词库：标注该拓展词归属的课标原词（真实取自 extendBaseMap）
    if (showBaseStd && (e.baseStd ?? '').isNotEmpty) {
      bodyText.write(para('对应课标原词：${e.baseStd}'));
    }

    // 例句行：标注年份 / 教材版本，一般词 2 条、多义项 4 条
    final examples = [...e.examples]..sort((a, b) => b.year.compareTo(a.year));
    for (var i = 0; i < examples.length; i++) {
      final ex = examples[i];
      bodyText.write(
          para('例句${i + 1}${_exampleTag(ex.year, ex.source)}：${ex.text}'));
    }

    // 拓展词：标题独立一行，每个拓展词独立一行（word(频次): 例句；无例句仅 word(频次):）。
    // 多个拓展词按行分隔，不再用逗号/分号挤在同一行。
    if (e.members.isNotEmpty) {
      bodyText.write(para('拓展词：'));
      for (final m in e.members) {
        final head = '${m.word}(${m.freq})';
        if (m.examples.isEmpty) {
          bodyText.write(para('$head:'));
        } else {
          final ex = m.examples.first;
          bodyText.write(
              para('$head: ${_exampleTag(ex.year, ex.source)}${ex.text}'));
        }
      }
    }

    // 词条之间空一行
    bodyText.write(para('', blank: true));
  }

  final subLine = subtitle ??
      '共 ${entries.length} 个高频词 · 语料 $corpusFileCount 篇 · 总词次 $totalTokens · 例句优先最近年份，一般词 2 条、多义项 4 条';
  final documentXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>'
      '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
      '<w:r><w:rPr><w:b/><w:sz w:val="36"/></w:rPr>'
      '<w:t>${_xmlEscape(title)}</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
      '<w:r><w:rPr><w:sz w:val="20"/></w:rPr>'
      '<w:t>${_xmlEscape(subLine)}</w:t></w:r></w:p>'
      '<w:p/>'
      '${bodyText.toString()}'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>'
      '</w:body></w:document>';

  final contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';

  final rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';

  final archive = Archive();
  archive.addFile(ArchiveFile(
      '[Content_Types].xml', utf8.encode(contentTypes).length, utf8.encode(contentTypes)));
  archive.addFile(ArchiveFile(
      '_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)));
  archive.addFile(ArchiveFile(
      'word/document.xml', utf8.encode(documentXml).length, utf8.encode(documentXml)));
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw Exception('docx 生成失败');
  return Uint8List.fromList(encoded);
}

/// Excel(xlsx) 版：与「导出高频」同一套表格版式（同表头字号、同列宽、
/// 同七类字色），词库导出只是数据来源不同，不另起一套表结构。
Uint8List _buildXlsx(
  List<_WordEntry> entries, {
  int corpusFileCount = 0,
  int totalTokens = 0,
  String sheetName = '高考高频词表',
  bool showFreq = true,
  bool showBaseStd = false,
  /// 频次列名：真题语料为「真题频次」，教材语料为「教材频次」。
  String freqLabel = '真题频次',
}) {
  final excel = Excel.createExcel();
  excel.rename('Sheet1', sheetName);
  final sheet = excel[sheetName];

  TextCellValue tv(String v) => TextCellValue(_sanitizeText(v));

  final headers = <String>[
    '序号', '单词', '类型',
    if (showFreq) freqLabel,
    '音标', '词性', '释义',
    if (showFreq) ...['例句1', '例句2', '例句3', '例句4'],
    if (showBaseStd) '对应课标原词',
    if (showFreq) ...['拓展词列表', '拓展词例句'],
  ];
  final widths = <double>[
    6, 16, 8,
    if (showFreq) 10,
    16, 10, 40,
    if (showFreq) ...[36, 36, 36, 36],
    if (showBaseStd) 16,
    if (showFreq) ...[26, 60],
  ];
  // 表头：与全站导出同款（加粗、居中、浅灰底），列名与列宽沿用高频统计
  final headerStyle = CellStyle(
    bold: true,
    horizontalAlign: HorizontalAlign.Center,
    backgroundColorHex: ExcelColor.fromHexString('FFF2F2F2'),
  );
  final headerRow = sheet.maxRows; // 表头写入前的行索引（空表为 0）
  sheet.appendRow(headers.map((h) => TextCellValue(h)).toList());
  for (var i = 0; i < headers.length; i++) {
    sheet
        .cell(CellIndex.indexByColumnRow(
            columnIndex: i, rowIndex: headerRow))
        .cellStyle = headerStyle;
  }

  final rows = _buildTableRows(entries,
      showFreq: showFreq, showBaseStd: showBaseStd);
  for (final row in rows) {
    sheet.appendRow(row.map(tv).toList());
  }

  // 列宽（按列内容语义设定，便于筛选统计）
  for (var i = 0; i < widths.length; i++) {
    sheet.setColumnWidth(i, widths[i]);
  }

  final bytes = excel.save();
  if (bytes == null) throw Exception('xlsx 生成失败：excel.save() 返回空');
  final fixed = _fixSheetDimension(
      Uint8List.fromList(bytes), entries.length + 1, headers.length);
  return fixed;
}

/// TXT 版：与 docx/xlsx 同列同内容（Tab 分隔，UTF-8 BOM 便于 Excel 直接打开）。
Uint8List _buildTxt(
  List<_WordEntry> entries, {
  required String title,
  required String subtitle,
  bool showFreq = true,
  bool showBaseStd = false,
  String freqLabel = '真题频次',
}) {
  final headers = <String>[
    '序号', '单词', '类型',
    if (showFreq) freqLabel,
    '音标', '词性', '释义',
    if (showFreq) ...['例句1', '例句2', '例句3', '例句4'],
    if (showBaseStd) '对应课标原词',
    if (showFreq) ...['拓展词列表', '拓展词例句'],
  ];
  final buf = StringBuffer()
    ..writeln(title)
    ..writeln(subtitle)
    ..writeln(headers.join('\t'));
  for (final row in _buildTableRows(entries,
      showFreq: showFreq, showBaseStd: showBaseStd)) {
    buf.writeln(row.map((c) => c.replaceAll(RegExp(r'[\t\r\n]'), ' ')).join('\t'));
  }
  final body = utf8.encode(buf.toString());
  return Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...body]);
}

/// 词条 → 七类导出分类（docx/xlsx 着色与「导出高频」同一口径）。
///
/// 词库导出时 category 已是规范七类之一（见 [kWordBankKinds]）；此处兼容
/// 高频统计返回的「初中/必修/选修」等旧式级别名，保证同一张规范表取色。
String _entryExportCategory(_WordEntry e) {
  final c = (e.category ?? '').trim();
  if (c.isEmpty) {
    return e.isStd ? ExportCategory.standardJunior : ExportCategory.extend;
  }
  if (kExportWordStyles.containsKey(c)) return c;
  if (c.contains('初中')) return ExportCategory.standardJunior;
  if (c.contains('必修')) return ExportCategory.standardCompulsory;
  if (c.contains('选修')) return ExportCategory.standardElective;
  if (c.contains('拓展')) return ExportCategory.extend;
  if (c.contains('超标')) return ExportCategory.overLimit;
  if (c.contains('专有')) return ExportCategory.proper;
  return ExportCategory.unfiltered;
}

/// excel 包 4.0.6 保存时不更新工作表 `<dimension ref="A1"/>`（恒为 A1），
/// 依赖 dimension 的解析器（openpyxl 等）会误认为工作表仅 1 个单元格。
/// 重写 sheet1.xml 的 dimension 为实际行数×列数（如 A1:M3001）。
Uint8List _fixSheetDimension(Uint8List bytes, int rowCount, int colCount) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final rebuilt = Archive();
  var patched = false;
  for (final f in archive.files) {
    if (f.name != 'xl/worksheets/sheet1.xml') {
      rebuilt.addFile(f);
      continue;
    }
    final content = f.content;
    if (content is! List<int>) {
      rebuilt.addFile(f);
      continue;
    }
    final xml = utf8.decode(content, allowMalformed: true);
    final fixed = xml.replaceFirst(
        '<dimension ref="A1"/>',
        '<dimension ref="A1:${_colLetter(colCount)}$rowCount"/>');
    rebuilt.addFile(ArchiveFile(f.name, fixed.length, utf8.encode(fixed)));
    patched = true;
  }
  if (!patched) return bytes;
  final encoded = ZipEncoder().encode(rebuilt);
  if (encoded == null) return bytes;
  return Uint8List.fromList(encoded);
}

/// 列索引转 Excel 列字母（1->A, 13->M, 27->AA）。
String _colLetter(int col) {
  var c = col;
  var s = '';
  while (c > 0) {
    final rem = (c - 1) % 26;
    s = String.fromCharCode(0x41 + rem) + s;
    c = (c - 1) ~/ 26;
  }
  return s;
}

/// 检测系统真实桌面目录：优先 Windows Known Folder API（通过 PowerShell），
/// 回退到 USERPROFILE\\Desktop；均失败时回退用户主目录。
Future<String> systemDesktopPath() async {
  try {
    final res = await Process.run(
      'powershell',
      ['-NoProfile', '-Command', "[Environment]::GetFolderPath('Desktop')"],
    );
    if (res.exitCode == 0) {
      final path = (res.stdout as String).trim();
      if (path.isNotEmpty && Directory(path).existsSync()) return path;
    }
  } catch (_) {
    // 忽略，走回退逻辑
  }
  final profile = Platform.environment['USERPROFILE'] ?? '';
  if (profile.isNotEmpty) {
    final d = p.join(profile, 'Desktop');
    if (Directory(d).existsSync()) return d;
  }
  return profile;
}
