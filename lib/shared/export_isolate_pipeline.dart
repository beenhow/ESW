/// ESW Windows 端「检测结果导出」后台流水线（全部为顶层纯函数，可跨 isolate 发送）。
///
/// 背景（本次需求）：导出检测结果时界面卡顿、顶栏出现异常条带。根因是导出全程在
/// UI isolate 上跑重活——原文标注正则逐词着色、数万个段落 XML 字符串拼接、
/// ZIP 压缩写盘、真题/教材全文句子索引与逐词例句抽取——单次几十万次正则匹配会
/// 长时间占满主线程，Flutter 无法出帧，窗口被系统判定为「未响应」，DWM 会重绘
/// 非客户区/给窗口加未响应态，表现为顶栏（自绘标题栏）在导出瞬间出现额外条带。
///
/// 因此把「数据准备（题型切分 / 例句抽取）」与「文档生成（docx/rtf/txt）」全部
/// 搬到后台 isolate：本文件只接受可发送的 Map 载荷（纯字符串 / 列表 / 映射），
/// 在 worker 内完成计算与写盘，UI isolate 只负责 await 与刷新进度。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'export_annotate_markup.dart';
import 'export_extra_table.dart';
import 'export_word_style.dart';
import 'inplace_docx_annotator.dart';

// ==========================================================================
// 载荷约定（由 windows_app 侧构建，键名在此集中说明，两端保持一致）
//
//   'outPath'       String            输出文件绝对路径（worker 内写盘）
//   'fileName'      String            被检测文档名
//   'originalText'  String            原文（标注主体）
//   'wordCatMap'    Map<String,String>  小写词 -> 分类
//   'summaryItems'  List<Map>         [{label,value,colorHex,bold}]
//   'legend'        List<Map>         [{label,count,colorHex,bold}]
//   'summaryLine'   String            纯文本汇总行（txt 使用）
//   'extend'        List<Map>         [{name,items:[{word,baseWord,originalExample,
//                                       textbookExample,gaokao:[{word,example,year}]}]}]
//   'overLimit'     List<Map>         [{name,items:[{word,posDef,originalExample}]}]
//   'srcPath'       String            原地标注的源 docx 路径
// ==========================================================================

String _escapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

Map<String, String> _stringMap(Object? raw) {
  final out = <String, String>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      if (k == null) return;
      out[k.toString()] = v?.toString() ?? '';
    });
  }
  return out;
}

List<Map> _mapList(Object? raw) {
  if (raw is List) {
    return raw.whereType<Map>().toList(growable: false);
  }
  return const <Map>[];
}

// ==========================================================================
// 一、数据准备 worker
// ==========================================================================

/// 题型切分（原文按题型标题归组 + 组内同句多词合并）的纯计算部分。
///
/// [a] 键：'text'（原文）、'words'（待查词，保留原大小写）、
/// 'baseByLower'（小写词 -> 课标原词，已由 UI 侧算好以规避跨 isolate 回调）、
/// 'mergeSameSentenceRows'（bool）。
List<Map<String, Object?>> buildExportSectionsWorker(Map<String, Object?> a) {
  final text = (a['text'] as String?) ?? '';
  final words = ((a['words'] as List?) ?? const []).map((e) => '$e').toList();
  final base = _stringMap(a['baseByLower']);
  final merge = a['mergeSameSentenceRows'] == true;

  String baseWordOf(String word) => base[word.toLowerCase()] ?? '';

  var sections = buildExtendSections(
    text: text,
    extendWords: words,
    baseWordOf: baseWordOf,
    mergeSameSentenceRows: merge,
  );
  // 原文无题型标题时降级为单组"全部"
  if (sections.isEmpty && words.isNotEmpty) {
    sections = [
      ExtendSection(
        name: '全部',
        rows: [
          for (final w in words)
            ExtendRowData(
              word: w,
              example: pickShortExample(text, w),
              baseWord: baseWordOf(w),
            ),
        ],
      ),
    ];
  }
  return [
    for (final sec in sections)
      {
        'name': sec.name,
        'rows': [
          for (final r in sec.rows)
            {'word': r.word, 'example': r.example, 'baseWord': r.baseWord},
        ],
      },
  ];
}

/// 例句抽取（教材句子索引 + 真题跨文件择优）的纯计算部分。
///
/// [a] 键：'originalText'、'textbookText'、'extendSections'（buildExportSectionsWorker
/// 产物）、'overLimitSections'、'corpus'（[{name,text}] 已选中的真题语料全文）、
/// 'posDef'（小写词 -> 词性.释义）、'isNAExtend' / 'isNAOver'（小写词 -> 名/形判定）。
Map<String, Object?> buildExportExamplesWorker(Map<String, Object?> a) {
  final originalText = (a['originalText'] as String?) ?? '';
  final textbookText = (a['textbookText'] as String?) ?? '';
  final posDef = _stringMap(a['posDef']);
  final isNAExtend = _stringMap(a['isNAExtend']);
  final isNAOver = _stringMap(a['isNAOver']);
  final extendSections = _mapList(a['extendSections']);
  final overSections = _mapList(a['overLimitSections']);
  final corpus = _mapList(a['corpus']);

  bool isNAExtendOf(String w) => isNAExtend[w.toLowerCase()] == '1';
  bool isNAOverOf(String w) => isNAOver[w.toLowerCase()] == '1';

  // 教材例句源建一次句子索引，供所有拓展词行复用
  final textbookIndex = buildSentenceIndex(textbookText);

  // 高考例句：逐真题文件建索引并提取年份（文件名前缀），为每个词收集候选，
  // 跨文件择优各取一句，保证"原文多词时每个词都有独立高考例句并标注年份"。
  final gluedLetterRe = RegExp(r'^([a-zA-Z]{3,})([A-H])$');
  final extendQueryWords = <String>{};
  for (final sec in extendSections) {
    for (final r in _mapList(sec['rows'])) {
      final word = (r['word'] as String?) ?? '';
      for (final w in word.split(' ')) {
        if (w.isEmpty) continue;
        final glued = gluedLetterRe.firstMatch(w);
        extendQueryWords
            .add((glued != null ? glued.group(1)! : w).toLowerCase());
      }
    }
  }
  final gaokaoByWord =
      <String, List<({String example, String year, bool isPhrase})>>{
    for (final w in extendQueryWords)
      w: <({String example, String year, bool isPhrase})>[],
  };
  final fileWordRe = RegExp(r'[a-zA-Z]+');
  final yearPrefixRe = RegExp(r'^(\d{4})');
  for (final cf in corpus) {
    final fileText = (cf['text'] as String?) ?? '';
    if (fileText.isEmpty) continue;
    final year = yearPrefixRe.firstMatch((cf['name'] as String?) ?? '')?.group(1) ?? '';
    final hitQueries = <String>{};
    for (final m in fileWordRe.allMatches(fileText)) {
      final raw = m.group(0)!;
      final glued = gluedLetterRe.firstMatch(raw);
      final q = (glued != null ? glued.group(1)! : raw).toLowerCase();
      if (extendQueryWords.contains(q)) hitQueries.add(q);
    }
    if (hitQueries.isEmpty) continue;
    final idx = buildSentenceIndex(fileText);
    final candsByWord = collectSentenceCandidates(idx, hitQueries);
    for (final q in hitQueries) {
      final cands = candsByWord[q];
      final ex = (cands != null && cands.isNotEmpty)
          ? pickBestCandidate(cands, q)
          : '';
      if (ex.isNotEmpty) {
        gaokaoByWord[q]!.add((example: ex, year: year, isPhrase: false));
      }
      final ph = pickPhraseFromIndex(idx, [q]);
      if (ph.isNotEmpty && ph != ex) {
        gaokaoByWord[q]!.add((example: ph, year: year, isPhrase: true));
      }
    }
  }

  final hanRe = RegExp(r'[\u4e00-\u9fff]');
  final enWordRe = RegExp(r'[a-zA-Z]+');
  int wordCountOfUsage(String s) => enWordRe.allMatches(s).length;
  int gaokaoScore(String s) {
    var score = 0;
    if (!hanRe.hasMatch(s)) score += 1000;
    if (!s.contains('_')) score += 100;
    if (enWordRe.allMatches(s).length >= 3) score += 10;
    score -= (s.length > 200 ? 200 : s.length) ~/ 5;
    return score;
  }

  List<Map<String, Object?>> bestGaokaoFor(String w, bool isNounAdj) {
    final glued = gluedLetterRe.firstMatch(w);
    final q = (glued != null ? glued.group(1)! : w).toLowerCase();
    final cands = gaokaoByWord[q] ??
        const <({String example, String year, bool isPhrase})>[];
    if (cands.isEmpty) return const [];
    final sentences = cands.where((c) => !c.isPhrase).toList();
    final phrases = cands.where((c) => c.isPhrase).toList();
    List<({String example, String year, bool isPhrase})> pool;
    if (isNounAdj) {
      final goodSentences =
          sentences.where((c) => wordCountOfUsage(c.example) <= 12).toList();
      pool = goodSentences.isNotEmpty
          ? goodSentences
          : (phrases.isNotEmpty ? phrases : sentences);
    } else {
      pool = sentences.isNotEmpty ? sentences : phrases;
    }
    if (pool.isEmpty) return const [];
    final best = pool.reduce((x, y) =>
        gaokaoScore(y.example) > gaokaoScore(x.example) ? y : x);
    return [
      {'word': w, 'example': best.example, 'year': best.year},
    ];
  }

  String resolveUsageFromIndex(String word) {
    final ws = word.split(' ').where((w) => w.isNotEmpty).toList();
    final sentence = pickFullSentenceFromText(
      textbookText,
      ws,
      fallbackToFirst: true,
    );
    if (sentence.isNotEmpty) return sentence;
    return pickPhraseFromIndex(textbookIndex, ws);
  }

  final extendOut = <Map<String, Object?>>[];
  for (final sec in extendSections) {
    final items = <Map<String, Object?>>[];
    for (final r in _mapList(sec['rows'])) {
      final word = (r['word'] as String?) ?? '';
      final isNA = isNAExtendOf(word);
      final gaokaoItems = <Map<String, Object?>>[];
      for (final w in word.split(' ')) {
        if (w.isNotEmpty) gaokaoItems.addAll(bestGaokaoFor(w, isNA));
      }
      items.add({
        'word': word,
        'baseWord': (r['baseWord'] as String?) ?? '',
        'originalExample': resolveUsageText(
          originalText,
          (r['example'] as String?) ?? '',
          word,
          isNA,
        ),
        'gaokao': gaokaoItems,
        'textbookExample': resolveUsageFromIndex(word),
      });
    }
    extendOut.add({'name': sec['name'], 'items': items});
  }

  final overOut = <Map<String, Object?>>[];
  for (final sec in overSections) {
    final items = <Map<String, Object?>>[];
    for (final r in _mapList(sec['rows'])) {
      final word = (r['word'] as String?) ?? '';
      final def = posDef[word.toLowerCase()] ?? '';
      items.add({
        'word': word,
        'posDef': def,
        'originalExample': resolveUsageText(
          originalText,
          (r['example'] as String?) ?? '',
          word,
          isNAOverOf(word),
        ),
      });
    }
    overOut.add({'name': sec['name'], 'items': items});
  }

  return {'extend': extendOut, 'overLimit': overOut};
}

// ==========================================================================
// 二、DOCX 段落拼接（与原主线程实现逐字节等价）
// ==========================================================================

String _paragraph(String text, {bool bold = false}) {
  final escaped = _escapeXml(text);
  return '<w:p><w:r><w:rPr>${bold ? '<w:b/>' : ''}</w:rPr>'
      '<w:t xml:space="preserve">$escaped</w:t></w:r></w:p>';
}

String _summaryParagraph(List<Map> items) {
  final runs = <String>[];
  for (var i = 0; i < items.length; i++) {
    if (i > 0) runs.add(docxRunXml(' | ', '000000'));
    final it = items[i];
    runs.add(docxRunXml(
      '${it['label']}: ${it['value']}',
      (it['colorHex'] as String?) ?? '000000',
      bold: it['bold'] == true,
    ));
  }
  return '<w:p>${runs.join('')}</w:p>';
}

String _legendParagraph(List<Map> legend) {
  final runs = <String>[];
  for (var i = 0; i < legend.length; i++) {
    if (i > 0) runs.add(docxRunXml('；', '000000'));
    final seg = legend[i];
    runs.add(docxRunXml(
      '${seg['label']}（${seg['count']} 词）',
      (seg['colorHex'] as String?) ?? '000000',
      bold: seg['bold'] == true,
    ));
  }
  return '<w:p>${runs.join('')}</w:p>';
}

List<String> _preambleParagraphs(Map<String, Object?> p) {
  final summaryItems = _mapList(p['summaryItems']);
  final legend = _mapList(p['legend']);
  return [
    _paragraph('ESW 课标词检测导出', bold: true),
    _paragraph('文件名: ${(p['fileName'] as String?) ?? ''}'),
    _summaryParagraph(summaryItems),
    _paragraph('【标注说明】', bold: true),
    _legendParagraph(legend),
  ];
}

List<String> _detailParagraphs(Map<String, Object?> p) {
  final bodyParts = <String>[];
  final extend = _mapList(p['extend']);
  final overLimit = _mapList(p['overLimit']);

  bodyParts.add(_paragraph('【拓展词明细】', bold: true));
  if (extend.isEmpty) {
    bodyParts.add(_paragraph('本套题无真题词频低于 400 次的拓展词'));
  } else {
    var firstSection = true;
    for (final sec in extend) {
      final items = _mapList(sec['items']);
      if (items.isEmpty) continue; // 无词的题型区块不输出
      if (!firstSection) bodyParts.add(_paragraph('')); // 题型之间空一行
      firstSection = false;
      bodyParts.add(_paragraph('${sec['name'] ?? ''}')); // 题型名单独一行
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final no = i + 1;
        final word = (it['word'] as String?) ?? '';
        bodyParts.add(_paragraph('$no. $word'));
        bodyParts.add(_paragraph('课标原词：${(it['baseWord'] as String?) ?? ''}'));
        final boldWords = word.split(' ');
        bodyParts.add(docxParagraphWithBoldWordsXml(
          '原文用法：${(it['originalExample'] as String?) ?? ''}',
          boldWords,
        ));
        final gaokao = _mapList(it['gaokao']);
        if (gaokao.isEmpty) {
          bodyParts.add(_paragraph('高考用法：'));
        } else {
          for (final g in gaokao) {
            final prefix =
                boldWords.length > 1 ? '高考用法·${g['word']}：' : '高考用法：';
            final year = (g['year'] as String?) ?? '';
            bodyParts.add(docxParagraphWithBoldWordsXml(
              '$prefix${(g['example'] as String?) ?? ''}'
              '${year.isNotEmpty ? '（$year）' : ''}',
              ['${g['word'] ?? ''}'],
            ));
          }
        }
        final tb = (it['textbookExample'] as String?) ?? '';
        bodyParts.add(docxParagraphWithBoldWordsXml(
          '教材用法：${tb.isEmpty ? '无' : tb}',
          boldWords,
        ));
      }
    }
  }

  bodyParts.add(_paragraph('【超标词】', bold: true));
  if (overLimit.isEmpty) {
    bodyParts.add(_paragraph('本套题未检测到超标词'));
  } else {
    var firstOverSection = true;
    for (final sec in overLimit) {
      final items = _mapList(sec['items']);
      if (items.isEmpty) continue;
      if (!firstOverSection) bodyParts.add(_paragraph(''));
      firstOverSection = false;
      bodyParts.add(_paragraph('${sec['name'] ?? ''}'));
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final no = i + 1;
        final word = (it['word'] as String?) ?? '';
        bodyParts.add(_paragraph('$no. $word'));
        bodyParts.add(_paragraph((it['posDef'] as String?) ?? ''));
        final overBold = <String>[word];
        final glued = RegExp(r'^([a-zA-Z]{3,})([A-H])$').firstMatch(word);
        if (glued != null) overBold.add(glued.group(1)!);
        bodyParts.add(docxParagraphWithBoldWordsXml(
          (it['originalExample'] as String?) ?? '',
          overBold,
        ));
      }
    }
  }
  return bodyParts;
}

Uint8List _zipDocx(String documentXml) {
  const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';
  const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';

  final documentBytes = utf8.encode(documentXml);
  final archive = Archive();
  // 必须用 ArchiveFile(name, 字节长度, 字节) 构造：zip 中记录的 uncompressed
  // size 需为 UTF-8 字节数，中文内容才不会在部分阅读器里被截断。
  archive.addFile(ArchiveFile(
      '[Content_Types].xml', utf8.encode(contentTypes).length, utf8.encode(contentTypes)));
  archive.addFile(ArchiveFile(
      '_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)));
  archive.addFile(
      ArchiveFile('word/document.xml', documentBytes.length, documentBytes));
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw Exception('DOCX 生成失败');
  return Uint8List.fromList(encoded);
}

// ==========================================================================
// 三、各格式 worker（在后台 isolate 内执行：构建 + 写盘）
// ==========================================================================

/// docx 重新生成模式：标题 + 汇总 + 标注说明 + 带标注全文 + 明细。
/// 返回写入字节数。
int writeDetectionDocxWorker(Map<String, Object?> p) {
  final originalText = (p['originalText'] as String?) ?? '';
  final wordCatMap = _stringMap(p['wordCatMap']);

  final bodyParts = <String>[];
  bodyParts.addAll(_preambleParagraphs(p));
  bodyParts.add(_paragraph('带标注全文', bold: true));
  bodyParts.add(docxAnnotatedParagraphXml(originalText, wordCatMap));
  bodyParts.addAll(_detailParagraphs(p));

  final documentXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\n'
      '<w:body>\n'
      '${bodyParts.join('\n')}\n'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>\n'
      '</w:body>\n</w:document>';

  final bytes = _zipDocx(documentXml);
  File((p['outPath'] as String?) ?? '').writeAsBytesSync(bytes);
  return bytes.length;
}

/// docx 原地标注模式：源 docx 只改写 word/document.xml，保留原排版。
/// 返回写入字节数。
int writeInplaceDocxWorker(Map<String, Object?> p) {
  final srcPath = (p['srcPath'] as String?) ?? '';
  final srcBytes = File(srcPath).readAsBytesSync();
  final appendix = <String>[
    '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
    ..._detailParagraphs(p),
  ];
  final bytes = annotateDocxBytes(
    srcBytes: srcBytes,
    catByLower: _stringMap(p['wordCatMap']),
    preambleParagraphsXml: _preambleParagraphs(p),
    appendixParagraphsXml: appendix,
  );
  File((p['outPath'] as String?) ?? '').writeAsBytesSync(bytes);
  return bytes.length;
}

/// txt：标题 + 统计 + 标注说明 + 原文 + 拓展词明细（纯文本，无颜色）。
int writeDetectionTxtWorker(Map<String, Object?> p) {
  final originalText = (p['originalText'] as String?) ?? '';
  final sb = StringBuffer();
  sb.writeln('ESW 课标词检测导出');
  sb.writeln('文件名: ${(p['fileName'] as String?) ?? ''}');
  sb.writeln((p['summaryLine'] as String?) ?? '');
  sb.writeln('【标注说明】');
  sb.writeln(
    '${exportAnnotateLegend()}（Word / PDF 导出按此逐词标注，并逐类给出统计词数）'
    '本文本格式仅保留原文，不做颜色标注。',
  );
  sb.writeln('【带标注全文】');
  sb.writeln(originalText);
  sb.writeln('【拓展词明细】');
  sb.writeln(_extendDetailPlain(_mapList(p['extend'])));
  sb.writeln();
  sb.writeln('【超标词】');
  sb.writeln(_overLimitPlain(_mapList(p['overLimit'])));
  final text = sb.toString();
  File((p['outPath'] as String?) ?? '')
      .writeAsStringSync(text, encoding: utf8);
  return text.length;
}

String _extendDetailPlain(List<Map> sections) {
  if (sections.isEmpty) return '本套题无真题词频低于 400 次的拓展词';
  final sb = StringBuffer();
  var first = true;
  for (final sec in sections) {
    final items = _mapList(sec['items']);
    if (items.isEmpty) continue;
    if (!first) sb.writeln();
    first = false;
    sb.writeln('${sec['name'] ?? ''}');
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final no = i + 1;
      final word = (it['word'] as String?) ?? '';
      sb.writeln('$no. $word');
      sb.writeln('课标原词：${(it['baseWord'] as String?) ?? ''}');
      sb.writeln('原文用法：${(it['originalExample'] as String?) ?? ''}');
      final gaokao = _mapList(it['gaokao']);
      if (gaokao.isEmpty) {
        sb.writeln('高考用法：');
      } else {
        final words = word.split(' ');
        for (final g in gaokao) {
          final prefix = words.length > 1 ? '高考用法·${g['word']}：' : '高考用法：';
          final year = (g['year'] as String?) ?? '';
          sb.writeln('$prefix${(g['example'] as String?) ?? ''}'
              '${year.isNotEmpty ? '（$year）' : ''}');
        }
      }
      final tb = (it['textbookExample'] as String?) ?? '';
      sb.writeln('教材用法：${tb.isEmpty ? '无' : tb}');
    }
  }
  return sb.toString();
}

String _overLimitPlain(List<Map> sections) {
  if (sections.isEmpty) return '本套题未检测到超标词';
  final sb = StringBuffer();
  var first = true;
  for (final sec in sections) {
    final items = _mapList(sec['items']);
    if (items.isEmpty) continue;
    if (!first) sb.writeln();
    first = false;
    sb.writeln('${sec['name'] ?? ''}');
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final no = i + 1;
      sb.writeln('$no. ${(it['word'] as String?) ?? ''}');
      sb.writeln((it['posDef'] as String?) ?? '');
      sb.writeln((it['originalExample'] as String?) ?? '');
    }
  }
  return sb.toString();
}

/// .doc（RTF 包装）：标题 + 统计 + 标注说明 + 带颜色全文 + 明细，latin1 写盘。
int writeDetectionRtfWorker(Map<String, Object?> p) {
  final originalText = (p['originalText'] as String?) ?? '';
  final wordCatMap = _stringMap(p['wordCatMap']);
  final summaryItems = _mapList(p['summaryItems']);
  final legend = _mapList(p['legend']);

  int colorIdx(String cat) {
    final idx = ExportCategory.all.indexOf(cat);
    return idx < 0 ? 0 : idx + 1;
  }

  String colorTableLine() {
    final buf = StringBuffer(r'\red0\green0\blue0;');
    for (final hex in exportPaletteHex()) {
      final h = hex.replaceAll('#', '').toUpperCase();
      final r = int.parse(h.substring(0, 2), radix: 16);
      final g = int.parse(h.substring(2, 4), radix: 16);
      final b = int.parse(h.substring(4, 6), radix: 16);
      buf.write('\\red$r\\green$g\\blue$b;');
    }
    return buf.toString();
  }

  String esc(String s) {
    final sb = StringBuffer();
    for (final c in s.codeUnits) {
      if (c == 0x5C) {
        sb.write('\\\\');
      } else if (c == 0x7B) {
        sb.write('\\{');
      } else if (c == 0x7D) {
        sb.write('\\}');
      } else if (c == 0x09) {
        sb.write('  ');
      } else if (c == 0x0D) {
        sb.write(' ');
      } else if (c < 128) {
        sb.writeCharCode(c);
      } else {
        sb.write('\\u$c?');
      }
    }
    return sb.toString();
  }

  String multiPar(String s) => s.replaceAll('\n', '\\par ');

  int sumColorIdx(String hex) {
    final h = hex.replaceAll('#', '').toUpperCase();
    final idx = exportPaletteHex().indexOf(h);
    return idx < 0 ? 0 : idx + 1;
  }

  List<String> legendRtfSegments() {
    final out = <String>[];
    for (final seg in legend) {
      final label = (seg['label'] as String?) ?? '';
      final idx = colorIdx(label);
      final text = esc('$label（${seg['count']} 词）');
      if (seg['bold'] != true || idx == 0) {
        out.add(text);
      } else {
        out.add('{\\cf$idx\\b $text}');
      }
    }
    return out;
  }

  String summaryRtf() {
    final buf = StringBuffer();
    for (var i = 0; i < summaryItems.length; i++) {
      if (i > 0) buf.write(esc(' | '));
      final it = summaryItems[i];
      final text = esc('${it['label']}: ${it['value']}');
      final idx = sumColorIdx((it['colorHex'] as String?) ?? '000000');
      if (idx == 0) {
        buf.write(text);
      } else {
        buf.write(it['bold'] == true ? '{\\cf$idx\\b $text}' : '{\\cf$idx $text}');
      }
    }
    return buf.toString();
  }

  String oneLineRtf(String line) {
    final regex = RegExp(r'[a-zA-Z]+');
    final runs = <String>[];
    int lastEnd = 0;
    for (final m in regex.allMatches(line)) {
      final word = m.group(0)!;
      final cat = wordCatMap[word.toLowerCase()];
      final plain = line.substring(lastEnd, m.start);
      if (plain.isNotEmpty) runs.add(esc(plain));
      final spec = exportWordStyleOf(cat);
      if (spec == null) {
        runs.add(esc(word));
      } else {
        final idx = colorIdx(cat!);
        runs.add(spec.bold
            ? '{\\cf$idx\\b ${esc(word)}}'
            : '{\\cf$idx ${esc(word)}}');
      }
      lastEnd = m.end;
    }
    final tail = line.substring(lastEnd);
    if (tail.isNotEmpty) runs.add(esc(tail));
    return '${runs.join('')}\\par';
  }

  final sb = StringBuffer();
  // \fonttbl 与 \colortbl 是目的控制字，必须用 {...} 成组包裹，否则 WPS/Word
  // 解析失败会把整份文档当作空文档打开。
  sb.writeln(
    '{\\rtf1\\ansi\\ansicpg936\\deff0'
    '{\\fonttbl{\\f0\\fnil\\fcharset134 ${esc('宋体')};}}'
    '{\\colortbl;${colorTableLine()}}',
  );
  sb.writeln('\\viewkind4\\uc1\\pard\\lang2052\\fs24');
  sb.writeln('{\\b ${esc('ESW 课标词检测导出')}\\b0}\\par');
  sb.writeln('${esc('文件名: ${(p['fileName'] as String?) ?? ''}')}\\par');
  sb.writeln('${summaryRtf()}\\par');
  sb.writeln('{\\b ${esc('【标注说明】')}\\b0}\\par');
  sb.writeln('${legendRtfSegments().join(esc('；'))}\\par');
  for (final line in originalText.split('\n')) {
    sb.writeln(oneLineRtf(line));
  }
  sb.writeln('\\page');
  sb.writeln('{\\b ${esc('拓展词明细')}\\b0}\\par');
  sb.writeln(multiPar(esc(_extendDetailPlain(_mapList(p['extend'])))));
  sb.writeln('{\\b ${esc('超标词')}\\b0}\\par');
  sb.writeln(multiPar(esc(_overLimitPlain(_mapList(p['overLimit'])))));
  sb.write('}');
  final text = sb.toString();
  File((p['outPath'] as String?) ?? '')
      .writeAsStringSync(text, encoding: latin1);
  return text.length;
}
