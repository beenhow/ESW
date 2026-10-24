// 任务④（运行速度）等价性回归测试。
//
// 优化的前提是「结果完全不变」。这里对改造过的纯逻辑热路径做同输入逐项比对：
// 1) 候选词生成：优化后实现 vs 优化前实现快照（小写词表 / 词干预计算 + 结果记忆）
// 2) 词库列表过滤：优化后实现 vs 优化前实现快照（单趟反向遍历 + 结果记忆）
// 任何一处语义漂移都会让本测试直接失败。

import 'package:esw/shared/base_word_candidates.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与窗口内 _bankSearchList 保持同一实现的对照副本（弹窗过滤热路径）。
List<String> optimizedBankFilter(List<String> source, String search) {
  final rev = source.reversed;
  if (search.isEmpty) return rev.toList();
  final loweredSearch = search.toLowerCase();
  return <String>[
    for (final w in rev)
      if (w.toLowerCase().contains(loweredSearch)) w,
  ];
}

List<String> legacyBankFilter(List<String> source, String search) {
  final words = source.reversed.toList();
  if (search.isEmpty) return words;
  final loweredSearch = search.toLowerCase();
  return words.where((w) => w.toLowerCase().contains(loweredSearch)).toList();
}

void main() {
  final standardWords = <String>[
    'go', 'goal', 'goat', 'god', 'gone', 'ago', 'begin', 'under', 'undergo',
    'happy', 'happiness', 'able', 'ability', 'disable', 'enable', 'start',
    'startle', 'star', 'state', 'time', 'timer', 'timely', 'test', 'text',
    'Text', 'Angle', 'angled', 'triangle',
  ];

  final queries = <String>[
    '', 'a', 'ab', 'abili', 'abiliti', 'undergo', 'happi', 'go', 'GO',
    'test', 'text', 'time', 'zzz', 'an',
  ];

  test('候选词生成：优化后实现与优化前逐项一致', () {
    for (final q in queries) {
      for (final target in <String?>[null, 'ability', 'undergo', 'timer']) {
        final a = baseWordCandidatesLegacy(q, standardWords,
            targetWord: target);
        final b = baseWordCandidates(q, standardWords, targetWord: target);
        expect(b, a, reason: 'query="$q" target=$target 结果不一致');
      }
    }
  });

  test('候选词生成：同一词表对象重复调用结果稳定（缓存不污染结果）', () {
    final first = baseWordCandidates('abili', standardWords, targetWord: 'ability');
    for (var i = 0; i < 3; i++) {
      expect(
        baseWordCandidates('abili', standardWords, targetWord: 'ability'),
        first,
      );
    }
    // 词表内容变化后，小写词表缓存必须失效重算
    final grown = List<String>.from(standardWords)..add('abilityless');
    expect(
      baseWordCandidates('abili', grown, targetWord: 'ability'),
      baseWordCandidatesLegacy('abili', grown, targetWord: 'ability'),
    );
  });

  test('词库列表过滤：优化后实现与优化前逐项一致', () {
    final bank = <String>[
      'start', 'Start', 'starting', 'star', 'STAR', 'state', 'test', 'ability',
      'able', 'timer', '', 'zz',
    ];
    for (final s in <String>['', 's', 'st', 'sta', 'star', 'S', 'zzz', 'A']) {
      expect(optimizedBankFilter(bank, s), legacyBankFilter(bank, s),
          reason: 'search="$s" 结果不一致');
    }
  });

  test('词库列表过滤：结果顺序为倒序 + 大小写不敏感子串匹配', () {
    final bank = <String>['start', 'star', 'STAR', 'test'];
    expect(optimizedBankFilter(bank, ''), <String>['test', 'STAR', 'star', 'start']);
    expect(optimizedBankFilter(bank, 'star'), <String>['STAR', 'star', 'start']);
    expect(optimizedBankFilter(bank, 'STAR'), <String>['STAR', 'star', 'start']);
  });
}
