// 内置真题语料：assets 内的 index.json + txt 随包发布，首启释放到用户目录，
// 之后完全复用现有「真题导入」链路（文件路径 + 文件名年份前缀），不新增数据层。
//
// Windows 与 Android 共用本文件：
//  - Windows 走 ensureExtracted：释放到 baseDir/v{N}（版本目录，避免每次启动重写）；
//  - Android 走 installFlat：平铺到现有 corpus 目录（扫描链路只认这一层），
//    用户同名文件不覆盖，内置文件记入清单，便于隐藏/恢复与导入避让。
//
// 设计约束：
//  - 写入先落临时文件再 rename，避免中途退出留下半截文件；
//  - 任何失败都返回空，不影响主流程（App 仍可正常手动导入）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

/// 单套内置真题的元信息。
class BuiltinPaper {
  final String id;
  final int year;
  final String paper;
  final String title;
  final String file;
  final int chars;

  const BuiltinPaper({
    required this.id,
    required this.year,
    required this.paper,
    required this.title,
    required this.file,
    required this.chars,
  });

  factory BuiltinPaper.fromJson(Map<String, dynamic> m) => BuiltinPaper(
        id: m['id'] as String,
        year: (m['year'] as num).toInt(),
        paper: m['paper'] as String? ?? '',
        title: m['title'] as String? ?? '',
        file: m['file'] as String,
        chars: (m['chars'] as num?)?.toInt() ?? 0,
      );
}

class BuiltinCorpus {
  BuiltinCorpus._();

  static const String assetDir = 'assets/gaokao';
  static const String indexAsset = '$assetDir/index.json';

  /// Android 平铺模式下记录「哪些文件由内置释放写入」的清单（非 .txt，不参与扫描）。
  static const String flatManifestName = '.builtin_corpus.json';

  /// 读取资产索引；缺失或格式异常时返回 null（调用方静默降级）。
  static Future<({int version, List<BuiltinPaper> papers})?> loadIndex() async {
    try {
      final raw = await rootBundle.loadString(indexAsset);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final list = (json['papers'] as List)
          .map((e) => BuiltinPaper.fromJson(e as Map<String, dynamic>))
          .toList();
      if (list.isEmpty) return null;
      return (version: (json['version'] as num?)?.toInt() ?? 1, papers: list);
    } catch (_) {
      return null;
    }
  }

  /// 把内置 txt 释放到 [baseDir]（通常是 %LOCALAPPDATA%\ESW\corpus）。
  ///
  /// 返回释放后的文件路径；失败返回 null。已是最新版本时只做校验、不重写。
  static Future<Map<String, String>?> ensureExtracted({
    required String baseDir,
    required int version,
    required List<BuiltinPaper> papers,
  }) async {
    try {
      final dir = Directory(p.join(baseDir, 'v$version'));
      final marker = File(p.join(dir.path, '.ok'));
      final expected = '${papers.length}|$version';
      final paths = <String, String>{};
      for (final paper in papers) {
        paths[paper.id] = p.join(dir.path, '${paper.id}.txt');
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
      for (final paper in papers) {
        final text = await rootBundle.loadString('$assetDir/${paper.file}');
        final target = File(paths[paper.id]!);
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

  /// Android：把内置 txt 平铺释放到 [corpusDir]（应用文档目录/corpus）。
  ///
  /// 与用户导入共存且互不覆盖：
  ///  - 目标名已被用户占用（不在上一版清单里）→ 改写为「{id}（内置）.txt」；
  ///  - 上一版清单里的自家文件才允许覆盖，其余用户文件一律不碰；
  ///  - 返回本次实际写入的文件名集合；失败返回 null。
  static Future<Set<String>?> installFlat({
    required String corpusDir,
    required int version,
    required List<BuiltinPaper> papers,
  }) async {
    try {
      final dir = Directory(corpusDir);
      await dir.create(recursive: true);
      final manifest = File(p.join(corpusDir, flatManifestName));
      final oldNames = await flatNames(corpusDir);
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
          if (!await File(p.join(corpusDir, name)).exists()) {
            allExist = false;
            break;
          }
        }
        if (allExist) return oldNames;
      }

      final names = <String>{};
      for (final paper in papers) {
        var name = '${paper.id}.txt';
        var target = File(p.join(corpusDir, name));
        if (await target.exists() && !oldNames.contains(name)) {
          name = '${paper.id}（内置）.txt';
          target = File(p.join(corpusDir, name));
        }
        final text = await rootBundle.loadString('$assetDir/${paper.file}');
        final tmp = File('${target.path}.tmp');
        await tmp.writeAsString(text, encoding: utf8, flush: true);
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
        names.add(name);
      }

      // 版本升级或清单变化时清掉自家旧文件，避免同一套真题残留两份。
      for (final name in oldNames) {
        if (names.contains(name)) continue;
        try {
          final f = File(p.join(corpusDir, name));
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      await _writeManifest(manifest, version, names);
      return names;
    } catch (_) {
      return null;
    }
  }

  /// Android：隐藏内置真题 = 把清单里的自家文件移出 corpus（不删除资产）。
  /// 返回被移出的文件名集合；清单保留，便于之后 [installFlat] 恢复。
  static Future<Set<String>> removeFlat({required String corpusDir}) async {
    final removed = <String>{};
    try {
      for (final name in await flatNames(corpusDir)) {
        try {
          final f = File(p.join(corpusDir, name));
          if (await f.exists()) {
            await f.delete();
            removed.add(name);
          }
        } catch (_) {}
      }
    } catch (_) {}
    return removed;
  }

  /// 读取清单里的内置文件名（含隐藏状态，用于导入避让与恢复）。
  static Future<Set<String>> flatNames(String corpusDir) async {
    final names = <String>{};
    try {
      final manifest = File(p.join(corpusDir, flatManifestName));
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

  /// 读取清单记录的版本号（无清单返回 -1），用于判断是否需要让词频索引失效。
  static Future<int> flatVersion(String corpusDir) async {
    try {
      final manifest = File(p.join(corpusDir, flatManifestName));
      if (!await manifest.exists()) return -1;
      final m = jsonDecode(await manifest.readAsString());
      if (m is Map) return (m['version'] as num?)?.toInt() ?? -1;
    } catch (_) {}
    return -1;
  }

  /// 清单原子写：临时文件 + rename。
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
