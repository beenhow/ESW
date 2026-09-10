/// 导出结果文档末尾「拓展词表格」构建模块（双端共用）。
///
/// 功能：把检测出的拓展词按题型（听力/阅读/七选五/完形填空/语法填空/写作）
/// 分组，并补充每个拓展词的「拓展释义」与「对应课标原词」，最终生成 DOCX 表格 XML
/// 或纯文本表格，供 Android / Windows 导出结果文档在末尾追加。
library;

/// 单行拓展词数据
class ExtendRowData {
  final String word; // 拓展词
  final String meaning; // 拓展释义
  final String baseWord; // 对应课标原词
  const ExtendRowData({
    required this.word,
    required this.meaning,
    required this.baseWord,
  });
}

/// 单个题型区块
class ExtendSection {
  final String name; // 题型名
  final List<ExtendRowData> rows; // 该题型下的拓展词行
  const ExtendSection({required this.name, required this.rows});
}

/// 题型关键词 -> 匹配正则（顺序即文档内典型出现顺序）
final Map<String, RegExp> _sectionPatterns = <String, RegExp>{
  '听力': RegExp(r'听力'),
  '阅读': RegExp(r'阅读'),
  '七选五': RegExp(r'七选五'),
  '完形填空': RegExp(r'完形|完型'),
  '语法填空': RegExp(r'语法填空'),
  '写作': RegExp(r'写作|书面表达'),
};

/// 按题型把拓展词分组。
///
/// [text]：被检测的原文全文
/// [extendWords]：检测出的全部拓展词（原始大小写列表）
/// [baseWordOf]：给定拓展词返回对应课标原词（原始大小写，无则返回空串）
/// [meaningOf]：给定拓展词及其课标原词返回释义（优先拓展词自身释义，兜底课标原词释义）
List<ExtendSection> buildExtendSections({
  required String text,
  required List<String> extendWords,
  required String Function(String word) baseWordOf,
  required String Function(String word, String baseWord) meaningOf,
}) {
  final lines = text.split('\n');

  // 扩展词小写 -> 原始大小写
  final extendByLower = <String, String>{};
  for (final w in extendWords) {
    extendByLower.putIfAbsent(w.toLowerCase(), () => w);
  }
  if (extendByLower.isEmpty) return const [];

  // 定位各题型标题行（按行匹配关键词，记录首次出现）
  final markerByName = <String, int>{};
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i].trim().toLowerCase();
    if (l.isEmpty) continue;
    for (final entry in _sectionPatterns.entries) {
      if (markerByName.containsKey(entry.key)) continue;
      if (entry.value.hasMatch(l)) {
        markerByName[entry.key] = i;
        break;
      }
    }
  }
  if (markerByName.isEmpty) return const [];

  // 按出现顺序排列题型
  final ordered = markerByName.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));

  final sections = <ExtendSection>[];
  final wordRe = RegExp(r'[a-zA-Z]+');
  for (var k = 0; k < ordered.length; k++) {
    final name = ordered[k].key;
    final start = ordered[k].value;
    final end = k + 1 < ordered.length ? ordered[k + 1].value : lines.length;
    final sectionText = lines.sublist(start, end).join('\n');

    // 收集该题型区间内出现的拓展词（去重、按出现顺序）
    final seen = <String>{};
    final found = <String>[];
    for (final m in wordRe.allMatches(sectionText)) {
      final lower = m.group(0)!.toLowerCase();
      final original = extendByLower[lower];
      if (original != null && seen.add(lower)) {
        found.add(original);
      }
    }
    if (found.isEmpty) continue;

    final rows = found.map((w) {
      final base = baseWordOf(w);
      final meaning = meaningOf(w, base);
      return ExtendRowData(word: w, meaning: meaning, baseWord: base);
    }).toList();
    sections.add(ExtendSection(name: name, rows: rows));
  }
  return sections;
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 生成拓展词表格的 DOCX `<w:tbl>` XML。
String buildExtendTableXml(List<ExtendSection> sections) {
  if (sections.isEmpty) return '';
  const grid = [1600, 2800, 2800, 2400]; // 题型/拓展词/拓展词义/课标词 列宽 dxa
  final sb = StringBuffer();
  sb.write('<w:tbl><w:tblPr><w:tblW w:w="9600" w:type="dxa"/><w:tblBorders>');
  for (final s in const ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']) {
    sb.write('<w:$s w:val="single" w:sz="4" w:space="0" w:color="000000"/>');
  }
  sb.write('</w:tblBorders><w:tblLayout w:type="autofit"/></w:tblPr><w:tblGrid>');
  for (final g in grid) {
    sb.write('<w:gridCol w:w="$g"/>');
  }
  sb.write('</w:tblGrid>');

  // 表头
  sb.write('<w:tr>');
  for (var c = 0; c < 4; c++) {
    final header = const ['题型', '拓展词', '拓展词义', '课标词'][c];
    sb.write(
        '<w:tc><w:tcPr><w:tcW w:w="${grid[c]}" w:type="dxa"/></w:tcPr>'
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(header)}</w:t></w:r></w:p></w:tc>');
  }
  sb.write('</w:tr>');

  // 数据行：题型名仅在所属区间的首行填写
  for (final sec in sections) {
    for (var i = 0; i < sec.rows.length; i++) {
      final row = sec.rows[i];
      final cells = [i == 0 ? sec.name : '', row.word, row.meaning, row.baseWord];
      sb.write('<w:tr>');
      for (var c = 0; c < 4; c++) {
        sb.write(
            '<w:tc><w:tcPr><w:tcW w:w="${grid[c]}" w:type="dxa"/></w:tcPr>'
            '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r>'
            '<w:t xml:space="preserve">${_xmlEscape(cells[c])}</w:t></w:r></w:p></w:tc>');
      }
      sb.write('</w:tr>');
    }
  }
  sb.write('</w:tbl>');
  return sb.toString();
}

/// 生成拓展词表格的纯文本版本（TXT 导出用）。
String buildExtendTableText(List<ExtendSection> sections) {
  if (sections.isEmpty) return '';
  final sb = StringBuffer();
  sb.writeln('');
  sb.writeln('=' * 64);
  sb.writeln('【拓展词明细（按题型）】');
  sb.writeln('=' * 64);
  for (final sec in sections) {
    sb.writeln('');
    sb.writeln('■ ${sec.name}');
    sb.writeln('拓展词\t拓展词义\t课标词');
    for (final r in sec.rows) {
      sb.writeln('${r.word}\t${r.meaning}\t${r.baseWord}');
    }
  }
  return sb.toString();
}
