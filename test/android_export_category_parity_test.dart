// 安卓 / Windows 导出原文标注口径一致性守卫。
//
// 用户口径：安卓「导入检测后导出」的文档，筛选结果的**颜色与字体标注**必须与
// Windows 版一致。两端的差异来源只有「检测结果的词库归属 → 导出分类」这一步，
// 本测试锁定该映射与最终的 DOCX run 表现。
import 'package:esw/shared/export_annotate_markup.dart';
import 'package:esw/shared/export_word_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('安卓检测分类 → 导出分类', () {
    test('课标词保持粗粒度，不按课标级别细分（与 Windows wordCatMap 一致）', () {
      // 无论词库里的课标级别是初中 / 必修 / 选修，导出分类都只能是「课标词」
      for (final level in <String>['初中', '必修', '选修', '']) {
        final cat = exportAnnotateCategoryOfFilter('课标词');
        expect(cat, '课标词', reason: '级别 $level 下导出分类被错误细分');
        // 课标词不在规范七类色表内 → 原文保持默认黑、不加粗（Windows 同款表现）
        expect(exportWordStyleOf(cat), isNull,
            reason: '课标词不应取到规范色，否则与 Windows 版不一致');
      }
    });

    test('其他（= Windows 未筛选且语料出现过）降为真题词，不配色', () {
      expect(exportAnnotateCategoryOfFilter('其他'), '真题词');
      expect(exportWordStyleOf(exportAnnotateCategoryOfFilter('其他')), isNull);
    });

    test('拓展 / 超标 / 专有词原样透传并取到规范色与字重', () {
      const carries = <String>[
        ExportCategory.extend,
        ExportCategory.overLimit,
        ExportCategory.proper,
      ];
      for (final c in carries) {
        final cat = exportAnnotateCategoryOfFilter(c);
        expect(cat, c, reason: '$c 不应被改写');
        final spec = exportWordStyleOf(cat);
        expect(spec, isNotNull, reason: '$c 必须取到规范色');
        // 与规范表自身对照，锁定字色 / 字重未漂移
        expect(spec!.colorHex, kExportWordStyles[c]!.colorHex);
        expect(spec.bold, kExportWordStyles[c]!.bold);
      }
      // 拓展词必须是"加粗的深绿"，作为规范表未被误改的锚点
      final extend = exportWordStyleOf(ExportCategory.extend)!;
      expect(extend.bold, isTrue, reason: '拓展词应加粗');
      expect(extend.colorHex.toLowerCase().endsWith('6400'), isTrue,
          reason: '拓展词应为深绿色系，实际 ${extend.colorHex}');
    });
  });

  group('DOCX 原文标注（安卓导出真实调用路径）', () {
    String annotate(String text, Map<String, String> catByLower) =>
        docxAnnotatedParagraphXml(text, catByLower);

    test('四类词按规范着色，课标词与其他不着色', () {
      final catByLower = <String, String>{
        for (final c in <String>['课标词', '拓展词', '超标词', '专有词', '其他'])
          c: exportAnnotateCategoryOfFilter(c),
      };
      final xml = annotate(
        'standard extend overlimit proper other',
        {
          'standard': catByLower['课标词']!,
          'extend': catByLower['拓展词']!,
          'overlimit': catByLower['超标词']!,
          'proper': catByLower['专有词']!,
          'other': catByLower['其他']!,
        },
      );

      // 课标词 / 其他：黑色、不加粗
      expect(
        xml.contains(
            '<w:r><w:rPr><w:color w:val="000000"/></w:rPr><w:t xml:space="preserve">standard</w:t></w:r>'),
        isTrue,
        reason: '课标词必须为默认黑、不加粗',
      );
      expect(
        xml.contains(
            '<w:r><w:rPr><w:color w:val="000000"/></w:rPr><w:t xml:space="preserve">other</w:t></w:r>'),
        isTrue,
        reason: '其他（真题词口径）必须为默认黑、不加粗',
      );

      // 拓展词：规范色 + 加粗
      final extend = exportWordStyleOf(ExportCategory.extend)!;
      expect(
        xml.contains(
            '<w:r><w:rPr><w:color w:val="${extend.colorHex}"/><w:b/></w:rPr>'
            '<w:t xml:space="preserve">extend</w:t></w:r>'),
        isTrue,
        reason: '拓展词必须按规范色加粗',
      );

      // 超标词 / 专有词：规范色、不加粗
      for (final e in <String, String>{
        ExportCategory.overLimit: 'overlimit',
        ExportCategory.proper: 'proper',
      }.entries) {
        final spec = exportWordStyleOf(e.key)!;
        expect(
          xml.contains('<w:r><w:rPr><w:color w:val="${spec.colorHex}"/></w:rPr>'
              '<w:t xml:space="preserve">${e.value}</w:t></w:r>'),
          isTrue,
          reason: '${e.key} 标注与规范表不一致',
        );
      }

      // Word 导出不得出现底纹 / 高亮
      expect(xml.contains('w:shd'), isFalse);
      expect(xml.contains('w:highlight'), isFalse);
    });

    test('课标词不得因课标级别被染成黑粗 / 深蓝 / 浅蓝', () {
      // 复现"错误细分"的输入，确认最终只有默认黑
      final xml = annotate('abandon', {
        'abandon': exportAnnotateCategoryOfFilter('课标词'),
      });
      expect(xml.contains('<w:b/>'), isFalse, reason: '课标词不得加粗');
      expect(xml.contains('<w:color w:val="000000"/>'), isTrue);
      // 不得出现除默认黑以外的任何规范色（细分后的深蓝 / 浅蓝等）
      final palette = <String>{};
      for (final c in ExportCategory.all) {
        final hex = kExportWordStyles[c]?.colorHex;
        if (hex != null) palette.add(hex.toLowerCase());
      }
      final used = RegExp(r'<w:color w:val="([0-9A-Fa-f]{6})"/>')
          .allMatches(xml)
          .map((m) => m.group(1)!.toLowerCase())
          .toSet();
      for (final hex in used) {
        if (hex == '000000') continue;
        expect(palette.contains(hex), isFalse,
            reason: '课标词被误染成规范色 $hex');
      }
    });
  });
}
