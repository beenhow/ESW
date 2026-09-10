import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'webdav_client.dart';

/// 分类判定优先级（高到低）
const _categoryPriority = ['超标词', '拓展词', '专有词'];

/// 共识阈值（70%）
const double _threshold = 0.7;

/// 共识服务：多用户投票、同步时刻快照判定、增量同步。
///
/// 核心原则：服务端权威，客户端仅为缓存。分类判定仅在 sync() 时触发。
class ConsensusService {
  static final ConsensusService _instance = ConsensusService._();
  factory ConsensusService() => _instance;

  /// 安全获取 words Map：若实际类型不是 Map 则返回空字典
  Map<String, dynamic> _safeWords(Map<String, dynamic> state) {
    final raw = state['words'];
    if (raw is Map<String, dynamic>) return raw;
    state['words'] = <String, dynamic>{};
    return state['words'] as Map<String, dynamic>;
  }

  /// 安全获取 extendBaseMap：若实际类型不是 Map 则返回空字典
  Map<String, dynamic> _safeExtendBaseMap(Map<String, dynamic> state) {
    final raw = state['extendBaseMap'];
    if (raw is Map<String, dynamic>) return raw;
    state['extendBaseMap'] = <String, dynamic>{};
    return state['extendBaseMap'] as Map<String, dynamic>;
  }
  ConsensusService._();

  // WebDAV 传输客户端（懒加载，无配置时为 null → 同步静默 offline）
  WebDavClient? _dav;

  Future<WebDavClient?> _davClient() async {
    if (_dav != null) return _dav;
    final cfg = await WebDavConfig.load();
    if (cfg == null || !cfg.isValid) return null;
    _dav = WebDavClient.fromConfig(cfg);
    return _dav;
  }

  int _localVersion = 0;
  int _lastSyncVersion = 0;
  final List<Map<String, dynamic>> _pendingVotes = [];
  bool _stateLoaded = false; // 惰性加载标记

  int get localVersion => _localVersion;
  int get lastSyncVersion => _lastSyncVersion;
  bool get hasPending => _pendingVotes.isNotEmpty;
  List<Map<String, dynamic>> get pendingVotes => List.unmodifiable(_pendingVotes);

  // ========== 持久化 ==========

  static Future<String> _syncStatePath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}consensus_sync_state.json';
  }

  Future<void> _ensureLoaded() async {
    if (_stateLoaded) return;
    _stateLoaded = true;
    try {
      final path = await _syncStatePath();
      final f = File(path);
      if (f.existsSync()) {
        final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        _lastSyncVersion = data['lastSyncVersion'] as int? ?? 0;
        _localVersion = data['localVersion'] as int? ?? 0;
        final pv = data['pendingVotes'];
        if (pv is List) {
          for (final v in pv) {
            if (v is Map<String, dynamic>) _pendingVotes.add(v);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSyncState() async {
    try {
      final path = await _syncStatePath();
      File(path).writeAsStringSync(jsonEncode({
        'lastSyncVersion': _lastSyncVersion,
        'localVersion': _localVersion,
        'pendingVotes': _pendingVotes,
      }));
    } catch (_) {}
  }

  // ========== 公开 API ==========

  /// 投票：记录用户分类投票（仅上传，不重算分类）。
  /// 投票后的分类状态需等待下次 sync() 才会更新。
  ///
  /// 返回 {success, word, current_category, server_version, message}
  /// 课标词锁定返回 error_code: "CURRICULUM_LOCKED"
  Future<Map<String, dynamic>> vote({
    required String word,
    required String category,
    required String userId,
    String? baseWord,
  }) async {
    try {
      return await _doVote(word: word, category: category, userId: userId, baseWord: baseWord);
    } catch (e) {
      // 离线：存入 pending 队列
      _pendingVotes.add({
        'word': word,
        'category': category,
        'userId': userId,
        'baseWord': baseWord ?? '',
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'pending',
      });
      return {
        'success': false,
        'offline': true,
        'word': word,
        'message': '离线修改，联网后生效',
      };
    }
  }

  /// 实际执行投票上传（线上路径）
  Future<Map<String, dynamic>> _doVote({
    required String word,
    required String category,
    required String userId,
    String? baseWord,
  }) async {
    final getResult = await _davGet('consensus_state.json');
    final state = getResult['content'] as Map<String, dynamic>;
    final sha = getResult['sha'] as String;

    final words = _safeWords(state);
    final lowerWord = word.toLowerCase();
    Map<String, dynamic>? wdata = words[lowerWord] as Map<String, dynamic>?;

    if (wdata == null) {
      wdata = {
        'is_curriculum': false,
        'current_category': null,
        'classify_version': 0,
        'votes': <String, dynamic>{},
        'original_case': word,
      };
      words[lowerWord] = wdata;
    }

    // 课标词检查
    if (wdata['is_curriculum'] == true) {
      return {
        'success': false,
        'error_code': 'CURRICULUM_LOCKED',
        'word': word,
        'current_category': '课标词',
        'server_version': state['version'] ?? 0,
        'message': '「$word」为课标词，不可修改',
      };
    }

    // 仅更新投票记录，不重算分类
    final votes = (wdata['votes'] as Map<String, dynamic>?) ?? {};
    votes[userId] = {
      'category': category,
      'timestamp': DateTime.now().toIso8601String().substring(0, 19),
    };
    wdata['votes'] = votes;

    // extendBaseMap
    if (baseWord != null && baseWord.isNotEmpty) {
      final ebm = _safeExtendBaseMap(state);
      ebm[word] = baseWord;
      state['extendBaseMap'] = ebm;
    }

    // bump version：让其他端 sync 能感知到新投票
    state['version'] = (state['version'] as int? ?? 0) + 1;

    // 推送
    final putSuccess = await _davPut(
      'consensus_state.json',
      state,
      sha,
      'vote: $word -> $category by $userId',
    );
    if (!putSuccess) {
      return {'success': false, 'error': '推送云端失败'};
    }

    return {
      'success': true,
      'word': word,
      'current_category': wdata['current_category'] ?? '未筛选词',
      'server_version': state['version'],
      'message': '已提交投票，同步后生效',
    };
  }

  /// 同步：根据本地状态执行场景A/B/C。
  /// 支持双向同步：上传本地独有词 → 共识，下载共识独有词 → 本地。
  /// 参数：[localExtendWords] / [localChaoGangWords] / [localExtraWords] 为本地分类词列表，
  /// [localExtendBaseMap] 为本地词形映射表，[userId] 用于投票投票人标识。
  /// 返回 {sync_direction, success, server_version, uploaded_count, downloaded_count, changes}
  Future<Map<String, dynamic>> sync({
    List<String>? localExtendWords,
    List<String>? localChaoGangWords,
    List<String>? localExtraWords,
    Map<String, String>? localExtendBaseMap,
    String userId = 'local_user',
  }) async {
    await _ensureLoaded();
    try {
      // 判断场景
      if (_pendingVotes.isNotEmpty) {
        return await _syncScenarioA();
      }

      // 拉取服务端状态检查版本
      final getResult = await _davGet('consensus_state.json');
      final state = getResult['content'] as Map<String, dynamic>;
      final serverVersion = state['version'] as int;
      String sha = getResult['sha'] as String;

      // --- 双向同步：上传本地独有词 ---
      _lastUploadedCount = 0;
      bool uploadedLocal = false;
      if (localExtendWords != null || localChaoGangWords != null || localExtraWords != null) {
        var words = _safeWords(state);
        if (words.isEmpty) {
          words = <String, dynamic>{};
          state['words'] = words;
        }
        uploadedLocal |= _mergeLocalWords(state, words, localExtendWords ?? [], '拓展词', userId);
        uploadedLocal |= _mergeLocalWords(state, words, localChaoGangWords ?? [], '超标词', userId);
        uploadedLocal |= _mergeLocalWords(state, words, localExtraWords ?? [], '专有词', userId);
      }
      if (localExtendBaseMap != null) {
        var ebm = _safeExtendBaseMap(state);
        if (ebm.isEmpty) {
          ebm = <String, dynamic>{};
          state['extendBaseMap'] = ebm;
        }
        for (final entry in localExtendBaseMap.entries) {
          if (!ebm.containsKey(entry.key)) {
            ebm[entry.key] = entry.value;
            uploadedLocal = true;
          }
        }
      }
      if (uploadedLocal) {
        state['version'] = (state['version'] as int) + 1;
        final putOk = await _davPut(
          'consensus_state.json', state, sha,
          'sync: upload $_lastUploadedCount local words',
        );
        if (!putOk) {
          return {'success': false, 'error': '上传本地词库失败'};
        }
        // 上传后重分类，返回全量已分类词条作为变更（用于调用端全量去重）
        _reclassifyAll(state);
        final changes = _buildAllClassifiedChanges(state);
        // 推送重分类结果
        final putOk2 = await _davPut(
          'consensus_state.json', state, '',
          'sync: reclassify after upload at version ${state['version']}',
        );
        if (putOk2) {
          _localVersion = state['version'] as int;
          _lastSyncVersion = state['version'] as int;
          await _saveSyncState();
        }
        return {
          'sync_direction': 'upload',
          'success': true,
          'server_version': state['version'],
          'uploaded_count': _lastUploadedCount,
          'downloaded_count': changes.length,
          'changes': changes,
          'extendBaseMap': state['extendBaseMap'] ?? {},
        };
      }
      // --- 双向同步结束 ---

      if (serverVersion <= _lastSyncVersion) {
        // 场景C：版本已最新，但检查本地与共识词数是否一致（去重场景）
        if (localExtendWords != null || localChaoGangWords != null || localExtraWords != null) {
          final localUnique = <String>{};
          for (final w in localExtendWords ?? <String>[]) { localUnique.add(w.toLowerCase()); }
          for (final w in localChaoGangWords ?? <String>[]) { localUnique.add(w.toLowerCase()); }
          for (final w in localExtraWords ?? <String>[]) { localUnique.add(w.toLowerCase()); }
          final consensusWords = _safeWords(state);
          final consensusClassified = consensusWords.values
              .where((v) => (v as Map<String, dynamic>)['current_category'] != null)
              .length;
          if (localUnique.length != consensusClassified) {
            // 本地词数与共识不一致 → 下载全量分类以去重对齐
            final changes = _buildAllClassifiedChanges(state);
            return {
              'sync_direction': 'download',
              'success': true,
              'server_version': serverVersion,
              'downloaded_count': changes.length,
              'changes': changes,
              'extendBaseMap': state['extendBaseMap'] ?? <String, dynamic>{},
            };
          }
        }
        // 真正已最新
        return {
          'sync_direction': 'none',
          'success': true,
          'message': '已是最新状态',
          'server_version': serverVersion,
          'changes': <dynamic>[],
          'extendBaseMap': state['extendBaseMap'] ?? <String, dynamic>{},
        };
      }

      // 首次同步：全量下载（本地无数据时服务端所有词条都作为变更）
      if (_lastSyncVersion == 0) {
        return await _syncScenarioFirst(state, serverVersion, sha);
      }

      // 场景B：直接拉取
      return await _syncScenarioB(state, serverVersion, sha);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// 记录本次上传数量（用于 commit message）
  int _lastUploadedCount = 0;

  /// 将本地分类词合并到共识状态：只上传共识中不存在的词。
  /// 返回 true 表示至少新增了一个词。
  bool _mergeLocalWords(Map<String, dynamic> state, Map<String, dynamic> words,
      List<String> localList, String category, String userId) {
    bool added = false;
    final now = DateTime.now().toUtc().toIso8601String();
    for (final word in localList) {
      final key = word.toLowerCase();
      if (words.containsKey(key)) continue; // 共识已有，跳过
      words[key] = {
        'original_case': word,
        'current_category': category,
        'votes': <String, dynamic>{
          userId: {
            'category': category,
            'timestamp': now,
          }
        },
        'first_seen_version': state['version'],
      };
      _lastUploadedCount++;
      added = true;
    }
    return added;
  }

  /// 构建共识中所有已分类词条的变更列表（用于全量对齐）。
  List<Map<String, dynamic>> _buildAllClassifiedChanges(Map<String, dynamic> state) {
    final words = _safeWords(state);
    final changes = <Map<String, dynamic>>[];
    for (final entry in words.entries) {
      final cat = (entry.value as Map<String, dynamic>)['current_category'] as String?;
      if (cat != null) {
        changes.add({
          'word': (entry.value as Map<String, dynamic>)['original_case'] ?? entry.key,
          'old_category': null,
          'new_category': cat,
          'version': state['version'],
        });
      }
    }
    return changes;
  }

  /// 场景A：本地有 pending → 先上传 pending → 再拉取
  Future<Map<String, dynamic>> _syncScenarioA() async {
    int uploaded = 0;

    // 按时间戳升序补发 pending
    _pendingVotes.sort((a, b) => (a['timestamp'] as String).compareTo(b['timestamp'] as String));
    final toUpload = List<Map<String, dynamic>>.from(_pendingVotes);

    for (final pv in toUpload) {
      try {
        final r = await _doVote(
          word: pv['word'] as String,
          category: pv['category'] as String,
          userId: pv['userId'] as String,
          baseWord: (pv['baseWord'] as String?) ?? '',
        );
        if (r['success'] == true || r['error_code'] == 'CURRICULUM_LOCKED') {
          _pendingVotes.remove(pv);
          uploaded++;
        }
      } catch (_) {
        break; // 网络中断，剩余 pending 下次同步
      }
    }

    // 补发后立即拉取
    final getResult = await _davGet('consensus_state.json');
    final state = getResult['content'] as Map<String, dynamic>;
    final serverVersion = state['version'] as int;

    // 以 T_sync 为界重算全部分类
    final changes = _reclassifyAll(state);

    // 推送重算结果
    final putSuccess = await _davPut(
      'consensus_state.json',
      state,
      getResult['sha'] as String,
      'sync: reclassify at version $serverVersion',
    );
    if (!putSuccess) {
      return {'success': false, 'error': '推送云端失败'};
    }

    _localVersion = state['version'] as int;
    _lastSyncVersion = state['version'] as int;
    await _saveSyncState();

    return {
      'sync_direction': 'upload_then_download',
      'success': true,
      'server_version': state['version'],
      'uploaded_count': uploaded,
      'downloaded_count': changes.length,
      'changes': changes,
      'extendBaseMap': state['extendBaseMap'] ?? {},
    };
  }

  /// 场景B：本地无 pending → 直接拉取
  Future<Map<String, dynamic>> _syncScenarioB(Map<String, dynamic> state, int serverVersion, String sha) async {
    // 以 T_sync 为界重算全部分类
    final changes = _reclassifyAll(state);

    // 推送重算结果
    final putSuccess = await _davPut(
      'consensus_state.json',
      state,
      sha,
      'sync: reclassify at version $serverVersion',
    );
    if (!putSuccess) {
      return {'success': false, 'error': '推送云端失败'};
    }

    _localVersion = state['version'] as int;
    _lastSyncVersion = state['version'] as int;
    await _saveSyncState();

    return {
      'sync_direction': 'download',
      'success': true,
      'server_version': state['version'],
      'downloaded_count': changes.length,
      'changes': changes,
      'extendBaseMap': state['extendBaseMap'] ?? {},
    };
  }

  /// 首次全量同步：将服务端所有已分类词条作为增量变更下发。
  Future<Map<String, dynamic>> _syncScenarioFirst(Map<String, dynamic> state, int serverVersion, String sha) async {
    // 先跑一次分类（确保课标词锁定等逻辑生效）
    _reclassifyAll(state);

    // 构建全量变更列表：所有已分类词条都视为"变更"
    final words = _safeWords(state);
    final changes = <Map<String, dynamic>>[];
    for (final entry in words.entries) {
      final cat = (entry.value as Map<String, dynamic>)['current_category'] as String?;
      if (cat != null) {
        changes.add({
          'word': (entry.value as Map<String, dynamic>)['original_case'] ?? entry.key,
          'old_category': null,
          'new_category': cat,
          'version': state['version'],
        });
      }
    }

    // 推送重算结果
    final putSuccess = await _davPut(
      'consensus_state.json',
      state,
      sha,
      'sync: full first sync at version $serverVersion',
    );
    if (!putSuccess) {
      return {'success': false, 'error': '推送云端失败'};
    }

    _localVersion = state['version'] as int;
    _lastSyncVersion = state['version'] as int;
    await _saveSyncState();

    return {
      'sync_direction': 'download',
      'success': true,
      'server_version': state['version'],
      'downloaded_count': changes.length,
      'changes': changes,
      'extendBaseMap': state['extendBaseMap'] ?? {},
    };
  }

  /// 拉取完整状态并重建本地词库
  Future<Map<String, dynamic>> fetchFullState() async {
    try {
      final getResult = await _davGet('consensus_state.json');
      final state = getResult['content'] as Map<String, dynamic>;
      _localVersion = state['version'] as int;
      _lastSyncVersion = _localVersion;
      await _saveSyncState();
      return _exportVocabLists(state);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ========== 内部算法 ==========

  /// 同步时刻快照判定：重新计算所有非课标词的分类（70%阈值）。
  /// 变更记录写入 state（version 递增），返回变更列表。
  List<Map<String, dynamic>> _reclassifyAll(Map<String, dynamic> state) {
    final words = _safeWords(state);
    final changed = <Map<String, dynamic>>[];

    for (final entry in words.entries) {
      final word = entry.key;
      final wdata = entry.value as Map<String, dynamic>;

      if (wdata['is_curriculum'] == true) {
        if (wdata['current_category'] != '课标词') {
          final old = wdata['current_category'];
          wdata['current_category'] = '课标词';
          state['version'] = (state['version'] as int) + 1;
          wdata['classify_version'] = state['version'];
          changed.add({
            'word': wdata['original_case'] ?? word, 'old_category': old,
            'new_category': '课标词', 'version': state['version'],
          });
        }
        continue;
      }

      // 归一化 votes：支持旧 List 格式和新 Map 格式
      final rawVotes = wdata['votes'];
      Map<String, dynamic> votesMap;
      if (rawVotes is Map<String, dynamic>) {
        votesMap = rawVotes;
      } else if (rawVotes is List) {
        votesMap = {};
        for (final item in rawVotes) {
          if (item is Map<String, dynamic> && item['voter'] is String) {
            votesMap[item['voter'] as String] = {
              'category': item['category'],
              'timestamp': item['timestamp'] ?? '',
            };
          }
        }
        wdata['votes'] = votesMap; // 写回 Map 格式
      } else {
        continue;
      }
      if (votesMap.isEmpty) continue; // 无投票 → 保持"未筛选词"

      // 统计各分类票数和最后时间戳
      final tally = <String, int>{};
      final lastTs = <String, String>{};
      for (final v in votesMap.entries) {
        final cat = (v.value as Map<String, dynamic>)['category'] as String?;
        final ts = (v.value as Map<String, dynamic>)['timestamp'] as String? ?? '';
        if (cat != null) {
          tally[cat] = (tally[cat] ?? 0) + 1;
          if (ts.compareTo(lastTs[cat] ?? '') > 0) {
            lastTs[cat] = ts;
          }
        }
      }
      final total = tally.values.fold(0, (a, b) => a + b);
      if (total == 0) continue;

      // 收集所有 ≥70% 的分类
      final qualifying = <String>[];
      for (final cat in _categoryPriority) {
        if ((tally[cat] ?? 0) / total >= _threshold) {
          qualifying.add(cat);
        }
      }

      String? newCat;
      if (qualifying.length == 1) {
        newCat = qualifying.first;
      } else if (qualifying.length > 1) {
        // 多分类达标：时间戳兜底（取最后修改时间最晚的分类）
        String? latestCat;
        String latestTsStr = '';
        for (final cat in qualifying) {
          final ts = lastTs[cat] ?? '';
          if (ts.compareTo(latestTsStr) > 0 || latestCat == null) {
            latestCat = cat;
            latestTsStr = ts;
          }
        }
        newCat = latestCat;
      }
      // 无分类达标 → null（"未筛选词"）

      final oldCat = wdata['current_category'] as String?;
      if (newCat != oldCat) {
        state['version'] = (state['version'] as int) + 1;
        wdata['current_category'] = newCat;
        wdata['classify_version'] = state['version'];
        changed.add({
          'word': wdata['original_case'] ?? word, 'old_category': oldCat,
          'new_category': newCat, 'version': state['version'],
        });
      }
    }

    return changed;
  }

  /// 导出词表列表（兼容旧格式）
  Map<String, dynamic> _exportVocabLists(Map<String, dynamic> state) {
    final words = _safeWords(state);
    final extendWords = <String>[];
    final chaoGang = <String>[];
    final extra = <String>[];

    for (final entry in words.entries) {
      final cat = (entry.value as Map<String, dynamic>)['current_category'] as String?;
      final origWord = (entry.value as Map<String, dynamic>)['original_case'] ?? entry.key;
      if (cat == '拓展词') {
        extendWords.add(origWord);
      } else if (cat == '超标词') {
        chaoGang.add(origWord);
      } else if (cat == '专有词') {
        extra.add(origWord);
      }
    }

    return {
      'extendWords': extendWords,
      'extendBaseMap': state['extendBaseMap'] ?? {},
      'manualChaoGangWords': chaoGang,
      'manualExtraWords': extra,
    };
  }

  // ========== WebDAV 传输层 ==========

  Future<Map<String, dynamic>> _davGet(String path) async {
    final dav = await _davClient();
    if (dav == null) {
      throw Exception('未配置 WebDAV 同步');
    }
    final content = await dav.getJson(path);
    if (content == null) {
      // 云端文件尚不存在 → 返回空状态（_safeWords/_safeExtendBaseMap 会补默认字段）
      return {'content': <String, dynamic>{}, 'sha': ''};
    }
    return {'content': content, 'sha': ''};
  }

  Future<bool> _davPut(String path, Map<String, dynamic> content, String sha, String message) async {
    final dav = await _davClient();
    if (dav == null) return false;
    return await dav.putJson(path, content);
  }
}
