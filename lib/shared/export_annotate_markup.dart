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

/// XML 文本转义（& < >）。
String _escapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 生成单个 DOCX run：仅字色 + 可选加粗。
///
/// 刻意不提供任何底纹/高亮参数：Word 导出结果不得出现 `w:shd` / `w:highlight`。
String docxRunXml(String text, String color, {bool bold = false}) {
  final b = bold ? '<w:b/>' : '';
  return '<w:r><w:rPr><w:color w:val="$color"/>$b</w:rPr>'
      '<w:t xml:space="preserve">${_escapeXml(text)}</w:t></w:r>';
}

/// 生成带标注全文的 DOCX 段落：按分类用规范七类的字色 + 字重着色（无底纹）。
///
/// 按行拆分，每行一个独立 `<w:p>`，保留原文段落结构（避免 Word 中段落被合并）。
/// 非规范七类（真题词 / 其他 / 未知）不着色，保持默认黑。
String docxAnnotatedParagraphXml(
  String text,
  Map<String, String> catByLower,
) {
  final regex = RegExp(r'[a-zA-Z]+');

  String oneLine(String line) {
    final runs = <String>[];
    int lastEnd = 0;
    for (final m in regex.allMatches(line)) {
      final word = m.group(0)!;
      final plain = line.substring(lastEnd, m.start);
      if (plain.isNotEmpty) runs.add(docxRunXml(plain, '000000'));
      final spec = exportWordStyleOf(catByLower[word.toLowerCase()]);
      if (spec == null) {
        // 真题词 / 其他 / 未知分类：不参与配色标注，保持默认黑
        runs.add(docxRunXml(word, '000000'));
      } else {
        runs.add(docxRunXml(word, spec.colorHex, bold: spec.bold));
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

// ==================== PDF（字色 + 字重 + 极淡同色底纹） ====================

/// 生成 PDF 原文标注单行：命中规范七类的单词以规范字色 + 字重 + 极淡同色底纹输出，
/// 其余文本保持默认黑（无底纹）。
///
/// 底纹通过 `pw.TextStyle.background`（[pw.BoxDecoration]）注入，
/// 是 PDF 侧唯一使用底纹的导出通道。
pw.Widget pdfAnnotatedLine(
  String line,
  Map<String, String> catByLower,
  pw.Font font, {
  double fontSize = 10,
}) {
  final black = pwpdf.PdfColor.fromInt(0xFF000000);
  pw.TextStyle plainStyle() =>
      pw.TextStyle(font: font, fontSize: fontSize, color: black);

  pw.TextStyle annotatedStyle(ExportWordStyle spec) => pw.TextStyle(
        font: font,
        fontSize: fontSize,
        color: pwpdf.PdfColor.fromHex(spec.dashedHex),
        fontWeight: spec.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        background: spec.dashedShadeHex == null
            ? null
            : pw.BoxDecoration(
                color: pwpdf.PdfColor.fromHex(spec.dashedShadeHex!),
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
    final spec = exportWordStyleOf(catByLower[word.toLowerCase()]);
    // 真题词 / 其他 / 未知分类：不参与配色标注，保持默认黑
    spans.add(
      pw.TextSpan(
        text: word,
        style: spec == null ? plainStyle() : annotatedStyle(spec),
      ),
    );
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
