// 词族显示顺序：检测结果按「被查词优先」排列。
//  - 搜课标词：课标词（被查词）→ 对应拼写 → 其他拓展词
//  - 搜拓展词：被查拓展词 → 课标原词 → 其他拓展词
// Windows 结果表与 Android 词频面板都依赖该顺序（formRank）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:esw/shared/vocab_service.dart';
import 'package:esw/shared/word_family.dart';

void main() {
  const standardKeys = <String>[
    'positive', 'color', 'colour',
  ];
  const extendWords = <String>[
    'positively', 'positivity', 'colours', 'coloured',
  ];
  const extBaseMap = <String, String>{
    'positively': 'positive',
    'positivity': 'positive',
    'colours': 'colour',
    'coloured': 'colour',
  };

  test('搜课标词：课标词先显示，再拓展词', () {
    final f = wordFamily('positive',
        standardKeys: standardKeys,
        extendWords: extendWords,
        extBaseMap: extBaseMap);
    expect(f.forms.first, 'positive');
    expect(f.forms.take(3).toList(), ['positive', 'positively', 'positivity']);
  });

  test('搜拓展词：被查拓展词 → 课标词 → 其他拓展词', () {
    final f = wordFamily('positively',
        standardKeys: standardKeys,
        extendWords: extendWords,
        extBaseMap: extBaseMap);
    expect(f.forms.take(3).toList(),
        ['positively', 'positive', 'positivity']);
  });

  test('搜英式课标拼写：被查拼写 → 美式规范形 → 其他拓展词', () {
    final f = wordFamily('colour',
        standardKeys: standardKeys,
        extendWords: extendWords,
        extBaseMap: extBaseMap);
    expect(f.forms.take(3).toList(), ['colour', 'color', 'coloured']);
  });

  test('检测页词频逐年内按被查词优先排序', () async {
    // 用仓库内置 119 套真题 + 最小化词库状态，验证页面实际返回顺序
    final stdJson = jsonDecode(
            utf8.decode(File('assets/standard_words.json').readAsBytesSync()))
        as Map<String, dynamic>;
    final vs = VocabService();
    vs.standardWords = {
      for (final k in stdJson.keys) k: const <String, String>{}
    };
    vs.extendWordKeySet.addAll(const ['positively', 'positivity']);
    vs.extendBaseMap.addAll(const {
      'positively': 'positive',
      'positivity': 'positive',
    });
    final data = await vs.getWordFrequency('positively', 'assets/gaokao/txt');
    if (data == null) return; // 语料未出现该词时无从校验顺序
    final byYear = data['byYear'] as Map<String, dynamic>;
    var checked = 0;
    for (final list in byYear.values) {
      final words =
          (list as List).map((e) => (e as Map)['word'] as String).toList();
      final seenPositive = words.indexOf('positive');
      final firstPositive = words.indexOf('positively');
      if (seenPositive < 0 || firstPositive < 0) continue;
      checked++;
      expect(firstPositive < seenPositive, isTrue,
          reason: '同一年内 positively($firstPositive) 应排在 '
              'positive($seenPositive) 之前，实际: $words');
    }
    // ignore: avoid_print
    print('ORDER_CHECK years=$checked');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
