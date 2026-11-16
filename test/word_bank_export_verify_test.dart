// 验证测试：「导出词频」三类词库（拓展 / 超标 / 专有）× Word/Excel 导出，
// 同时生成高频统计基线文件，供人工复核排版同源性与字段完整性。
//
// 全部输入取自项目内置资产（assets/standard_words.json、assets/ecdict.db、
// assets/gaokao/txt），输出写入系统临时目录；不读取本机外部真题目录、
// %LOCALAPPDATA% 用户配置或任何固定绝对路径。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:esw/high_freq_export.dart';

void main() {
  test('word bank export 3 kinds x 2 formats + high freq baseline', () async {
    final root = Directory.current.path;
    final dbPath = p.join(root, 'assets', 'ecdict.db');
    final stdRaw =
        File(p.join(root, 'assets', 'standard_words.json')).readAsStringSync();
    final corpusDir = p.join(root, 'assets', 'gaokao', 'txt');
    expect(File(dbPath).existsSync(), isTrue, reason: 'assets/ecdict.db 应存在');
    expect(Directory(corpusDir).existsSync(), isTrue,
        reason: '内置真题目录 assets/gaokao/txt 应存在');

    final outDir = Directory.systemTemp.createTempSync('esw_wordbank_verify_');

    // 拓展词：取课标词库声明的 extensions（与导出器白名单同一数据源）。
    final stdJson = jsonDecode(stdRaw) as Map<String, dynamic>;
    final baseMap = <String, String>{};
    for (final entry in stdJson.entries) {
      final meta = entry.value;
      if (meta is! Map) continue;
      final exts = meta['extensions'];
      if (exts is! List) continue;
      final base = entry.key.toLowerCase();
      for (final ex in exts) {
        final le = ex.toString().trim().toLowerCase();
        if (le.isEmpty || le == base) continue;
        baseMap.putIfAbsent(le, () => base);
      }
    }
    final extendWords = baseMap.keys.toList()..sort();
    expect(extendWords, isNotEmpty, reason: '课标词库应声明拓展词');

    // 超标 / 专有词：固定小样本 fixture（不读取本机用户词库）。
    const overLimit = <String>['abandon', 'abstract', 'absurd'];
    const proper = <String>['Beijing', 'London', 'Olympic'];

    final inputs = <String, List<String>>{
      'extend': extendWords,
      'overLimit': overLimit,
      'proper': proper,
    };

    for (final entry in inputs.entries) {
      for (final fmt in <String>['docx', 'xlsx']) {
        final sw = Stopwatch()..start();
        final r = await HighFreqExporter.exportWordBank(
          kind: entry.key,
          words: entry.value,
          baseMap: entry.key == 'extend' ? baseMap : const <String, String>{},
          dbPath: dbPath,
          format: fmt,
        );
        final f = File(p.join(outDir.path, 'ESW-${entry.key}.$fmt'));
        f.writeAsBytesSync(r.bytes);
        expect(r.bytes.length, greaterThan(1000),
            reason: '${entry.key}.$fmt 不应生成空文件');
        expect(r.wordCount, entry.value.toSet().length,
            reason: '${entry.key}.$fmt 词条数应等于输入词数');
        expect(r.dictHit, greaterThan(0),
            reason: '${entry.key}.$fmt 应命中词典释义');
        // ignore: avoid_print
        print('EXPORT ${entry.key}.$fmt words=${r.wordCount} '
            'dictHit=${r.dictHit} bytes=${r.bytes.length} '
            'seconds=${sw.elapsedMilliseconds / 1000}');
      }
    }

    // 高频统计基线（内置 98 套真题 + 课标词库），用于比对排版是否同源。
    final base = await HighFreqExporter.export(
      corpusDir: corpusDir,
      standardWordsRaw: stdRaw,
      dbPath: dbPath,
      extendBaseMapRaw: jsonEncode(baseMap),
      extendWordsRaw: jsonEncode(extendWords),
      format: 'xlsx',
    );
    File(p.join(outDir.path, 'ESW-base.xlsx'))
        .writeAsBytesSync(base.xlsxBytes);
    expect(base.corpusFileCount, 98,
        reason: '基线统计应只覆盖内置 98 套真题');
    expect(base.exportedWords, greaterThan(0), reason: '基线应导出高频词');
    // ignore: avoid_print
    print('BASELINE files=${base.corpusFileCount} '
        'exported=${base.exportedWords} bytes=${base.xlsxBytes.length}');
    // ignore: avoid_print
    print('WORD_BANK_OUTPUT_DIR=${outDir.path}');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
