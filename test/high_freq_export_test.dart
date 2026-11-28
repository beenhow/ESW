// 冒烟测试：验证导出高频 xlsx 生成（词条数量、归并、例句年份、无 [v:43/n:57] 标记、
// 课标词全量保留、课标短语整条统计、Excel 列结构）
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';

import 'package:esw/high_freq_export.dart';
import 'package:esw/shared/phrase_stats.dart';
import 'package:esw/shared/word_family.dart';

void main() {
  test('原词未出现时，拓展词频次仍计入课标原词', () async {
    // 语料里只有变形/派生形式时，词条仍应是课标原词 develop，
    // 频次为全部拓展词之和，而不是把某个变形词单独列一条。
    final temp = Directory.systemTemp.createTempSync('esw_orphan_');
    try {
      File(p.join(temp.path, 'sample.txt'))
          .writeAsStringSync('developing developed developments');
      const stdRaw = '{"develop":{"extensions":'
          '["developing","developed","developments"]}}';
      final res = await HighFreqExporter.export(
        corpusDir: temp.path,
        standardWordsRaw: stdRaw,
        dbPath: p.join(Directory.current.path, 'assets', 'ecdict.db'),
        extendBaseMapRaw: jsonEncode(<String, String>{
          'developing': 'develop',
          'developed': 'develop',
          'developments': 'develop',
        }),
        extendWordsRaw:
            jsonEncode(<String>['developing', 'developed', 'developments']),
      );
      final xl = Excel.decodeBytes(res.xlsxBytes);
      final rows = xl['高考高频词表']
          .rows
          .map((r) => r.map((c) => c?.value?.toString() ?? '').toList())
          .toList();
      final row = rows.firstWhere((r) => r[1] == 'develop',
          orElse: () => <String>[]);
      expect(row, isNotEmpty, reason: '词条应显示课标原词 develop');
      expect(row[3], '3', reason: '频次应为三个拓展词之和');
      expect(row[11], contains('developing(1)'));
      expect(row[11], contains('developed(1)'));
      expect(row[11], contains('developments(1)'));
      // 变形形式不得再独立成条
      for (final w in <String>['developing', 'developed', 'developments']) {
        expect(rows.where((r) => r[1] == w), isEmpty, reason: '$w 不应独立成条');
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('wordLimit 控制导出词数（1000 / 2000 / 3000 选项）', () async {
    final temp = Directory.systemTemp.createTempSync('esw_limit_');
    try {
      File(p.join(temp.path, 'sample.txt'))
          .writeAsStringSync('alpha alpha beta beta beta gamma');
      const stdRaw = '{"alpha":{},"beta":{},"gamma":{}}';
      Future<HighFreqExportResult> run(int? limit) => HighFreqExporter.export(
            corpusDir: temp.path,
            standardWordsRaw: stdRaw,
            dbPath: p.join(Directory.current.path, 'assets', 'ecdict.db'),
            format: 'xlsx',
            wordLimit: limit ?? 3000,
          );
      expect((await run(null)).exportedWords, 3, reason: '默认取前 3000，语料不足时全量');
      expect((await run(2)).exportedWords, 2, reason: '选择 2 词时只导出前 2');
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('TV 与 television 合并统计', () async {
    final temp = Directory.systemTemp.createTempSync('esw_tv_');
    try {
      File(p.join(temp.path, 'sample.txt'))
          .writeAsStringSync('TV TV television');
      final res = await HighFreqExporter.export(
        corpusDir: temp.path,
        standardWordsRaw: '{"television":{}}',
        dbPath: p.join(Directory.current.path, 'assets', 'ecdict.db'),
        format: 'xlsx',
      );
      expect(res.exportedWords, 1, reason: 'TV 不应再单独成条');
      final xl = Excel.decodeBytes(res.xlsxBytes);
      final rows = xl['高考高频词表']
          .rows
          .map((r) => r.map((c) => c?.value?.toString() ?? '').toList())
          .toList();
      final row = rows.firstWhere((r) => r[1] == 'television',
          orElse: () => <String>[]);
      expect(row, isNotEmpty);
      expect(row[3], '3', reason: 'TV 的 2 次应并入 television');
      expect(rows.where((r) => r[1] == 'TV'), isEmpty);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('英美拼写合并统计（color / colour）', () async {
    final temp = Directory.systemTemp.createTempSync('esw_uk_');
    try {
      File(p.join(temp.path, 'sample.txt'))
          .writeAsStringSync('color colour colours color');
      final res = await HighFreqExporter.export(
        corpusDir: temp.path,
        standardWordsRaw: '{"color":{},"colour":{"extensions":["colours"]}}',
        dbPath: p.join(Directory.current.path, 'assets', 'ecdict.db'),
        format: 'xlsx',
      );
      expect(res.exportedWords, 1, reason: 'color / colour 不应分成两条');
      final xl = Excel.decodeBytes(res.xlsxBytes);
      final rows = xl['高考高频词表']
          .rows
          .map((r) => r.map((c) => c?.value?.toString() ?? '').toList())
          .toList();
      final row = rows.firstWhere((r) => r[1] == 'color',
          orElse: () => <String>[]);
      expect(row, isNotEmpty, reason: '规范形应为美式拼写 color');
      expect(row[3], '4', reason: 'color 2 + colour 1 + colours 1 应合并为 4');
      expect(rows.where((r) => r[1] == 'colour'), isEmpty);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('export high freq xlsx smoke', () async {
    // 全部输入取自项目内置资产，不依赖本机外部真题目录 / 用户配置目录：
    //  - 语料：assets/gaokao/txt（内置 119 套真题）
    //  - 词典：assets/standard_words.json + assets/ecdict.db
    final root = Directory.current.path;
    final corpusDir = p.join(root, 'assets', 'gaokao', 'txt');
    final stdRaw =
        File(p.join(root, 'assets', 'standard_words.json')).readAsStringSync();
    final dbPath = p.join(root, 'assets', 'ecdict.db');
    expect(Directory(corpusDir).existsSync(), isTrue,
        reason: '内置真题目录 assets/gaokao/txt 应存在');
    expect(File(dbPath).existsSync(), isTrue,
        reason: 'assets/ecdict.db 应随仓库提供');

    final sw = Stopwatch()..start();
    // 词库拓展词映射：直接取课标词库声明的 extensions（项目内置资产，
    // 不读取本机 %LOCALAPPDATA% 下的用户配置）。
    final stdJson = jsonDecode(stdRaw) as Map<String, dynamic>;
    final ebmMerged = <String, String>{};
    final ewAll = <String>{};
    for (final entry in stdJson.entries) {
      final meta = entry.value;
      if (meta is! Map) continue;
      final exts = meta['extensions'];
      if (exts is! List) continue;
      final base = entry.key.toLowerCase();
      for (final ex in exts) {
        final le = ex.toString().trim().toLowerCase();
        if (le.isEmpty || le == base) continue;
        ewAll.add(le);
        ebmMerged.putIfAbsent(le, () => base);
      }
    }
    expect(ewAll, isNotEmpty, reason: '课标词库应声明拓展词');
    expect(ebmMerged.containsKey('ind'), isFalse,
        reason: 'ind 不在课标拓展词集合，白名单过滤后必须剔除');
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
    expect(result.corpusFileCount, 119,
        reason: '语料应恰好为内置 119 套真题');
    final exported = result.exportedWords;
    expect(exported, greaterThan(2500),
        reason: '内置 119 套真题应覆盖绝大多数高频课标词');
    expect(exported, lessThanOrEqualTo(3000), reason: '词表上限为 3000');
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
    expect(rows.length, exported + 1, reason: '表头+全部词行');

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
    expect(dataRows.length, exported, reason: '数据行数应等于导出词数');
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

    // ---- 需求：非专有课标词一律保留（代词/助动词/数词/大小写同形普通词） ----
    // 专有名词（America/London/Monday/January 等，category=专有词）按新口径
    // 不计入高频导出，见下方单独断言。
    for (final w in [
      'china', 'march', 'may', 'miss',
      'first', 'second', 'third', 'twentieth',
      'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us',
      'them', 'my', 'your', 'his', 'its', 'our', 'their',
      'be', 'am', 'is', 'are', 'was', 'were', 'been', 'being',
      'do', 'did', 'have', 'has', 'had',
      'can', 'could', 'might', 'must', 'shall', 'should', 'will', 'would',
      'mr', 'mrs', 'ms', 'ok',
    ]) {
      expect(entryNames.contains(w) || extWordsInTable.contains(w), isTrue,
          reason: '课标词 $w 不应被剔除（词条或拓展词列应出现）');
    }
    // 内置专有词参与高频排名（用户 2026-11-27 口径）：
    // 用户自建专有词不在课标库内，仍不参与。
    for (final w in ['america', 'monday', 'china']) {
      expect(entryNames.contains(w) || extWordsInTable.contains(w), isTrue,
          reason: '内置专有词 $w 应参与高频排名');
    }
    // 星期/月份/序数词的清理回执已废弃，必须为空
    expect(result.calendarOrdinalExcluded, isEmpty,
        reason: '固定排除集已移除，回执应为空');
    // ignore: avoid_print
    print('calendarOrdinalExcluded=${result.calendarOrdinalExcluded.length}');

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
      expect({'初中', '必修', '选修', '课标词', '拓展词', '专有词'}.contains(t), isTrue,
          reason: '类型列值非法: $t');
    }

    // ---- 既有回归：拓展词归并 / 缩略脏拓展词 ----
    // 缩略/机构脏拓展词
    for (final ext in ['nots', 'eco', 'tue']) {
      expect(entryNames.contains(ext), isFalse,
          reason: '脏拓展词 $ext 不得作为独立词条');
      expect(extWordsInTable.contains(ext), isFalse,
          reason: '$ext 不得出现在拓展词列');
    }
    expect(result.cleanedExtWords.toSet(), contains('wasn'),
        reason: '课标词库把 wasn 声明为 be 的拓展词，属缩约脏映射，应剔除并记录，'
            '实际: ${result.cleanedExtWords}');

    // 课标短语整条统计与展示（according to 不拆开）
    expect(entryNames.contains('according to'), isTrue,
        reason: '课标短语 according to 应按整条成词条');
    // o'clock 单独成条，不再归并到 clock
    expect(entryNames.contains("o'clock"), isTrue,
        reason: "o'clock 应单独成条");
    final clockRow =
        dataRows.where((r) => r[1].trim().toLowerCase() == 'clock').toList();
    expect(clockRow.isEmpty || !clockRow.first[11].toLowerCase().contains("o'clock"),
        isTrue,
        reason: "clock 的拓展词列表不得包含 o'clock");
    // 归并成员跟在词根词后面展示（program 跟随主条 programme）
    final programRow =
        dataRows.firstWhere((r) => r[1].trim().toLowerCase() == 'programme');
    expect(programRow[11].toLowerCase().contains('program'), isTrue,
        reason: 'program 应作为 programme 的归并成员展示，实际: ${programRow[11]}');

    // 同名专有词（March/march）：语料里专有写法占多数时，词条名与类型按专有词
    // 展示，频次为大小写合并数；不再作为 march 的成员重复展示。
    expect(entryNames.contains('march'), isTrue,
        reason: 'march/March 应导出为一条');
    final marchRow =
        dataRows.firstWhere((r) => r[1].trim().toLowerCase() == 'march');
    expect(marchRow[1].trim(), 'March',
        reason: 'March 写法占多数时词条名应显示 March');
    expect(marchRow[2].trim(), '专有词',
        reason: 'March 词条类型应为专有词');
    expect(marchRow[11].contains('March'), isFalse,
        reason: 'March 不应再作为成员重复展示');
    final chinaRow =
        dataRows.firstWhere((r) => r[1].trim().toLowerCase() == 'china');
    expect(chinaRow[1].trim(), 'China',
        reason: 'China 写法占多数时词条名应显示 China');
    expect(chinaRow[2].trim(), '专有词',
        reason: 'China 词条类型应为专有词');

    // 专有词：课标词保留（olympic 在课标表内），表外专有词仍排除
    expect(entryNames.contains('olympic'), isTrue,
        reason: '课标词 olympic 不应被专有词启发式剔除');
    for (final w in ['beijing', 'londoners']) {
      expect(entryNames.contains(w), isFalse,
          reason: '表外专有词 $w 不应独立成词条');
    }
    expect(result.nonHeadCapsExcluded.contains('beijing'), isTrue,
        reason: '清理回执应含表外非句首大写专有词 beijing，实际: ${result.nonHeadCapsExcluded.length} 项');

    // report 归并（reporter 未在课标词库 extensions 中声明，按白名单口径不参与归并）
    expect(entryNames.contains('report'), isTrue,
        reason: '内置语料应覆盖高频课标词 report');
    // 已归并拓展词不得独立成条（said/says/sayings）
    for (final ext in ['said', 'says', 'sayings']) {
      expect(entryNames.contains(ext), isFalse,
          reason: '已归并拓展词 $ext 不得作为独立词条');
    }

    // ---- 需求2：Excel 列结构抽查 ----
    // 每行序号连续、单词列非空、频次列为数字、释义列基本非空（前 100 行抽查）
    var emptyDefinition = 0;
    for (var i = 0; i < 100; i++) {
      final r = dataRows[i];
      expect(r[0].trim(), '${i + 1}', reason: '第 ${i + 1} 行序号应连续');
      expect(r[1].trim(), isNotEmpty, reason: '单词列不应为空');
      expect(int.tryParse(r[3].trim()), isNotNull,
          reason: '真题频次列应为数字: ${r[3]}');
      // 短语（according to 等）在 ecdict 中无独立词条，允许释义为空
      if (r[6].trim().isEmpty) emptyDefinition++;
    }
    expect(emptyDefinition, lessThanOrEqualTo(10),
        reason: '前 100 行空释义过多（短语/功能词最多 10 条），实际 $emptyDefinition');

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

    // 拓展词必须全部在界面词库集合内（内置补充映射 practises→practice、
    // 同义词 tv/tvs→television 属代码内置规则，不写用户词库，需一并允许）
    final allowedExt = <String>{
      ...ewAll,
      ...builtinExtendBase.keys,
      ...builtinWordAliases.keys,
      // 英美拼写（programme/colour/organise 等）作为词根成员展示
      ...buildSpellingAliases(stdJson.keys).keys,
      // 大小写异义词的规范小写形（china/march/may/miss/ok）作为词条名
      ...buildCaseVariantGroups(stdJson.keys).keys,
    };
    final outsideExt =
        extWordsInTable.where((w) => !allowedExt.contains(w)).toSet();
    expect(outsideExt, isEmpty,
        reason: '导出拓展词必须全部在界面词库集合或内置映射内，多余词: $outsideExt');

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
    expect(docxResult.exportedWords, exported,
        reason: 'docx 口径与 xlsx 一致');
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
    expect(entryCount, exported,
        reason: 'docx 词条行数应等于导出词数（序号. 词（类型）真题频次：N），实际: $entryCount');
    // 释义另起一行
    final defCount = RegExp('<w:t xml:space="preserve">释义：').allMatches(documentXml).length;
    expect(defCount, greaterThanOrEqualTo(exported - 300),
        reason: 'docx 释义行应逐词另起一行，实际: $defCount');
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
    expect(pCount, greaterThan(exported * 2),
        reason: 'docx 段落数应远大于词条数（列举排版逐行成段），实际: $pCount');
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

    // 保存副本供人工复核（系统临时目录，不写入仓库/本机固定路径）
    final tmpDir = Directory.systemTemp.createTempSync('esw_high_freq_');
    File(p.join(tmpDir.path, 'smoke_high_freq.xlsx'))
        .writeAsBytesSync(result.xlsxBytes);
    File(p.join(tmpDir.path, 'smoke_high_freq.docx'))
        .writeAsBytesSync(docxResult.docxBytes!);
    // ignore: avoid_print
    print('SMOKE_OUTPUT_DIR=${tmpDir.path}');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
