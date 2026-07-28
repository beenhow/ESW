import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

/// 应用更新服务：检查 GitHub Release 获取最新版本。
/// 下载由外部浏览器或系统下载器处理。
class UpdateService {
  static const String _repoOwner = 'beenhow';
  static const String _repoName = 'ESW';
  static const String _releasesListUrl =
      'https://api.github.com/repos/$_repoOwner/$_repoName/releases';

  /// 当前平台版本号，发布时需同步更新。
  static const String currentVersion = '1.3.6';

  bool get isWindows =>
      defaultTargetPlatform == TargetPlatform.windows;

  bool get isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  /// 检查更新：遍历 Release，按 asset 文件名匹配当前平台。
  /// 返回第一个包含本平台安装包的 Release 信息，若已是最新则返回 null。
  Future<UpdateInfo?> checkUpdate() async {
    try {
      final resp = await http.get(
        Uri.parse(_releasesListUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (resp.statusCode != 200) return null;
      final releases = (jsonDecode(resp.body) as List)
          .cast<Map<String, dynamic>>();

      for (final release in releases) {
        final tag = (release['tag_name'] as String?) ?? '';
        final versionStr = _extractVersion(tag);
        if (versionStr == null) continue;

        if (_compareVersion(versionStr, currentVersion) <= 0) return null;

        return UpdateInfo(
          version: versionStr,
          releaseUrl: (release['html_url'] as String?) ?? 
              'https://github.com/$_repoOwner/$_repoName/releases/tag/$tag',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 从 tag 中提取纯版本号，如 "v1.3.1" / "android-v1.3.1" → "1.3.1"
  static String? _extractVersion(String tag) {
    final match = RegExp(r'v?(\d+\.\d+\.\d+)$').firstMatch(tag);
    return match?.group(1);
  }

  /// 版本号比较：返回正数表示 a > b，0 相等，负数 a < b
  int _compareVersion(String a, String b) {
    final aParts = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final bParts = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av - bv;
    }
    return 0;
  }
}

class UpdateInfo {
  final String version;
  final String releaseUrl;

  UpdateInfo({
    required this.version,
    required this.releaseUrl,
  });
}
