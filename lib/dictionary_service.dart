import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class DictionaryService {
  static Database? _db;
  static const int _dbVersion = 4;

  static Future<Database> _database() async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
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

    _db = await openDatabase(dbPath, readOnly: true);
    return _db!;
  }

  /// 查询单词：返回 {pos, definition, ...}，未收录返回 null
  /// 若单词为变形（如 quitting），自动反查原形（quit）
  static Future<Map<String, String>?> lookup(String word) async {
    try {
      final db = await _database();
      final lower = word.toLowerCase();

      // 1. 精确匹配
      var results = await db.query('dict',
        columns: ['pos', 'definition', 'phonetic', 'collins', 'tag', 'bnc', 'frq', 'exchange'],
        where: 'word = ?',
        whereArgs: [lower],
        limit: 1,
      );

      // 1b. 找到但可能是变形词 → exchange 中有 0:xxx 则改用原形
      if (results.isNotEmpty) {
        final ex = (results.first['exchange'] as String?) ?? '';
        for (final seg in ex.split('/')) {
          final parts = seg.split(':');
          if (parts.length == 2 && parts[0] == '0') {
            // 当前词是变形词，查原形
            final baseResults = await db.query('dict',
              columns: ['pos', 'definition', 'phonetic', 'collins', 'tag', 'bnc', 'frq', 'exchange'],
              where: 'word = ?',
              whereArgs: [parts[1]],
              limit: 1,
            );
            if (baseResults.isNotEmpty) {
              results = baseResults;
            }
            break;
          }
        }
      }

      // 2. 未找到 → exchange 反查变形词
      if (results.isEmpty) {
        final rev = await db.query('dict',
          columns: ['pos', 'definition', 'phonetic', 'collins', 'tag', 'bnc', 'frq', 'exchange'],
          where: 'exchange LIKE ?',
          whereArgs: ['%:%$lower%'],
          limit: 10,
        );
        for (final r in rev) {
          final ex = (r['exchange'] as String?) ?? '';
          for (final seg in ex.split('/')) {
            final parts = seg.split(':');
            if (parts.length == 2 && parts[1].toLowerCase() == lower) {
              // 找到原形词，返回原形的释义
              results = [r];
              break;
            }
          }
          if (results.length == 1) break;
        }
      }

      if (results.isEmpty) return null;
      final r = results.first;
      return {
        'pos': (r['pos'] as String?) ?? '',
        'definition': (r['definition'] as String?) ?? '',
        'phonetic': (r['phonetic'] as String?) ?? '',
        'collins': (r['collins'] ?? 0).toString(),
        'tag': (r['tag'] as String?) ?? '',
        'bnc': (r['bnc'] ?? 0).toString(),
        'frq': (r['frq'] ?? 0).toString(),
      };
    } catch (_) {
      return null;
    }
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
