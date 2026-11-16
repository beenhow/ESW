// 安卓 / Windows 导出原文标注口径一致性守卫。
//
// 用户口径（本轮）：
//   1) 导出文档对单词的标注严格按 Windows 版——课标词按课标级别区分
//      「初中 / 必修 / 选修」，统计与标注一致；拓展 / 超标 / 专有原样；
//      「真题词」「未筛选」的定义与 Windows 完全相同。
//   2) 双端口径单点落地于 shared/export_word_style.dart 的
//      exportAnnotateCategoryOfDetected，本测试锁定该映射与最终 DOCX run 表现。
import 'package:esw/shared/export_annotate_markup.dart';
import 'package:esw/shared/export_word_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('检测分类 → 导出分类（双端唯一口径）', () {
    test('课标词按课标级别细分为初中 / 必修 / 选修三色', () {
      expect(
        exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '初中'),
        ExportCategory.standardJunior,
      );
      expect(
        exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '必修'),
        ExportCategory.standardCompulsory,
      );
      expect(
        exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '选修'),
        ExportCategory.standardElective,
      );
    });

    test('课标级别缺失时按初中处理（与导出统计口径一致）', () {
      expect(
        exportAnnotateCategoryOfDetected(category: '课标词'),
        ExportCategory.standardJunior,
      );
      expect(
        exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '未知级别'),
        ExportCategory.standardJunior,
      );
      // 未知级别必须与「初中」落同一分类，否则统计分类与正文着色会错位
      expect(
        exportAnnotateCategoryOfDetected(category: '课标词', standardLevel: ''),
        exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '初中'),
      );
    });

    test('拓展 / 超标 / 专有词原样透传并取到规范色与字重', () {
      const carries = <String>[
        ExportCategory.extend,
        ExportCategory.overLimit,
        ExportCategory.proper,
      ];
      for (final c in carries) {
        final cat = exportAnnotateCategoryOfDetected(category: c);
        expect(cat, c, reason: '$c 不应被改写');
        final spec = exportWordStyleOf(cat);
        expect(spec, isNotNull, reason: '$c 必须取到规范色');
        expect(spec!.colorHex, kExportWordStyles[c]!.colorHex);
        expect(spec.bold, kExportWordStyles[c]!.bold);
      }
      final extend = exportWordStyleOf(ExportCategory.extend)!;
      expect(extend.bold, isTrue, reason: '拓展词应加粗');
      expect(extend.colorHex.toLowerCase().endsWith('6400'), isTrue,
          reason: '拓展词应为深绿色系，实际 ${extend.colorHex}');
    });

    test('未筛选 / 其他：语料出现过 → 真题词（不配色），否则 → 未筛选（土红）', () {
      for (final raw in <String>['未筛选', '其他']) {
        // 真题语料出现过：叠加为真题词，不参与配色标注
        final inCorpus =
            exportAnnotateCategoryOfDetected(category: raw, isInCorpus: true);
        expect(inCorpus, '真题词', reason: '$raw + 语料命中应降为真题词');
        expect(exportWordStyleOf(inCorpus), isNull);

        // 四库均不收录且语料未出现：未筛选（土红色，不加粗）
        final unfiltered =
            exportAnnotateCategoryOfDetected(category: raw, isInCorpus: false);
        expect(unfiltered, ExportCategory.unfiltered);
        final spec = exportWordStyleOf(unfiltered);
        expect(spec, isNotNull, reason: '未筛选必须有规范色');
        expect(spec!.colorHex, 'A0522D');
        expect(spec.bold, isFalse);
      }
    });

    test('七类导出分类全部能取到规范样式，无遗漏', () {
      for (final c in ExportCategory.all) {
        expect(exportWordStyleOf(c), isNotNull, reason: '$c 缺少规范样式');
      }
    });
  });

  group('DOCX 原文标注（安卓导出真实调用路径）', () {
    String annotate(String text, Map<String, String> catByLower) =>
        docxAnnotatedParagraphXml(text, catByLower);

    test('七类词逐类按规范色 + 字重标注，真题词保持默认黑', () {
      final catByLower = <String, String>{
        'junior': exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '初中'),
        'compulsory': exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '必修'),
        'elective': exportAnnotateCategoryOfDetected(
            category: '课标词', standardLevel: '选修'),
        'extend': exportAnnotateCategoryOfDetected(category: '拓展词'),
        'overlimit': exportAnnotateCategoryOfDetected(category: '超标词'),
        'proper': exportAnnotateCategoryOfDetected(category: '专有词'),
        'unfiltered':
            exportAnnotateCategoryOfDetected(category: '未筛选'),
        'corpus':
            exportAnnotateCategoryOfDetected(category: '未筛选', isInCorpus: true),
      };
      final xml = annotate(
        'junior compulsory elective extend overlimit proper unfiltered corpus',
        catByLower,
      );

      String runOf(String word, ExportWordStyle spec) =>
          '<w:r><w:rPr><w:color w:val="${spec.colorHex}"/>'
          '${spec.bold ? '<w:b/>' : ''}</w:rPr>'
          '<w:t xml:space="preserve">$word</w:t></w:r>';

      for (final e in <String, String>{
        'junior': ExportCategory.standardJunior,
        'compulsory': ExportCategory.standardCompulsory,
        'elective': ExportCategory.standardElective,
        'extend': ExportCategory.extend,
        'overlimit': ExportCategory.overLimit,
        'proper': ExportCategory.proper,
        'unfiltered': ExportCategory.unfiltered,
      }.entries) {
        final spec = kExportWordStyles[e.value]!;
        expect(xml.contains(runOf(e.key, spec)), isTrue,
            reason: '${e.value} 的着色 / 字重与规范表不一致');
      }

      // 真题词（语料出现过）不参与配色：默认黑、不加粗
      expect(
        xml.contains(
            '<w:r><w:rPr><w:color w:val="000000"/></w:rPr>'
            '<w:t xml:space="preserve">corpus</w:t></w:r>'),
        isTrue,
        reason: '真题词必须为默认黑、不加粗',
      );

      // Word 导出不得出现底纹 / 高亮
      expect(xml.contains('w:shd'), isFalse);
      expect(xml.contains('w:highlight'), isFalse);
    });

    test('统计分类与正文着色必须一一对应（课标词三级别各具其色）', () {
      // 三个级别必须映射到三个互不相同的规范色，否则统计分三行、正文却同色
      final colors = <String>{
        for (final level in <String>['初中', '必修', '选修'])
          kExportWordStyles[exportAnnotateCategoryOfDetected(
              category: '课标词', standardLevel: level)]!
              .colorHex,
      };
      expect(colors.length, 3, reason: '初中 / 必修 / 选修必须各具其色');
      expect(colors.contains('000000'), isTrue, reason: '初中课标词为黑色');
      expect(colors.contains('0B3D91'), isTrue, reason: '必修课标词为深蓝色');
      expect(colors.contains('00B0F0'), isTrue, reason: '选修课标词为浅蓝色');
    });

    test('非试题文本的控制字符被清理，不会生成非法 XML', () {
      final xml = annotate('a\u0001b\u000Cc\u000Bd', {'ab': '拓展词'});
      expect(xml.contains('\u0001'), isFalse);
      expect(xml.contains('\u000C'), isFalse);
      expect(xml.contains('\u000B'), isFalse);
      expect(xml.contains('<w:p>'), isTrue);
    });

    test('多行文本按行拆分为独立段落，不合并成一段', () {
      final xml = annotate('one line\ntwo line', const {});
      expect('<w:p>'.allMatches(xml).length, 2);
    });
  });
}
