// 提取文本的统一规范化（运行时与构建脚本共用，避免两处行为分叉）。
//
// 背景：旧实现只拼接 w:t，把 w:tab 与 w:br 当作不存在，
// 于是 Word 里靠制表符/软换行排成四列的选项被压成 `A. itB. thatC. whoseD. which`，
// 分词后产出 itB / ofB / toC / AsC 这类假词。
//
// 规则：
//  1. w:tab → 空格（有效分隔，不能丢）；
//  2. w:br / w:cr → 换行（软换行就是断行）；
//  3. 每行做空白规范化，再按选项标记断行（A/B/C/D 各自独立成行）；
//  4. 只增删空白与换行，不改动任何非空白字符。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// 选项标记：A. / B．等（只认大写 A-H）
final RegExp _markerRe = RegExp(r'([A-H])[.．]');

bool _isUpperLetter(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x41 && u <= 0x5A;
}

/// 单行空白规范化：制表符/不换行空格/全角空格 → 空格，连续空格压成一个。
String normalizeLineText(String raw) {
  var s = raw.replaceAll('\u00A0', ' ').replaceAll('\u3000', ' ');
  s = s.replaceAll(RegExp(r'[\t\r\n]+'), ' ');
  s = s.replaceAll(RegExp(r' {2,}'), ' ');
  return s.trim();
}

/// 按选项标记断行：把 `A. itB. thatC. whoseD. which` 拆成四行。
///
/// 误伤防线：
///  - 只认大写 A-H + 点号，且必须是「连续递增序列」（A→B→C→D）；
///  - 排除缩写（`U.S.A.`：标记前是「大写字母 + .」）、全大写单词句点
///    （`WILD.` / `NBA.`：标记前紧邻大写字母）、`A..` 这类叠点；
///  - 只有 2 个标记时要求首个标记在行首或前缀是纯题号，
///    避免 `Dr. A. Smith and B. Jones`、`Corrado A. G. Piccoli` 被误拆。
List<String> splitOptionMarkers(String line) {
  final starts = <int>[];
  final letters = <String>[];
  for (final m in _markerRe.allMatches(line)) {
    final i = m.start;
    if (i >= 2 && line[i - 1] == '.' && _isUpperLetter(line[i - 2])) continue;
    if (i >= 1 && _isUpperLetter(line[i - 1])) continue;
    if (i + 2 < line.length && line[i + 2] == '.') continue;
    // 注：不排除「标记后紧跟数字」，否则 B.90. / C.118. 这类数字选项无法识别
    starts.add(i);
    letters.add(m.group(1)!);
  }
  if (starts.length < 2) return <String>[line];

  var bestStart = 0, bestLen = 1;
  var s = 0;
  while (s < letters.length) {
    var e = s;
    while (e + 1 < letters.length &&
        letters[e + 1].codeUnitAt(0) == letters[e].codeUnitAt(0) + 1) {
      e++;
    }
    final len = e - s + 1;
    if (len > bestLen) {
      bestLen = len;
      bestStart = s;
    }
    s = e + 1;
  }

  final pos = starts.sublist(bestStart, bestStart + bestLen);
  final head = line.substring(0, pos.first).trim();
  final headIsNumber = RegExp(r'^\d{1,3}[.．、]?$').hasMatch(head);
  if (bestLen < 3 && starts[bestStart] != 0 && !headIsNumber) {
    return <String>[line];
  }

  final out = <String>[];
  if (head.isNotEmpty && !headIsNumber) out.add(head);
  for (var k = 0; k < pos.length; k++) {
    final end = k + 1 < pos.length ? pos[k + 1] : line.length;
    var seg = line.substring(pos[k], end).trim();
    if (k == 0 && headIsNumber) seg = '$head $seg';
    if (seg.isNotEmpty) out.add(seg);
  }
  return out;
}

/// 整段文本规范化（幂等）：制表符当分隔、软换行当断行、选项标记断行、空行折叠。
String normalizeText(String raw) {
  if (raw.isEmpty) return raw;
  final out = <String>[];
  for (final line in raw.split(RegExp(r'\r\n|\r|\n'))) {
    final norm = normalizeLineText(line);
    if (norm.isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }
    out.addAll(splitOptionMarkers(norm));
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  while (out.isNotEmpty && out.first.isEmpty) {
    out.removeAt(0);
  }
  return out.join('\n');
}

/// 分词用字符折叠：只影响“词”的识别，不改动展示原文。
///
/// 解决的问题：
///  - PDF 常见连字（ﬁ/ﬂ）被正则当成非字母，导致 find → nd 这类缺字母 token；
///  - café / naïve / résumé 等带变音符号的词被截成 caf / na / sum；
///  - 全角英文（Ｔｈｅ）完全匹配不到；
///  - 软连字符、零宽字符把单词劈成两半。
String foldWordText(String raw) {
  if (raw.isEmpty) return raw;
  final buf = StringBuffer();
  for (final rune in raw.runes) {
    // 不可见字符：BOM / 零宽 / 软连字符 / 方向控制符
    if (rune == 0x00AD ||
        rune == 0xFEFF ||
        rune == 0x2060 ||
        (rune >= 0x200B && rune <= 0x200F) ||
        (rune >= 0x202A && rune <= 0x202E)) {
      continue;
    }
    // 组合变音符号：é 被拆成 e + U+0301 时只保留 e
    if (rune >= 0x0300 && rune <= 0x036F) continue;
    // 全角 ASCII（！..～）折叠为半角
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buf.writeCharCode(rune - 0xFEE0);
      continue;
    }
    // 常见连字
    switch (rune) {
      case 0xFB00:
        buf.write('ff');
        continue;
      case 0xFB01:
        buf.write('fi');
        continue;
      case 0xFB02:
        buf.write('fl');
        continue;
      case 0xFB03:
        buf.write('ffi');
        continue;
      case 0xFB04:
        buf.write('ffl');
        continue;
      case 0xFB05:
      case 0xFB06:
        buf.write('st');
        continue;
      case 0x2018:
      case 0x2019:
      case 0x02BC:
        buf.write("'");
        continue;
    }
    buf.write(_foldLatin1[rune] ?? String.fromCharCode(rune));
  }
  return buf.toString();
}

/// Latin-1 常见变音字母 → ASCII（大小写保持）。
const Map<int, String> _foldLatin1 = {
  0xC0: 'A', 0xC1: 'A', 0xC2: 'A', 0xC3: 'A', 0xC4: 'A', 0xC5: 'A',
  0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a',
  0xC7: 'C', 0xE7: 'c',
  0xC8: 'E', 0xC9: 'E', 0xCA: 'E', 0xCB: 'E',
  0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e',
  0xCC: 'I', 0xCD: 'I', 0xCE: 'I', 0xCF: 'I',
  0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i',
  0xD1: 'N', 0xF1: 'n',
  0xD2: 'O', 0xD3: 'O', 0xD4: 'O', 0xD5: 'O', 0xD6: 'O', 0xD8: 'O',
  0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o', 0xF8: 'o',
  0xD9: 'U', 0xDA: 'U', 0xDB: 'U', 0xDC: 'U',
  0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u',
  0xDD: 'Y', 0xFD: 'y', 0xFF: 'y',
  0xC6: 'AE', 0xE6: 'ae', 0x152: 'OE', 0x153: 'oe',
  0xDF: 'ss', 0xD0: 'D', 0xF0: 'd', 0xDE: 'TH', 0xFE: 'th',
};

/// 统一词 token：ASCII 字母串，前后不得紧邻字母/数字（与旧 `\b[a-zA-Z]{2,}\b`
/// 的边界语义一致，但作用在 foldWordText 折叠后的文本上）。
final RegExp wordTokenRegExp = RegExp(r'(?<![A-Za-z0-9])[A-Za-z]+(?![A-Za-z0-9])');

/// 选项字母粘连：≥2 字母 + A-H。
///
/// 旧规则要求前缀 ≥3 字母，导致 itB / ofB / toC / AsC 这类三字符粘连漏网；
/// 这里放宽到 2 字母，同时排除全大写缩写（MBA/GPA 等）与常见混合大小写缩写，
/// 避免把 PhD 这类正常缩写误切成 Ph。
final RegExp _optionGlueRe = RegExp(r'^([A-Za-z]{2,})([A-H])$');
const Set<String> _optionGlueExceptions = <String>{'PhD', 'EdD', 'McD'};

bool _isAllCaps(String token) {
  for (final u in token.codeUnits) {
    if (u >= 0x61 && u <= 0x7A) return false;
  }
  return true;
}

/// 从任意文本提取统一词 token（已折叠连字/变音/全角，并剥离选项字母粘连）。
///
/// 两端（Windows / Android）以及语料统计、年份命中统计都应使用本方法，
/// 避免同一份文档在不同功能里得到不同的词边界。
List<String> extractWordTokens(
  String raw, {
  int minLength = 2,
  bool stripOptionGlue = true,
}) {
  if (raw.isEmpty) return const <String>[];
  final out = <String>[];
  for (final m in wordTokenRegExp.allMatches(foldWordText(raw))) {
    var token = m.group(0)!;
    if (token.length < minLength) continue;
    if (stripOptionGlue &&
        token.length >= 3 &&
        !_isAllCaps(token) &&
        !_optionGlueExceptions.contains(token) &&
        // McA/McB/McC 这类三字母人名缩写不按选项粘连处理
        !(token.length == 3 && token.startsWith('Mc'))) {
      final glued = _optionGlueRe.firstMatch(token);
      if (glued != null) token = glued.group(1)!;
    }
    if (token.length >= minLength) out.add(token);
  }
  return out;
}

/// 段落原始文本：按文档顺序保留制表符（→ 空格）与软换行（→ 换行）。
String docxParagraphRaw(XmlElement p) {
  final buf = StringBuffer();
  void walk(XmlElement el) {
    for (final node in el.children) {
      if (node is! XmlElement) continue;
      switch (node.name.local) {
        case 't':
          buf.write(node.innerText);
        case 'tab':
        case 'ptab':
          buf.write(' '); // 有效分隔，不能压掉（ptab 为制表位，同样要留空）
        case 'br':
        case 'cr':
          buf.write('\n'); // 软换行 = 真实换行
        case 'noBreakHyphen':
          buf.write('-'); // 不换行连字符：丢掉会把 well-known 粘成 wellknown
        case 'softHyphen':
          break; // 可选连字符本身不可见，直接忽略
        case 'p':
          // 文本框等嵌套段落：外层段落不再重复收集，交给 findAllElements 单独处理，
          // 否则同一段文字会被统计两次。
          break;
        case 'pPr':
        case 'rPr':
          break;
        default:
          walk(node); // w:r / w:hyperlink / w:smartTag / w:ins ...
      }
    }
  }

  walk(p);
  return buf.toString();
}

/// 从 docx 字节提取规范化正文（运行时 docx 解析与构建脚本共用同一实现）。
String extractDocxText(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final entry = archive.findFile('word/document.xml');
  if (entry == null) return '';
  final content = entry.content;
  final Uint8List data = content is List<int>
      ? Uint8List.fromList(content)
      : content as Uint8List;
  final document = XmlDocument.parse(utf8.decode(data));
  final buf = StringBuffer();
  for (final p in document.findAllElements('w:p')) {
    buf.writeln(docxParagraphRaw(p));
  }
  return normalizeText(buf.toString());
}
