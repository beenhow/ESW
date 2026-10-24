// 验证测试：「导出词频」三类词库（拓展 / 超标 / 专有）× Word/Excel 真实数据导出，
// 同时生成高频统计基线文件，供外部脚本比对排版同源性与字段完整性。
// 数据全部取自本机软件词库（%LOCALAPPDATA%\ESW\esw_config.json）与已部署
// ecdict.db，不伪造词条。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:esw/high_freq_export.dart';

const String kOutDir =
    r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_c2a67664691e4c018bfd5a14378aff25\temp\wordbank_verify';

void main() {
  test('word bank export 3 kinds x 2 formats + high freq baseline', () async {
    final outDir = Directory(kOutDir)..createSync(recursive: true);
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '.';
    final cfgPath = p.join(localAppData, 'ESW', 'esw_config.json');
    final dbPath = p.join(localAppData, 'ESW', 'ecdict.db');
    expect(File(cfgPath).existsSync(), isTrue, reason: 'esw_config.json 应存在');
    expect(File(dbPath).existsSync(), isTrue, reason: 'ecdict.db 应已部署');

    final cfg =
        jsonDecode(File(cfgPath).readAsStringSync()) as Map<String, dynamic>;
    final extendWords =
        (cfg['extendWords'] as List).map((e) => e.toString()).toList();
    final extendLower = extendWords.map((e) => e.toLowerCase()).toSet();
    // 与界面 _collectExtendBaseMapRaw 同一白名单口径：键必须在扩展词列表内
    final baseMap = <String, String>{};
    final rawMap = cfg['extendBaseMap'];
    if (rawMap is Map) {
      for (final e in rawMap.entries) {
        final k = e.key.toString().trim().toLowerCase();
        final v = e.value.toString().trim().toLowerCase();
        if (k.isEmpty || v.isEmpty) continue;
        if (!extendLower.contains(k)) continue;
        baseMap[k] = v;
      }
    }
    final overLimit =
        (cfg['manualChaoGangWords'] as List).map((e) => e.toString()).toList();
    final proper =
        (cfg['manualExtraWords'] as List).map((e) => e.toString()).toList();

    final inputs = <String, List<String>>{
      'extend': extendWords,
      'overLimit': overLimit,
      'proper': proper,
    };
    final report = <String, dynamic>{
      'sources': {
        'extend': extendWords.length,
        'extendBaseMapWhitelisted': baseMap.length,
        'overLimit': overLimit.length,
        'proper': proper.length,
      },
      'exports': <String, dynamic>{},
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
        (report['exports'] as Map)[
                '${entry.key}.$fmt'] =
            <String, dynamic>{
          'wordCount': r.wordCount,
          'dictHit': r.dictHit,
          'bytes': r.bytes.length,
          'seconds': sw.elapsedMilliseconds / 1000,
        };
        // ignore: avoid_print
        print('EXPORT ${entry.key}.$fmt words=${r.wordCount} '
            'dictHit=${r.dictHit} bytes=${r.bytes.length}');
      }
    }

    // 高频统计基线（真实真题语料 + 标准词库），用于比对排版是否同源
    final stdRaw =
        File(p.join(r'D:\UserData\Desktop\ESW', 'assets', 'standard_words.json'))
            .readAsStringSync();
    final base = await HighFreqExporter.export(
      corpusDir: r'D:\UserData\Desktop\2005-2025真题TXT',
      standardWordsRaw: stdRaw,
      dbPath: dbPath,
      extendBaseMapRaw: jsonEncode(baseMap),
      extendWordsRaw: jsonEncode(extendLower.toList()),
      format: 'xlsx',
    );
    File(p.join(outDir.path, 'ESW-base.xlsx'))
        .writeAsBytesSync(base.xlsxBytes);
    report['base'] = {'exportedWords': base.exportedWords};
    if (base.docxBytes != null) {
      File(p.join(outDir.path, 'ESW-base.docx'))
          .writeAsBytesSync(base.docxBytes!);
    }
    final docxBase = await HighFreqExporter.export(
      corpusDir: r'D:\UserData\Desktop\2005-2025真题TXT',
      standardWordsRaw: stdRaw,
      dbPath: dbPath,
      extendBaseMapRaw: jsonEncode(baseMap),
      extendWordsRaw: jsonEncode(extendLower.toList()),
      format: 'docx',
    );
    if (docxBase.docxBytes != null) {
      File(p.join(outDir.path, 'ESW-base.docx'))
          .writeAsBytesSync(docxBase.docxBytes!);
    }

    File(p.join(outDir.path, 'report.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  }, timeout: const Timeout(Duration(minutes: 15)));
}
