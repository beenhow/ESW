import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:esw/shared/doc_extractor.dart';
import 'package:esw/shared/text_normalize.dart';
import 'package:esw/shared/vocab_service.dart';
import 'package:esw/word_filter_rules.dart';

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
      // 末尾 A-H 紧跟大写时属于缩写块（MoMA），不能当选项标号剥离
      expect(extractWordTokens('MoMA'), <String>['MoMA']);
      expect(extractWordTokens('MoMA itB ofB'), <String>['MoMA', 'it', 'of']);
    });

    test('撇号缩略形式整体成词（couldn\'t 不再被截成 couldn）', () {
      const text =
          "I couldn't believe it. Don't stop — we're late; I've won't can't "
          "o'clock it's students' books.";
      final tokens =
          extractWordTokens(text).map((e) => e.toLowerCase()).toList();
      expect(tokens, containsAll(<String>[
        "couldn't",
        "don't",
        "we're",
        "i've",
        "won't",
        "can't",
        "o'clock",
        "it's",
        // 复数所有格只在词尾带撇号，词元仍是 students
        'students',
      ]));
      for (final bad in ['couldn', 'don', 'won', 'clock']) {
        expect(tokens.contains(bad), isFalse, reason: '出现截断 token: $bad');
      }
    });

    test('弯撇号与直撇号归一为同一词元', () {
      final straight = extractWordTokens("It's fine. I don't know.");
      final curly = extractWordTokens('It\u2019s fine. I don\u2019t know.');
      expect(straight, containsAll(<String>["It's", "don't"]));
      expect(curly, straight);
    });

    test('连字符复合词整体成词（harbor-side 不再拆成两词）', () {
      final tokens = extractWordTokens('a harbor-side view of well-known brands')
          .map((e) => e.toLowerCase())
          .toList();
      expect(tokens, containsAll(<String>['harbor-side', 'well-known']));
      expect(tokens.contains('harbor'), isFalse);
      expect(tokens.contains('side'), isFalse);
    });

    test('撇号与词根之间被空格分开时也能并回整词', () {
      expect(
        extractWordTokens("haven 't I ' ve student 's").map((e) => e.toLowerCase()),
        <String>["haven't", "i've", "student's"],
      );
    });

    test('连字符复合词整体未命中时按部分回退', () {
      final entries = <String, Object?>{
        'harbor': <String, String?>{},
        'side': <String, String?>{},
        'well': <String, String?>{},
        'known': <String, String?>{},
      };
      expect(isWordEntryHit(entries, 'harbor-side'), isTrue);
      expect(isWordEntryHit(entries, 'well-known'), isTrue);
      expect(isWordEntryHit(entries, 'harbor-mystery'), isFalse);
      expect(isWordSetHit(<String>{'harbor', 'side'}, 'Harbor-Side'), isTrue);
      expect(isWordSetHit(<String>{'Harbor', 'side'}, 'harbor-Side'), isFalse);
      expect(isWordSetHit(<String>{'harbor'}, 'harbor-side'), isFalse);
    });

    test('查词表按「完整词形 → 基形」回退，所有格不丢分类', () {
      expect(wordLookupKeys("China's"), <String>["china's", 'china']);
      expect(wordLookupKeys("couldn't"), <String>["couldn't", 'could']);
      expect(wordLookupKeys("won't"), <String>["won't", 'will', 'wo']);
      expect(wordLookupKeys("students'"), <String>["students'", 'students']);
      expect(wordLookupKeys("o'clock"), <String>["o'clock"]);
      expect(wordLookupKeys("I've"), <String>["i've", 'i']);
      expect(wordLookupKeys("China's").any(<String>{'china'}.contains), isTrue);
      expect(wordLookupKeys("can't").any(<String>{'can'}.contains), isTrue);
      expect(wordLookupKeys("we're").any(<String>{'we'}.contains), isTrue);
      expect(wordLookupKeys('couldn').any(<String>{'china'}.contains), isFalse);
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

    test('缩略形式整体检测，不产出 re / ve / ll 残片', () {
      expect(
        extractWordTokens("they're we've she'll I'd"),
        <String>["they're", "we've", "she'll", "I'd"],
      );
      final tails = extractWordTokens("they're we're he'll")
          .map((e) => e.toLowerCase())
          .toSet();
      for (final bad in ['re', 've', 'll']) {
        expect(tails.contains(bad), isFalse, reason: '出现残片: $bad');
      }
    });

    test('专有词只认大写写法：Messy / MESSY 命中，小写留给用户确认', () {
      final keys = properNounKeySet(<String>['Messy', 'WTO', 'Xinjiang']);
      expect(isProperNounHit(keys, 'Messy'), isTrue);
      expect(isProperNounHit(keys, 'MESSY'), isTrue);
      expect(isProperNounHit(keys, 'Wto'), isTrue);
      expect(isProperNounHit(keys, 'XINJIANG'), isTrue);
      expect(isProperNounHit(keys, "Messy's"), isTrue);
      // 小写写法即使词条也收在专有词库，也不自动归为专有词
      expect(isProperNounHit(keys, 'messy'), isFalse);
      expect(isProperNounHit(keys, 'wto'), isFalse);
      expect(isProperNounHit(keys, 'xinjiang'), isFalse);
      // 查词页/重新归类用的成员判定仍大小写不敏感
      expect(matchWordEntryKey(keys, 'messy'), isNotNull);
    });

    test('带撇号的缩略形式按基形判定，不被大写专有规则抢走', () {
      final keys = properNounKeySet(<String>['I', 'He', 'Rowling']);
      expect(isProperNounHit(keys, "I've"), isTrue);
      expect(isProperNounHit(keys, "He's"), isTrue);
      // 基形在课标 → 按课标词算
      expect(apostropheBaseInStandard("I've", true), isTrue);
      expect(apostropheBaseInStandard("He's", true), isTrue);
      // 即使词条同时出现在拓展/超标表里，基形在课标仍归课标词
      expect(
        resolveFilterCategory(
          inCorpus: false,
          inStandard: true,
          inExtend: true,
          inChaoGang: true,
          inProper: true,
          preferProper: true,
          apostropheBaseStandard: true,
        ),
        '课标词',
      );
      // 用户历史归类仍然优先
      expect(
        resolveFilterCategory(
          inCorpus: false,
          inStandard: true,
          inExtend: false,
          inChaoGang: false,
          inProper: false,
          apostropheBaseStandard: true,
          remembered: '拓展词',
        ),
        '拓展词',
      );
      expect(
        resolveFilterCategory(
          inCorpus: false,
          inStandard: true,
          inExtend: false,
          inChaoGang: false,
          inProper: false,
          preferProper: !apostropheBaseInStandard("I've", true),
        ),
        '课标词',
      );
      // 基形不在课标（人名所有格）→ 仍归专有词
      expect(apostropheBaseInStandard("Rowling's", false), isFalse);
      expect(
        resolveFilterCategory(
          inCorpus: false,
          inStandard: false,
          inExtend: false,
          inChaoGang: false,
          inProper: false,
          preferProper: !apostropheBaseInStandard("Rowling's", false),
        ),
        '专有词',
      );
    });

    test('大写写法命中专有词时优先于拓展词/超标词', () {
      expect(
        resolveFilterCategory(
          inCorpus: false,
          inStandard: false,
          inExtend: true,
          inChaoGang: true,
          inProper: false,
          preferProper: true,
        ),
        '专有词',
      );
      // 历史归类优先于自动判定（分类由用户决定）
      expect(
        resolveFilterCategory(
          inCorpus: false,
          inStandard: false,
          inExtend: true,
          inChaoGang: false,
          inProper: false,
          preferProper: true,
          remembered: '拓展词',
        ),
        '拓展词',
      );
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

  group('原文定位/高亮正则（撇号等价 + 整词）', () {
    test('直撇号关键词命中弯撇号原文', () {
      const keyword = "couldn't";
      for (final text in <String>[
        "I couldn't go.",
        'I couldn\u2019t go.', // ’
        'I couldn\u2018t go.', // ‘
        'I couldn\u02BCt go.', // ʼ
        'I COULDN\u2019T go.',
      ]) {
        final m = keywordMatchRegExp(keyword).firstMatch(text);
        expect(m, isNotNull, reason: '未命中：$text');
        expect(text.substring(m!.start, m.end).toLowerCase().replaceAll('\u2019', "'"),
            contains("couldn"));
      }
    });

    test('弯撇号关键词同样命中原文字面写法', () {
      expect(
        keywordMatchRegExp('couldn\u2019t').hasMatch("I couldn't go."),
        isTrue,
      );
    });

    test('按完整词形匹配，不命中更长单词内部', () {
      final re = keywordMatchRegExp('he');
      expect(re.hasMatch('he is here'), isTrue);
      expect(re.hasMatch('the hero'), isFalse);
      // 缩略词不会退化成截断形式
      expect(keywordMatchRegExp("couldn't").hasMatch('couldn go'), isFalse);
      expect(keywordMatchRegExp("couldn't").hasMatch('couldnX go'), isFalse);
    });

    test('第 N 次命中下标与原文一致', () {
      const text = "It couldn\u2019t work. They couldn't either.";
      expect(keywordMatchOffset(text, "couldn't"), text.indexOf('couldn'));
      final second = keywordMatchOffset(text, "couldn't", occurrence: 1);
      expect(second, text.indexOf('couldn', text.indexOf('couldn') + 1));
      expect(keywordMatchOffset(text, "couldn't", occurrence: 2), -1);
    });

    test('空关键词不产生零宽命中', () {
      expect(keywordMatchRegExp('').hasMatch('anything'), isFalse);
      expect(keywordMatchOffset('anything', ''), -1);
    });
  });
}
