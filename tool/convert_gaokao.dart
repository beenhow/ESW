// 真题 docx → txt + index.json 转换脚本（构建期一次性使用，不参与 App 运行）。
//
// 用法：
//   dart run tool/convert_gaokao.dart [源目录] [输出目录]
//   默认源目录：D:\UserData\Desktop\精校版高考真题
//   默认输出目录：assets/gaokao
//
// 清洗规则（与勘察结论一致）：
//   1. 只读 word/document.xml，按文档顺序取全部 w:p（含表格单元格内的段落）；
//   2. 丢弃页眉 / 页脚（不在 document.xml 内，天然规避）；
//   3. 制表符当分隔、软换行当断行，并按选项标记断行（A/B/C/D 各自成行）；
//   4. 丢弃答题横线行（连续下划线）与纯空白行；连续空行压成 1 行；
//   5. 不注入任何标记符，保持原文一行一段；
//   6. 输出 UTF-8 无 BOM。
import 'dart:convert';
import 'dart:io';

import 'package:esw/shared/text_normalize.dart';

/// 答题横线：整行基本只有下划线/空格，且不少于 20 个下划线。
final RegExp _answerLineRe = RegExp(r'^[_\s]*_{20,}[_\s]*$');

/// 清洗规则（与运行时共用 lib/shared/text_normalize.dart，避免两处行为分叉）：
///   1. 只读 word/document.xml，按文档顺序取全部 w:p（含表格单元格内的段落）；
///   2. 制表符当分隔、软换行当断行，并按选项标记断行（A/B/C/D 各自成行）；
///   3. 丢弃答题横线行与纯空白行；连续空行压成 1 行；
///   4. 不注入任何标记，保持原文一行一段。
List<String> extractLines(List<int> bytes) {
  final text = extractDocxText(bytes);
  if (text.isEmpty) return const <String>[];
  final out = <String>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }
    if (_answerLineRe.hasMatch(line)) continue;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}

String _stripBom(String s) =>
    s.startsWith('\uFEFF') ? s.substring(1) : s;

void main(List<String> args) {
  final srcDir = args.isNotEmpty
      ? args[0]
      : r'D:\UserData\Desktop\精校版高考真题';
  final outDir = args.length > 1 ? args[1] : 'assets/gaokao';

  final src = Directory(srcDir);
  if (!src.existsSync()) {
    stderr.writeln('源目录不存在：$srcDir');
    exit(2);
  }

  final txtDir = Directory('$outDir/txt');
  if (!txtDir.existsSync()) txtDir.createSync(recursive: true);

  final docxFiles = src
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.docx'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final papers = <Map<String, Object>>[];
  final warnings = <String>[];
  var totalChars = 0;

  for (final f in docxFiles) {
    final base = f.uri.pathSegments.last.replaceAll(RegExp(r'\.docx$', caseSensitive: false), '');
    final yearMatch = RegExp(r'^(\d{4})').firstMatch(base);
    if (yearMatch == null) {
      warnings.add('文件名缺少年份前缀，已跳过：$base');
      continue;
    }
    final year = int.parse(yearMatch.group(1)!);
    var paper = base.substring(4);
    if (paper.startsWith('年')) paper = paper.substring(1);
    paper = paper.trim();
    if (paper.isEmpty) paper = '真题';

    List<String> lines;
    try {
      lines = extractLines(f.readAsBytesSync());
    } catch (e) {
      warnings.add('解析失败，已跳过：$base（$e）');
      continue;
    }
    if (lines.isEmpty) {
      warnings.add('正文为空，已跳过：$base');
      continue;
    }

    final title = lines.first;
    final text = '${lines.join('\n')}\n';
    final txtName = '$base.txt';
    final txtFile = File('${txtDir.path}/$txtName');
    txtFile.writeAsBytesSync(utf8.encode(text), flush: true);
    totalChars += text.length;

    papers.add({
      'id': base,
      'year': year,
      'paper': paper,
      'title': title,
      'file': 'txt/$txtName',
      'chars': text.length,
    });
  }

  papers.sort((a, b) {
    final ya = a['year'] as int, yb = b['year'] as int;
    if (ya != yb) return ya.compareTo(yb);
    return (a['id'] as String).compareTo(b['id'] as String);
  });

  final index = {
    // v2：保留制表符/软换行分隔 + 选项标记断行（修复 A. itB. that 粘连）
    'version': 2,
    'generatedAt': DateTime.now().toIso8601String().split('T').first,
    'count': papers.length,
    'totalChars': totalChars,
    'papers': papers,
  };

  final indexFile = File('$outDir/index.json');
  indexFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(index)}\n',
    encoding: utf8,
  );

  // 自检：逐条确认 txt 存在、UTF-8 无 BOM、首行与 index 标题一致
  var checked = 0;
  for (final p in papers) {
    final path = '$outDir/${p['file']}';
    final bytes = File(path).readAsBytesSync();
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      warnings.add('存在 BOM：${p['id']}');
    }
    final first = _stripBom(utf8.decode(bytes)).split('\n').first;
    if (first.trim() != (p['title'] as String).trim()) {
      warnings.add('首行标题不一致：${p['id']}');
    }
    checked++;
  }

  stdout.writeln('源文件 ${docxFiles.length} 个，产出 ${papers.length} 套');
  stdout.writeln('总字符 $totalChars（avg ${papers.isEmpty ? 0 : totalChars ~/ papers.length}）');
  stdout.writeln('输出目录：${Directory(outDir).absolute.path}');
  stdout.writeln('自检通过 $checked 套');
  if (warnings.isNotEmpty) {
    stdout.writeln('警告 ${warnings.length} 条：');
    for (final w in warnings) {
      stdout.writeln('  - $w');
    }
  }
}
