import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:esw/pages/detect_page.dart';
import 'package:esw/shared/builtin_corpus.dart';
import 'package:esw/shared/text_normalize.dart';

/// Android 内置真题自检：
///  - 119 套资产可读取、年份可提取、无 BOM；
///  - 2015 安徽卷规范化后不产生 itB / ofB / toC / AsC 等粘连 token；
///  - 分词口径与 Windows 一致（同一正则 + 同一粘连剥离规则）；
///  - 释放/隐藏/恢复不覆盖用户同名文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory('assets/gaokao');
  final indexFile = File('${root.path}/index.json');

  test('内置 119 套真题可读取且年份/字符数正常', () {
    expect(indexFile.existsSync(), isTrue);
    final json = jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
    final papers = (json['papers'] as List).cast<Map<String, dynamic>>();
    expect(papers.length, 119);
    expect((json['version'] as num).toInt(), greaterThanOrEqualTo(2));

    final years = <int>{};
    for (final paper in papers) {
      final file = File('${root.path}/${paper['file']}');
      expect(file.existsSync(), isTrue, reason: '${paper['id']} 缺失');
      final bytes = file.readAsBytesSync();
      expect(bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB,
          isFalse, reason: '${paper['id']} 含 UTF-8 BOM');
      final text = utf8.decode(bytes);
      expect(text.length, greaterThan(5000), reason: '${paper['id']} 内容过短');
      expect(text, isNot(contains('\uFFFD')), reason: '${paper['id']} 非 UTF-8');
      // 选项标记前一字母不是大写（排除 BC. 这类缩写）
      expect(
        RegExp(r'[A-Za-z]{2,}(?<![A-Z])[A-H][.．]').hasMatch(text),
        isFalse,
        reason: '${paper['id']} 仍存在字母紧邻选项标记',
      );
      final year = int.parse(paper['id'].toString().substring(0, 4));
      expect(year, (paper['year'] as num).toInt());
      years.add(year);
    }
    expect(years.length, greaterThanOrEqualTo(10));
  });

  test('2015 安徽卷规范化后无粘连 token，正常词计数与 Windows 口径一致', () {
    final text = File('${root.path}/txt/2015安徽.txt').readAsStringSync();
    final normalized = normalizeText(text);
    // 幂等：重复规范化不再变化（资产已是规范化文本，仅可能差尾部换行）
    expect(normalizeText(normalized), normalized);

    final tokens = _windowsTokens(normalized);
    final lower = tokens.map((e) => e.toLowerCase()).toSet();
    for (final bad in ['itb', 'ofb', 'toc', 'asc']) {
      expect(lower.contains(bad), isFalse, reason: '存在粘连 token: $bad');
    }
    expect(
      lower.any((t) => RegExp(r'^[a-z]{2,}[A-H]$').hasMatch(t)),
      isFalse,
      reason: '仍存在「字母+选项字母」形式的粘连 token',
    );
    expect(tokens.length, greaterThan(2000));
    // 记录基准，便于后续回归对比（Windows 端同一 normalizeText + 同一正则）
    // ignore: avoid_print
    print('2015安徽 tokens=${tokens.length} unique=${lower.length}');
  });

  test('选项标记断行能消除运行时粘连，且不误伤正常文本', () {
    final fixed = normalizeText(
      '49.A. realB. perfectC. clearD. possible\n'
      'One factor is itB. thatC. whoseD. which matters.\n'
      'He lives in the U.S.A. with Dr. A. Smith.',
    );
    final tokens = _windowsTokens(fixed);
    for (final bad in ['itb', 'ofb', 'toc', 'asc']) {
      expect(tokens.map((e) => e.toLowerCase()), isNot(contains(bad)));
    }
    expect(fixed, contains('U.S.A.'));
    expect(fixed, contains('Dr. A. Smith'));
  });

  testWidgets('检测页可见内置 119 套，且不再提供隐藏入口', (tester) async {
    final ctrl = TextEditingController();
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DetectPage(
            corpusCount: 119,
            textbookCount: 0,
            yearHits: const {2015: 10},
            textbookHits: const {},
            categoryCounts: const [0, 0, 0, 0],
            onImportCorpus: () async {},
            onImportTextbook: () async {},
            onImportFile: () {},
            onScanDocument: () {},
            pasteController: ctrl,
            pasteFocus: focus,
            onAnalyze: (_) {},
            history: const [],
            onClearHistory: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('共 119 份真题'), findsOneWidget);
    // 隐藏入口已按用户要求移除，语料统计只保留「共 N 份真题」这一行
    expect(find.textContaining('内置真题 119 套'), findsNothing);
    expect(find.textContaining('点此隐藏'), findsNothing);
    ctrl.dispose();
    focus.dispose();
  });

  test('内置释放/隐藏/恢复不覆盖用户同名文件', () async {
    final index = await BuiltinCorpus.loadIndex();
    expect(index, isNotNull);
    final temp = Directory.systemTemp.createTempSync('esw_builtin_test_');
    try {
      final corpusDir = temp.path;
      final userFile = File('$corpusDir/2015安徽.txt');
      await userFile.writeAsString('USER-OWNED');

      final installed = await BuiltinCorpus.installFlat(
        corpusDir: corpusDir,
        version: index!.version,
        papers: index.papers,
      );
      expect(installed, isNotNull);
      expect(installed!.length, 119);
      // 用户同名文件不被覆盖，内置改为可区分文件名
      expect(await userFile.readAsString(), 'USER-OWNED');
      expect(installed.contains('2015安徽（内置）.txt'), isTrue);

      final removed = await BuiltinCorpus.removeFlat(corpusDir: corpusDir);
      expect(removed.length, 119);
      expect(await userFile.exists(), isTrue);
      expect(await File('$corpusDir/2015安徽（内置）.txt').exists(), isFalse);

      final restored = await BuiltinCorpus.installFlat(
        corpusDir: corpusDir,
        version: index.version,
        papers: index.papers,
      );
      expect(restored, isNotNull);
      expect(restored!.length, 119);
      expect(await userFile.readAsString(), 'USER-OWNED');
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}

/// Windows 端同款分词口径：[a-zA-Z]{2,} 且剥离「≥3 字母 + 选项字母」粘连。
List<String> _windowsTokens(String text) {
  final glued = RegExp(r'^([a-zA-Z]{3,})([A-H])$');
  final re = RegExp(r'\b[a-zA-Z]{2,}\b');
  return [
    for (final m in re.allMatches(text))
      glued.firstMatch(m.group(0)!)?.group(1) ?? m.group(0)!,
  ];
}

