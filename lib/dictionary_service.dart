import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:path/path.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class DictionaryService {
  static sqlite3.Database? _db;
  static const int _dbVersion = 8;
  static const Map<String, String> _posMap = {
    'j': 'adj.',
    'r': 'adv.',
    'n': 'n.',
    'v': 'v.',
    'p': 'pron.',
    'd': 'det.',
    'c': 'conj.',
    'i': 'prep.',
    'u': 'interj.',
    't': 'abbr.',
  };

  static Future<sqlite3.Database> _database() async {
    if (_db != null) return _db!;

    final dbPath = await _deployDb();
    _db = sqlite3.sqlite3.open(dbPath);
    return _db!;
  }

  /// 确保词典库已部署到本地，并返回其绝对路径。
  /// 跨平台统一：Windows 为 LOCALAPPDATA/ESW/ecdict.db，
  /// Android 为应用文档目录/ESW/ecdict.db。
  /// 供导出等需要在独立 isolate 中自行打开数据库的调用方使用，
  /// 避免直接拼接目录导致打开空库（如安卓端导出高频 no such table: dict）。
  static Future<String> ensureDeployedDbPath() async {
    return _deployDb();
  }

  /// 部署词典库：版本过低或缺失时从 assets/ecdict.db 拷贝到本地目录。
  static Future<String> _deployDb() async {
    // 跨平台目录：Android 用 path_provider，Windows 用 LOCALAPPDATA
    String baseDir;
    if (Platform.isWindows) {
      baseDir = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          '.';
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      baseDir = appDir.path;
    }

    final dir = Directory(join(baseDir, 'ESW'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final dbPath = join(dir.path, 'ecdict.db');
    final versionPath = join(dir.path, 'ecdict.version');

    int localVersion = 0;
    try {
      final vf = File(versionPath);
      if (await vf.exists()) {
        localVersion = int.tryParse(await vf.readAsString()) ?? 0;
      }
    } catch (_) {}

    if (localVersion < _dbVersion) {
      try { await File(dbPath).delete(); } catch (_) {}
      final data = await rootBundle.load('assets/ecdict.db');
      await File(dbPath).writeAsBytes(data.buffer.asUint8List());
      await File(versionPath).writeAsString(_dbVersion.toString());
    } else if (!await File(dbPath).exists()) {
      final data = await rootBundle.load('assets/ecdict.db');
      await File(dbPath).writeAsBytes(data.buffer.asUint8List());
      await File(versionPath).writeAsString(_dbVersion.toString());
    }

    return dbPath;
  }

  static Map<String, String>? _rowToResult(sqlite3.Row row) {
    final def = row['definition'];
    final pos = row['pos'];
    if ((def == null || (def as String).isEmpty) &&
        (pos == null || (pos as String).isEmpty)) {
      return null;
    }
    final rawPos = (pos as String?) ?? '';
    var cleanPos = rawPos.split('/').map((s) {
      final code = s.split(':').first;
      return _posMap[code] ?? code;
    }).join('/');
    // pos 为空时，从 exchange 推断词性
    if (cleanPos.isEmpty) {
      final exchange = (row['exchange'] as String?) ?? '';
      if (exchange.isNotEmpty) {
        if (RegExp(r'(^|/)s:').hasMatch(exchange)) {
          cleanPos = 'n.';
        } else if (RegExp(r'(^|/)(d|i|3):').hasMatch(exchange)) {
          cleanPos = 'v.';
        } else if (RegExp(r'(^|/)(r|t):').hasMatch(exchange)) {
          cleanPos = 'adj./adv.';
        }
      }
    }
    return {
      'pos': cleanPos,
      'definition': (def as String?) ?? '',
      'phonetic': (row['phonetic'] as String?) ?? '',
      'tag': (row['tag'] as String?) ?? '',
      'exchange': (row['exchange'] as String?) ?? '',
    };
  }

  /// 查询单词：返回 {pos, definition, ...}，未收录返回 null
  /// 若单词为变形（如 quitting），自动反查原形（quit）
  static Future<Map<String, String>?> lookup(String word) async {
    try {
      final db = await _database();
      final lower = word.toLowerCase();

      // 1. 精确匹配
      final rows = db.select(
        'SELECT pos, definition, phonetic, tag, exchange '
        'FROM dict WHERE word = ? LIMIT 1',
        [lower],
      ).toList();
      var result = rows.isNotEmpty ? _rowToResult(rows.first) : null;

      // 1b. 找到但可能是变形词 → exchange 中有 0:xxx 则改用原形
      if (result != null) {
        final ex = result['exchange'] ?? '';
        for (final seg in ex.split('/')) {
          final parts = seg.split(':');
          if (parts.length == 2 && parts[0] == '0') {
            final baseRows = db.select(
              'SELECT pos, definition, phonetic, tag, exchange '
              'FROM dict WHERE word = ? LIMIT 1',
              [parts[1]],
            ).toList();
            final baseResult = baseRows.isNotEmpty ? _rowToResult(baseRows.first) : null;
            if (baseResult != null) result = baseResult;
            break;
          }
        }
      }

      // 2. 未找到 → exchange 反查变形词
      if (result == null) {
        for (final row in db.select(
          'SELECT pos, definition, phonetic, tag, exchange '
          'FROM dict WHERE exchange LIKE ? LIMIT 10',
          ['%:%$lower%'],
        )) {
          final ex = (row['exchange'] as String?) ?? '';
          for (final seg in ex.split('/')) {
            final parts = seg.split(':');
            if (parts.length == 2 && parts[1].toLowerCase() == lower) {
              result = _rowToResult(row);
              break;
            }
          }
          if (result != null) break;
        }
      }

      if (result == null) {
        return null;
      }
      return result;
    } catch (e) {
      debugPrint('[DictService] lookup error: $e');
      return null;
    }
  }

  static Future<void> close() async {
    if (_db != null) {
      _db!.dispose();
      _db = null;
    }
  }
}
