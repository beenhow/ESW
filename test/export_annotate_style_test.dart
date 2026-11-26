// 导出标注样式守卫测试（用户口径：Word 导出不加底纹，底纹只用于 PDF）。
//
// 覆盖：
//   1) 七类规范表（字色 / 字重 / 底纹色）防漂移；
//   2) DOCX 重生成路径（docxAnnotatedParagraphXml）：XML 无 w:shd / w:highlight，
//      字色与加粗仍按七类规范；
//   3) DOCX 原地标注路径（annotateDocxBytes）：标注后 XML 无 w:shd / w:highlight，
//      且源文档中被标注 run 上原有的 highlight / shd 也被清除；
//   4) PDF 路径（pdfAnnotatedLine）：原文标注带极淡同色底纹 + 规范字色字重。
//
// 同时把三份真实样例产物写到 build/export_verify/ 供人工用 Word / PDF 阅读器打开核验。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pwpdf;
import 'package:pdf/widgets.dart' as pw;

import 'package:esw/shared/export_annotate_markup.dart';
import 'package:esw/shared/export_word_style.dart';
import 'package:esw/shared/inplace_docx_annotator.dart';

/// 规范表期望值：分类 -> (字色, 加粗, 底纹色)
/// 加粗为规范表历史值（Android 沿用）；Windows 方案一导出时统一关闭加粗。
const Map<String, (String, bool, String)> kExpect = {
  '初中课标词': ('000000', true, 'D9D9D9'),
  '必修课标词': ('0B3D91', true, 'D6E0F5'),
  '选修课标词': ('00B0F0', false, 'D6F0FC'),
  '拓展词': ('006400', true, 'D6E9D7'),
  '超标词': ('FF0000', false, 'FFDBDB'),
  '专有词': ('800080', false, 'EBD9F0'),
};

/// 样例句：七类各一个词 + 一个真题词（不参与配色标注）。
const String kSampleText =
    'JuniorWord CompulsoryWord ElectiveWord ExtendWord OverLimitWord '
    'ProperWord UnfilteredWord RealExamWord plain tail.';

const Map<String, String> kSampleCatByLower = {
  'juniorword': '初中课标词',
  'compulsoryword': '必修课标词',
  'electiveword': '选修课标词',
  'extendword': '拓展词',
  'overlimitword': '超标词',
  'properword': '专有词',
  'unfilteredword': '未筛选',
  'realexamword': '真题词',
};

/// 类别 -> 样例句中该词的实际大小写写法（用于精确核对生成的 run XML）。
const Map<String, String> kSampleWordOf = {
  '初中课标词': 'JuniorWord',
  '必修课标词': 'CompulsoryWord',
  '选修课标词': 'ElectiveWord',
  '拓展词': 'ExtendWord',
  '超标词': 'OverLimitWord',
  '专有词': 'ProperWord',
  '未筛选': 'UnfilteredWord',
};

/// pdf 包的 PdfColor.toHex() 返回 8 位 ARGB（含不透明 alpha ff），这里统一拼成可比较的 8 位写法。
String hex8(String rgb) => '#${rgb.toLowerCase()}ff';

/// 与生产导出同源的字体加载：优先取系统中文字体，便于样例 PDF 正常显示中文。
pw.Font loadExportFont() {
  const candidates = <String>[
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\simfang.ttf',
    r'C:\Windows\Fonts\simsun.ttc',
    r'C:\Windows\Fonts\msyh.ttc',
  ];
  for (final p in candidates) {
    final f = File(p);
    if (!f.existsSync()) continue;
    try {
      final b = f.readAsBytesSync();
      return pw.Font.ttf(
        ByteData.view(b.buffer, b.offsetInBytes, b.lengthInBytes),
      );
    } catch (_) {
      // 个别 ttc 集合不受支持，继续尝试下一个候选
    }
  }
  return pw.Font.helvetica();
}

Directory _sampleDir() {
  final d = Directory('build/export_verify');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 组装一个最小可用的 .docx（仅 [Content_Types].xml + _rels/.rels + word/document.xml）。
List<int> buildDocx(List<String> bodyParagraphsXml) {
  const ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  final documentXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<w:document xmlns:w="$ns"><w:body>'
      '${bodyParagraphsXml.join()}'
      '<w:sectPr/></w:body></w:document>';
  const contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';
  const rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';
  final archive = Archive();
  void add(String name, String xml) {
    final data = utf8.encode(xml);
    archive.addFile(ArchiveFile(name, data.length, data));
  }

  add('[Content_Types].xml', contentTypes);
  add('_rels/.rels', rels);
  add('word/document.xml', documentXml);
  return ZipEncoder().encode(archive)!;
}

/// 从 .docx 字节中取出 word/document.xml 文本。
String readDocumentXml(List<int> docxBytes) {
  final archive = ZipDecoder().decodeBytes(docxBytes);
  final f = archive.findFile('word/document.xml')!;
  return utf8.decode(f.content as List<int>, allowMalformed: true);
}

/// 断言 XML 中不含任何底纹 / 高亮标记。
void expectNoShading(String xml, String reason) {
  expect(xml.contains('w:shd'), isFalse, reason: '$reason：不得出现 w:shd');
  expect(xml.contains('w:highlight'), isFalse, reason: '$reason：不得出现 w:highlight');
}

void main() {
  test('规范表：字色 / 字重 / 底纹色齐全且无漂移', () {
    // 表内保留未筛选的历史样式（Android 与统计口径使用）；Windows 导出前会拦截
    expect(kExportWordStyles.length, 7);
    kExpect.forEach((cat, exp) {
      final spec = exportWordStyleOf(cat);
      expect(spec, isNotNull, reason: '$cat 必须在规范表内');
      expect(spec!.colorHex, exp.$1, reason: '$cat 字色漂移');
      expect(spec.bold, exp.$2, reason: '$cat 字重漂移');
      expect(spec.shadeHex, exp.$3, reason: '$cat 底纹色漂移');
      expect(exportShadeHexOf(cat), exp.$3);
    });
    // 非规范类别不参与配色，也无底纹
    expect(exportWordStyleOf('真题词'), isNull);
    expect(exportShadeHexOf('真题词'), isNull);
  });

  test('DOCX 重生成路径：六类字色，无加粗 / w:shd / w:highlight', () {
    final xml = docxAnnotatedParagraphXml(kSampleText, kSampleCatByLower,
        colorBold: false, annotateUnfiltered: false);
    expectNoShading(xml, 'DOCX 重生成路径');

    // 每类字色都必须出现
    kExpect.forEach((cat, exp) {
      expect(
        xml.contains('<w:color w:val="${exp.$1}"/>'),
        isTrue,
        reason: '$cat 字色 ${exp.$1} 未出现在导出标注中',
      );
    });
    // 方案一不加粗：命中词 run 只带字色
    for (final cat in kExpect.keys) {
      final word = kSampleWordOf[cat]!;
      expect(
        xml.contains(docxRunXml(word, kExpect[cat]!.$1)),
        isTrue,
        reason: '$cat 命中 run 应为“字色且不加粗”',
      );
    }
    expect(xml.contains('<w:b/>'), isFalse, reason: '方案一不得加粗');
    // 未筛选词 / 真题词：黑色不加粗（不参与标注）
    for (final w in ['UnfilteredWord', 'RealExamWord']) {
      expect(
        xml.contains(docxRunXml(w, '000000')),
        isTrue,
        reason: '$w 不应参与配色标注，需保持黑色不加粗',
      );
    }

    final bytes = buildDocx([
      docxAnnotatedParagraphXml(kSampleText, kSampleCatByLower),
    ]);
    final out = File('${_sampleDir().path}/样例1_Word导出_原文标注_无底纹.docx');
    out.writeAsBytesSync(bytes);
    expectNoShading(readDocumentXml(bytes), '落盘样例（重生成路径）');
  });

  test('DOCX 原地标注路径：清除已有底纹 + 六类字色，且无加粗 / w:shd / w:highlight', () {
    // 源文档：被标注的单词所在 run 预置 w:highlight 与 w:shd 底纹（模拟历史导出残留），
    // 标注后该 run 应被重建为「只有字色 + 字重」，底纹标记全部消失。
    const head = 'JuniorWord CompulsoryWord ElectiveWord ';
    const tailText =
        ' OverLimitWord ProperWord UnfilteredWord RealExamWord plain tail.';
    final srcPara = '<w:p>'
        '<w:r><w:t xml:space="preserve">$head</w:t></w:r>'
        '<w:r><w:rPr><w:rFonts w:ascii="Times New Roman"/>'
        '<w:highlight w:val="yellow"/>'
        '<w:shd w:val="clear" w:color="auto" w:fill="FFFF00"/>'
        '</w:rPr><w:t xml:space="preserve">ExtendWord</w:t></w:r>'
        '<w:r><w:t xml:space="preserve">$tailText</w:t></w:r>'
        '</w:p>';
    final srcBytes = buildDocx([srcPara]);
    expect(
      readDocumentXml(srcBytes).contains('w:highlight'),
      isTrue,
      reason: '测试前置：源文档需自带 highlight 才能验证“被清除”',
    );

    final annotated = annotateDocxBytes(
      srcBytes: srcBytes,
      catByLower: kSampleCatByLower,
      preambleParagraphsXml: [
        docxRunXml('ESW 课标词检测导出（示例）', '000000'),
      ],
      colorBold: false,
      annotateUnfiltered: false,
    );
    final xml = readDocumentXml(annotated);
    expectNoShading(xml, 'DOCX 原地标注路径');
    kExpect.forEach((cat, exp) {
      expect(
        xml.contains('<w:color w:val="${exp.$1}"/>'),
        isTrue,
        reason: '$cat 字色未写入原地标注',
      );
    });
    // 方案一不加粗：整篇不得出现 w:b（标题段也不加粗）
    expect(xml.contains('<w:b/>'), isFalse, reason: '方案一不得加粗');
    // 未筛选词 / 真题词：黑色不加粗（不参与标注）
    for (final w in ['UnfilteredWord', 'RealExamWord']) {
      expect(xml.contains(docxRunXml(w, '000000')), isTrue,
          reason: '$w 不应参与配色标注');
    }

    final out = File('${_sampleDir().path}/样例2_Word导出_原地标注_无底纹.docx');
    out.writeAsBytesSync(annotated);
  });

  test('方案一原地标注：原文自带加粗保持原样，不被标注清除', () {
    // 用户口径：方案一只着色不加粗，原文本身加粗必须保留，避免与原文混淆。
    const srcPara = '<w:p><w:r><w:rPr><w:b/></w:rPr>'
        '<w:t xml:space="preserve">ExtendWord</w:t></w:r></w:p>';
    final annotated = annotateDocxBytes(
      srcBytes: buildDocx([srcPara]),
      catByLower: const {'extendword': '拓展词'},
      colorBold: false,
      annotateUnfiltered: false,
    );
    final xml = readDocumentXml(annotated);
    expect(xml.contains('<w:b/>'), isTrue,
        reason: '原文自带加粗必须原样保留');
    expect(xml.contains('<w:color w:val="006400"/>'), isTrue,
        reason: '拓展词仍应按规范色着色');
  });

  test('跨 run 的所有格/缩写按整词标注（Mary + ’s、you + ’ + ve）', () {
    // Word 常把同一单词拆到多个 run：逐 run 匹配会只给词头着色，尾巴落空。
    const src = '<w:p>'
        '<w:r><w:t xml:space="preserve">Borrowing </w:t></w:r>'
        '<w:r><w:t xml:space="preserve">Mary</w:t></w:r>'
        '<w:r><w:t xml:space="preserve">’s</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> watch and </w:t></w:r>'
        '<w:r><w:t xml:space="preserve">you</w:t></w:r>'
        '<w:r><w:t xml:space="preserve">’</w:t></w:r>'
        '<w:r><w:t xml:space="preserve">ve</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> done.</w:t></w:r>'
        '</w:p>';
    final annotated = annotateDocxBytes(
      srcBytes: buildDocx([src]),
      catByLower: const {"mary's": '专有词', "you've": '拓展词'},
      colorBold: false,
      annotateUnfiltered: false,
    );
    final xml = readDocumentXml(annotated);
    expect(xml.contains(docxRunXml('Mary', '800080')), isTrue,
        reason: '人名所有格的词头应按专有词着色');
    expect(xml.contains(docxRunXml('’s', '800080')), isTrue,
        reason: '撇号尾巴应与词头同色，不能落空');
    expect(xml.contains(docxRunXml('you', '006400')), isTrue);
    expect(xml.contains(docxRunXml('’', '006400')), isTrue);
    expect(xml.contains(docxRunXml('ve', '006400')), isTrue);
  });

  test('PDF 路径：原文标注带极淡同色底纹 + 规范字色字重', () async {
    final font = loadExportFont();

    // ① 结构层：逐类校验 span 的字色 / 字重 / 底纹（底纹 = BoxDecoration 同色）
    final widget = pdfAnnotatedLine(kSampleText, kSampleCatByLower, font,
            colorBold: false, annotateUnfiltered: false)
        as pw.RichText;
    final spans =
        (widget.text as pw.TextSpan).children!.cast<pw.TextSpan>();
    for (final entry in kSampleCatByLower.entries) {
      final cat = entry.value;
      if (!kExpect.containsKey(cat)) continue; // 真题词 / 未筛选：不参与标注
      final word = kSampleWordOf[cat]!;
      final span = spans.firstWhere((s) => s.text == word);
      final exp = kExpect[cat]!;
      expect(
        span.style!.color!.toHex(),
        hex8(exp.$1),
        reason: '$cat PDF 字色漂移',
      );
      expect(
        span.style!.fontWeight == pw.FontWeight.bold,
        false,
        reason: '$cat PDF 方案一不得加粗',
      );
      final bg = span.style!.background;
      expect(bg, isNotNull, reason: '$cat PDF 应带极淡同色底纹');
      expect(
        bg!.color!.toHex(),
        hex8(exp.$3),
        reason: '$cat PDF 底纹色漂移',
      );
    }
    // 未筛选词 / 真题词：无底纹（不参与标注）
    for (final w in ['UnfilteredWord', 'RealExamWord']) {
      final span = spans.firstWhere((s) => s.text == w);
      expect(span.style!.background, isNull, reason: '$w 不得加底纹');
    }

    // ② 产物层：真实渲染一份 PDF，正文流内应出现七类底纹填充色
    final doc = pw.Document(verbose: true, compress: false);
    doc.addPage(
      pw.MultiPage(
        pageFormat: pwpdf.PdfPageFormat.a4,
        build: (_) => [
          pw.Paragraph(
            text: 'ESW 导出标注示例（PDF 通道：字色 + 字重 + 极淡同色底纹）',
            style: pw.TextStyle(font: font, fontSize: 12),
          ),
          pw.SizedBox(height: 6),
          pw.Paragraph(
            text: exportAnnotateLegend(),
            style: pw.TextStyle(font: font, fontSize: 9),
          ),
          pw.SizedBox(height: 8),
          for (final line in kSampleText.split('\n'))
            pdfAnnotatedLine(line, kSampleCatByLower, font),
          pw.SizedBox(height: 10),
          pw.Paragraph(
            text: '注：Word（.docx）导出为同款字色，但不加底纹；方案一不使用加粗。',
            style: pw.TextStyle(font: font, fontSize: 9),
          ),
        ],
      ),
    );
    final bytes = await doc.save();
    final raw = latin1.decode(bytes);
    // verbose 模式下正文流会写入 `% setFillColor(#RRGGBB)` 注释，可据此逐色核验
    for (final entry in kExpect.entries) {
      expect(
        raw.contains('setFillColor(${hex8(entry.value.$1)})'),
        isTrue,
        reason: '${entry.key} 的 PDF 字色 ${entry.value.$1} 未出现在正文流',
      );
      expect(
        raw.contains('setFillColor(${hex8(entry.value.$3)})'),
        isTrue,
        reason: '${entry.key} 的 PDF 底纹 ${entry.value.$3} 未出现在正文流',
      );
    }
    final out = File('${_sampleDir().path}/样例3_PDF导出_原文标注_带底纹.pdf');
    out.writeAsBytesSync(bytes);
    expect(out.lengthSync(), greaterThan(1000));
  });

  test('方案二（简化映射）：DOCX 加粗 / 单线 / 30% 灰底，未筛选不标注', () {
    final xml = docxAnnotatedParagraphXml(
      kSampleText,
      kSampleCatByLower,
      scheme: ExportAnnotateScheme.typography,
    );
    // 方案二专有词允许 30% 灰底纹，因此这里不做“全文无底纹”断言，
    // 只断言底纹只出现在专有词上（下方逐 token 精确核对）。
    // 全文单词（含真题词）统一 Times New Roman
    for (final w in [
      'JuniorWord',
      'CompulsoryWord',
      'ElectiveWord',
      'RealExamWord',
    ]) {
      expect(xml.contains(docxRunXml(w, '000000', fontName: kExportTypographyFont)),
          isTrue,
          reason: '$w 应为 TNR');
    }
    // 拓展词：加粗；超标词：单线；专有词：30% 灰底
    expect(
      xml.contains(docxRunXml('ExtendWord', '000000',
          fontName: kExportTypographyFont, bold: true)),
      isTrue,
      reason: '拓展词应加粗',
    );
    expect(
      xml.contains(docxRunXml('OverLimitWord', '000000',
          fontName: kExportTypographyFont, underline: 'single')),
      isTrue,
      reason: '超标词应单线下划线',
    );
    expect(
      xml.contains(docxRunXml('ProperWord', '000000',
          fontName: kExportTypographyFont, shadeFill: 'B3B3B3')),
      isTrue,
      reason: '专有词应 30% 灰底纹',
    );
    // 未筛选不再标注：与课标词同为纯 TNR
    expect(
      xml.contains(docxRunXml('UnfilteredWord', '000000',
          fontName: kExportTypographyFont)),
      isTrue,
      reason: '未筛选词应只保留 TNR，不带任何标记',
    );
    // 课标词与真题词保持默认：无加粗 / 下划线 / 底纹
    for (final w in [
      'JuniorWord',
      'CompulsoryWord',
      'ElectiveWord',
      'RealExamWord',
    ]) {
      expect(
        xml.contains(docxRunXml(w, '000000', fontName: kExportTypographyFont)),
        isTrue,
        reason: '$w 不应带任何标记',
      );
    }
    // 不再插入任何编号 / 斜体
    for (final m in ['①', '②', '③', '④', '⑤', '⑥', '⑦']) {
      expect(xml.contains(m), isFalse, reason: '方案二不应出现编号 $m');
    }
    expect(xml.contains('<w:i/>'), isFalse);
    // 不得残留方案一的分类色（黑色是方案二统一字色，排除）
    for (final hex in exportPaletteHex().where((h) => h != '000000')) {
      expect(xml.contains('<w:color w:val="$hex"/>'), isFalse,
          reason: '方案二正文不应出现方案一配色 $hex');
    }

    // 原地标注路径：覆盖源字体 / 斜体 / 下划线，重写为方案二标记
    final srcPara = '<w:p>'
        '<w:r><w:rPr><w:rFonts w:ascii="Courier New"/><w:i/>'
        '<w:u w:val="single"/></w:rPr>'
        '<w:t xml:space="preserve">ExtendWord</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> </w:t></w:r>'
        '<w:r><w:rPr><w:rFonts w:ascii="Courier New"/>'
        '<w:u w:val="single"/></w:rPr>'
        '<w:t xml:space="preserve">ProperWord</w:t></w:r>'
        '</w:p>';
    final annotated = annotateDocxBytes(
      srcBytes: buildDocx([srcPara]),
      catByLower: kSampleCatByLower,
      scheme: ExportAnnotateScheme.typography,
    );
    final annotatedXml = readDocumentXml(annotated);
    expect(annotatedXml.contains('Courier New'), isFalse,
        reason: '命中词字体应被覆盖为 Times New Roman');
    expect(annotatedXml.contains('<w:i/>'), isFalse,
        reason: '命中词应清除斜体');
    expect(annotatedXml.contains('<w:b/>'), isTrue, reason: '拓展词应加粗');
    expect(annotatedXml.contains('<w:shd w:val="clear" w:color="auto" '
        'w:fill="B3B3B3"/>'), isTrue, reason: '专有词应写入 30% 灰底纹');

    final out = File('${_sampleDir().path}/样例4_Word导出_简化映射方案.docx');
    out.writeAsBytesSync(
      buildDocx([
        docxAnnotatedParagraphXml(
          kSampleText,
          kSampleCatByLower,
          scheme: ExportAnnotateScheme.typography,
        ),
      ]),
    );
    expect(out.lengthSync(), greaterThan(1000));
  });

  test('方案二（简化映射）：PDF 加粗 / 单线 / 灰底，未筛选不标注', () {
    final font = loadExportFont();
    final wordFont = pw.Font.times();
    final boldFont = pw.Font.timesBold();
    final widget = pdfAnnotatedLine(
      kSampleText,
      kSampleCatByLower,
      font,
      scheme: ExportAnnotateScheme.typography,
      wordFont: wordFont,
      boldFont: boldFont,
    ) as pw.RichText;
    final spans = (widget.text as pw.TextSpan).children!.cast<pw.TextSpan>();

    pw.TextSpan spanOf(String text) => spans.firstWhere((s) => s.text == text);

    // 课标词：默认 TNR，无标记
    for (final w in [
      'JuniorWord',
      'CompulsoryWord',
      'ElectiveWord',
      'RealExamWord',
    ]) {
      final style = spanOf(w).style!;
      expect(style.font, wordFont, reason: '$w 应为 TNR');
      expect(style.decoration, isNull, reason: '$w 不应有下划线');
      expect(style.background, isNull, reason: '$w 不应有底纹');
    }
    // 拓展词：加粗字体
    expect(spanOf('ExtendWord').style!.font, boldFont, reason: '拓展词应加粗');
    // 超标词：单线
    final over = spanOf('OverLimitWord').style!;
    expect(over.decoration, pw.TextDecoration.underline);
    expect(over.decorationStyle, pw.TextDecorationStyle.solid);
    // 专有词：30% 灰底纹
    expect(spanOf('ProperWord').style!.background, isNotNull,
        reason: '专有词应有底纹');
    // 未筛选：不标注（与课标词同为纯 TNR）
    final unfiltered = spanOf('UnfilteredWord').style!;
    expect(unfiltered.font, wordFont);
    expect(unfiltered.decoration, isNull);
    expect(unfiltered.background, isNull);
    // 不插入任何编号
    for (final m in ['①', '②', '③', '④', '⑤', '⑥', '⑦']) {
      expect(spans.any((s) => s.text == m), isFalse, reason: 'PDF 不应插入编号 $m');
    }
  });

  test('撇号缩略形式：整词标注，不拆成 couldn + t', () {
    const text = "We couldn't stay. It's o'clock and they don't know.";
    const cases = <({String original, String key, String cat})>[
      (original: "couldn't", key: "couldn't", cat: '拓展词'),
      (original: "It's", key: "it's", cat: '超标词'),
      (original: "o'clock", key: "o'clock", cat: '专有词'),
      (original: "don't", key: "don't", cat: '拓展词'),
    ];
    final cats = <String, String>{
      for (final c in cases) c.key: c.cat,
    };

    // 1) DOCX 重生成路径：命中 run 的文本必须是完整缩略形式
    final xml = docxAnnotatedParagraphXml(text, cats, colorBold: false);
    for (final c in cases) {
      expect(
        xml.contains(docxRunXml(c.original, kExpect[c.cat]!.$1)),
        isTrue,
        reason: '${c.original} 应整体成为一个标注 run',
      );
    }
    expect(
      xml.contains('<w:t xml:space="preserve">couldn</w:t>'),
      isFalse,
      reason: '不得截断成 couldn',
    );

    // 2) DOCX 原地标注：弯撇号原文命中小写词条，且整词替换
    final curlyXml = readDocumentXml(
      annotateDocxBytes(
        srcBytes: buildDocx([
          '<w:p><w:r><w:t xml:space="preserve">We couldn\u2019t stay.</w:t></w:r></w:p>',
        ]),
        catByLower: const {"couldn't": '拓展词'},
        colorBold: false,
      ),
    );
    expect(
      curlyXml.contains(docxRunXml('couldn\u2019t', kExpect['拓展词']!.$1)),
      isTrue,
      reason: '弯撇号缩略形式应整体标注',
    );

    // 3) PDF 路径：整词作为一个 span
    final widget = pdfAnnotatedLine(text, cats, loadExportFont()) as pw.RichText;
    final spans = (widget.text as pw.TextSpan).children!.cast<pw.TextSpan>();
    for (final c in cases) {
      expect(
        spans.any((s) => s.text == c.original),
        isTrue,
        reason: 'PDF 应输出完整词元 ${c.original}',
      );
    }
  });
}
