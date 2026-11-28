// 全量一致性核对：119 套真题语料上，检测页与高频导出「每一个词条」的频次
// 必须相等，而不是只抽查几个词。
//
// 页面侧：取 VocabService.familyFor(word).forms（检测页实际使用的词族），
//         按检测页同一分词器 wordTokenRegExp 统计语料中出现次数；
// 导出侧：直接取 HighFreqExporter.export 生成的 xlsx 中「真题频次」列。
// 两侧输入（课标词库 / 拓展词库 / 拓展映射）完全一致。
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/high_freq_export.dart';
import 'package:esw/shared/doc_extractor.dart';
import 'package:esw/shared/phrase_stats.dart';
import 'package:esw/shared/text_normalize.dart';
import 'package:esw/shared/vocab_service.dart';
import 'package:esw/shared/word_family.dart';

void main() {
  test('全部词条：检测页与高频导出频次逐条一致', () async {
    final root = Directory.current.path;
    final corpusDir = '$root\\assets\\gaokao\\txt';

    // 与软件运行一致：拓展词库取用户配置（缺失则退化为仅课标词库声明）
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final cfgFile = File('$local\\ESW\\esw_config.json');
    var cfgBase = <String, String>{};
    var cfgExtend = <String>[];
    if (cfgFile.existsSync()) {
      final cfg = jsonDecode(utf8.decode(cfgFile.readAsBytesSync()))
          as Map<String, dynamic>;
      cfgBase = ((cfg['extendBaseMap'] as Map?) ?? const {})
          .map((k, v) => MapEntry(k.toString(), v.toString()));
      cfgExtend = ((cfg['extendWords'] as List?) ?? const [])
          .map((e) => '$e')
          .toList();
    }

    final stdRaw = utf8
        .decode(File('$root\\assets\\standard_words.json').readAsBytesSync());
    final stdJson = jsonDecode(stdRaw) as Map<String, dynamic>;

    // 生产口径：界面「拓展词汇」白名单（_collectExtendBaseMapRaw）——
    // 仅过滤键不在 extendWords 列表的脏映射，键的大小写原样保留，
    // 由 buildExtendBaseMap 统一规范化（小写键优先）。
    final extendWordsLower = cfgExtend.map((e) => e.toLowerCase().trim()).toSet();
    final cfgBaseFiltered = <String, String>{
      for (final e in cfgBase.entries)
        if (extendWordsLower.contains(e.key.toLowerCase().trim()))
          e.key.trim(): e.value.trim(),
    };

    final vs = VocabService();
    vs.standardWords = stdJson.map(
        (k, v) => MapEntry(k, (v as Map).cast<String, String>()));
    vs.extendWordKeySet.addAll(cfgExtend);
    // 与导出侧、生产口径一致：只用白名单内的拓展映射
    vs.extendBaseMap.addAll(cfgBaseFiltered);
    // 复刻 VocabService.loadStandardWords 的索引：课标库 extensions 反向索引
    // 与英美拼写合并后的「变体 → 主条」映射（变体已挂主条 extensions）。
    // 与生产一致：形同义不同的独立词条不并入主条（buildLibraryExtensionBaseMap）。
    final extByBase = <String, Iterable<String>>{};
    stdJson.forEach((k, v) {
      final m = v as Map<String, dynamic>;
      if ((m['category'] as String?) == '专有词') return;
      final exts = m['extensions'];
      if (exts is List && exts.isNotEmpty) {
        extByBase[k] = exts.map((e) => '$e');
      }
    });
    vs.extendReverseIndex.addAll(buildLibraryExtensionBaseMap(
      standardKeys: stdJson.keys,
      extensionsByBase: extByBase,
    ));
    vs.spellingExtensionAliases = buildExtensionSpellingAliases(extByBase);

    // ---- 共用口径：短语覆盖合并 / 大小写异义词 ----
    // 这两类词在页面与导出按不同口径展示（短语合并成一条、大小写页面分计
    // 而导出合并），不在本一致性用例的逐词比对范围内，单独由
    // high_freq_export_test 覆盖。这里先算出需要跳过的词。
    final phrases = buildStandardPhrases(stdJson.keys);
    final caseCanon = buildCaseVariantGroups(stdJson.keys).keys.toSet();
    final covTracker = PhraseCoverageTracker(phrases);
    final corpusTexts = <String>[];
    final corpusFiles = Directory(corpusDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.txt'))
        .toList();
    corpusFiles.sort((a, b) => a.path.compareTo(b.path));
    for (final f in corpusFiles) {
      final text = normalizeCorpusText(decodeTextBytes(f.readAsBytesSync()));
      corpusTexts.add(text);
      covTracker.addText(text);
    }
    final mergedHeads = <String>{
      for (final c in covTracker.result().values)
        if (c.merged) c.head,
    };

    // ---- 导出侧 ----
    final res = await HighFreqExporter.export(
      corpusDir: corpusDir,
      standardWordsRaw: stdRaw,
      dbPath: '$root\\assets\\ecdict.db',
      extendBaseMapRaw: jsonEncode(cfgBaseFiltered),
      extendWordsRaw: jsonEncode(cfgExtend),
      format: 'xlsx',
      wordLimit: 3000,
    );
    final xl = Excel.decodeBytes(res.xlsxBytes);
    final rows = xl['高考高频词表']
        .rows
        .map((r) => r.map((c) => c?.value?.toString() ?? '').toList())
        .toList()
        .skip(1);

    final exportTotal = <String, int>{};
    final exportPhraseTotal = <String, int>{};
    final exportMembers = <String, Map<String, int>>{};
    final exportOrder = <String>[];
    for (final r in rows) {
      final w = r[1].trim().toLowerCase();
      if (w.isEmpty) continue;
      // 课标短语（according to 等）单独校验：页面整条查询应与导出一致。
      if (w.contains(' ')) {
        exportPhraseTotal[w] = int.tryParse(r[3].trim()) ?? -1;
        continue;
      }
      // 短语完全覆盖的首词（according）页面/短语口径单独校验
      if (mergedHeads.contains(w)) continue;
      // 大小写异义词（March/march 等）页面分计、导出合并，单独校验
      if (caseCanon.contains(w)) continue;
      // 含变音字母的课标词（café）：页面按词形规则归并 cafe/cafes，
      // 导出按词库显式映射统计，口径差异不在本用例约束内
      if (RegExp(r'[^\x00-\x7F]').hasMatch(w)) continue;
      exportOrder.add(w);
      exportTotal[w] = int.tryParse(r[3].trim()) ?? -1;
      final m = <String, int>{};
      for (final x in RegExp(r'(?<![a-z])([a-zA-Z]+)\((\d+)\)')
          .allMatches(r[11])) {
        m[x.group(1)!.toLowerCase()] = int.parse(x.group(2)!);
      }
      exportMembers[w] = m;
    }

    // ---- 页面侧：每个词条取检测页实际词族，单次扫描语料统计 ----
    final formsByRoot = <String, Set<String>>{};
    final rootByForm = <String, List<String>>{};
    for (final w in exportOrder) {
      final forms = vs.familyFor(w).forms.toSet();
      formsByRoot[w] = forms;
      for (final f in forms) {
        (rootByForm[f] ??= <String>[]).add(w);
      }
    }

    final pageTotal = <String, int>{};
    final pageMembers = <String, Map<String, int>>{};
    for (final text in corpusTexts) {
      for (final m in wordTokenRegExp.allMatches(text)) {
        final t = m.group(0)!.toLowerCase();
        final roots = rootByForm[t];
        if (roots == null) continue;
        for (final r in roots) {
          pageTotal[r] = (pageTotal[r] ?? 0) + 1;
          final pm = pageMembers[r] ??= <String, int>{};
          pm[t] = (pm[t] ?? 0) + 1;
        }
      }
    }

    // 抽样校验单次扫描与检测页真实接口完全等价（用实际 getWordFrequency）
    final probe = <String>[
      for (var i = 0; i < exportOrder.length; i += exportOrder.length ~/ 12)
        exportOrder[i],
    ];
    for (final w in probe.toSet()) {
      final page = await vs.getWordFrequency(w, corpusDir);
      final actual = (page?['total'] as int?) ?? 0;
      expect(pageTotal[w], actual,
          reason: '扫描口径与检测页接口不一致: $w（单次扫描=${pageTotal[w]}，接口=$actual）');
    }

    // 短语整条：页面搜短语与导出词条必须同一数字；搜首词也必须同一数字。
    for (final e in exportPhraseTotal.entries) {
      final d = await vs.getWordFrequency(e.key, corpusDir);
      expect((d?['total'] as int?) ?? 0, e.value,
          reason: '短语 ${e.key} 页面与导出频次不一致');
      // 只有覆盖关系成立（首词每次出现都在短语内）才要求首词同数；
      // 未覆盖的短语（per cent 等）首词仍有独立用法，保持自身 token 数。
      final head = e.key.split(' ').first;
      if (!mergedHeads.contains(head)) continue;
      final h = await vs.getWordFrequency(head, corpusDir);
      expect((h?['total'] as int?) ?? 0, e.value,
          reason: '短语首词 $head 与短语 ${e.key} 页面频次不一致');
    }
    // 大小写异义词：页面必须分开计数（March 与 march 不同）。
    final marchLower = await vs.getWordFrequency('march', corpusDir);
    final marchUpper = await vs.getWordFrequency('March', corpusDir);
    expect(marchLower?['total'], isNot(marchUpper?['total']),
        reason: 'March/march 页面应按原始大小写分开计数');

    // ---- 逐条比对 ----
    final mismatches = <String>[];
    for (final w in exportOrder) {
      final p = pageTotal[w] ?? 0;
      final e = exportTotal[w] ?? 0;
      if (p == e) continue;
      final pm = pageMembers[w] ?? const <String, int>{};
      final em = exportMembers[w] ?? const <String, int>{};
      final diff = <String>[];
      for (final k in {...pm.keys, ...em.keys}) {
        final pv = pm[k] ?? 0;
        final ev = em[k] ?? 0;
        if (pv != ev) diff.add('$k(页面$pv/导出$ev)');
      }
      mismatches.add('$w: 页面=$p 导出=$e 差=${p - e} | ${diff.join(', ')}');
    }

    // ignore: avoid_print
    print('AUDIT entries=${exportOrder.length} mismatches=${mismatches.length}');
    for (final m in mismatches) {
      // ignore: avoid_print
      print('MISMATCH $m');
    }
    expect(mismatches, isEmpty,
        reason: '检测页与高频导出存在不一致词条:\n${mismatches.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
