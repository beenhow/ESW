// 启动恢复实测：模拟「用户主动导入 → 写入配置 → 重启 → 自动恢复」。
// 只恢复仍存在的用户导入项；缺失路径静默跳过；用户删除后重启不再出现；
// 内置文件不进入用户恢复集（由内置链路单独释放）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:esw/shared/imported_corpus.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('esw_restart_'));
  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('Android：重启只恢复仍存在的用户导入真题，删除后不再出现', () async {
    final corpusDir = Directory(p.join(temp.path, 'corpus'))..createSync();
    final a = File(p.join(corpusDir.path, '2023甲.txt'))
      ..writeAsStringSync('a');
    final b = File(p.join(corpusDir.path, '2024乙.txt'))
      ..writeAsStringSync('b');
    final builtin = File(p.join(corpusDir.path, '2015北京.txt'))
      ..writeAsStringSync('builtin');
    // 模拟上一次导入后写入的配置（含一条已删除、一条内置同名）
    final cfgFile = File(p.join(temp.path, 'esw_android_config.json'))
      ..writeAsStringSync(jsonEncode({
        'userCorpusNames': [
          '2023甲.txt',
          '2024乙.txt',
          '已删除.txt',
          p.basename(builtin.path),
        ],
      }));

    // 模拟重启：读回配置 → 校验存在性 → 生成生效集
    final saved = (jsonDecode(cfgFile.readAsStringSync())['userCorpusNames']
            as List)
        .map((e) => e.toString())
        .toList();
    final restored = await ImportedCorpusRestore.existingNames(
      recorded: saved,
      dir: corpusDir.path,
      builtinNames: {p.basename(builtin.path)},
    );
    expect(restored, ['2023甲.txt', '2024乙.txt'],
        reason: '存在且非内置的用户导入文件应恢复；缺失项与内置项应剔除');

    // 用户删除 a 后再次重启：a 不再出现，b 仍在
    a.deleteSync();
    final restored2 = await ImportedCorpusRestore.existingNames(
      recorded: restored,
      dir: corpusDir.path,
      builtinNames: {p.basename(builtin.path)},
    );
    expect(restored2, ['2024乙.txt'], reason: '删除项重启后不得复活');
    expect(b.existsSync(), isTrue);
  });

  test('Windows：重启只恢复仍存在的用户导入路径（真题 + 教材）', () async {
    final exam = File(p.join(temp.path, '2022丙.txt'))..writeAsStringSync('x');
    final book = File(p.join(temp.path, '教材甲.txt'))..writeAsStringSync('y');
    final missing = p.join(temp.path, '不存在.txt');
    final j = jsonDecode(jsonEncode({
      'importedCorpusPaths': [exam.path, missing],
      'importedTextbookPaths': [book.path, missing],
    })) as Map<String, dynamic>;

    final examRestored = await ImportedCorpusRestore.existingPaths(
      (j['importedCorpusPaths'] as List).map((e) => e.toString()),
    );
    final bookRestored = await ImportedCorpusRestore.existingPaths(
      (j['importedTextbookPaths'] as List).map((e) => e.toString()),
    );
    expect(examRestored, [exam.path]);
    expect(bookRestored, [book.path]);

    // 删除后重启：不再恢复
    exam.deleteSync();
    final after = await ImportedCorpusRestore.existingPaths([exam.path]);
    expect(after, isEmpty, reason: '删除项重启后不得复活');
  });

  test('恢复过程只认配置记录，不扫描其他未记录文件', () async {
    final corpusDir = Directory(p.join(temp.path, 'corpus'))..createSync();
    File(p.join(corpusDir.path, '外部残留.txt')).writeAsStringSync('z');
    final restored = await ImportedCorpusRestore.existingNames(
      recorded: const [],
      dir: corpusDir.path,
    );
    expect(restored, isEmpty, reason: '未记录的目录内容不得自动恢复');
  });
}
