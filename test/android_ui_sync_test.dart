// Android 端追平 Windows 的界面 / 导出能力守卫。
//
// 覆盖：
//   1) 词库主面板以 2×2 统计卡总览课标 / 拓展 / 超标 / 专有四类词库，
//      点卡片进入对应词库列表。
//   2) Android PDF 导出的中文字体资产可被 pdf 包解析，方案一 / 方案二
//      都能生成非空 PDF（无模拟器时以此替代真机截图核验）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;

import 'package:esw/android_app.dart';
import 'package:esw/pages/word_bank_page.dart';
import 'package:esw/shared/export_annotate_markup.dart';
import 'package:esw/shared/export_word_style.dart';
import 'package:esw/shared/vocab_service.dart';
import 'package:esw/shared/word_sync_service.dart';

pw.Font _load(String path) {
  final bytes = File(path).readAsBytesSync();
  return pw.Font.ttf(ByteData.sublistView(Uint8List.fromList(bytes)));
}

Widget _corpusSheet({
  required bool isTextbook,
  required String dirPath,
  String? highlightPath,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CorpusSheet(
        isTextbook: isTextbook,
        dirPath: dirPath,
        highlightPath: highlightPath,
        keyword: null,
        onImportCorpus: () async {},
        onImportTextbook: () async {},
      ),
    ),
  );
}

/// 语料栏内部使用真实文件 I/O，不能用 pumpAndSettle（等待加载动画会超时）：
/// 先让真实事件循环跑完 I/O，再用固定时长 pump 推进滚动动画。
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('语料栏在 320×640 小屏下不溢出、不变形', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = Directory.systemTemp.createTempSync('esw_corpus_small_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    File('${dir.path}/2015安徽卷.txt').writeAsStringSync('Small screen text.');

    await tester.pumpWidget(
      _corpusSheet(isTextbook: false, dirPath: dir.path),
    );
    await tester.pump();
    await _settleIo(tester);

    expect(tester.takeException(), isNull, reason: '小屏下不得出现布局溢出');
    expect(find.text('真题语料'), findsOneWidget);
    expect(find.text('返回段落分析'), findsOneWidget);
    expect(find.text('2015安徽卷'), findsOneWidget);
  });

  testWidgets('语料栏按结果类型切换：真题 / 教材只显示一列，条目就地展开', (tester) async {
    final dir = Directory.systemTemp.createTempSync('esw_corpus_ui_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final paper = File('${dir.path}/2023全国卷I.txt')
      ..writeAsStringSync('Hello ExtendWord world.\nSecond line.');
    File('${dir.path}/2024全国卷II.txt')
        .writeAsStringSync('Another paper text.');

    // 真题结果：真题列占满，教材列不出现
    await tester.pumpWidget(
      _corpusSheet(
        isTextbook: false,
        dirPath: dir.path,
        highlightPath: paper.path,
      ),
    );
    await tester.pump();
    await _settleIo(tester);
    expect(find.text('真题语料'), findsOneWidget);
    expect(find.text('教材语料'), findsNothing);
    expect(find.text('2023全国卷I'), findsOneWidget);
    expect(find.text('2024全国卷II'), findsOneWidget);
    expect(find.text('我的导入（2）'), findsOneWidget);

    // 返回段落分析入口显著放大：明显高于同区域导入按钮
    final back = find.ancestor(
      of: find.text('返回段落分析'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    final importBtn = find.ancestor(
      of: find.text('导入真题'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    expect(back, findsOneWidget);
    expect(
      tester.getSize(back).height,
      greaterThan(tester.getSize(importBtn).height),
      reason: '返回段落分析必须显著大于常规按钮',
    );

    // 点击条目：在该行下方就地展开原文
    await tester.tap(find.text('2023全国卷I'));
    await _settleIo(tester);
    expect(find.textContaining('Hello ExtendWord world.'), findsOneWidget);

    // 教材结果：整列换成教材列表，真题列不出现
    await tester.pumpWidget(
      _corpusSheet(isTextbook: true, dirPath: dir.path),
    );
    await tester.pump();
    await _settleIo(tester);
    expect(find.text('教材语料'), findsOneWidget);
    expect(find.text('真题语料'), findsNothing);
    expect(find.text('我的导入（2）'), findsNothing);
    expect(find.text('教材文件（2）'), findsOneWidget);
    expect(find.text('2023全国卷I'), findsOneWidget);
  });

  testWidgets('词库主面板：四类词库以 2×2 统计卡总览，点卡片进入列表', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WordBankPage(
            vocab: VocabService(),
            onSaveConfig: () {},
            showBaseWordDialog: (word, onAdded) async {},
            onSyncVocab: () {},
            onCheckUpdate: () {},
            onImportCorpus: () async {},
            onImportTextbook: () async {},
            syncing: false,
            wordSyncService: WordSyncService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 四类词库各一张统计卡，恢复简洁的 2×2 总览
    for (final label in ['课标词', '拓展词', '超标词', '专有词']) {
      expect(find.text(label), findsOneWidget, reason: '缺少统计卡：$label');
    }
    // 旧的三个入口按钮已移除
    for (final label in ['拓展词库', '超标词库', '专有词库']) {
      expect(find.text(label), findsNothing);
    }

    // 2×2：第一行课标/拓展同高，第二行超标/专有同高且位于下方
    final yCourse = tester.getTopLeft(find.text('课标词')).dy;
    final yExtend = tester.getTopLeft(find.text('拓展词')).dy;
    final yChao = tester.getTopLeft(find.text('超标词')).dy;
    final yProper = tester.getTopLeft(find.text('专有词')).dy;
    expect(yCourse, closeTo(yExtend, 1), reason: '课标词与拓展词应同处第一行');
    expect(yChao, closeTo(yProper, 1), reason: '超标词与专有词应同处第二行');
    expect(yChao, greaterThan(yCourse), reason: '第二行应位于第一行下方');
  });

  test('PDF 长文必须可跨页：逐行 Column 作为 MultiPage 直接子项', () async {
    // 回归守卫：Padding 不是 SpanningWidget，长文被包在 Padding 里会整块超高，
    // 触发 “Widget won't fit into the page … exceed a page height” 导出失败。
    final font = _load('assets/fonts/NotoSansSC-Regular.ttf');
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: pdf.PdfPageFormat.a4,
        build: (context) => [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 600; i++)
                pw.Text(
                  '第 $i 行：这是用于验证长文本跨页排版的示例内容。',
                  style: pw.TextStyle(font: font, fontSize: 10),
                ),
            ],
          ),
        ],
      ),
    );
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(1000),
        reason: '长文 PDF 应能正常跨页生成，而不是抛出超高异常');
  });

  test('方案一 PDF：只靠字色区分，不加粗 / 不加底纹', () {
    final regular = _load('assets/fonts/NotoSansSC-Regular.ttf');
    final widget = pdfAnnotatedLine(
      'ExtendWord',
      const {'extendword': ExportCategory.extend},
      regular,
      colorBold: false,
      annotateUnfiltered: false,
      annotateShade: false,
    ) as pw.RichText;
    final span = (widget.text as pw.TextSpan).children!.first as pw.TextSpan;
    expect(span.style!.color!.toHex(), '#006400ff');
    expect(span.style!.fontWeight, pw.FontWeight.normal);
    expect(span.style!.background, isNull, reason: '方案一 PDF 不得加底纹');
  });

  test('Android PDF 字体资产可解析，方案一 / 方案二均能生成 PDF', () async {
    final regular = _load('assets/fonts/NotoSansSC-Regular.ttf');
    final bold = _load('assets/fonts/NotoSansSC-Bold.ttf');
    const text = 'ExtendWord OverLimitWord ProperWord 中文正文';
    const catByLower = {
      'extendword': ExportCategory.extend,
      'overlimitword': ExportCategory.overLimit,
      'properword': ExportCategory.proper,
    };

    for (final scheme in ExportAnnotateScheme.values) {
      final doc = pw.Document();
      doc.addPage(
        pw.Page(
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'ESW 文本检测导出',
                style: pw.TextStyle(font: bold, fontSize: 16),
              ),
              pdfAnnotatedLine(
                text,
                catByLower,
                regular,
                scheme: scheme,
                colorBold: false,
                annotateUnfiltered: false,
                wordFont: pw.Font.times(),
                boldFont: pw.Font.timesBold(),
              ),
            ],
          ),
        ),
      );
      final bytes = await doc.save();
      expect(
        bytes.length,
        greaterThan(2000),
        reason: '$scheme 方案的 PDF 产物异常',
      );
    }
  });
}
