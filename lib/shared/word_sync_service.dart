import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'webdav_client.dart';

/// 基于时间戳的词库同步服务。
///
/// 原则：逐词比对时间戳，谁新谁赢。
/// - 本地更新 → 上传覆盖云端
/// - 云端更新 → 返回变更列表，由调用方弹窗让用户决定接受/拒绝
/// - 无网络 / 无凭据 / 鉴权失败 → 不再静默：返回 success:false + error_kind，
///   由 UI 明确告知原因（历史版本静默当成"已是最新"，换机后无从判断）。
class WordSyncService {
  static final WordSyncService _instance = WordSyncService._();
  factory WordSyncService() => _instance;

  WordSyncService._();

  /// 诊断日志：定位同步失败环节。
  /// 跨机器可运行性：日志写入用户可写目录（%LOCALAPPDATA%\ESW），不再写 exe
  /// 同目录——安装到 Program Files 等只读位置时那里不可写；用户目录不可用时
  /// 才退回 exe 同目录，且整段写入失败均静默忽略，绝不影响主流程。
  static Future<void> _debugLog(String msg) async {
    try {
      final local = Platform.environment['LOCALAPPDATA'];
      var dir = (local == null || local.isEmpty)
          ? File(Platform.resolvedExecutable).parent.path
          : '$local${Platform.pathSeparator}ESW';
      try {
        final d = Directory(dir);
        if (!await d.exists()) await d.create(recursive: true);
      } catch (_) {
        dir = File(Platform.resolvedExecutable).parent.path;
      }
      final f = File('$dir${Platform.pathSeparator}esw_sync_debug.log');
      await f.writeAsString(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  // WebDAV 传输客户端（懒加载，无配置时为 null → sync 返回 no_config 失败）
  WebDavClient? _dav;

  /// 最近一次同步失败的分类原因，供 UI 给出可读提示：
  /// no_config / auth / network / timeout / http / unknown；null 表示最近一次未失败。
  String? lastErrorKind;
  String? lastError;

  /// 本次实际使用凭据的来源（user / localappdata / portable / bundled），用于诊断。
  String? credentialSource;

  /// 凭据或网络环境变化后强制重新加载配置（手动填写账号后必须调用）。
  void resetClient() {
    _dav = null;
    lastErrorKind = null;
    lastError = null;
    credentialSource = null;
  }

  Future<WebDavClient?> _davClient() async {
    if (_dav != null) return _dav;
    try {
      final cfg = await WebDavConfig.load();
      if (cfg == null || !cfg.isValid) {
        lastErrorKind = 'no_config';
        lastError = '本机未找到可用的同步账号配置（用户目录 / %LOCALAPPDATA%\\ESW / exe 同目录 / 内置配置均不可用）';
        await _debugLog('[_davClient] 无可用凭据: $lastError');
        return null;
      }
      _dav = WebDavClient.fromConfig(cfg);
      credentialSource = cfg.source;
      lastErrorKind = null;
      lastError = null;
      await _debugLog(
          '[_davClient] 配置加载成功 source=${cfg.source} baseUrl=${cfg.baseUrl} user=${cfg.username}');
      return _dav;
    } catch (e) {
      lastErrorKind = 'no_config';
      lastError = '同步账号配置读取异常：$e';
      await _debugLog('[_davClient] 配置加载异常: $e');
      return null;
    }
  }

  /// 账号自检（供「同步账号设置 → 测试连接」使用），返回 {ok, message, kind, status}。
  Future<Map<String, dynamic>> verifyAccount(WebDavConfig cfg) async {
    final probe = await WebDavClient.fromConfig(cfg).probe();
    return {
      'ok': probe['ok'] == true,
      'message': probe['message']?.toString() ?? '',
      'kind': probe['kind']?.toString() ?? '',
      'status': probe['status'],
    };
  }

  // 本地时间戳缓存：{lowercase_word: iso8601_timestamp}
  final Map<String, String> _localTimestamps = {};
  // 本地删除墓碑：{lowercase_word: iso8601_timestamp}。本地删除过的词记录删除时间，
  // 同步时若墓碑时间戳比云端时间戳新，则从云端删除该词（删除意图传播到云端）。
  final Map<String, String> _localDeletions = {};
  bool _loaded = false;
  Timer? _saveDebounce;

  Future<String> _localFilePath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}word_sync_timestamps.json';
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final path = await _localFilePath();
      final f = File(path);
      if (await f.exists()) {
        final raw = await f.readAsString();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in data.entries) {
          if (e.key.startsWith('del:')) {
            // 删除墓碑，键格式 del:{word} → {word}: 墓碑时间
            _localDeletions[e.key.substring(4)] = e.value as String;
          } else {
            _localTimestamps[e.key] = e.value as String;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveTimestamps() async {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final path = await _localFilePath();
        final f = File(path);
        await f.writeAsString(jsonEncode(_persistMap()));
      } catch (_) {}
    });
  }

  /// 立即持久化时间戳（同步完成后调用，不等 debounce）
  Future<void> _saveTimestampsNow() async {
    _saveDebounce?.cancel();
    try {
      final path = await _localFilePath();
      final f = File(path);
      await f.writeAsString(jsonEncode(_persistMap()));
    } catch (_) {}
  }

  /// 时间戳 + 删除墓碑合并为一个 map 落盘（墓碑用 del: 前缀区分）。
  Map<String, String> _persistMap() {
    final map = <String, String>{
      for (final e in _localDeletions.entries) 'del:${e.key}': e.value,
    };
    map.addAll(_localTimestamps);
    return map;
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  /// 将任意格式的时间戳标准化为纯数字字符串 yyyyMMddHHmmss，确保跨格式可比对。
  /// 支持: ISO 8601 UTC ("2026-08-01T09:54:45.650197Z") 和 "yyyy-MM-dd HH:mm:ss"。
  String _normalizeTs(String ts) {
    final digits = ts.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 14 ? digits.substring(0, 14) : '00000000000000';
  }

  /// 标记本地单词分类变更，记录当前时间戳。
  /// 同时清除该词的删除墓碑：本地又有了这个词，不再向云端传播删除。
  void markChanged(String word) {
    final key = word.toLowerCase();
    _localTimestamps[key] = _formatTimestamp(DateTime.now());
    _localDeletions.remove(key);
    _saveTimestamps();
  }

  /// 标记本地单词删除/拒绝：记录删除墓碑，下次同步会将该删除传播到云端。
  void markDeleted(String word) {
    final key = word.toLowerCase();
    _localTimestamps.remove(key);
    _localDeletions[key] = _formatTimestamp(DateTime.now());
    _saveTimestamps();
  }

  /// 查询本地是否对该词做过删除/拒绝标记（供 UI 调试用）。
  bool isDeletedLocally(String word) => _localDeletions.containsKey(word.toLowerCase());

  /// 在云端备份当前完整词库状态到带时间戳的备份文件（word_sync_state_backup_<时间戳>.json）。
  /// 用于大范围删除前的兜底：即使删除误操作，仍可从备份恢复。
  ///
  /// 规则：
  /// - 与最近一次备份对比，单词集合变动 < 10 个时跳过备份（避免小改动反复产生备份）；
  /// - 每次备份后仅保留最近 10 个备份文件，更早的自动清理。
  ///
  /// 返回备份是否成功（备份到云端并写入成功）。
  Future<bool> backupRemoteState() async {
    try {
      final dav = await _davClient();
      if (dav == null) return false;
      final getResult = await _davGet('word_sync_state.json');
      final content = getResult['content'] as Map<String, dynamic>;
      if (content.isEmpty) return false;
      final currentWords = (content['words'] as Map<String, dynamic>?) ?? <String, dynamic>{};

      // 1) 列出云端已有备份（文件名按时间戳字典序即时间序）
      final allRemote = await dav.listFiles('');
      final backupNames = allRemote
          .where((n) => n.startsWith('word_sync_state_backup_') && n.endsWith('.json'))
          .toList()
        ..sort();

      // 2) 与最近一次备份对比，变动 < 10 词则跳过
      if (backupNames.isNotEmpty) {
        final lastContent = await dav.getJson(backupNames.last);
        if (lastContent != null) {
          final lastWords = (lastContent['words'] as Map<String, dynamic>?) ?? <String, dynamic>{};
          final currentSet = currentWords.keys.toSet();
          final lastSet = lastWords.keys.toSet();
          final diff = currentSet.difference(lastSet).length + lastSet.difference(currentSet).length;
          if (diff < 10) {
            await _debugLog('[backupRemoteState] 与最近备份(${backupNames.last})差异仅 $diff 词，跳过备份');
            return true;
          }
        }
      }

      // 3) 创建新备份
      final ts = DateTime.now();
      final name = 'word_sync_state_backup_'
          '${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}'
          '_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}${ts.second.toString().padLeft(2, '0')}.json';
      final ok = await dav.putJson(name, content);
      if (!ok) {
        await _debugLog('[backupRemoteState] 备份 $name 失败');
        return false;
      }
      await _debugLog('[backupRemoteState] 备份到 $name 结果: $ok words=${currentWords.length}');

      // 4) 只保留最近 10 个备份，更早的清理
      final all = (backupNames + [name])..sort();
      var removed = 0;
      while (all.length > 10) {
        final old = all.removeAt(0);
        final delOk = await dav.deleteFile(old);
        removed++;
        await _debugLog('[backupRemoteState] 清理旧备份 $old 结果: $delOk');
      }
      if (removed > 0) {
        await _debugLog('[backupRemoteState] 共清理 $removed 个旧备份，保留 ${all.length} 个');
      }
      return true;
    } catch (e) {
      await _debugLog('[backupRemoteState] 备份异常: $e');
      return false;
    }
  }

  /// 同步：拉取云端 → 逐词比对时间戳 → 推送/返回变更。
  ///
  /// [localWords] 格式：{lowercase_word: {category, original_case}}
  /// [localExtendBaseMap]：本地词形映射表
  /// 返回 {success, remote_changes, pushed_count, extendBaseMap}
  Future<Map<String, dynamic>> sync({
    required Map<String, Map<String, String>> localWords,
    Map<String, String>? localExtendBaseMap,
    String source = 'unknown',
  }) async {
    await _ensureLoaded();

    try {
      // 整个同步过程设置 120 秒超时，防止网络异常时无限卡死
      return await _doSync(
        localWords: localWords,
        localExtendBaseMap: localExtendBaseMap,
        source: source,
      ).timeout(const Duration(seconds: 120));
    } catch (e) {
      if (e is TimeoutException) {
        lastErrorKind = 'timeout';
        lastError = '同步超时（120 秒无响应），请检查网络后重试';
        await _debugLog('[sync] 同步超时(120s)');
        return {
          'success': false,
          'offline': true,
          'error_kind': 'timeout',
          'error': lastError,
          'remote_changes': <Map<String, String>>[],
          'pushed_count': 0,
          'extendBaseMap': <String, String>{},
        };
      }
      lastErrorKind = 'unknown';
      lastError = '同步异常：$e';
      await _debugLog('[sync] 外层异常: $e');
      return {
        'success': false,
        'offline': true,
        'error_kind': 'unknown',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    }
  }

  Future<Map<String, dynamic>> _doSync({
    required Map<String, Map<String, String>> localWords,
    Map<String, String>? localExtendBaseMap,
    String source = 'unknown',
  }) async {
    try {
      // 1. 拉取云端状态
      final getResult = await _davGet('word_sync_state.json');
      final state = Map<String, dynamic>.from(getResult['content'] as Map<String, dynamic>);
      final remoteWords = (state['words'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final remoteBaseMap = (state['extendBaseMap'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      // 云端删除墓碑：{lowercase_word: iso8601_timestamp}。某端删除/拒绝词后写入，
      // 其他端同步时发现本地有该词、云端已删且墓碑比本地新 → 提示本地删除（双向传播）。
      final remoteDeleted = (state['deleted'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final sha = getResult['sha'] as String;
      // 本次同步开始时云端词库总数（用于大范围删除保护的比例判断）
      final remoteInitialCount = remoteWords.length;

      final now = _formatTimestamp(DateTime.now());
      final remoteChanges = <Map<String, String>>[];
      bool needsPush = false;

      // 2. 处理 extendBaseMap：本地覆盖远程
      if (localExtendBaseMap != null && localExtendBaseMap.isNotEmpty) {
        for (final e in localExtendBaseMap.entries) {
          final oldVal = remoteBaseMap[e.key];
          if (oldVal == null || oldVal != e.value) {
            remoteBaseMap[e.key] = e.value;
            needsPush = true;
          }
        }
      }

      // 3-pre. 换电脑 / 首次同步的整库恢复（bootstrap）
      //
      // 新机本地词库为空（无词、无时间戳、无删除墓碑）时，云端每个词都会被判成
      // remote_only 新增，历史实现会生成上万条逐词冲突卡（1.5.8 实测 12973 条），
      // 用户既不可能逐词点选，体验上等同于"换电脑后同步不了词库"。
      // 这里改为一次性整库恢复：不弹逐词冲突，也不反向推送。
      final freshLocal =
          localWords.isEmpty && _localTimestamps.isEmpty && _localDeletions.isEmpty;
      if (freshLocal && remoteWords.isNotEmpty) {
        final bootstrapWords = <String, Map<String, String>>{};
        for (final e in remoteWords.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final cat = (v['category'] as String?) ?? '';
          if (cat.isEmpty) continue;
          bootstrapWords[e.key] = {
            'original_case': (v['original_case'] as String?) ?? e.key,
            'category': cat,
            'timestamp': (v['timestamp'] as String?) ?? '',
          };
        }
        await _debugLog(
            '[bootstrap] 本机词库为空，云端 ${bootstrapWords.length} 词 → 整库恢复（不生成逐词冲突）');
        return {
          'success': true,
          'bootstrap': true,
          'bootstrap_words': bootstrapWords,
          'remote_changes': <Map<String, String>>[],
          'pushed_count': 0,
          'extendBaseMap': _mapToStringMap(remoteBaseMap),
          'remote_count': remoteInitialCount,
        };
      }

      // 3. 逐词比对
      final localKeys = localWords.keys.toSet();
      final remoteKeys = remoteWords.keys.toSet();
      final allKeys = localKeys.union(remoteKeys);

      for (final key in allKeys) {
        final local = localWords[key];
        final remote = remoteWords[key] as Map<String, dynamic>?;

        if (local == null && remote != null) {
          // 云端有、本地无：
          // ① 若本地存在删除墓碑且墓碑时间不早于云端时间 → 把删除传播到云端（本地明确删过/拒过该词）
          // ② 否则视为云端新增 → 返回变更提示下载
          final cat = remote['category'] as String? ?? '';
          final orig = remote['original_case'] as String? ?? key;
          final delTs = _localDeletions[key];
          final remoteTs = (remote['timestamp'] as String?) ?? '1970-01-01 00:00:00';
          if (delTs != null && _normalizeTs(delTs).compareTo(_normalizeTs(remoteTs)) >= 0) {
            remoteWords.remove(key);
            remoteDeleted[key] = delTs; // 云端记录删除墓碑，供其他端识别该词已被删除
            needsPush = true;
          } else if (cat.isNotEmpty) {
            remoteChanges.add({
              'word': orig,
              'new_category': cat,
              'old_category': '',
              'reason': 'remote_only',
            });
          }
        } else if (local != null && remote == null) {
          // 本地有、云端无：
          // ① 若云端存在该词的删除墓碑，且云端删除时间不早于本地时间戳 → 云端删得比本地新，
          //    提示本地删除（双向传播：云端删除 → 本地删除）。不上传、不清墓碑，等待用户决策。
          // ② 否则（本地新增 / 本地时间戳更新，即本地恢复）→ 上传本地词，并撤销云端删除墓碑。
          final delTs = remoteDeleted[key];
          final localTs = _localTimestamps[key] ?? '1970-01-01 00:00:00';
          if (delTs != null && _normalizeTs(delTs).compareTo(_normalizeTs(localTs)) >= 0) {
            remoteChanges.add({
              'word': local['original_case'] ?? key,
              'new_category': '',
              'old_category': local['category'] ?? '',
              'reason': 'remote_deleted',
            });
          } else {
            // 本地新增或本地恢复 → 上传，并清除云端删除墓碑（该词重新出现在云端）
            _localDeletions.remove(key); // 本地恢复了该词，清除删除墓碑
            remoteDeleted.remove(key);
            remoteWords[key] = {
              'original_case': local['original_case'] ?? key,
              'category': local['category'] ?? '',
              'timestamp': _localTimestamps[key] ?? now,
              'source': source,
            };
            needsPush = true;
          }
        } else if (local != null && remote != null) {
          // 两端都有 → 比对时间戳
          final localTs = _localTimestamps[key] ?? '1970-01-01 00:00:00';
          final remoteTs = (remote['timestamp'] as String?) ?? '1970-01-01 00:00:00';
          final localCat = local['category'] ?? '';
          final remoteCat = remote['category'] as String? ?? '';

          if (localCat != remoteCat) {
            if (_normalizeTs(localTs).compareTo(_normalizeTs(remoteTs)) > 0) {
              // 本地更新 → 上传
              _localDeletions.remove(key); // 本地保留了该词，清除删除墓碑
              remoteWords[key] = {
                'original_case': local['original_case'] ?? key,
                'category': localCat,
                'timestamp': localTs,
                'source': source,
              };
              needsPush = true;
            } else if (_normalizeTs(remoteTs).compareTo(_normalizeTs(localTs)) > 0) {
              // 云端更新 → 返回变更
              remoteChanges.add({
                'word': remote['original_case'] as String? ?? key,
                'new_category': remoteCat,
                'old_category': localCat,
                'reason': 'remote_newer',
              });
            }
            // 时间戳相等 → 不动
          }
        }
      }

      // 4. 推送
      int pushedCount = 0;
      var pushFailed = false;
      if (needsPush) {
        state['words'] = remoteWords;
        state['deleted'] = remoteDeleted;
        state['extendBaseMap'] = remoteBaseMap;
        state['last_modified'] = now;
        final ok = await _davPut('word_sync_state.json', state, sha, 'sync: $source @ $now');
        if (ok) {
          pushedCount = 1;
          await _saveTimestampsNow(); // 同步成功后立即持久化时间戳
        } else {
          // 拉取成功但上传失败（网络抖动 / 目录权限）：不能报"已是最新"，
          // 否则用户以为同步成功，重装或换机后云端仍是旧数据。
          pushFailed = true;
          lastErrorKind = 'push_failed';
          lastError = '本地变更上传云端失败（网络或云端权限问题）';
          await _debugLog('[sync] 推送失败：本地变更未上传');
        }
      }

      return {
        'success': true,
        'remote_changes': remoteChanges,
        'pushed_count': pushedCount,
        'push_failed': pushFailed,
        'extendBaseMap': _mapToStringMap(remoteBaseMap),
        'remote_count': remoteInitialCount,
      };

    } on WebDavConfigException catch (e) {
      lastErrorKind = 'no_config';
      lastError = e.message;
      await _debugLog('[_doSync] 无可用凭据: $e');
      return {
        'success': false,
        'offline': false,
        'error_kind': 'no_config',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    } on WebDavAuthException catch (e) {
      lastErrorKind = 'auth';
      lastError = e.message;
      await _debugLog('[_doSync] 鉴权失败: $e');
      return {
        'success': false,
        'offline': false,
        'error_kind': 'auth',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    } on WebDavHttpException catch (e) {
      lastErrorKind = 'http';
      lastError = e.message;
      await _debugLog('[_doSync] 云端返回错误: $e');
      return {
        'success': false,
        'offline': false,
        'error_kind': 'http',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    } on TimeoutException catch (e) {
      lastErrorKind = 'timeout';
      lastError = '云端响应超时：$e';
      await _debugLog('[_doSync] 超时: $e');
      return {
        'success': false,
        'offline': true,
        'error_kind': 'timeout',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    } on SocketException catch (e) {
      lastErrorKind = 'network';
      lastError = '网络不可用：${e.message}';
      await _debugLog('[_doSync] 网络异常: $e');
      return {
        'success': false,
        'offline': true,
        'error_kind': 'network',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    } on http.ClientException catch (e) {
      lastErrorKind = 'network';
      lastError = '网络请求失败：${e.message}';
      await _debugLog('[_doSync] HTTP 客户端异常: $e');
      return {
        'success': false,
        'offline': true,
        'error_kind': 'network',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    } catch (e, st) {
      // 其它异常：不再静默吞掉，返回 unknown 由 UI 提示，同时写日志留证
      lastErrorKind = 'unknown';
      lastError = '同步失败：$e';
      await _debugLog('[_doSync] 同步异常: $e\n$st');
      return {
        'success': false,
        'offline': false,
        'error_kind': 'unknown',
        'error': lastError,
        'remote_changes': <Map<String, String>>[],
        'pushed_count': 0,
        'extendBaseMap': <String, String>{},
      };
    }
  }

  Map<String, String> _mapToStringMap(Map<String, dynamic> map) {
    final out = <String, String>{};
    for (final e in map.entries) {
      out[e.key] = e.value.toString();
    }
    return out;
  }

  // ========== WebDAV 传输层 ==========

  /// 读取云端 JSON。无 WebDAV 配置时抛出异常（调用方捕获后静默 offline）。
  /// 返回结构：{content, sha}，WebDAV 无 sha 概念，固定为空串。
  Future<Map<String, dynamic>> _davGet(String path) async {
    final dav = await _davClient();
    if (dav == null) {
      await _debugLog('[_davGet] davClient 为 null，无法同步');
      throw WebDavConfigException(lastError ?? '未配置 WebDAV 同步');
    }
    final content = await dav.getJson(path);
    if (content == null) {
      // 云端文件尚不存在 → 返回空状态，首次同步会把本地词库整体上传完成初始化
      await _debugLog('[_davGet] 云端 $path 不存在(404) → 返回空状态，首次上传');
      return {'content': <String, dynamic>{'words': <String, dynamic>{}, 'extendBaseMap': <String, dynamic>{}}, 'sha': ''};
    }
    await _debugLog('[_davGet] 云端 $path 读取成功 words=${(content['words'] as Map<String, dynamic>?)?.length ?? 0}');
    return {'content': content, 'sha': ''};
  }

  Future<bool> _davPut(String path, Map<String, dynamic> content, String sha, String message) async {
    final dav = await _davClient();
    if (dav == null) {
      await _debugLog('[_davPut] davClient 为 null，推送失败');
      return false;
    }
    final ok = await dav.putJson(path, content);
    await _debugLog('[_davPut] 推送 $path 结果: $ok words=${(content['words'] as Map<String, dynamic>?)?.length ?? 0}');
    return ok;
  }
}
