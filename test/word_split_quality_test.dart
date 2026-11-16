import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:esw/shared/doc_extractor.dart';
import 'package:esw/shared/text_normalize.dart';
import 'package:esw/shared/vocab_service.dart';

/// 分词/抽取质量守卫：粘连、缺字母、隐形字符、编码。
void main() {
  group('分词折叠', () {
    test('变音字母、连字、全角、软连字符不再产生缺字母 token', () {
      final tokens = extractWordTokens(
        'The café is naïve; ﬁnancial ﬂow Ｔｈｅ ＡＢＣ co\u00ADoperate résumé',
      );
      final lower = tokens.map((e) => e.toLowerCase()).toSet();
      expect(lower, containsAll(<String>[
        'the',
        'cafe',
        'is',
        'naive',
        'financial',
        'flow',
        'abc',
        'cooperate',
        'resume',
      ]));
      // 不能出现被截断的半截词
      for (final bad in ['caf', 'na', 'sum', 'nd', 'ow']) {
        expect(lower.contains(bad), isFalse, reason: '出现截断 token: $bad');
      }
    });

    test('组合变音符号与零宽字符不会拆词', () {
      final tokens = extractWordTokens('cafe\u0301 zero\u200Bwidth');
      final lower = tokens.map((e) => e.toLowerCase()).toList();
      expect(lower, contains('cafe'));
      expect(lower, contains('zerowidth'));
    });

    test('选项字母粘连按共用规则剥离（含 itB/ofB/toC/AsC）', () {
      expect(extractWordTokens('hostedB'), <String>['hosted']);
      expect(extractWordTokens('itB ofB toC AsC'), <String>['it', 'of', 'to', 'As']);
      // 正常缩写不能被误切
      expect(extractWordTokens('PhD MBA GPA'), <String>['PhD', 'MBA', 'GPA']);
    });

    test('多选项粘连行经规范化后不残留 realB 类 token', () {
      final text = normalizeText('49.A. realB. perfectC. clearD. possible');
      final tokens = extractWordTokens(text);
      final lower = tokens.map((e) => e.toLowerCase()).toSet();
      for (final bad in ['realb', 'perfectc', 'cleard']) {
        expect(lower.contains(bad), isFalse, reason: '残留粘连: $bad');
      }
      expect(lower, containsAll(<String>['real', 'perfect', 'clear', 'possible']));
    });
  });

  group('docx 段落抽取', () {
    XmlElement p(String xml) =>
        XmlDocument.parse(xml).findAllElements('w:p').first;

    test('不换行连字符保留为分隔，软连字符不粘连', () {
      final raw = docxParagraphRaw(p('''
<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:t>well</w:t><w:noBreakHyphen/><w:t>known</w:t></w:r>
  <w:r><w:t> co</w:t><w:softHyphen/><w:t>operate</w:t></w:r>
  <w:r><w:t>A</w:t><w:ptab/><w:t>B</w:t></w:r>
</w:p>'''));
      expect(raw, contains('well-known'));
      expect(raw, contains('cooperate'));
      expect(raw, contains('A B'));
    });

    test('删除修订与域代码文本不进入正文', () {
      final raw = docxParagraphRaw(p('''
<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:t>keep</w:t></w:r>
  <w:r><w:delText>removed</w:delText></w:r>
  <w:r><w:instrText>PAGE</w:instrText></w:r>
</w:p>'''));
      expect(raw.trim(), 'keep');
    });

    test('文本框嵌套段落不会在外层重复收集', () {
      final raw = docxParagraphRaw(p('''
<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:t>outer</w:t></w:r>
  <w:r><w:drawing><w:txbxContent>
    <w:p><w:r><w:t>inner</w:t></w:r></w:p>
  </w:txbxContent></w:drawing></w:r>
</w:p>'''));
      expect(raw, contains('outer'));
      expect(raw, isNot(contains('inner')));
    });
  });

  group('纯文本编码', () {
    test('UTF-16 LE BOM', () {
      final text = 'English 英语';
      final bytes = <int>[0xFF, 0xFE];
      for (final u in text.codeUnits) {
        bytes.addAll([u & 0xFF, u >> 8]);
      }
      expect(decodeTextBytes(bytes), text);
    });

    test('UTF-16 BE BOM', () {
      final text = 'English';
      final bytes = <int>[0xFE, 0xFF];
      for (final u in text.codeUnits) {
        bytes.addAll([u >> 8, u & 0xFF]);
      }
      expect(decodeTextBytes(bytes), text);
    });

    test('UTF-8 BOM 不残留到首个词', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...'English'.codeUnits];
      expect(decodeTextBytes(bytes), 'English');
    });
  });

  group('真题生效集过滤', () {
    test('只统计本次生效文件，历史导入文件保留但不参与', () async {
      final temp = Directory.systemTemp.createTempSync('esw_corpus_scope_');
      try {
        File('${temp.path}/2023全国卷.txt').writeAsStringSync('apple apple');
        File('${temp.path}/2018旧导入.txt').writeAsStringSync(
          'apple apple apple',
        );

        final onlyBuiltin = await VocabService().getWordFrequency(
          'apple',
          temp.path,
          onlyNames: <String>{'2023全国卷.txt'},
        );
        expect(onlyBuiltin?['total'], 2);
        expect((onlyBuiltin?['byYear'] as Map).keys, <String>['2023全国卷']);

        // 不传过滤时保持旧行为（全目录），用于对照文件仍在磁盘上
        final all = await VocabService().getWordFrequency('apple', temp.path);
        expect(all?['total'], 5);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });
}
