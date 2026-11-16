// 启动恢复「用户主动导入」语料的共用口径（Windows / Android 行为一致）：
//  - 只恢复配置中记录、且在本应用内主动导入的项；
//  - 路径 / 文件已不存在时静默跳过，不报错、不阻塞启动；
//  - 绝不读取外部固定路径或历史遗留目录；内置真题由内置链路单独释放，不走这里。
import 'dart:io';

class ImportedCorpusRestore {
  ImportedCorpusRestore._();

  /// Windows：按配置记录的绝对路径恢复真题 / 教材，仅保留仍存在的文件。
  static Future<List<String>> existingPaths(Iterable<String> recorded) async {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in recorded) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      try {
        if (!await File(path).exists()) continue;
      } catch (_) {
        continue;
      }
      if (seen.add(path)) out.add(path);
    }
    return out;
  }

  /// Android：按配置记录的文件名恢复真题，仅保留 corpus 目录中仍存在、
  /// 且不属于内置释放文件的 .txt。
  static Future<List<String>> existingNames({
    required Iterable<String> recorded,
    required String dir,
    Set<String> builtinNames = const <String>{},
  }) async {
    final existing = <String>{};
    try {
      final d = Directory(dir);
      if (await d.exists()) {
        await for (final e in d.list()) {
          if (e is File && e.path.toLowerCase().endsWith('.txt')) {
            existing.add(e.uri.pathSegments.last);
          }
        }
      }
    } catch (_) {
      // 目录不可读时按「全部失效」处理，启动流程继续
      return <String>[];
    }
    final out = <String>[];
    final seen = <String>{};
    for (final raw in recorded) {
      final name = raw.trim();
      if (name.isEmpty || !existing.contains(name)) continue;
      if (builtinNames.contains(name)) continue;
      if (seen.add(name)) out.add(name);
    }
    return out;
  }
}
