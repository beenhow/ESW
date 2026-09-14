/// 导出结果文档末尾「拓展词表格」构建模块（双端共用）。
///
/// 功能：把检测出的拓展词按题型（听力/阅读/七选五/完形填空/语法填空/改错/写作）
/// 分组，并为每个拓展词从真题原文中提取一个较短例句（同一拓展词全局只列一次），
/// 最终生成 DOCX 表格 XML 或纯文本表格，供 Android / Windows 导出结果文档在末尾追加。
library;

/// 单行拓展词数据
class ExtendRowData {
  final String word; // 拓展词
  final String example; // 该拓展词在真题中的例句（选较短者）
  final String baseWord; // 对应课标原词
  const ExtendRowData({
    required this.word,
    required this.example,
    required this.baseWord,
  });
}

/// 单个题型区块
class ExtendSection {
  final String name; // 题型名
  final List<ExtendRowData> rows; // 该题型下的拓展词行
  const ExtendSection({required this.name, required this.rows});
}

/// 题型识别规则（有序，顺序即优先级与文档内典型出现顺序）。
///
/// 识别策略：按「单词所在段落前面的汉语要求（题型标题行）」定位题型边界。
/// 关键词取较具体的短语，避免与正文混淆：阅读只认“阅读理解”或行首“阅读（/阅读共”，
/// 七选五认“七选五/根据短文内容”，完形填空认“完形填空/完型”，
/// 语法填空认“语法填空/在空白处填入/用括号内”等。
class _SectionRule {
  final String name;
  final RegExp re;
  const _SectionRule(this.name, this.re);
}

final List<_SectionRule> _sectionRules = [
  _SectionRule('听力', RegExp(r'听力')),
  _SectionRule('阅读', RegExp(r'阅读理解|^\s*阅读[（(共]|阅读[（(共]')),
  _SectionRule('七选五', RegExp(r'七选五|根据短文内容')),
  _SectionRule('完形填空', RegExp(r'完形填空|完型填空|完形|完型')),
  _SectionRule('语法填空', RegExp(r'语法填空|短文填空|适当形式填空|在空白处填入|用括号内')),
  _SectionRule('改错', RegExp(r'短文改错|^\s*改错|改错[（(共]')),
  _SectionRule('写作', RegExp(r'书面表达|写作[（(共]|^\s*写作')),
];

/// 从一段文本中提取包含 [word] 的句子，优先返回较短的例句。
///
/// 先合并换行/空白使跨行句子连续，再按句子结尾标点切句，
/// 在包含该词的句子中选最短者返回；找不到返回空串。
String pickShortExample(String text, String word) {
  final lower = word.toLowerCase();
  final wordRe =
      RegExp(r'\b' + RegExp.escape(lower) + r'\b', caseSensitive: false);
  final flat = text.replaceAll(RegExp(r'\s+'), ' ');
  final sentenceRe = RegExp(r'[^.!?。！？]+[.!?。！？]');
  String? best;
  for (final m in sentenceRe.allMatches(flat)) {
    final s = m.group(0)!.trim();
    if (s.length < 3) continue;
    if (!wordRe.hasMatch(s)) continue;
    if (best == null || s.length < best.length) best = s;
  }
  return best ?? '';
}

/// 对英文单词做常见屈折变化还原，返回候选词干（小写、不含原词）。
///
/// 用于课标词映射回退：当拓展词（如 discussing/effectiveness）未直接收录时，
/// 依次尝试去掉 -ing/-ed/-s/-ies/-ness/-ly 等后缀得到词干，再查课标词库。
List<String> _stemCandidates(String word) {
  final s = word.toLowerCase();
  final out = <String>{};
  void addAll(Iterable<String> xs) {
    for (final x in xs) {
      if (x.length >= 3 && x != s) out.add(x);
    }
  }

  if (s.endsWith('ing') && s.length > 5) {
    final stem = s.substring(0, s.length - 3);
    addAll([stem, '${stem}e']);
    if (stem.length >= 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
      addAll([stem.substring(0, stem.length - 1)]); // running -> run
    }
  }
  if (s.endsWith('ied') && s.length > 4) {
    addAll([s.substring(0, s.length - 3) + 'y']); // studied -> study
  }
  if (s.endsWith('ed') && s.length > 4) {
    final stem = s.substring(0, s.length - 2);
    addAll([stem, stem + 'e']);
    if (stem.length >= 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
      addAll([stem.substring(0, stem.length - 1)]); // stopped -> stop
    }
  }
  if (s.endsWith('ies') && s.length > 4) {
    addAll([s.substring(0, s.length - 3) + 'y']); // cities -> city
  }
  if (s.endsWith('es') && s.length > 3) {
    addAll([s.substring(0, s.length - 2), s.substring(0, s.length - 1)]);
  } else if (s.endsWith('s') && s.length > 3) {
    addAll([s.substring(0, s.length - 1)]); // dogs -> dog
  }
  if (s.endsWith('ness') && s.length > 5) {
    addAll([s.substring(0, s.length - 4)]); // effectiveness -> effective
  }
  if (s.endsWith('ly') && s.length > 4) {
    addAll([s.substring(0, s.length - 2)]); // quickly -> quick
  }
  if (s.endsWith('er') && s.length > 4) {
    addAll([s.substring(0, s.length - 2), s.substring(0, s.length - 1)]); // bigger -> big, player -> play
  }
  if (s.endsWith('est') && s.length > 5) {
    addAll([s.substring(0, s.length - 3)]); // biggest -> big
  }
  if (s.endsWith('tion') && s.length > 6) {
    addAll([s.substring(0, s.length - 3)]); // action -> act? action->act 需去e
    addAll([s.substring(0, s.length - 4)]); // creation -> creat? -> create
  }
  return out.toList();
}

/// 解析拓展词对应的课标词，带词形还原回退。
///
/// 先按原词查 [baseWordOf]；查不到时对常见屈折变形做词干还原后重查，
/// 任一命中即返回第一个非空结果。
String resolveBaseWord(String word, String Function(String word) baseWordOf) {
  final direct = baseWordOf(word);
  if (direct.isNotEmpty) return direct;
  for (final cand in _stemCandidates(word)) {
    final r = baseWordOf(cand);
    if (r.isNotEmpty) return r;
  }
  return '';
}

/// 按题型把拓展词分组。
///
/// [text]：被检测的原文全文
/// [extendWords]：检测出的全部拓展词（原始大小写列表）
/// [baseWordOf]：给定拓展词返回对应课标原词（原始大小写，无则返回空串）
/// 同一拓展词全局只列一次，归属其首次出现的题型区间；每行的例句取自该区间原文。
/// 同一句中出现的多个拓展词会自动合并为一行（拓展词、课标词均以空格连接）。
List<ExtendSection> buildExtendSections({
  required String text,
  required List<String> extendWords,
  required String Function(String word) baseWordOf,
}) {
  final lines = text.split('\n');

  // 扩展词小写 -> 原始大小写
  final extendByLower = <String, String>{};
  for (final w in extendWords) {
    extendByLower.putIfAbsent(w.toLowerCase(), () => w);
  }
  if (extendByLower.isEmpty) return const [];

  // 定位各题型标题行（按行匹配规则，记录每个题型首次出现位置）
  final markerByName = <String, int>{};
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i].trim().toLowerCase();
    if (l.isEmpty) continue;
    for (final rule in _sectionRules) {
      if (markerByName.containsKey(rule.name)) continue;
      if (rule.re.hasMatch(l)) {
        markerByName[rule.name] = i;
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
  final globalSeen = <String>{}; // 跨题型全局去重
  for (var k = 0; k < ordered.length; k++) {
    final name = ordered[k].key;
    final start = ordered[k].value;
    final end = k + 1 < ordered.length ? ordered[k + 1].value : lines.length;
    final sectionText = lines.sublist(start, end).join('\n');

    // 收集该题型区间内出现的拓展词（全局去重、按出现顺序）
    final found = <String>[];
    for (final m in wordRe.allMatches(sectionText)) {
      final lower = m.group(0)!.toLowerCase();
      final original = extendByLower[lower];
      if (original != null && globalSeen.add(lower)) {
        found.add(original);
      }
    }
    // 即使该题型区间内没有新增拓展词，也保留题型区块（题型名须完整呈现）
    // 后续 buildExtendTableXml / buildExtendTableText 会以空块/占位行输出

    // 每行：拓展词 + 该区间较短例句 + 课标词（含词形还原回退）
    final rows = found.map((w) {
      return ExtendRowData(
        word: w,
        example: pickShortExample(sectionText, w),
        baseWord: resolveBaseWord(w, baseWordOf),
      );
    }).toList();

    // 同一句中出现多个拓展词时合并为一行：拓展词与课标词均以空格连接，例句只显示一次
    final merged = <ExtendRowData>[];
    final byExample = <String, List<ExtendRowData>>{};
    for (final r in rows) {
      if (r.example.isEmpty) {
        merged.add(r); // 无例句的行不参与合并，保持原样
        continue;
      }
      byExample.putIfAbsent(r.example, () => []).add(r);
    }
    for (final list in byExample.values) {
      if (list.length == 1) {
        merged.add(list.single);
      } else {
        merged.add(ExtendRowData(
          word: list.map((e) => e.word).join(' '),
          example: list.first.example,
          baseWord: list
              .map((e) => e.baseWord)
              .where((b) => b.isNotEmpty)
              .join(' '),
        ));
      }
    }
    sections.add(ExtendSection(name: name, rows: merged));
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
  const grid = [1600, 2400, 3600, 2000]; // 题型/拓展词/真题例句/课标词 列宽 dxa
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
    final header = const ['题型', '拓展词', '真题例句', '课标词'][c];
    sb.write(
        '<w:tc><w:tcPr><w:tcW w:w="${grid[c]}" w:type="dxa"/></w:tcPr>'
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(header)}</w:t></w:r></w:p></w:tc>');
  }
  sb.write('</w:tr>');

  // 数据行：题型名仅在所属区间的首行填写；无拓展词的题型块也输出占位行以保留题型名
  for (final sec in sections) {
    if (sec.rows.isEmpty) {
      final cells = [sec.name, '', '', ''];
      sb.write('<w:tr>');
      for (var c = 0; c < 4; c++) {
        sb.write(
            '<w:tc><w:tcPr><w:tcW w:w="${grid[c]}" w:type="dxa"/></w:tcPr>'
            '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r>'
            '<w:t xml:space="preserve">${_xmlEscape(cells[c])}</w:t></w:r></w:p></w:tc>');
      }
      sb.write('</w:tr>');
      continue;
    }
    for (var i = 0; i < sec.rows.length; i++) {
      final row = sec.rows[i];
      final cells = [i == 0 ? sec.name : '', row.word, row.example, row.baseWord];
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
    sb.writeln('拓展词\t真题例句\t课标词');
    for (final r in sec.rows) {
      sb.writeln('${r.word}\t${r.example}\t${r.baseWord}');
    }
  }
  return sb.toString();
}
