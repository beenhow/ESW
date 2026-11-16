/// ESW 双端共用：导出文档「原文标注」markup 单点落地。
///
/// 分界（用户口径，务必遵守）：
///   - Word（.docx 原地标注 / 重生成，以及 .doc 的 RTF）：原文标注**不加底纹/高亮**，
///     只规范字色与字重（七类配色与字重取自 [kExportWordStyles]）。
///   - PDF：原文标注在七类字色 + 字重之外，**加规范色的极淡同色底纹**（[exportShadeHexOf]）。
///   - TXT：纯文本，不着色也不加底纹，保持原样。
///
/// 本文件是上述 markup 的唯一真源：Windows 端导出器（docx 重生成 / 原地标注 / pdf）
/// 全部调用本文件，测试亦直接调用以校验导出的真实产物。
library;

import 'package:pdf/pdf.dart' as pwpdf;
import 'package:pdf/widgets.dart' as pw;

import 'export_word_style.dart';

// ==================== DOCX（无底纹，仅字色 + 字重） ====================

/// 清理 XML 1.0 不允许出现的字符，并归一换行。
///
/// 非试题类文本（PDF / DOC 提取的散文本、网页粘贴文本）常带 `\f`（换页）、
/// `\u0001`（字段标记）、`\u0000` 等控制字符。这些字符直接写入 OOXML 会让
/// `word/document.xml` 变成非法 XML，Word 打开即报错，用户侧表现为
/// 「导出失败」；极端情况下解析/压缩链路还会抛异常。统一在 run 级清理。
String sanitizeXmlText(String text) {
  if (text.isEmpty) return text;
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '');
}

/// XML 文本转义（& < >），并先清理非法控制字符。
String _escapeXml(String text) => sanitizeXmlText(text)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 生成单个 DOCX run：字色 + 可选加粗（方案一），或指定西文字体 +
/// 加粗 / 下划线 / 底纹（方案二）。
///
/// 方案一刻意不提供底纹参数；方案二仅专有词写 `w:shd`（30% 灰底纹）。
///
/// [fontName] 非空时写入 `w:rFonts`（方案二全文统一 Times New Roman）。
/// [underline] 为 OOXML `w:u` 值（'single' / 'dotted'）；[shadeFill] 为
/// `w:shd` 填充色（无 # 前缀）。子元素顺序遵循 CT_RPr：rFonts → b → color
/// → u → shd。
String docxRunXml(
  String text,
  String color, {
  bool bold = false,
  String? fontName,
  String? underline,
  String? shadeFill,
}) {
  if (fontName == null && underline == null && shadeFill == null) {
    // 方案一：与既有导出逐字节一致（<w:color/> + <w:b/>）。
    final b = bold ? '<w:b/>' : '';
    return '<w:r><w:rPr><w:color w:val="$color"/>$b</w:rPr>'
        '<w:t xml:space="preserve">${_escapeXml(text)}</w:t></w:r>';
  }
  final b = bold ? '<w:b/>' : '';
  final rFonts = fontName == null
      ? ''
      : '<w:rFonts w:ascii="$fontName" w:hAnsi="$fontName" w:cs="$fontName"/>';
  final u = underline == null ? '' : '<w:u w:val="$underline"/>';
  final shd = shadeFill == null
      ? ''
      : '<w:shd w:val="clear" w:color="auto" w:fill="$shadeFill"/>';
  return '<w:r><w:rPr>$rFonts$b<w:color w:val="$color"/>$u$shd</w:rPr>'
      '<w:t xml:space="preserve">${_escapeXml(text)}</w:t></w:r>';
}

/// 生成带标注全文的 DOCX 段落：按 [scheme] 标注原文中的单词。
///
/// 按行拆分，每行一个独立 `<w:p>`，保留原文段落结构（避免 Word 中段落被合并）。
/// 方案二：全文单词统一 Times New Roman，按类型用加粗 / 单下划线 /
/// 30% 灰底纹 / 点线下划线区分；课标词与真题词保持默认、不加任何标记。
String docxAnnotatedParagraphXml(
  String text,
  Map<String, String> catByLower, {
  ExportAnnotateScheme scheme = ExportAnnotateScheme.color,
  bool colorBold = true,
  bool annotateUnfiltered = true,
}) {
  final regex = RegExp(r'[a-zA-Z]+');
  final typographyMode = scheme == ExportAnnotateScheme.typography;

  String oneLine(String line) {
    final runs = <String>[];
    int lastEnd = 0;
    for (final m in regex.allMatches(line)) {
      final word = m.group(0)!;
      final plain = line.substring(lastEnd, m.start);
      if (plain.isNotEmpty) runs.add(docxRunXml(plain, '000000'));
      final cat = catByLower[word.toLowerCase()];
      if (typographyMode) {
        // 全文统一 TNR；课标词 / 真题词无标记，其余按简化映射标注
        final style = exportScheme2StyleOf(cat);
        runs.add(docxRunXml(
          word,
          '000000',
          fontName: kExportTypographyFont,
          bold: style?.bold ?? false,
          underline: style?.underline,
          shadeFill: style?.shadeFill,
        ));
      } else {
        final spec = exportWordStyleOf(cat);
        if (spec == null ||
            (cat == ExportCategory.unfiltered && !annotateUnfiltered)) {
          // 真题词 / 其他 / 未筛选（Windows）：不参与配色标注，保持默认黑
          runs.add(docxRunXml(word, '000000'));
        } else {
          runs.add(docxRunXml(word, spec.colorHex,
              bold: spec.bold && colorBold));
        }
      }
      lastEnd = m.end;
    }
    final tail = line.substring(lastEnd);
    if (tail.isNotEmpty) runs.add(docxRunXml(tail, '000000'));
    return '<w:p>${runs.join('')}</w:p>';
  }

  return text.split('\n').map(oneLine).join('\n');
}

/// 生成 DOCX 段落：按英文单词边界拆分，[words] 中的单词（大小写不敏感）
/// 用加粗黑色 run 输出，其余文本用普通黑色 run（用于例句/明细加粗强调）。
String docxParagraphWithBoldWordsXml(String text, List<String> words) {
  final targets = words.map((w) => w.toLowerCase()).toSet();
  final regex = RegExp(r'[a-zA-Z]+');
  final runs = <String>[];
  int lastEnd = 0;
  for (final m in regex.allMatches(text)) {
    final word = m.group(0)!;
    final plain = text.substring(lastEnd, m.start);
    if (plain.isNotEmpty) runs.add(docxRunXml(plain, '000000'));
    runs.add(
      docxRunXml(word, '000000', bold: targets.contains(word.toLowerCase())),
    );
    lastEnd = m.end;
  }
  final tail = text.substring(lastEnd);
  if (tail.isNotEmpty) runs.add(docxRunXml(tail, '000000'));
  return '<w:p>${runs.join('')}</w:p>';
}

// ==================== PDF（方案一：字色 + 底纹；方案二：线型 / 灰底 / 加粗） ====================

/// 生成 PDF 原文标注单行。
///
/// 方案一（默认）：命中规范七类的单词以规范字色 + 字重 + 极淡同色底纹输出。
/// 方案二：全文单词统一 Times New Roman（[wordFont]），按类型标注：
/// 拓展词加粗（[boldFont]）、超标词单下划线、专有词 30% 灰底纹。
/// 课标词、未筛选词与真题词保持默认、不加任何标记。
///
/// 其余文本保持默认黑（无底纹）。
pw.Widget pdfAnnotatedLine(
  String line,
  Map<String, String> catByLower,
  pw.Font font, {
  double fontSize = 10,
  ExportAnnotateScheme scheme = ExportAnnotateScheme.color,
  bool colorBold = true,
  bool annotateUnfiltered = true,
  bool annotateShade = true,
  pw.Font? wordFont,
  pw.Font? boldFont,
}) {
  final black = pwpdf.PdfColor.fromInt(0xFF000000);
  final typographyMode = scheme == ExportAnnotateScheme.typography;
  pw.TextStyle plainStyle() =>
      pw.TextStyle(font: font, fontSize: fontSize, color: black);

  pw.TextStyle annotatedStyle(ExportWordStyle spec) => pw.TextStyle(
        font: font,
        fontSize: fontSize,
        color: pwpdf.PdfColor.fromHex(spec.dashedHex),
        fontWeight: spec.bold && colorBold
            ? pw.FontWeight.bold
            : pw.FontWeight.normal,
        background: (!annotateShade || spec.dashedShadeHex == null)
            ? null
            : pw.BoxDecoration(
                color: pwpdf.PdfColor.fromHex(spec.dashedShadeHex!),
              ),
      );

  // 方案二：全文 TNR；仅拓展 / 超标 / 专有带标记
  pw.TextStyle scheme2Style(ExportScheme2Style? style) => pw.TextStyle(
        font: style?.bold == true ? (boldFont ?? wordFont ?? font) : (wordFont ?? font),
        fontSize: fontSize,
        color: black,
        decoration: style?.underline == 'single'
            ? pw.TextDecoration.underline
            : null,
        decorationStyle: style?.underline == 'single'
            ? pw.TextDecorationStyle.solid
            : null,
        decorationColor: black,
        background: style?.shadeFill == null
            ? null
            : pw.BoxDecoration(
                color: pwpdf.PdfColor.fromHex(style!.shadeFill!),
              ),
      );

  final regex = RegExp(r'[a-zA-Z]+');
  final spans = <pw.TextSpan>[];
  int lastEnd = 0;
  for (final m in regex.allMatches(line)) {
    final word = m.group(0)!;
    final plain = line.substring(lastEnd, m.start);
    if (plain.isNotEmpty) {
      spans.add(pw.TextSpan(text: plain, style: plainStyle()));
    }
    final cat = catByLower[word.toLowerCase()];
    if (typographyMode) {
      final style = exportScheme2StyleOf(cat);
      spans.add(pw.TextSpan(
        text: word,
        style: style == null
            ? pw.TextStyle(
                font: wordFont ?? font,
                fontSize: fontSize,
                color: black,
              )
            : scheme2Style(style),
      ));
    } else {
      final spec = exportWordStyleOf(cat);
      // 真题词 / 其他 / 未筛选（Windows 关闭标注）：保持默认黑
      spans.add(
        pw.TextSpan(
          text: word,
          style: spec == null ||
                  (cat == ExportCategory.unfiltered && !annotateUnfiltered)
              ? plainStyle()
              : annotatedStyle(spec),
        ),
      );
    }
    lastEnd = m.end;
  }
  final tail = line.substring(lastEnd);
  if (tail.isNotEmpty) {
    spans.add(pw.TextSpan(text: tail, style: plainStyle()));
  }
  return pw.RichText(
    text: pw.TextSpan(
      style: pw.TextStyle(font: font, fontSize: fontSize),
      children: spans,
    ),
    textDirection: pw.TextDirection.ltr,
  );
}
