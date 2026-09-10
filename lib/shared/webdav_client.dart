import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 坚果云 WebDAV 同步配置。
///
/// 配置文件位于应用支持目录下 esw_sync_config.json，结构：
/// {
///   "baseUrl": "https://dav.jianguoyun.com/dav/esw_sync",
///   "username": "你的坚果云账号",
///   "password": "你的应用密码（坚果云安全设置里生成，勿用登录密码）"
/// }
///
/// 凭据只存放在本地配置文件，绝不进入源码 / 仓库。
class WebDavConfig {
  final String baseUrl;
  final String username;
  final String password;

  const WebDavConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  bool get isValid =>
      baseUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  static Future<String> configPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}esw_sync_config.json';
  }

  /// 读取配置。
  /// 优先读应用支持目录下的 esw_sync_config.json（用户可自行覆盖）；
  /// 不存在时回退到打包内置的 assets/esw_sync_config.json（开箱即用）。
  /// 两者均缺失或字段无效时返回 null（调用方静默跳过同步）。
  static Future<WebDavConfig?> load() async {
    // 1) 支持目录优先：用户覆盖配置
    try {
      final path = await configPath();
      final f = File(path);
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return _fromMap(data);
      }
    } catch (_) {
      // 支持目录读取失败 → 继续尝试内置资产
    }
    // 2) 内置资产兜底：随包分发的默认配置
    try {
      final raw = await rootBundle.loadString('assets/esw_sync_config.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return _fromMap(data);
    } catch (_) {
      return null;
    }
  }

  static WebDavConfig? _fromMap(Map<String, dynamic> data) {
    return WebDavConfig(
      baseUrl: (data['baseUrl'] as String? ?? '').replaceAll(RegExp(r'/+$'), ''),
      username: data['username'] as String? ?? '',
      password: data['password'] as String? ?? '',
    );
  }
}

/// WebDAV 传输客户端（坚果云兼容）。
///
/// 将云同步的状态读写统一落地为 WebDAV 文件读写：
/// - GET  → 读取远程 JSON 文件内容
/// - PUT  → 覆盖写入远程 JSON 文件（WebDAV 天然支持覆盖）
/// 使用 Basic Auth 鉴权，base64 编码凭据后走 HTTPS。
class WebDavClient {
  final WebDavConfig _config;
  String? _authHeader;

  WebDavClient(this._config);

  factory WebDavClient.fromConfig(WebDavConfig config) => WebDavClient(config);

  String get _authorization {
    return _authHeader ??= 'Basic ${base64Encode(utf8.encode('${_config.username}:${_config.password}'))}';
  }

  Uri _uri(String relativePath) {
    // 去除前后多余的斜杠，避免拼出双重路径
    final clean = relativePath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('${_config.baseUrl}/$clean');
  }

  /// 读取远程 JSON。文件不存在（404）时返回 null。
  Future<Map<String, dynamic>?> getJson(String relativePath) async {
    try {
      final resp = await http
          .get(
            _uri(relativePath),
            headers: {
              'Authorization': _authorization,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 404) return null;
      if (resp.statusCode != 200) {
        throw Exception('WebDAV GET $relativePath 失败: ${resp.statusCode}');
      }
      // 大 JSON 解析移到 isolate，避免阻塞 UI
      return await Isolate.run(() => jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      rethrow;
    }
  }

  /// 覆盖写入远程 JSON（WebDAV PUT 天然支持整文件覆盖，无 sha 前置条件）。
  /// 首次写入若父目录不存在，自动递归创建目录后重试。
  Future<bool> putJson(String relativePath, Map<String, dynamic> content) async {
    try {
      final body = utf8.encode(jsonEncode(content));
      var resp = await http
          .put(
            _uri(relativePath),
            headers: {
              'Authorization': _authorization,
              'Content-Type': 'application/octet-stream',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode == 409 || resp.statusCode == 404) {
        // 父目录不存在 → 先递归建目录再重试
        final made = await _ensureParentDirs(relativePath);
        if (!made) return false;
        resp = await http
            .put(
              _uri(relativePath),
              headers: {
                'Authorization': _authorization,
                'Content-Type': 'application/octet-stream',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 60));
      }
      return resp.statusCode == 200 || resp.statusCode == 201 || resp.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// 递归创建远程目录（WebDAV MKCOL）。
  Future<bool> _ensureParentDirs(String relativePath) async {
    final parts = relativePath.split('/')..removeLast();
    final segments = <String>[];
    for (final p in parts) {
      if (p.isEmpty) continue;
      segments.add(p);
      final dirPath = segments.join('/');
      final req = http.Request('MKCOL', _uri(dirPath))
        ..headers['Authorization'] = _authorization;
      final resp = await http.Client().send(req).timeout(const Duration(seconds: 15));
      await resp.stream.drain<void>();
      // 201 已创建 / 405 已存在 均视为成功
      if (resp.statusCode != 201 && resp.statusCode != 405) {
        return false;
      }
    }
    return true;
  }

  /// 列出远程目录下全部文件名（WebDAV PROPFIND depth:1）。
  /// 只返回文件名（去掉 href 中的路径部分），失败返回空列表。
  Future<List<String>> listFiles(String relativePath) async {
    try {
      final req = http.Request('PROPFIND', _uri(relativePath))
        ..headers['Authorization'] = _authorization
        ..headers['Depth'] = '1'
        ..headers['Content-Type'] = 'application/xml';
      final resp = await http.Client().send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 207) return <String>[];
      final body = await resp.stream.bytesToString();
      // 兼容 <d:href> 与 <href> 两种命名空间写法
      final re = RegExp(r'<[^>]*:?href>([^<]+)</[^>]*:?href>', caseSensitive: false);
      final names = <String>[];
      for (final m in re.allMatches(body)) {
        final href = m.group(1)!;
        final name = Uri.decodeFull(href.split('/').last);
        if (name.isNotEmpty) {
          names.add(name);
        }
      }
      return names;
    } catch (_) {
      return <String>[];
    }
  }

  /// 删除远程文件（WebDAV DELETE）。
  Future<bool> deleteFile(String relativePath) async {
    try {
      final req = http.Request('DELETE', _uri(relativePath))
        ..headers['Authorization'] = _authorization;
      final resp = await http.Client().send(req).timeout(const Duration(seconds: 30));
      await resp.stream.drain<void>();
      return resp.statusCode == 200 || resp.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}
