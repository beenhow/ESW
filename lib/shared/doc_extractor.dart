import 'dart:convert';
import 'dart:typed_data';
import 'package:fast_gbk/fast_gbk.dart' as gbk_pkg;

/// 从 Word 97-2003 二进制格式（.doc，OLE2 复合文档）中提取正文纯文本。
///
/// 提取策略（按优先级）：
/// 1. 标准 piece table 提取（MS-DOC FIB + CLX），可正确处理压缩(cp1252)/非压缩(UTF-16LE)正文；
/// 2. UTF-16LE 启发式扫描 WordDocument 流（兼容 WPS 等非标准实现，中文真题文本通常以此存储）；
/// 3. cp1252 启发式扫描（纯西文压缩文档兜底）；
/// 4. 非 OLE2 时按普通文本解码兜底。
/// 从 Word 97-2003 二进制格式（.doc，OLE2 复合文档）中提取正文纯文本。
///
/// 出口统一将 \r\n / \r 归一化为 \n：doc 原文段落标记为 \r（0x0D），
/// 若不做归一化，按 \n 切行的下游渲染（如检测页原文查看器按行渲染）
/// 会把整段内容粘成超长行，导致长按修改单词时 Text.rich 布局卡顿。
String extractDocText(List<int> bytes) {
  final t = _extractDocTextInner(bytes);
  return t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

String _extractDocTextInner(List<int> bytes) {
  if (bytes.length < 8) return '';
  final isOle = bytes[0] == 0xD0 &&
      bytes[1] == 0xCF &&
      bytes[2] == 0x11 &&
      bytes[3] == 0xE0;
  if (!isOle) {
    // 部分 .doc 实为 RTF 伪装格式（Word/WPS 兼容打开但非 OLE2 二进制），
    // 若直接按纯文本兜底会把 {\rtf...\uXXXX?} 源码显示成乱码，必须先解析 RTF。
    final rtf = _tryDecodeRtf(bytes);
    if (rtf != null) return rtf;
    return _decodeAsText(bytes);
  }
  try {
    final ole = Ole2(bytes);
    final wd = ole.readStream('WordDocument');
    if (wd == null || wd.isEmpty) return _decodeAsText(bytes);

    // 1) 标准 piece table
    final std = _extractByPieceTable(ole, wd);
    if (_looksLikeText(std, 40)) return std;

    // 2) FIB fcMin..fcMac 连续区段 UTF-16 直解：WPS 裁剪 FIB 的文档（cbRgFcLcb
    //    不足）没有可用的 fcClx/lcbClx 与标准 piece table，但正文常以连续
    //    UTF-16LE 直接存储于 fcMin..fcMac 区段，按实际可用偏移解码即为完整正文。
    final range = _decodeUtf16Range(wd);
    if (range.isNotEmpty && _looksLikeText(range, 40)) return range;

    // 3) UTF-16LE 启发式 与 4) cp1252 启发式：piece table 失败后两者都执行，
    //    比较提取完整性取更优者（UTF-16 扫描可能因正文中途 NUL 填充区被截断，
    //    只提出开头一小段"像文本"的内容，此时 cp1252 反而更完整，不能先命中即返）。
    final h16 = _scanUtf16(wd);
    final h8 = _scanCp1252(wd);
    final ok16 = h16.isNotEmpty && _looksLikeText(h16, 40);
    final ok8 = h8.isNotEmpty && _looksLikeText(h8, 70);
    if (ok16 && ok8) return _betterText(h16, h8);
    if (ok16) return h16;
    if (ok8) return h8;

    return '';
  } catch (_) {
    return _decodeAsText(bytes);
  }
}

bool _looksLikeText(String s, int minRatioPercent) {
  if (s.length < 20) return false;
  var good = 0;
  for (final code in s.codeUnits) {
    if (_isPrintableCode(code)) good++;
  }
  return good * 100 >= s.length * minRatioPercent;
}

/// 两路提取结果择优：优先取英文单词量更多者（单词量能反映正文完整度）；
/// 单词量相同（如全中文文档）则取字符数更多者。
String _betterText(String a, String b) {
  final aw = _wordCount(a);
  final bw = _wordCount(b);
  if (aw != bw) return aw > bw ? a : b;
  return a.length >= b.length ? a : b;
}

int _wordCount(String s) {
  var n = 0;
  var inWord = false;
  for (final c in s.codeUnits) {
    final isWord = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    if (isWord && !inWord) n++;
    inWord = isWord;
  }
  return n;
}

bool _isPrintableCode(int c) {
  if (c >= 32 && c < 127) return true;
  if (c == 9 || c == 10 || c == 13) return true;
  if (c >= 0x4E00 && c <= 0x9FFF) return true; // CJK
  if (c >= 0x3000 && c <= 0x303F) return true; // CJK 标点
  if (c >= 0xFF00 && c <= 0xFFEF) return true; // 全角
  if (c == 0x2014 || c == 0x2018 || c == 0x2019) return true;
  if (c == 0x201C || c == 0x201D || c == 0x2026) return true;
  if (c == 0x00B7) return true;
  return false;
}

bool _isBytePrintable(int b) {
  return (b >= 32 && b < 127) || b == 9 || b == 10 || b == 13;
}

String _decodeAsText(List<int> bytes) {
  // 依次尝试 utf8 / latin1
  try {
    final s = latin1.decode(bytes);
    if (_looksLikeText(s, 50)) return s;
  } catch (_) {}
  final s = utf8.decode(bytes, allowMalformed: true);
  return s.replaceAll(RegExp(r'[^\x20-\x7E\u4e00-\u9fff\u3000-\u303f\uff00-\uffef\r\n\t]'), ' ');
}

// ---------------------------------------------------------------------------
// RTF 文本提取（.doc 伪装为 RTF、或直接导入 RTF 源码时使用）
// ---------------------------------------------------------------------------

/// 检测是否为 RTF（{\\rtf...} 头），是则提取纯文本；否则返回 null。
/// RTF 源码按单字节（latin1）解码解析：中文以 \\uN? 转义存储，
/// 控制字与分组不影响正文；图片/对象等二进制组整体跳过。
String? _tryDecodeRtf(List<int> bytes) {
  if (bytes.length < 8) return null;
  var idx = 0;
  // 跳过 UTF-8 BOM（EF BB BF）与前导空白
  while (idx < bytes.length &&
      (bytes[idx] == 0x20 || bytes[idx] == 0x09 || bytes[idx] == 0x0D ||
          bytes[idx] == 0x0A || bytes[idx] == 0xEF || bytes[idx] == 0xBB ||
          bytes[idx] == 0xBF)) {
    idx++;
  }
  final headLen = bytes.length - idx < 32 ? bytes.length - idx : 32;
  if (headLen < 6) return null;
  final head = latin1.decode(bytes.sublist(idx, idx + headLen));
  if (!head.startsWith('{\\rtf')) return null;
  final t = _parseRtf(latin1.decode(bytes));
  if (t.isEmpty) return null;
  return t;
}

String _parseRtf(String src) {
  final sb = StringBuffer();
  var i = 0;
  final n = src.length;
  var uc = 1; // \uN 后的占位字符数（由 \ucN 控制，默认 1）
  var codePage = 1252; // 由 \ansicpgN 指定，\'XX 字节按此代码页解码
  var ansiBytes = <int>[]; // \'XX 产生的原始字节（GBK/cp1252）

  void flushAnsi() {
    if (ansiBytes.isEmpty) return;
    if (codePage == 936 || codePage == 950) {
      // 简体/繁体中文代码页：\'XX 按 GBK 双字节存储，需整体解码
      try {
        sb.write(gbk_pkg.gbk.decode(ansiBytes));
      } catch (_) {
        for (final b in ansiBytes) {
          sb.writeCharCode(b);
        }
      }
    } else {
      for (final b in ansiBytes) {
        sb.writeCharCode(b);
      }
    }
    ansiBytes = <int>[];
  }

  while (i < n) {
    final c = src[i];
    if (c == '\\') {
      i++;
      if (i >= n) break;
      final nc = src[i];
      if (nc == '\\' || nc == '{' || nc == '}') {
        flushAnsi();
        sb.write(nc);
        i++;
        continue;
      }
      if (nc == "'") {
        // \'XX：单字节十六进制（cp1252 或 GBK 代码页字节）
        if (i + 2 < n) {
          final v = int.tryParse(src.substring(i + 1, i + 3), radix: 16);
          if (v != null) ansiBytes.add(v);
          i += 3;
        } else {
          i++;
        }
        continue;
      }
      if (!_isRtfLetter(nc)) {
        flushAnsi();
        i++;
        continue;
      }
      // 控制字：字母序列
      var j = i;
      while (j < n && _isRtfLetter(src[j])) {
        j++;
      }
      final word = src.substring(i, j);
      // 可选参数：符号 + 数字
      var k = j;
      var sign = 1;
      if (k < n && (src[k] == '-' || src[k] == '+')) {
        if (src[k] == '-') sign = -1;
        k++;
      }
      var hasVal = false;
      var val = 0;
      while (k < n && _isRtfDigit(src[k])) {
        hasVal = true;
        val = val * 10 + (src.codeUnitAt(k) - 48);
        k++;
      }
      if (word == 'u') {
        // \uN?：Unicode 码点转义（十进制，可为负表示高位字符）
        flushAnsi();
        if (hasVal) sb.writeCharCode((sign * val) & 0xFFFF);
        // 跳过占位字符（通常是 uc 个 '?'）
        var skipped = 0;
        while (k < n && src[k] == '?' && skipped < uc) {
          k++;
          skipped++;
        }
        i = k;
        continue;
      }
      if (word == 'uc') {
        if (hasVal) uc = sign * val < 0 ? 1 : sign * val;
        i = k;
        continue;
      }
      if (word == 'ansicpg') {
        if (hasVal) codePage = sign * val;
        i = k;
        continue;
      }
      // 字体字符集：简体(134→GBK)/繁体(136→Big5)。仅当未显式声明 ansicpg
      // 时用作代码页推断（兼容缺失 ansicpg 的简版 RTF）。
      if (word == 'fcharset') {
        if (hasVal && codePage == 1252) {
          final cs = sign * val;
          if (cs == 134) {
            codePage = 936;
          } else if (cs == 136) {
            codePage = 950;
          }
        }
        i = k;
        continue;
      }
      if (word == 'par' || word == 'line' || word == 'sect' || word == 'page') {
        flushAnsi();
        sb.write('\n');
        i = k;
        continue;
      }
      if (word == 'tab' || word == 'cell') {
        flushAnsi();
        sb.write('\t');
        i = k;
        continue;
      }
      if (word == 'emdash') {
        flushAnsi();
        sb.write('—');
        i = k;
        continue;
      }
      if (word == 'endash') {
        flushAnsi();
        sb.write('–');
        i = k;
        continue;
      }
      if (word == 'bullet') {
        flushAnsi();
        sb.write('•');
        i = k;
        continue;
      }
      if (word == 'enspace' || word == 'emspace' || word == 'qmspace' ||
          word == 'nbsp') {
        flushAnsi();
        sb.write(' ');
        i = k;
        continue;
      }
      // 图片/对象/二进制数据组：整体跳过，避免十六进制数据污染正文
      if (word == 'pict' || word == 'object' || word == 'bin' ||
          word == 'blip' || word == 'shp') {
        flushAnsi();
        i = _skipRtfGroup(src, k);
        continue;
      }
      // 其它控制字：跳过；控制字与后续文本间的分隔空格属于控制字
      if (k < n && src[k] == ' ') k++;
      i = k;
      continue;
    }
    if (c == '{' || c == '}') {
      i++;
      continue;
    }
    // 中文代码页下：码点 > 0x7F 的原始字节按 GBK/Big5 缓冲，遇 ASCII 再整体解码
    final code = c.codeUnitAt(0);
    if (code > 0x7F && (codePage == 936 || codePage == 950)) {
      ansiBytes.add(code);
      i++;
      continue;
    }
    flushAnsi();
    sb.write(c);
    i++;
  }
  flushAnsi();
  return sb.toString().replaceAll('\r', '\n');
}

bool _isRtfLetter(String ch) {
  final code = ch.codeUnitAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

bool _isRtfDigit(String ch) {
  final code = ch.codeUnitAt(0);
  return code >= 48 && code <= 57;
}

/// 从 idx 起找到最近的 '{' 并跳过整个花括号组（图片/对象二进制区）。
int _skipRtfGroup(String src, int idx) {
  final n = src.length;
  var i = idx;
  while (i < n && src[i] != '{') {
    i++;
  }
  if (i >= n) return idx;
  var depth = 0;
  while (i < n) {
    final c = src[i];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) {
        i++;
        break;
      }
    }
    i++;
  }
  return i;
}

// ---------------------------------------------------------------------------
// UTF-16LE 启发式扫描
// ---------------------------------------------------------------------------
String _scanUtf16(Uint8List wd) {
  final buf = StringBuffer();
  final runs = <String>[];
  var cur = StringBuffer();
  // 跳过 FIB 头：FIB 是流前部数百字节的结构数据，其字节对极易落入 CJK
  // 区间，若从流开头扫描，会在正文前拼出一串无意义的“汉字”乱码。
  // fcMin（FIB 偏移 0x18）是正文最小文件偏移，用它对齐到正文起点。
  var i = _bodyStartOffset(wd);
  final end = _bodyEndOffset(wd);
  while (i + 1 < end) {
    final c = wd[i] | (wd[i + 1] << 8);
    if (c == 0x13 || c == 0x14) {
      // 字段开始/分隔符（0x13/0x14）：跳过整个字段区（代码+结果）直到字段结束符 0x15。
      // 字段结果常为二进制缓存（如页码域），按 UTF-16 读取会产生"伔J倀J"类乱码。
      if (cur.isNotEmpty) {
        if (cur.length >= 8) runs.add(cur.toString());
        cur = StringBuffer();
      }
      var j = i;
      var found = false;
      while (j + 1 < end) {
        if (wd[j] == 0x15 && wd[j + 1] == 0x00) {
          found = true;
          break;
        }
        j += 2;
      }
      i = (found ? j + 2 : i + 2);
      continue;
    }
    if (c == 0x0000) {
      // 跳过连续 NUL 区（不再判定为正文结束）：WPS 正文中途常有 NUL 填充区
      // （如分页符/域结果缓存），若在此 break 会把后半卷正文截断。
      // 跳过该区后继续扫描；尾部若因此混入错位乱码，由 _looksLikeText 与
      // 三路择优统一过滤。
      var j = i;
      while (j + 1 < end && wd[j] == 0 && wd[j + 1] == 0) {
        j += 2;
      }
      i = j;
      continue;
    }
    if (_isPrintableCode(c)) {
      cur.writeCharCode(c);
      i += 2;
    } else {
      if (cur.isNotEmpty) {
        if (cur.length >= 8) runs.add(cur.toString());
        cur = StringBuffer();
      }
      i += 2;
    }
  }
  if (cur.isNotEmpty && cur.length >= 8) runs.add(cur.toString());
  for (final r in runs) {
    buf.write(r);
    buf.write('\n');
  }
  return buf.toString();
}

/// 计算 UTF-16 启发式扫描的起始字节偏移（跳过 FIB 结构头）。
int _bodyStartOffset(Uint8List wd) {
  if (wd.length >= 0x1C) {
    final fcMin = _u32(wd, 0x18); // FIB FibBase 内 fcMin
    if (fcMin > 0 && fcMin < wd.length) return fcMin & ~1;
  }
  return (wd.length ~/ 8) & ~1; // 保守回退：跳过流前 1/8
}

/// 计算 UTF-16 启发式扫描的结束字节偏移：正文区上限 fcMac（FIB 偏移 0x1C）。
/// 限制扫描范围可避免把 fcMac 之后的样式/页眉等结构数据误当正文扫入。
int _bodyEndOffset(Uint8List wd) {
  if (wd.length >= 0x1C) {
    final fcMac = _u32(wd, 0x1C);
    if (fcMac > 0 && fcMac <= wd.length) return fcMac & ~1;
  }
  return wd.length & ~1;
}

/// 按 FIB fcMin..fcMac 连续区段直接按 UTF-16LE 解码。
///
/// 适用 WPS 裁剪 FIB（cbRgFcLcb 不足、无可用 fcClx/lcbClx）的 .doc：
/// 此类文档正文常以连续 UTF-16LE 存储于 fcMin..fcMac，无标准 piece table。
/// 解码时丢弃码元为 0x0000 的字符（正文中途的 NUL 填充区/域缓存），
/// 避免在正文中留下空洞。
String _decodeUtf16Range(Uint8List wd) {
  if (wd.length < 0x1C) return '';
  final fcMin = _u32(wd, 0x18);
  final fcMac = _u32(wd, 0x1C);
  if (fcMin < 0 || fcMac <= fcMin || fcMac > wd.length) return '';
  final start = fcMin & ~1;
  final end = fcMac & ~1;
  if (end - start < 16) return '';
  final buf = StringBuffer();
  for (var i = start; i + 1 < end; i += 2) {
    final c = wd[i] | (wd[i + 1] << 8);
    if (c == 0x0000) continue; // 丢弃 NUL 填充
    buf.writeCharCode(c);
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// cp1252 启发式扫描
// ---------------------------------------------------------------------------
String _scanCp1252(Uint8List wd) {
  final buf = StringBuffer();
  var cur = StringBuffer();
  for (var i = 0; i < wd.length; i++) {
    final b = wd[i];
    if (_isBytePrintable(b)) {
      cur.writeCharCode(b);
    } else {
      if (cur.isNotEmpty) {
        if (cur.length >= 8) {
          buf.write(cur.toString());
          buf.write('\n');
        }
        cur = StringBuffer();
      }
    }
  }
  if (cur.isNotEmpty && cur.length >= 8) {
    buf.write(cur.toString());
    buf.write('\n');
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// 标准 piece table 提取（MS-DOC）
// ---------------------------------------------------------------------------
String _extractByPieceTable(Ole2 ole, Uint8List wd) {
  final table = ole.readStream('1Table') ?? ole.readStream('0Table');
  if (table == null) return '';

  // 优先走标准 FIB fcClx/lcbClx 路径；WPS 等裁剪 FIB 的文档（cbRgFcLcb
  // 不足以覆盖到 33 号表项，如 cbRgFcLcb=183 < 33*8+8）读不到有效偏移，
  // 改为在 Table 流中特征搜索 CLX（Pcdt）兜底。
  var pieces = <_Piece>[];
  final csw = _u16(wd, 0x20);
  final cslw = _u16(wd, 0x22 + csw * 2);
  final fibRgLwOff = 0x22 + csw * 2 + 2;
  final cbRgFcLcb = _u16(wd, fibRgLwOff + cslw * 4);
  if (cbRgFcLcb >= 33 * 8 + 8) {
    final blobOff = fibRgLwOff + cslw * 4 + 2;
    final fcClx = _u32(wd, blobOff + 33 * 8);
    final lcbClx = _u32(wd, blobOff + 33 * 8 + 4);
    if (lcbClx > 0) {
      pieces = _parseClx(table, fcClx, lcbClx);
    }
  }
  if (pieces.isEmpty) {
    pieces = _searchClx(table, wd);
  }
  if (pieces.isEmpty) return '';

  final sb = StringBuffer();
  for (final p in pieces) {
    final startCp = p.startCp;
    final endCp = p.endCp;
    final len = endCp - startCp;
    if (len <= 0) continue;
    if (p.compressed) {
      final start = p.fc;
      if (start < 0 || start + len > wd.length) continue;
      final seg = wd.sublist(start, start + len);
      sb.write(latin1.decode(seg));
    } else {
      final start = p.fc;
      if (start < 0 || start + len * 2 > wd.length) continue;
      final seg = wd.sublist(start, start + len * 2);
      sb.write(utf16leDecode(seg, len));
    }
  }
  return sb.toString();
}

String utf16leDecode(Uint8List seg, int chars) {
  final buf = StringBuffer();
  for (var i = 0; i < chars && i * 2 + 1 < seg.length; i++) {
    final c = seg[i * 2] | (seg[i * 2 + 1] << 8);
    buf.writeCharCode(c);
  }
  return buf.toString();
}

/// Table 流中特征搜索 CLX（Pcdt）兜底：遍历流中所有以 0x02 开头的 PlcPcd
/// 结构，解析出各候选 piece list。仅保留通过有效性校验（Cp 严格递增且
/// 大部分 piece 的 fc 落在 WordDocument 正文范围内）的候选，再取其中
/// Cp 跨度最大的一组——正文 piece table 覆盖字符数最多，远大于脚注/尾注
/// 等其他 Pcdt 或二进制数据中的伪命中。
List<_Piece> _searchClx(Uint8List table, Uint8List wd) {
  var best = <_Piece>[];
  var bestSpan = 0;
  var p = 0;
  while (p + 5 < table.length) {
    if (table[p] == 2) {
      final lcb = _u16(table, p + 1);
      if (lcb >= 4 && p + 3 + lcb <= table.length) {
        final n = (lcb - 4) ~/ 12;
        if (n >= 1 && n < 1000000) {
          final plcpcdEnd = p + 3 + lcb;
          final cpsEnd = p + 3 + (n + 1) * 4;
          final pcdEnd = cpsEnd + n * 8;
          if (pcdEnd <= plcpcdEnd) {
            final ps = _parsePcdtAt(table, p);
            if (_validPieceList(ps, wd)) {
              final span = ps.last.endCp - ps.first.startCp;
              if (span > bestSpan) {
                bestSpan = span;
                best = ps;
              }
            }
          }
        }
      }
      p += 3; // 跳过已识别 Pcdt 头部（0x02 + lcb）
    } else {
      p += 1;
    }
  }
  return best;
}

/// 校验 piece list 是否像真实正文 Pcdt：Cp 严格递增，且至少 60% 的 piece
/// 其 fc 解码后落在 WordDocument 流范围内（压缩 piece 按字节数、非压缩按
/// 双字节），以此排除二进制数据中随机命中 0x02 结构的伪候选。
bool _validPieceList(List<_Piece> ps, Uint8List wd) {
  if (ps.isEmpty) return false;
  var prev = ps.first.startCp;
  var valid = 0;
  for (final p in ps) {
    if (p.endCp < p.startCp || p.startCp < prev) return false;
    prev = p.endCp;
    final len = p.endCp - p.startCp;
    if (len <= 0) continue;
    if (p.compressed) {
      if (p.fc >= 0 && p.fc + len <= wd.length) valid++;
    } else {
      if (p.fc >= 0 && p.fc + len * 2 <= wd.length) valid++;
    }
  }
  return valid * 100 >= ps.length * 60;
}

/// 解析 Table 流中从 pcdtStart（指向 0x02 字节）开始的 Pcdt 结构。
List<_Piece> _parsePcdtAt(Uint8List table, int pcdtStart) {
  final pieces = <_Piece>[];
  if (pcdtStart + 3 > table.length) return pieces;
  final lcb = _u16(table, pcdtStart + 1);
  final plcpcdEnd = pcdtStart + 3 + lcb;
  if (plcpcdEnd > table.length) return pieces;
  final n = (lcb - 4) ~/ 12;
  if (n < 0) return pieces;
  final p = pcdtStart + 3;
  final cps = <int>[];
  for (var i = 0; i <= n; i++) {
    if (p + (i + 1) * 4 > plcpcdEnd) return <_Piece>[];
    cps.add(_u32(table, p + i * 4));
  }
  final pcdOff = p + (n + 1) * 4;
  for (var i = 0; i < n; i++) {
    if (pcdOff + i * 8 + 6 > plcpcdEnd) return <_Piece>[];
    var fc = _u32(table, pcdOff + i * 8 + 2);
    final compressed = (fc & 0x40000000) != 0;
    fc = fc & 0x3FFFFFFF;
    if (compressed) {
      fc = fc >> 1;
    }
    pieces.add(_Piece(cps[i], cps[i + 1], fc, compressed));
  }
  return pieces;
}

List<_Piece> _parseClx(Uint8List table, int fcClx, int lcbClx) {
  final pieces = <_Piece>[];
  if (fcClx < 0 || fcClx + lcbClx > table.length) return pieces;
  var p = fcClx;
  final end = fcClx + lcbClx;
  while (p < end) {
    final t = table[p];
    if (t == 1) {
      // Prc
      final cb = table[p + 1];
      p += 2 + cb;
    } else if (t == 2) {
      // Pcdt
      p += 1;
      if (p + 2 > end) break;
      final lcb = _u16(table, p);
      p += 2;
      final plcpcdEnd = p + lcb;
      if (plcpcdEnd > end) break;
      final n = (lcb - 4) ~/ 12;
      if (n < 0) break;
      final cps = <int>[];
      for (var i = 0; i <= n; i++) {
        cps.add(_u32(table, p + i * 4));
      }
      final pcdOff = p + (n + 1) * 4;
      for (var i = 0; i < n; i++) {
        var fc = _u32(table, pcdOff + i * 8 + 2);
        final compressed = (fc & 0x40000000) != 0;
        fc = fc & 0x3FFFFFFF;
        if (compressed) {
          fc = fc >> 1;
        }
        pieces.add(_Piece(cps[i], cps[i + 1], fc, compressed));
      }
      p = end; // CLX 只含一个 Pcdt（正文）；其后可能还有 Prc，忽略
      break;
    } else {
      break;
    }
  }
  return pieces;
}

class _Piece {
  final int startCp;
  final int endCp;
  final int fc;
  final bool compressed;
  _Piece(this.startCp, this.endCp, this.fc, this.compressed);
}

// ---------------------------------------------------------------------------
// OLE2 复合文档解析
// ---------------------------------------------------------------------------
class _DirEntry {
  final String name;
  final int type;
  final int startSector;
  final int size;
  _DirEntry(this.name, this.type, this.startSector, this.size);
}

class Ole2 {
  final Uint8List data;
  late final int sectorSize;
  late final int miniSize;
  late final List<int> _fat;
  late final List<_DirEntry> _entries;

  Ole2(List<int> raw) : data = Uint8List.fromList(raw) {
    final sectorShift = _u16(data, 30);
    sectorSize = 1 << sectorShift;
    final miniShift = _u16(data, 32);
    miniSize = 1 << miniShift;
    _fat = _buildFat();
    _entries = _buildDirectory();
  }

  static const int _free = 0xFFFFFFFF;
  static const int _endOfChain = 0xFFFFFFFE;

  List<int> _buildFat() {
    final difat = <int>[];
    for (var i = 0; i < 109; i++) {
      difat.add(_u32(data, 0x4C + i * 4));
    }
    var next = _u32(data, 0x44); // firstDIFAT
    final seen = <int>{};
    final cntPerSector = sectorSize ~/ 4 - 1;
    while (next != _free && next != _endOfChain && !seen.contains(next)) {
      seen.add(next);
      final sec = _sectorBytes(next);
      for (var i = 0; i < cntPerSector; i++) {
        difat.add(_u32(sec, i * 4));
      }
      next = _u32(sec, cntPerSector * 4);
    }
    final fat = <int>[];
    for (final ds in difat) {
      if (ds == _free || ds == _endOfChain) continue;
      final sec = _sectorBytes(ds);
      for (var i = 0; i < sectorSize ~/ 4; i++) {
        fat.add(_u32(sec, i * 4));
      }
    }
    return fat;
  }

  Uint8List _sectorBytes(int n) {
    final start = sectorSize * (n + 1);
    if (start >= data.length) return Uint8List(0);
    final end = (start + sectorSize) <= data.length
        ? start + sectorSize
        : data.length;
    return Uint8List.sublistView(data, start, end);
  }

  Uint8List _readChain(int start) {
    final out = BytesBuilder(copy: false);
    var n = start;
    final seen = <int>{};
    while (n != _free && n != _endOfChain && !seen.contains(n) && n < _fat.length) {
      seen.add(n);
      final sec = _sectorBytes(n);
      out.add(sec);
      n = _fat[n];
    }
    return out.toBytes();
  }

  List<_DirEntry> _buildDirectory() {
    final firstDir = _u32(data, 0x30);
    final raw = _readChain(firstDir);
    final entries = <_DirEntry>[];
    for (var o = 0; o + 128 <= raw.length; o += 128) {
      final nameLen = _u16(raw, o + 64);
      if (nameLen < 2 || nameLen > 64) continue;
      final name = utf16leDecode(
          Uint8List.sublistView(raw, o, o + nameLen - 2), (nameLen - 2) ~/ 2);
      final type = raw[o + 66];
      final start = _u32(raw, o + 116);
      final size = _u32(raw, o + 120);
      entries.add(_DirEntry(name, type, start, size));
    }
    return entries;
  }

  Uint8List? readStream(String name) {
    for (final e in _entries) {
      if (e.name == name && e.type == 2) {
        return _readStream(e);
      }
    }
    return null;
  }

  Uint8List _readStream(_DirEntry e) {
    if (e.size < 4096) {
      // mini stream
      _DirEntry? root;
      for (final x in _entries) {
        if (x.name == 'Root Entry') {
          root = x;
          break;
        }
      }
      if (root == null) return Uint8List(0);
      final miniCont = _readChain(root.startSector);
      final minifat = <int>[];
      var n = _u32(data, 0x3C); // firstMiniFAT
      final seen = <int>{};
      while (n != _free && n != _endOfChain && !seen.contains(n)) {
        seen.add(n);
        final sec = _sectorBytes(n);
        for (var i = 0; i < sectorSize ~/ 4; i++) {
          minifat.add(_u32(sec, i * 4));
        }
        n = _fat[n];
      }
      final out = BytesBuilder(copy: false);
      var cur = e.startSector;
      var left = e.size;
      final seen2 = <int>{};
      while (cur != _free && cur != _endOfChain && !seen2.contains(cur) && left > 0) {
        seen2.add(cur);
        final start = cur * miniSize;
        final chunk = (start < miniCont.length)
            ? Uint8List.sublistView(miniCont, start,
                (start + miniSize) <= miniCont.length ? start + miniSize : miniCont.length)
            : Uint8List(0);
        final take = chunk.length < left ? chunk.length : left;
        out.add(Uint8List.sublistView(chunk, 0, take));
        left -= take;
        cur = cur < minifat.length ? minifat[cur] : _endOfChain;
      }
      return out.toBytes();
    } else {
      final raw = _readChain(e.startSector);
      if (raw.length <= e.size) return raw;
      return Uint8List.sublistView(raw, 0, e.size);
    }
  }
}

int _u16(Uint8List b, int o) {
  return b[o] | (b[o + 1] << 8);
}

int _u32(Uint8List b, int o) {
  return b[o] |
      (b[o + 1] << 8) |
      (b[o + 2] << 16) |
      ((b[o + 3] & 0xFF) << 24);
}
