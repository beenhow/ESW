import 'dart:convert';
import 'dart:typed_data';

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
    return _decodeAsText(bytes);
  }
  try {
    final ole = Ole2(bytes);
    final wd = ole.readStream('WordDocument');
    if (wd == null || wd.isEmpty) return _decodeAsText(bytes);

    // 1) 标准 piece table
    final std = _extractByPieceTable(ole, wd);
    if (_looksLikeText(std, 40)) return std;

    // 2) UTF-16LE 启发式
    final h16 = _scanUtf16(wd);
    if (h16.isNotEmpty && _looksLikeText(h16, 40)) return h16;

    // 3) cp1252 启发式（要求较高可读比例以过滤格式噪音）
    final h8 = _scanCp1252(wd);
    if (h8.isNotEmpty && _looksLikeText(h8, 70)) return h8;

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
  while (i + 1 < wd.length) {
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
      while (j + 1 < wd.length) {
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
      // 连续 NUL（≥8 对）判定为正文结束：WPS 文档页脚/页码域后常有大段
      // 0x00 填充，其后的错位字节若继续扫描会产生"伔J倀J儀J帀J愀"类乱码。
      var n = 0;
      var j = i;
      while (j + 1 < wd.length && wd[j] == 0 && wd[j + 1] == 0) {
        n++;
        j += 2;
      }
      if (n >= 8) break;
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
  final csw = _u16(wd, 0x20);
  final cslw = _u16(wd, 0x22 + csw * 2);
  final fibRgLwOff = 0x22 + csw * 2 + 2;
  final cbRgFcLcb = _u16(wd, fibRgLwOff + cslw * 4);
  if (cbRgFcLcb < 33 * 8 + 8) return '';
  final blobOff = fibRgLwOff + cslw * 4 + 2;
  final fcClx = _u32(wd, blobOff + 33 * 8);
  final lcbClx = _u32(wd, blobOff + 33 * 8 + 4);
  if (lcbClx <= 0) return '';

  final table = ole.readStream('1Table') ?? ole.readStream('0Table');
  if (table == null) return '';

  final pieces = _parseClx(table, fcClx, lcbClx);
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
        final flags = _u16(table, pcdOff + i * 8);
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
