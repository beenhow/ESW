/// ESW 双端共用：DOCX 原地标注模块。
///
/// 解决“导出检测结果文档时原文档排版/格式丢失”问题：
/// 不再从零重新生成最小 OOXML，而是对源 docx 副本只改写 word/document.xml——
/// 在需要标注的目标词上拆分 run 并追加高亮/颜色/加粗属性，
/// 其余部件（styles/fontTable/主题/媒体/页眉页脚/rels）原样保留，
/// 因此原文档的字体、字号、缩进、页边距、图片、表格、分页全部不变。
///
/// 标注样式（严格按导出汇总样式图，字色 + 字重七类规范）：
/// - 初中课标词：黑色加粗
/// - 必修课标词：深蓝加粗
/// - 选修课标词：浅蓝（不加粗）
/// - 拓展词：深绿加粗
/// - 超标词：红色（不加粗）
/// - 专有词：紫色（不加粗）
/// - 未筛选：土红色（不加粗）
/// - 真题词 / 其他未知分类：不标注（保持原样）
///
/// 底纹：Word（.docx/.doc）导出结果**不加底纹/高亮**（用户口径）；
/// 底纹只用于 PDF 导出，见 shared/export_annotate_markup.dart 的 PDF 侧实现。
/// 源文档中被标注 run 上原有的 highlight/shd 一并清除，保证导出的 Word 无底纹。
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

const String _wordNs =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/// 单个词的标注样式（仅字色 + 字重；Word 导出不使用底纹）。
class AnnotateStyle {
  final String color; // w:color 值（无 # 前缀）
  final bool bold;
  const AnnotateStyle({required this.color, this.bold = false});
}

/// 分类 -> 标注样式（双端统一）。
///
/// 颜色与字重取自 shared/export_word_style.dart 的七类规范表；
/// 刻意不含任何底纹/高亮字段：Word 导出结果不得出现 w:shd / w:highlight。
Map<String, AnnotateStyle> defaultAnnotateStyles() => const {
      // 初中课标词：黑色加粗
      '初中课标词': AnnotateStyle(color: '000000', bold: true),
      // 必修课标词：深蓝色加粗
      '必修课标词': AnnotateStyle(color: '0B3D91', bold: true),
      // 选修课标词：浅蓝色（不加粗）
      '选修课标词': AnnotateStyle(color: '00B0F0'),
      // 拓展词：深绿色加粗
      '拓展词': AnnotateStyle(color: '006400', bold: true),
      // 超标词：红色（不加粗）
      '超标词': AnnotateStyle(color: 'FF0000'),
      // 专有词：紫色（不加粗）
      '专有词': AnnotateStyle(color: '800080'),
      // 未筛选：土红色（不加粗）
      '未筛选': AnnotateStyle(color: 'A0522D'),
    };

/// OOXML CT_RPr 子元素规范顺序（用于把 b/color/highlight 插入正确位置，
/// 避免 Word 报“元素顺序错乱”）。
const List<String> _rPrOrder = [
  'rStyle', 'rFonts', 'b', 'bCs', 'i', 'iCs', 'caps', 'smallCaps', 'strike',
  'dstrike', 'outline', 'shadow', 'emboss', 'imprint', 'noProof', 'snapToGrid',
  'vanish', 'webHidden', 'color', 'spacing', 'w', 'kern', 'position', 'sz',
  'szCs', 'highlight', 'u', 'effect', 'bdr', 'shd', 'fitText', 'vertAlign',
  'rtl', 'cs', 'em', 'lang', 'eastAsianLayout', 'specVanish', 'oMath',
];

final RegExp _wordRe = RegExp(r'[a-zA-Z]+');
final RegExp _rPrChildTagRe = RegExp(r'<w:([a-zA-Z]+)(?:[^>]*)?/>');

/// 在源 docx 字节上原地标注并追加明细节，返回标注后的 docx 字节。
///
/// [catByLower]：小写单词 -> 分类（拓展词/超标词/专有词等）。
/// [preambleParagraphsXml]：要插入到正文开头的段落 XML（Word 命名空间 w:），
/// 可为空；非空时插到 body 最前（如“ESW 课标词检测导出/文件名/统计/标注说明”汇总块）。
/// [appendixParagraphsXml]：要追加到文末的段落 XML（Word 命名空间 w:），
/// 可为空；非空时在正文末尾（sectPr 之前）追加一节，用于“拓展词明细/超标词”等。
List<int> annotateDocxBytes({
  required List<int> srcBytes,
  required Map<String, String> catByLower,
  List<String> preambleParagraphsXml = const [],
  List<String> appendixParagraphsXml = const [],
}) {
  final archive = ZipDecoder().decodeBytes(srcBytes);
  final docEntry = archive.findFile('word/document.xml');
  if (docEntry == null) {
    throw Exception('word/document.xml not found in docx');
  }
  // 直接引用条目解压字节，避免 Uint8List.fromList 额外复制一份（大文档时多副本推高峰值）。
  final document = XmlDocument.parse(
      utf8.decode(docEntry.content as List<int>, allowMalformed: true));
  _annotateDocument(document, catByLower);
  if (preambleParagraphsXml.isNotEmpty) {
    _insertPreamble(document, preambleParagraphsXml);
  }
  if (appendixParagraphsXml.isNotEmpty) {
    _appendAppendix(document, appendixParagraphsXml);
  }
  final newDocXml = document.toXmlString();
  // 只编码一次，避免 length 与 content 各编码一份（多副本推高峰值）。
  final docXmlBytes = utf8.encode(newDocXml);

  final newArchive = Archive();
  for (final f in archive.files) {
    if (f.name == 'word/document.xml') {
      newArchive.addFile(ArchiveFile(f.name, docXmlBytes.length, docXmlBytes));
    } else {
      // 其余条目（styles/fontTable/媒体/页眉页脚/rels 等）直接复用原解压字节引用，
      // 不再 Uint8List.fromList 复制，降低大文档标注时的内存峰值。
      final data = f.content as List<int>;
      newArchive.addFile(ArchiveFile(f.name, data.length, data));
    }
  }
  final encoder = ZipEncoder();
  final bytes = encoder.encode(newArchive);
  if (bytes == null) throw Exception('DOCX 标注失败（打包失败）');
  return bytes;
}

/// 遍历 document.xml 所有 `<w:t>`，把命中分类的单词拆分为独立 run 并追加标注属性。
void _annotateDocument(XmlDocument document, Map<String, String> catByLower) {
  if (catByLower.isEmpty) return;
  final styles = defaultAnnotateStyles();
  // 收集需要替换的 w:r（引用原节点），统一从后往前替换，避免索引失效
  final replacements = <(XmlElement, String)>[];
  for (final t in document.findAllElements('w:t')) {
    final r = t.parentElement;
    if (r == null || r.name.local != 'r') continue;
    final text = t.innerText;
    if (text.isEmpty) continue;
    // 命中区间：[word, start, end, category]
    final hits = <(String, int, int, String)>[];
    for (final m in _wordRe.allMatches(text)) {
      final cat = catByLower[m.group(0)!.toLowerCase()];
      if (cat != null) hits.add((m.group(0)!, m.start, m.end, cat));
    }
    if (hits.isEmpty) continue;
    // 原 run 的 rPr（若有），命中 run 在其基础上追加属性，未命中 run 原样继承
    final rPr = r.getElement('w:rPr');
    final rPrXml = rPr != null ? rPr.toXmlString() : '';
    final runsXml = <String>[];
    var lastEnd = 0;
    for (final h in hits) {
      if (h.$2 > lastEnd) {
        runsXml.add(_runXml(text.substring(lastEnd, h.$2), rPrXml, null));
      }
      final style = styles[h.$4];
      runsXml.add(
        _runXml(h.$1, rPrXml, style ?? const AnnotateStyle(color: '000000')),
      );
      lastEnd = h.$3;
    }
    if (lastEnd < text.length) {
      runsXml.add(_runXml(text.substring(lastEnd), rPrXml, null));
    }
    replacements.add((r, runsXml.join()));
  }
  for (final rep in replacements.reversed) {
    final parent = rep.$1.parentElement;
    if (parent == null) continue;
    final idx = parent.children.indexOf(rep.$1);
    if (idx < 0) continue;
    parent.children.removeAt(idx);
    final fragment = _parseFragment(rep.$2);
    parent.children.insertAll(idx, fragment);
  }
}

/// 生成单个 `<w:r>`：文本转义 + 继承原 rPr（可选追加标注属性）。
String _runXml(String text, String rPrXml, AnnotateStyle? style) {
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final props = style != null ? _rebuildRPr(rPrXml, style) : rPrXml;
  return '<w:r>$props<w:t xml:space="preserve">$escaped</w:t></w:r>';
}

/// 在原 rPr XML 基础上按规范顺序追加 b/color（仅字色 + 字重，不加底纹）。
///
/// 原 rPr 为空时直接构造最小 rPr。原 rPr 各子元素解析后与注入属性合并，
/// 统一按 [_rPrOrder] 排序输出；解析失败或含非自闭合子元素（极罕见）时
/// 退回“仅注入属性”的最小 rPr（宁可丢罕见格式，绝不生成嵌套 rPr——
/// 嵌套 rPr 会使 Word/WPS 忽略内层 rFonts/sz，导致命中词字体丢失）。
///
/// 底纹口径（用户要求）：Word 导出结果不加底纹/高亮，因此这里既不注入
/// `<w:shd>`，也不注入 `<w:highlight>`；命中 run 上原有的 highlight/shd
/// 会被一并移除（见下方 removeWhere），确保导出的 Word 无底纹。
String _rebuildRPr(String rPrXml, AnnotateStyle style) {
  final props = <String>[
    if (style.bold) '<w:b/>',
    '<w:color w:val="${style.color}"/>',
  ];
  if (rPrXml.isEmpty) {
    return '<w:rPr>${props.join()}</w:rPr>';
  }
  // 去掉外层 <w:rPr> 包裹，只看内部子元素
  final content = rPrXml
      .replaceFirst(RegExp(r'^<w:rPr>'), '')
      .replaceFirst(RegExp(r'</w:rPr>$'), '');
  if (content.contains('</')) {
    // 含非自闭合子元素：退回最小 rPr（仅注入属性），避免嵌套
    return '<w:rPr>${props.join()}</w:rPr>';
  }
  final children = <String>[];
  for (final m in _rPrChildTagRe.allMatches(content)) {
    children.add(m.group(0)!);
  }
  // 移除已有 b/color/highlight/shd，避免重复
  children.removeWhere((x) {
    final m = _rPrChildTagRe.firstMatch(x);
    if (m == null) return false;
    final tag = m.group(1)!;
    return tag == 'b' || tag == 'color' || tag == 'highlight' || tag == 'shd';
  });
  final all = <String>[...children, ...props];
  all.sort((a, b) {
    final na = _rPrChildTagRe.firstMatch(a)?.group(1) ?? '';
    final nb = _rPrChildTagRe.firstMatch(b)?.group(1) ?? '';
    final ra = _rPrOrder.indexOf(na);
    final rb = _rPrOrder.indexOf(nb);
    return (ra < 0 ? 999 : ra).compareTo(rb < 0 ? 999 : rb);
  });
  return '<w:rPr>${all.join()}</w:rPr>';
}

/// 在 `<w:body>` 最前插入汇总段落（preamble）。
void _insertPreamble(XmlDocument document, List<String> paragraphsXml) {
  final body = document.rootElement.getElement('w:body');
  if (body == null) return;
  final fragment = _parseFragment(paragraphsXml.join('\n'));
  body.children.insertAll(0, fragment);
}

/// 在 `<w:body>` 末尾（sectPr 之前）插入明细段落。
void _appendAppendix(XmlDocument document, List<String> paragraphsXml) {
  final body = document.rootElement.getElement('w:body');
  if (body == null) return;
  final fragment = _parseFragment(paragraphsXml.join('\n'));
  final sectPr = body.getElement('w:sectPr');
  if (sectPr != null) {
    final idx = body.children.indexOf(sectPr);
    body.children.insertAll(idx, fragment);
  } else {
    body.children.addAll(fragment);
  }
}

/// 解析带 Word 命名空间的 XML 片段（调用方传入的段落无独立命名空间声明）。
///
/// 返回的节点必须通过 [XmlNode.copy] 脱父：`XmlDocumentFragment.parse` 解析出的
/// 子节点其 parent 仍指向包裹用的临时 root 元素，直接插入目标树会抛
/// `XmlParentException: Node already has a parent`；copy 出的副本 parent 为 null，
/// 可安全 insert 到 body / w:r 容器。
List<XmlNode> _parseFragment(String xml) {
  final doc = XmlDocumentFragment.parse(
    '<root xmlns:w="$_wordNs">$xml</root>',
  );
  final nodes = <XmlNode>[];
  for (final child in doc.children) {
    if (child is XmlElement) {
      for (final node in child.children) {
        nodes.add(node.copy());
      }
    }
  }
  return nodes;
}
