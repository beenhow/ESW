// 冒烟测试：验证导出高频 xlsx 生成（词条数量、归并、例句年份、无 [v:43/n:57] 标记、
// 星期/月份/序数词排除、Excel 列结构）
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';

import 'package:esw/high_freq_export.dart';

// 与导出器一致的排除集（测试侧独立声明，防实现自证）
const calendarSet = <String>{
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
  'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun',
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december',
  'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
  'first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth',
  'ninth', 'tenth', 'eleventh', 'twelfth', 'thirteenth', 'fourteenth',
  'fifteenth', 'sixteenth', 'seventeenth', 'eighteenth', 'nineteenth',
  'twentieth', 'thirtieth',
  '1st', '2nd', '3rd',
};

// 星期/月份/序数词屈折形态（词库可能声明的拓展，如 Tuesdays 归并 Tuesday）
const calendarFlexSet = <String>{
  'mondays', 'tuesdays', 'wednesdays', 'thursdays', 'fridays', 'saturdays',
  'sundays', 'januarys', 'februarys', 'marchs', 'aprils', 'mays', 'junes',
  'julys', 'augusts', 'septembers', 'octobers', 'novembers', 'decembers',
  'firsts', 'seconds', 'thirds', 'fourths', 'fifths', 'sixths',
};

void main() {
  test('export high freq xlsx smoke', () async {
    final eswDir = r'D:\UserData\Desktop\ESW';
    final corpusDir = r'D:\UserData\Desktop\2005-2025真题TXT';
    final stdRaw = File(p.join(eswDir, 'assets', 'standard_words.json'))
        .readAsStringSync();
    final dbPath = p.join(
        Platform.environment['LOCALAPPDATA'] ?? '.', 'ESW', 'ecdict.db');
    expect(File(dbPath).existsSync(), isTrue, reason: 'ecdict.db 应已部署');

    final sw = Stopwatch()..start();
    // 词库拓展词映射：与导出器生产环境一致（exe 同目录 esw_config.json）。
    final ebmMerged = <String, String>{};
    var ewAll = <String>{};
    final cfgCandidates = [
      r'D:\UserData\Desktop\ESW\build\windows\x64\runner\Release\esw_config.json',
      p.join(eswDir, 'esw_config.json'),
    ];
    for (final cfgPath in cfgCandidates) {
      final f = File(cfgPath);
      if (!f.existsSync()) continue;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final ew = (j['extendWords'] as List?)?.map((e) => e.toString().toLowerCase()).toSet() ?? {};
      ewAll = ew;
      final m = j['extendBaseMap'];
      if (m is Map) {
        for (final e in m.entries) {
          final k = e.key.toString().toLowerCase();
          if (!ew.contains(k)) continue;
          ebmMerged[k] = e.value.toString().toLowerCase();
        }
      }
      break;
    }
    expect(ebmMerged.containsKey('ind'), isFalse,
        reason: 'ind 不在界面 extendWords 集合，白名单过滤后必须剔除');
    final result = await HighFreqExporter.export(
      corpusDir: corpusDir,
      standardWordsRaw: stdRaw,
      dbPath: dbPath,
      extendBaseMapRaw: jsonEncode(ebmMerged),
      extendWordsRaw: jsonEncode(ewAll.toList()),
    );
    sw.stop();
    // ignore: avoid_print
    print('ELAPSED_SECONDS=${sw.elapsedMilliseconds / 1000.0}');
    expect(result.corpusFileCount, greaterThan(200));
    expect(result.exportedWords, 3000,
        reason: '新口径：排除星期/月份/序数词后仍导出 3000 高频词');
    expect(result.xlsxBytes.length, greaterThan(100000),
        reason: 'xlsx 字节不应过小');

    // 解码 xlsx：读取"高考高频词表"全部行
    final xl = Excel.decodeBytes(result.xlsxBytes);
    expect(xl.tables.containsKey('高考高频词表'), isTrue,
        reason: 'xlsx 应包含 Sheet 高考高频词表');
    final sheet = xl['高考高频词表'];
    final rows = sheet.rows
        .map((r) => r.map((c) => c?.value?.toString() ?? '').toList())
        .toList();
    expect(rows.length, greaterThan(3000), reason: '表头+3000 词行');

    // 表头校验：序号/单词/类型/真题频次/音标/词性/释义/例句1~4/拓展词列表/拓展词例句
    final header = rows.first;
    const expectHeaders = <String>[
      '序号', '单词', '类型', '真题频次', '音标', '词性', '释义',
      '例句1', '例句2', '例句3', '例句4',
      '拓展词列表', '拓展词例句',
    ];
    expect(header.take(expectHeaders.length).toList(), expectHeaders,
        reason: 'xlsx 表头列结构应符合设计，实际: $header');

    final dataRows = rows.skip(1).toList();
    expect(dataRows.length, 3000, reason: '数据行应为 3000');
    final entryNames = dataRows
        .map((r) => r[1].trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList();

    // 扩展词行解析：从拓展词列表/拓展词例句列提取 "word(nn)"
    // 注意：例句列（r[12]）仅匹配 "word(freq):" 形式，避免把例句内完形填空
    // 题号残留（如 behave(80)、of(81)）误当作拓展词；列表列（r[11]）为纯
    // word(freq) 清单，可全量提取。
    final extWordsInTable = <String>{};
    for (final r in dataRows) {
      final mList = RegExp(r'(?<![a-z])([a-zA-Z]+)(?=\(\d+\))')
          .allMatches(r[11])
          .map((x) => x.group(1)!.toLowerCase());
      extWordsInTable.addAll(mList);
      final mEx = RegExp(r'(?<![a-z])([a-zA-Z]+)\(\d+\)\s*:')
          .allMatches(r[12])
          .map((x) => x.group(1)!.toLowerCase());
      extWordsInTable.addAll(mEx);
    }

    // ---- 需求1：星期/月份/序数词（含缩写/屈折拓展）一律排除 ----
    // 1) 词条列不出现任何排除集词
    final calInEntries = entryNames.where(calendarSet.contains).toSet();
    expect(calInEntries, isEmpty,
        reason: '词表不得出现星期/月份/序数词，违规: $calInEntries');
    // 2) 拓展词列不出现任何排除集词（Tuesdays→Tuesday 归并被双向剔除）
    final calInExt = extWordsInTable.where(calendarSet.contains).toSet();
    expect(calInExt, isEmpty,
        reason: '拓展词列不得出现星期/月份/序数词，违规: $calInExt');
    // 3) 屈折形式（Tuesdays/Mondays/firsts 等）同样不得出现在词条列与拓展词列
    final flexInEntries = entryNames.where(calendarFlexSet.contains).toSet();
    expect(flexInEntries, isEmpty,
        reason: '词表不得出现星期/月份/序数词屈折形式，违规: $flexInEntries');
    final flexInExt = extWordsInTable.where(calendarFlexSet.contains).toSet();
    expect(flexInExt, isEmpty,
        reason: '拓展词列不得出现星期/月份/序数词屈折形式，违规: $flexInExt');
    // 4) 清理回执：应记录实际剔除的星期/月份/序数词（语料 86 万词次中
    //    first/second/march 等必然出现），且回执集合 ⊆ 排除集 ∪ 排除集词的
    //    词库拓展/屈折形式（如 Tuesdays→Tuesday、marching→March、
    //    secondhand→second，由词库归并映射级联剔除）
    expect(result.calendarOrdinalExcluded, isNotEmpty,
        reason: '清理回执不应为空（语料应含星期/月份/序数词）');
    final calBaseLookup = <String, String>{};
    calBaseLookup.addAll(ebmMerged);
    {
      final std2 = jsonDecode(stdRaw) as Map<String, dynamic>;
      for (final k in std2.keys) {
        final exts = (std2[k] as Map<String, dynamic>?)?['extensions'];
        if (exts is List) {
          for (final ex in exts) {
            final le = ex.toString().toLowerCase();
            if (le.isNotEmpty &&
                le != k.toLowerCase() &&
                ewAll.contains(le)) {
              calBaseLookup.putIfAbsent(le, () => k.toLowerCase());
            }
          }
        }
      }
    }
    final outOfSet = result.calendarOrdinalExcluded.where((w) {
      if (calendarSet.contains(w)) return false;
      final base = calBaseLookup[w];
      return !(base != null && calendarSet.contains(base));
    }).toSet();
    expect(outOfSet, isEmpty,
        reason: '清理回执只能包含排除集词或其词库拓展/屈折形式，违规: $outOfSet');
    // ignore: avoid_print
    print('calendarOrdinalExcluded=${result.calendarOrdinalExcluded.length}: '
        '${result.calendarOrdinalExcluded.take(30).toList()}');

    // 无词性频率标记
    final allText = dataRows.map((r) => r.join('|')).join('\n');
    expect(allText.contains('[v:'), isFalse, reason: '不应残留词性频率标记');
    expect(RegExp(r'\[[a-zA-Z]+:\d+(?:/[a-zA-Z]+:\d+)*\]').hasMatch(allText),
        isFalse, reason: '不应残留任何词性频率标记');
    // 例句带年份（例句列 1-4）
    expect(
        dataRows.any((r) =>
            [r[7], r[8], r[9], r[10]].any((c) => RegExp(r'（20\d{2}）').hasMatch(c))),
        isTrue,
        reason: '例句列应标年份');
    // 课标类型列：必须存在初中/必修/选修之一
    final typeSet = dataRows.map((r) => r[2].trim()).toSet();
    expect(typeSet.intersection({'初中', '必修', '选修'}).isNotEmpty, isTrue,
        reason: '类型列应出现初中/必修/选修，实际: $typeSet');
    for (final t in typeSet) {
      expect({'初中', '必修', '选修', '课标词', '拓展词'}.contains(t), isTrue,
          reason: '类型列值非法: $t');
    }

    // ---- 既有回归：拓展词归并 / 专有词 / 停用词 / 缩略脏拓展词 ----
    // 停用词不得作为独立词条
    for (final sw in [
      'be', 'is', 'are', 'am', 'was', 'were', 'been', 'being',
      'do', 'does', 'did', 'have', 'has', 'had',
      'can', 'could', 'may', 'might', 'must', 'shall', 'should', 'will', 'would',
      'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them',
      'my', 'your', 'his', 'hers', 'its', 'our', 'their', 'mine', 'yours', 'ours', 'theirs',
      'wills', 'willed',
    ]) {
      expect(entryNames.contains(sw), isFalse,
          reason: '停用词 $sw 不应独立成词条');
    }
    // 拓展词列不得出现停用词词族成员
    for (final sw in ['wills', 'willed', 'cans', 'could', 'being', 'was', 'were', 'did', 'done', 'had', 'cannot', 'soes']) {
      expect(extWordsInTable.contains(sw), isFalse,
          reason: '停用词词族成员 $sw 不应出现在拓展词列');
    }
    // 缩略/机构脏拓展词
    for (final ext in ['nots', 'eco', 'tue']) {
      expect(entryNames.contains(ext), isFalse,
          reason: '脏拓展词 $ext 不得作为独立词条');
      expect(extWordsInTable.contains(ext), isFalse,
          reason: '$ext 不得出现在拓展词列');
    }
    expect(result.cleanedExtWords.toSet().containsAll({'nots', 'eco', 'isn', 'wasn', 'tue'}),
        isTrue,
        reason: '清理清单应包含 nots/eco/isn/wasn/tue，实际: ${result.cleanedExtWords}');

    // 专有词抽查
    for (final w in ['beijing', 'olympic', 'londoners']) {
      expect(entryNames.contains(w), isFalse,
          reason: '专有词 $w 不应独立成词条');
    }
    expect(result.nonHeadCapsExcluded.contains('londoners'), isTrue,
        reason: '清理回执应含 londoners，实际: ${result.nonHeadCapsExcluded}');

    // report 归并
    final hasReport = entryNames.contains('report');
    final hasReporterStandalone = entryNames.contains('reporter');
    expect(hasReport || hasReporterStandalone, isTrue,
        reason: 'report 或孤立的 reporter 词条应存在');
    if (hasReport) {
      final reportRow = dataRows.firstWhere((r) => r[1].trim().toLowerCase() == 'report');
      final reportExts = RegExp(r'(?<![a-z])([a-zA-Z]+)(?=\(\d+\))')
          .allMatches('${reportRow[11]} ${reportRow[12]}')
          .map((m) => m.group(1)!.toLowerCase())
          .toList();
      expect(reportExts.contains('reporter'), isTrue,
          reason: 'report 词条拓展词列应含 reporter');
    }
    // 已归并拓展词不得独立成条（said/says/sayings）
    for (final ext in ['said', 'says', 'sayings']) {
      expect(entryNames.contains(ext), isFalse,
          reason: '已归并拓展词 $ext 不得作为独立词条');
    }

    // ---- 需求2：Excel 列结构抽查 ----
    // 每行序号连续、单词列非空、频次列为数字、释义列非空（前 100 行抽查）
    for (var i = 0; i < 100; i++) {
      final r = dataRows[i];
      expect(r[0].trim(), '${i + 1}', reason: '第 ${i + 1} 行序号应连续');
      expect(r[1].trim(), isNotEmpty, reason: '单词列不应为空');
      expect(int.tryParse(r[3].trim()), isNotNull,
          reason: '真题频次列应为数字: ${r[3]}');
      expect(r[6].trim(), isNotEmpty, reason: '释义列不应为空');
    }

    // 释义修复回归（seen/made/appeare/prohibite）
    // seen 已归并为 see 的拓展词（member），释义不再落盘到主词条释义列；
    // 回归点改为：see 词条拓展词列表必须含 seen（带频次），且 seen 不独立成条。
    final seeRow =
        dataRows.firstWhere((r) => r[1].trim().toLowerCase() == 'see');
    expect(RegExp(r'(?<![a-z])seen(?=\(\d+\))').hasMatch(seeRow[11]),
        isTrue,
        reason: 'see 词条拓展词列表应含 seen，实际: ${seeRow[11]}');
    expect(entryNames.contains('seen'), isFalse,
        reason: 'seen 不得作为独立词条');
    expect(allText.contains('s. ee'), isFalse,
        reason: '不得出现 seen 释义拆词 s. ee');
    expect(allText.contains('appeare的过去式'), isFalse,
        reason: 'appeared 释义不得残留词典错拼 appeare');
    expect(allText.contains('prohibite的过去分词'), isFalse,
        reason: 'prohibited 释义不得残留词典错拼 prohibite');

    // 拓展词必须全部在界面词库集合内
    final outsideExt = extWordsInTable.where((w) => !ewAll.contains(w)).toSet();
    expect(outsideExt, isEmpty,
        reason: '导出拓展词必须全部在界面词库集合内，多余词: $outsideExt');

    // 通用去重
    final stdSetForTest = (jsonDecode(stdRaw) as Map<String, dynamic>).keys
        .map((k) => k.toString().toLowerCase())
        .toSet();
    final dupViolations = entryNames.where((w) {
      final base = ebmMerged[w];
      if (base == null || base == w || stdSetForTest.contains(w)) return false;
      return entryNames.contains(base);
    }).toList();
    expect(dupViolations, isEmpty,
        reason: '已归并拓展词不得独立成条，违规: $dupViolations');

    // 输出摘要
    // ignore: avoid_print
    print('exported=${result.exportedWords} files=${result.corpusFileCount} '
        'tokens=${result.totalTokens} bytes=${result.xlsxBytes.length}');
    // ignore: avoid_print
    print('groups=${result.groupSummary}');

    // ---- 需求1 扩展：Word(docx) 格式导出（与 xlsx 完全同口径）----
    final docxSw = Stopwatch()..start();
    final docxResult = await HighFreqExporter.export(
      corpusDir: corpusDir,
      standardWordsRaw: stdRaw,
      dbPath: dbPath,
      extendBaseMapRaw: jsonEncode(ebmMerged),
      extendWordsRaw: jsonEncode(ewAll.toList()),
      format: 'docx',
    );
    docxSw.stop();
    // ignore: avoid_print
    print('DOCX_ELAPSED_SECONDS=${docxSw.elapsedMilliseconds / 1000.0}');
    expect(docxResult.format, 'docx', reason: 'format 应回显 docx');
    expect(docxResult.docxBytes, isNotNull,
        reason: 'docx 格式应生成 docxBytes');
    expect(docxResult.docxBytes!.length, greaterThan(100000),
        reason: 'docx 字节不应过小');
    expect(docxResult.exportedWords, 3000,
        reason: 'docx 口径与 xlsx 一致：3000 词');
    // 解包 OOXML：校验三件套与表格结构
    final docxArchive = ZipDecoder().decodeBytes(docxResult.docxBytes!);
    final names = docxArchive.files.map((f) => f.name).toSet();
    expect(names.contains('[Content_Types].xml'), isTrue,
        reason: 'docx 应含 [Content_Types].xml');
    expect(names.contains('_rels/.rels'), isTrue,
        reason: 'docx 应含 _rels/.rels');
    expect(names.contains('word/document.xml'), isTrue,
        reason: 'docx 应含 word/document.xml');
    final documentXml = utf8.decode(
        docxArchive.files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>);
    expect(documentXml.contains('高考高频词表'), isTrue,
        reason: 'docx 应含标题 高考高频词表');
    // 需求1：Word 用直接列举排版（不用表格），Excel 保持 13 列表格
    expect(documentXml.contains('<w:tbl>'), isFalse,
        reason: 'docx 不得使用表格（应直接列举单词和例句）');
    // 词条行：序号. 词（类型）真题频次：N /音标/
    final entryLineRe = RegExp(
        r'<w:t xml:space="preserve">\d+\. [^<]+真题频次：\d+');
    final entryCount = entryLineRe.allMatches(documentXml).length;
    expect(entryCount, 3000,
        reason: 'docx 词条行应为 3000 行（序号. 词（类型）真题频次：N），实际: $entryCount');
    // 释义另起一行
    final defCount = RegExp('<w:t xml:space="preserve">释义：').allMatches(documentXml).length;
    expect(defCount, greaterThanOrEqualTo(2900),
        reason: 'docx 释义行应逐词另起一行（至少 2900），实际: $defCount');
    // 例句标注年份、按年份倒序（优先最近年份）
    expect(RegExp(r'（20\d{2}）').hasMatch(documentXml), isTrue,
        reason: 'docx 例句应标注年份');
    // 拓展词排版：'拓展词：' 独立一行，每个拓展词独立一行（word(频次): 例句），
    // 不允许旧格式"拓展词：w1(n), w2(n)"与"拓展词例句：w1(n): …；w2(n): …"挤同一行。
    final paras = RegExp(r'<w:p>.*?</w:p>', dotAll: true)
        .allMatches(documentXml)
        .map((m) => RegExp(r'<w:t xml:space="preserve">(.*?)</w:t>', dotAll: true)
            .allMatches(m.group(0)!)
            .map((x) => x.group(1)!)
            .join())
        .toList();
    expect(paras.any((t) => t.trim() == '拓展词：'), isTrue,
        reason: 'docx 应含独立 拓展词： 标题行，实际段落数: ${paras.length}');
    expect(
        paras.any((t) => t.startsWith('拓展词：') && t.length > '拓展词：'.length),
        isFalse,
        reason: '不允许旧格式"拓展词：w1(n), w2(n)"挤一行');
    expect(paras.any((t) => t.startsWith('拓展词例句：')), isFalse,
        reason: '不允许旧格式"拓展词例句："挤一行');
    // 每个段落最多一个拓展词前缀 word(nn):（多个拓展词必须按行分隔）
    final extPrefixRe = RegExp(r'(?<![a-z])[a-zA-Z]+\(\d+\):');
    final multiExtParas = paras
        .where((t) => extPrefixRe.allMatches(t).length > 1)
        .toList();
    expect(multiExtParas, isEmpty,
        reason: '不允许同一段落挤多个拓展词，违规段落: $multiExtParas');
    // 段落总量远大于词条数（每词至少 词条+释义+例句×N 段）
    final pCount = RegExp('<w:p>').allMatches(documentXml).length;
    expect(pCount, greaterThan(9000),
        reason: 'docx 段落数应大于 9000（列举排版逐行成段），实际: $pCount');
    // 打印真实拓展词排版示例：取第一个含"拓展词："标题的词条段落组
    final extTitleIdx = paras.indexWhere((t) => t.trim() == '拓展词：');
    if (extTitleIdx >= 0) {
      // ignore: avoid_print
      print('DOCX_EXT_EXAMPLE_START');
      // ignore: avoid_print
      print(paras[extTitleIdx - 1].trim());
      for (var i = extTitleIdx; i < paras.length && i < extTitleIdx + 5; i++) {
        // ignore: avoid_print
        print(paras[i].trim());
      }
      // ignore: avoid_print
      print('DOCX_EXT_EXAMPLE_END');
    }
    // 额外打印一个含例句的拓展词行示例（word(频次): （年份）例句）
    final extLineWithEx = paras.firstWhere(
      (t) => RegExp(r'^[a-zA-Z]+\(\d+\): （20\d{2}）').hasMatch(t.trim()),
      orElse: () => '',
    );
    if (extLineWithEx.isNotEmpty) {
      // ignore: avoid_print
      print('DOCX_EXT_EXAMPLE_WITH_EX: ${extLineWithEx.trim()}');
    }
    // ignore: avoid_print
    print('docx_entries=$entryCount defs=$defCount paras=$pCount '
        'bytes=${docxResult.docxBytes!.length}');

    // 保存副本供人工复核
    final tmpDir = Directory(
        r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_284ba040af294dcaaa63326645affae3\temp');
    if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
    File(p.join(tmpDir.path, 'smoke_high_freq.xlsx'))
        .writeAsBytesSync(result.xlsxBytes);
    File(p.join(tmpDir.path, 'smoke_high_freq.docx'))
        .writeAsBytesSync(docxResult.docxBytes!);
  }, timeout: const Timeout(Duration(minutes: 25)));
}
