// 构建内置教材资产：把「八套教材」目录下的 doc/docx 转成 txt，
// 输出 assets/textbook/txt/*.txt + assets/textbook/index.json。
//
// 转换复用运行时同一实现 extractDocText（lib/shared/doc_extractor.dart），
// 保证内置教材与用户导入文档的分词/规范化口径完全一致。
//
// 用法：dart run scripts/build_builtin_textbooks.dart [源目录]
// 默认源目录：D:\UserData\Desktop\八套教材
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:esw/shared/doc_extractor.dart';

void main(List<String> args) {
  final srcDir = args.isNotEmpty ? args.first : r'D:\UserData\Desktop\八套教材';
  final dir = Directory(srcDir);
  if (!dir.existsSync()) {
    stderr.writeln('源目录不存在: $srcDir');
    exit(1);
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) {
        final ext = p.extension(f.path).toLowerCase();
        return ext == '.docx' || ext == '.doc';
      })
      .toList()
    ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  if (files.isEmpty) {
    stderr.writeln('未找到 doc/docx 文件: $srcDir');
    exit(1);
  }

  final outDir = Directory(p.join('assets', 'textbook', 'txt'));
  outDir.createSync(recursive: true);

  final books = <Map<String, dynamic>>[];
  var totalChars = 0;
  for (final f in files) {
    final base = p.basenameWithoutExtension(f.path);
    // 教材名只显示版本简称：人教版_全套合并 → 人教版
    final id = base.replaceAll(RegExp(r'[_\-]?全套合并$'), '').trim();
    final text = extractDocText(f.readAsBytesSync()).trim();
    if (text.isEmpty) {
      stderr.writeln('空内容，跳过: ${f.path}');
      continue;
    }
    File(p.join(outDir.path, '$id.txt'))
        .writeAsStringSync(text, encoding: utf8, flush: true);
    final chars = text.runes.length;
    totalChars += chars;
    books.add({
      'id': id,
      'title': id,
      'file': 'txt/$id.txt',
      'chars': chars,
    });
    stdout.writeln('OK $id -> $chars chars');
  }

  final index = {
    'version': 1,
    'generatedAt': DateTime.now().toIso8601String().substring(0, 10),
    'count': books.length,
    'totalChars': totalChars,
    'books': books,
  };
  File(p.join('assets', 'textbook', 'index.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(index),
          encoding: utf8, flush: true);
  stdout.writeln('index.json: ${books.length} books, $totalChars chars');
}
