import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 没有任何可用的 WebDAV 凭据（用户目录、%LOCALAPPDATA%、exe 同目录与内置资产全部缺失）。
class WebDavConfigException implements Exception {
  final String message;
  const WebDavConfigException([this.message = '未找到可用的 WebDAV 同步账号配置']);
  @override
  String toString() => message;
}

/// 凭据被服务端拒绝（401/403）：账号或应用密码无效。
class WebDavAuthException implements Exception {
  final String message;
  const WebDavAuthException([this.message = 'WebDAV 鉴权失败（401/403）']);
  @override
  String toString() => message;
}

/// WebDAV 其它 HTTP 错误。
class WebDavHttpException implements Exception {
  final int statusCode;
  final String message;
  WebDavHttpException(this.statusCode, [String? detail])
      : message = detail ?? 'WebDAV 请求失败: HTTP $statusCode';
  @override
  String toString() => message;
}

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

  /// 凭据来源（仅用于日志与诊断提示）：
  /// user=用户目录覆盖文件；localappdata=%LOCALAPPDATA%\ESW 同目录；
  /// portable=exe 同目录（便携版/旧包迁移）；bundled=随包内置资产。
  final String source;

  const WebDavConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.source = 'unknown',
  });

  bool get isValid =>
      baseUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  static Future<String> configPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}esw_sync_config.json';
  }

  /// 凭据文件的候选路径（按优先级）。
  ///
  /// 换电脑场景下多给一层兜底：除用户目录外，还认 %LOCALAPPDATA%\ESW 与
  /// exe 同目录的 esw_sync_config.json，用户把老机器上的这个文件拷过来即可生效。
  static Future<List<MapEntry<String, String>>> fileCandidates() async {
    final sep = Platform.pathSeparator;
    final out = <MapEntry<String, String>>[];
    try {
      out.add(MapEntry('user', await configPath()));
    } catch (_) {}
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      out.add(MapEntry('localappdata', '$local${sep}ESW${sep}esw_sync_config.json'));
    }
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      out.add(MapEntry('portable', '$exeDir${sep}esw_sync_config.json'));
    } catch (_) {}
    return out;
  }

  /// 读取配置。
  /// 顺序：用户目录（可手动覆盖）→ %LOCALAPPDATA%\ESW → exe 同目录
  /// → 打包内置的 assets/esw_sync_config.json（开箱即用兜底）。
  /// 某一层文件存在但字段无效时继续往下找；全部不可用才返回 null。
  static Future<WebDavConfig?> load() async {
    for (final cand in await fileCandidates()) {
      try {
        final f = File(cand.value);
        if (!await f.exists()) continue;
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final cfg = _fromMap(data, cand.key);
        if (cfg.isValid) return cfg;
      } catch (_) {
        // 单层读取/解析失败 → 继续下一层
      }
    }
    try {
      final raw = await rootBundle.loadString('assets/esw_sync_config.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cfg = _fromMap(data, 'bundled');
      if (cfg.isValid) return cfg;
    } catch (_) {
      // 内置资产缺失（例如发布包被剥离 assets）→ 无凭据
    }
    return null;
  }

  /// 保存到用户目录（手动填写入口），返回是否写入成功。
  Future<bool> save() async {
    try {
      final path = await configPath();
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(toMap()), flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
      };

  WebDavConfig copyWith({String? baseUrl, String? username, String? password}) {
    return WebDavConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      source: source,
    );
  }

  static WebDavConfig _fromMap(Map<String, dynamic> data, String source) {
    return WebDavConfig(
      baseUrl: (data['baseUrl'] as String? ?? '').replaceAll(RegExp(r'/+$'), ''),
      username: data['username'] as String? ?? '',
      password: data['password'] as String? ?? '',
      source: source,
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
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        // 一定要抛出可识别的鉴权异常：否则上层只能笼统记成"离线"，
        // 换机后账号被拒会被误当成"已是最新"。
        throw WebDavAuthException(
            '坚果云拒绝访问（HTTP ${resp.statusCode}）：同步账号或应用密码无效');
      }
      if (resp.statusCode != 200) {
        throw WebDavHttpException(
            resp.statusCode, 'WebDAV GET $relativePath 失败: HTTP ${resp.statusCode}');
      }
      // 大 JSON 解析移到 isolate，避免阻塞 UI。
      // 必须先提取纯字节再进闭包：闭包若捕获整个 resp（http.Response），
      // 其内部 Future/Stream/Timer（dart:async/_AsyncCompleter、
      // dart:isolate/_Timer）会被连带发送，触发 "object is unsendable"。
      final bytes = resp.bodyBytes;
      return await Isolate.run(() => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
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
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw WebDavAuthException(
            '坚果云拒绝写入（HTTP ${resp.statusCode}）：同步账号或应用密码无效');
      }
      return resp.statusCode == 200 || resp.statusCode == 201 || resp.statusCode == 204;
    } on WebDavAuthException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  /// 连通性 / 鉴权自检（PROPFIND 根目录 Depth:0）。
  ///
  /// 返回 {ok, status, dirMissing, message}：
  /// - ok=true 表示账号密码被服务端接受（目录不存在也算账号可用，首次上传会自动建目录）；
  /// - ok=false 时 message 给出可读原因（401 → 账号或应用密码错误）。
  Future<Map<String, dynamic>> probe() async {
    try {
      final req = http.Request('PROPFIND', _uri(''))
        ..headers['Authorization'] = _authorization
        ..headers['Depth'] = '0'
        ..headers['Content-Type'] = 'application/xml';
      final resp =
          await http.Client().send(req).timeout(const Duration(seconds: 20));
      await resp.stream.drain<void>();
      final code = resp.statusCode;
      if (code == 401 || code == 403) {
        return {
          'ok': false,
          'status': code,
          'kind': 'auth',
          'message': '鉴权失败（HTTP $code）：同步账号或应用密码无效',
        };
      }
      if (code == 207 || code == 200) {
        return {'ok': true, 'status': code, 'dirMissing': false, 'message': '连接正常，账号可用'};
      }
      if (code == 404 || code == 409) {
        return {
          'ok': true,
          'status': code,
          'dirMissing': true,
          'message': '账号可用，云端同步目录尚不存在（首次上传会自动创建）',
        };
      }
      return {'ok': false, 'status': code, 'kind': 'http', 'message': '服务端返回 HTTP $code'};
    } catch (e) {
      return {'ok': false, 'status': 0, 'kind': 'network', 'message': '网络不可用：$e'};
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
