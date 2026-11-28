import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/high_freq_export.dart';
import 'package:esw/shared/vocab_service.dart';
import 'package:esw/shared/word_family.dart';

/// 页面词频（VocabService）与高频导出必须完全一致：
/// 同一分词、同一大小写口径、同一英美拼写/变体归并。
void main() {
  test('页面词频与高频导出在同一批语料上完全一致', () async {
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final cfg = jsonDecode(utf8.decode(
            File('$local\\ESW\\esw_config.json').readAsBytesSync()))
        as Map<String, dynamic>;
    final cfgBase = Map<String, String>.from((cfg['extendBaseMap'] as Map)
        .map((k, v) => MapEntry(k.toString(), v.toString())));
    final cfgExtend =
        ((cfg['extendWords'] as List?) ?? const []).map((e) => '$e').toList();
    final stdRaw =
        utf8.decode(File('assets/standard_words.json').readAsBytesSync());
    final stdJson = jsonDecode(stdRaw) as Map<String, dynamic>;

    final vs = VocabService();
    vs.standardWords = stdJson.map(
        (k, v) => MapEntry(k, (v as Map).cast<String, String>()));
    vs.extendWordKeySet.addAll(cfgExtend);
    vs.extendBaseMap.addAll(cfgBase);
    // 复刻 VocabService.loadStandardWords 的索引：课标库 extensions 反向索引
    // 与英美拼写合并后的「变体 → 主条」映射
    final extByBase = <String, Iterable<String>>{};
    stdJson.forEach((k, v) {
      final m = v as Map<String, dynamic>;
      if ((m['category'] as String?) == '专有词') return;
      final exts = m['extensions'];
      if (exts is List && exts.isNotEmpty) {
        extByBase[k] = exts.map((e) => '$e');
        for (final e in exts) {
          vs.extendReverseIndex['$e'.toLowerCase()] = k.toLowerCase();
        }
      }
    });
    vs.spellingExtensionAliases = buildExtensionSpellingAliases(extByBase);

    final res = await HighFreqExporter.export(
      corpusDir: 'assets/gaokao/txt',
      standardWordsRaw: stdRaw,
      dbPath: 'assets/ecdict.db',
      extendBaseMapRaw: jsonEncode(cfgBase),
      extendWordsRaw: jsonEncode(cfgExtend),
      format: 'xlsx',
    );
    final xl = Excel.decodeBytes(res.xlsxBytes);
    final rows = xl['高考高频词表']
        .rows
        .map((r) => r.map((c) => c?.value?.toString() ?? '').toList())
        .toList();
    int exportFreq(String w) {
      final aliases = buildSpellingAliases(stdJson.keys);
      final canonical = aliases[w] ?? w;
      for (final r in rows) {
        if (r.length > 3 && r[1].toLowerCase() == canonical) {
          return int.tryParse(r[3]) ?? -1;
        }
      }
      return 0;
    }

    final words = <String>['the', 'practise', 'colour', 'television'];
    for (final w in words) {
      final page = await vs.getWordFrequency(w, 'assets/gaokao/txt');
      final pageTotal = (page?['total'] as int?) ?? 0;
      final exp = exportFreq(w);
      // ignore: avoid_print
      print('$w: 页面=$pageTotal 导出=$exp');
      expect(exp, pageTotal, reason: '$w 在两处统计不一致');
    }
    // 英美拼写已合并为单条：美式变体页面统计应等于主条导出频次
    final practicePage = await vs.getWordFrequency('practice', 'assets/gaokao/txt');
    expect(exportFreq('practise'), (practicePage?['total'] as int?) ?? 0,
        reason: 'practice 应并入主条 practise 统计');
    // 英美拼写：查 practise 时页面总数应包含 practice 及其变形
    final practise = await vs.getWordFrequency('practise', 'assets/gaokao/txt');
    final forms = (practise?['forms'] as List).cast<String>();
    expect(forms.first, 'practise');
    expect(forms[1], 'practice');
    expect(forms, contains('practises'));
  });
}
