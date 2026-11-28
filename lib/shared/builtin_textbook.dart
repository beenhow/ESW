// 内置教材语料：assets/textbook 内的 index.json + txt 随包发布。
//
// Windows：首启释放到用户目录 textbook/v{N}，作为「内置」分组与用户导入项并存；
// Android：平铺释放到现有教材目录（扫描链路只认这一层），内置清单单独记录。
//
// 与内置真题一致的设计约束：
//  - 写入先落临时文件再 rename，失败静默降级；
//  - 内置文件不写入用户配置（Windows 的 importedTextbookPaths 只存用户导入项）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

/// 单本内置教材的元信息。
class BuiltinBook {
  final String id;
  final String title;
  final String file;
  final int chars;

  const BuiltinBook({
    required this.id,
    required this.title,
    required this.file,
    required this.chars,
  });

  factory BuiltinBook.fromJson(Map<String, dynamic> m) => BuiltinBook(
        id: m['id'] as String,
        title: m['title'] as String? ?? m['id'] as String,
        file: m['file'] as String,
        chars: (m['chars'] as num?)?.toInt() ?? 0,
      );
}

class BuiltinTextbook {
  BuiltinTextbook._();

  static const String assetDir = 'assets/textbook';
  static const String indexAsset = '$assetDir/index.json';

  /// Android 平铺模式下记录内置教材文件名的清单（非 .txt，不参与扫描）。
  static const String flatManifestName = '.builtin_textbook.json';

  /// 读取资产索引；缺失或格式异常时返回 null（调用方静默降级）。
  static Future<({int version, List<BuiltinBook> books})?> loadIndex() async {
    try {
      final raw = await rootBundle.loadString(indexAsset);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final list = (json['books'] as List)
          .map((e) => BuiltinBook.fromJson(e as Map<String, dynamic>))
          .toList();
      if (list.isEmpty) return null;
      return (version: (json['version'] as num?)?.toInt() ?? 1, books: list);
    } catch (_) {
      return null;
    }
  }

  /// Windows：释放到 [baseDir]（通常是 %LOCALAPPDATA%\ESW\textbook）。
  /// 返回释放后的文件路径；已是最新版本时只做校验、不重写。
  static Future<Map<String, String>?> ensureExtracted({
    required String baseDir,
    required int version,
    required List<BuiltinBook> books,
  }) async {
    try {
      final dir = Directory(p.join(baseDir, 'v$version'));
      final marker = File(p.join(dir.path, '.ok'));
      final expected = '${books.length}|$version';
      final paths = <String, String>{};
      for (final book in books) {
        paths[book.id] = p.join(dir.path, '${book.id}.txt');
      }

      if (await marker.exists()) {
        final sig = (await marker.readAsString()).trim();
        if (sig == expected) {
          var allExist = true;
          for (final path in paths.values) {
            if (!await File(path).exists()) {
              allExist = false;
              break;
            }
          }
          if (allExist) return paths;
        }
      }

      await dir.create(recursive: true);
      for (final book in books) {
        final text = await rootBundle.loadString('$assetDir/${book.file}');
        final target = File(paths[book.id]!);
        final tmp = File('${target.path}.tmp');
        await tmp.writeAsString(text, encoding: utf8, flush: true);
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
      }
      await marker.writeAsString(expected, flush: true);
      return paths;
    } catch (_) {
      return null;
    }
  }

  /// Android：把内置教材平铺释放到 [textbookDir]，不覆盖用户同名文件。
  /// 返回本次实际写入的文件名集合；失败返回 null。
  static Future<Set<String>?> installFlat({
    required String textbookDir,
    required int version,
    required List<BuiltinBook> books,
  }) async {
    try {
      final dir = Directory(textbookDir);
      await dir.create(recursive: true);
      final manifest = File(p.join(textbookDir, flatManifestName));
      final oldNames = await flatNames(textbookDir);
      var oldVersion = -1;
      try {
        if (await manifest.exists()) {
          final m = jsonDecode(await manifest.readAsString());
          if (m is Map) oldVersion = (m['version'] as num?)?.toInt() ?? -1;
        }
      } catch (_) {}

      if (oldVersion == version && oldNames.isNotEmpty) {
        var allExist = true;
        for (final name in oldNames) {
          if (!await File(p.join(textbookDir, name)).exists()) {
            allExist = false;
            break;
          }
        }
        if (allExist) return oldNames;
      }

      final names = <String>{};
      for (final book in books) {
        var name = '${book.id}.txt';
        var target = File(p.join(textbookDir, name));
        if (await target.exists() && !oldNames.contains(name)) {
          name = '${book.id}（内置）.txt';
          target = File(p.join(textbookDir, name));
        }
        final text = await rootBundle.loadString('$assetDir/${book.file}');
        final tmp = File('${target.path}.tmp');
        await tmp.writeAsString(text, encoding: utf8, flush: true);
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
        names.add(name);
      }

      for (final name in oldNames) {
        if (names.contains(name)) continue;
        try {
          final f = File(p.join(textbookDir, name));
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      await _writeManifest(manifest, version, names);
      return names;
    } catch (_) {
      return null;
    }
  }

  /// 读取清单里的内置教材文件名（用于导入避让与统计排除）。
  static Future<Set<String>> flatNames(String textbookDir) async {
    final names = <String>{};
    try {
      final manifest = File(p.join(textbookDir, flatManifestName));
      if (!await manifest.exists()) return names;
      final m = jsonDecode(await manifest.readAsString());
      if (m is Map) {
        final files = m['files'];
        if (files is List) {
          for (final e in files) {
            names.add('$e');
          }
        }
      }
    } catch (_) {}
    return names;
  }

  static Future<void> _writeManifest(
    File manifest,
    int version,
    Set<String> names,
  ) async {
    final sorted = names.toList()..sort();
    final tmp = File('${manifest.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'version': version, 'files': sorted}),
      encoding: utf8,
      flush: true,
    );
    if (await manifest.exists()) await manifest.delete();
    await tmp.rename(manifest.path);
  }
}
