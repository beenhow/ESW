// 内置教材资产与释放机制：
//  - assets/textbook/index.json 登记 8 套教材（简称命名）
//  - Windows：版本目录释放，manifest 命中时不重复写
//  - Android：平铺释放，遇到用户同名文件改名避让，内置清单单独记录
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:esw/shared/builtin_textbook.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置教材索引为 8 套且使用简称', () async {
    final index = await BuiltinTextbook.loadIndex();
    expect(index, isNotNull);
    final ids = index!.books.map((b) => b.id).toList();
    expect(ids, [
      '人教版', '冀教版', '北师大版', '外研社', '沪外版', '沪教版', '译林版', '重大版',
    ]);
    for (final b in index.books) {
      expect(b.chars, greaterThan(1000), reason: '${b.id} 内容过少');
    }
  });

  test('Windows 版本目录释放：内容非空且可重复调用', () async {
    final index = await BuiltinTextbook.loadIndex();
    final temp = Directory.systemTemp.createTempSync('esw_tb_');
    try {
      final paths = await BuiltinTextbook.ensureExtracted(
        baseDir: temp.path,
        version: index!.version,
        books: index.books,
      );
      expect(paths, isNotNull);
      expect(paths!.length, 8);
      for (final path in paths.values) {
        final f = File(path);
        expect(f.existsSync(), isTrue);
        expect(f.lengthSync(), greaterThan(2000));
      }
      // 二次调用命中 manifest，不再改写
      final before = File(paths.values.first).lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final again = await BuiltinTextbook.ensureExtracted(
        baseDir: temp.path,
        version: index.version,
        books: index.books,
      );
      expect(again, isNotNull);
      expect(File(paths.values.first).lastModifiedSync(), before);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('Android 平铺释放：不覆盖用户同名文件，清单可回读', () async {
    final index = await BuiltinTextbook.loadIndex();
    final temp = Directory.systemTemp.createTempSync('esw_tb_flat_');
    try {
      // 用户已有一个同名文件（person 版）
      final userFile = File(p.join(temp.path, '人教版.txt'));
      userFile.writeAsStringSync('用户自己的内容');

      final names = await BuiltinTextbook.installFlat(
        textbookDir: temp.path,
        version: index!.version,
        books: index.books,
      );
      expect(names, isNotNull);
      expect(names!.length, 8);
      expect(names, contains('人教版（内置）.txt'));
      expect(userFile.readAsStringSync(), '用户自己的内容',
          reason: '内置释放不得覆盖用户同名教材');

      final manifest =
          File(p.join(temp.path, BuiltinTextbook.flatManifestName));
      expect(manifest.existsSync(), isTrue);
      final m = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
      expect((m['files'] as List).length, 8);
      expect(await BuiltinTextbook.flatNames(temp.path), names);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
