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

/// 七类规范期望值：分类 -> (字色, 加粗, 底纹色)
const Map<String, (String, bool, String)> kExpect = {
  '初中课标词': ('000000', true, 'D9D9D9'),
  '必修课标词': ('0B3D91', true, 'D6E0F5'),
  '选修课标词': ('00B0F0', false, 'D6F0FC'),
  '拓展词': ('006400', true, 'D6E9D7'),
  '超标词': ('FF0000', false, 'FFDBDB'),
  '专有词': ('800080', false, 'EBD9F0'),
  '未筛选': ('A0522D', false, 'F0E0D6'),
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
  test('七类规范表：字色 / 字重 / 底纹色齐全且无漂移', () {
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

  test('DOCX 重生成路径：七类字色 + 字重，无 w:shd / w:highlight', () {
    final xml = docxAnnotatedParagraphXml(kSampleText, kSampleCatByLower);
    expectNoShading(xml, 'DOCX 重生成路径');

    // 每类字色都必须出现，且加粗只出现在规范要求加粗的三类上
    kExpect.forEach((cat, exp) {
      expect(
        xml.contains('<w:color w:val="${exp.$1}"/>'),
        isTrue,
        reason: '$cat 字色 ${exp.$1} 未出现在导出标注中',
      );
    });
    for (final cat in ['初中课标词', '必修课标词', '拓展词']) {
      final word = kSampleWordOf[cat]!;
      // 命中词的 run：字色 + 加粗相邻
      final runXml = docxRunXml(word, kExpect[cat]!.$1, bold: true);
      expect(xml.contains(runXml), isTrue, reason: '$cat 命中 run 未按规范加粗');
    }
    // 真题词 / 普通文本：黑色不加粗（不参与配色标注）
    expect(
      xml.contains(docxRunXml('RealExamWord', '000000')),
      isTrue,
      reason: '真题词不应参与配色标注，需保持黑色不加粗',
    );

    final bytes = buildDocx([
      docxAnnotatedParagraphXml(kSampleText, kSampleCatByLower),
    ]);
    final out = File('${_sampleDir().path}/样例1_Word导出_原文标注_无底纹.docx');
    out.writeAsBytesSync(bytes);
    expectNoShading(readDocumentXml(bytes), '落盘样例（重生成路径）');
  });

  test('DOCX 原地标注路径：清除已有底纹 + 七类字色字重，且无 w:shd / w:highlight', () {
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
        docxRunXml('ESW 课标词检测导出（示例）', '000000', bold: true),
      ],
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
    // 命中词加粗（初中 / 必修 / 拓展三类）
    expect(xml.contains('<w:b/>'), isTrue);

    final out = File('${_sampleDir().path}/样例2_Word导出_原地标注_无底纹.docx');
    out.writeAsBytesSync(annotated);
  });

  test('PDF 路径：原文标注带极淡同色底纹 + 规范字色字重', () async {
    final font = loadExportFont();

    // ① 结构层：逐类校验 span 的字色 / 字重 / 底纹（底纹 = BoxDecoration 同色）
    final widget = pdfAnnotatedLine(kSampleText, kSampleCatByLower, font)
        as pw.RichText;
    final spans =
        (widget.text as pw.TextSpan).children!.cast<pw.TextSpan>();
    for (final entry in kSampleCatByLower.entries) {
      final cat = entry.value;
      if (cat == '真题词') continue; // 不参与配色标注
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
        exp.$2,
        reason: '$cat PDF 字重漂移',
      );
      final bg = span.style!.background;
      expect(bg, isNotNull, reason: '$cat PDF 应带极淡同色底纹');
      expect(
        bg!.color!.toHex(),
        hex8(exp.$3),
        reason: '$cat PDF 底纹色漂移',
      );
    }
    // 真题词：无底纹
    final plainSpan = spans.firstWhere((s) => s.text == 'RealExamWord');
    expect(plainSpan.style!.background, isNull, reason: '真题词不得加底纹');

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
            text: '注：Word（.docx/.doc）导出为同款字色与字重，但不加底纹；'
                'TXT 为纯文本，不着色不加底纹。',
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
}
