import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:isolate' show Isolate;
import 'dart:typed_data';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData;
import 'package:flutter/gestures.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:fast_gbk/fast_gbk.dart' show gbk;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'theme/app_theme.dart';
import 'theme/esw_tokens.dart';
import 'widgets/esw_widgets.dart';
import 'pages/search_page.dart';
import 'pages/detect_page.dart';
import 'pages/word_bank_page.dart';
import 'shared/vocab_service.dart';
import 'shared/word_sync_service.dart';
import 'shared/doc_extractor.dart';
import 'shared/export_extra_table.dart';
import 'shared/base_word_candidates.dart';
import 'shared/inplace_docx_annotator.dart';
import 'shared/app_snack_bar.dart';
import 'shared/export_progress_overlay.dart';
import 'dictionary_service.dart';

/// 生成导出文件名：ESW + 原文件名(去扩展名) + 检测结果 + 时间戳防重后缀。
/// 源文件场景取 widget.fileName；为空（粘贴文本）时用「文本检测」兜底；
/// 过滤 Windows 非法字符（\ / : * ? " < > | 及首尾空格）。
String _exportBaseName(String rawFileName, String stamp) {
  var name = rawFileName.trim();
  if (name.isEmpty) name = '文本检测';
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  if (name.isEmpty) name = '文本检测';
  return 'ESW$name检测结果_$stamp';
}

/// 应用文档目录缓存：启动路径多处获取同一目录，跨插件通道 await 有固定开销，缓存一次复用。
String? _cachedAppDocDir;
Future<String> _appDocDir() async {
  final c = _cachedAppDocDir;
  if (c != null) return c;
  final dir = await getApplicationDocumentsDirectory();
  _cachedAppDocDir = dir.path;
  return dir.path;
}

/// 上次导出路径（模块级记忆，避免每次重新选择）
String? _lastExportPath;
String? _lastVocabExportPath;

class AndroidEswApp extends StatefulWidget {
  const AndroidEswApp({super.key});

  @override
  State<AndroidEswApp> createState() => _AndroidEswAppState();
}

class _AndroidEswAppState extends State<AndroidEswApp> {
  int _currentIndex = 0;
  final VocabService _vocab = VocabService();

  /// 文本检测历史记录
  final List<_DetectHistory> _detectHistory = [];

  /// corpus 词频索引缓存（O(1) 查表，替代 getWordFrequency 全量扫描）

  /// 已导入真题文件数（-1 表示尚未统计完成）
  int _corpusFileCount = -1;

  /// 已导入教材文件数（-1 表示尚未统计完成）
  int _textbookFileCount = -1;

  /// 按年份统计的真题语料词库命中单词数（{年份: 命中次数}）。
  /// null 表示尚未统计完成 / 加载中；空 Map 表示无年份数据。
  Map<int, int>? _yearHitCounts;

  /// 按教材文件统计的教材语料词库命中单词数（{教材名(去扩展名): 命中次数}）。
  /// null 表示尚未统计完成 / 加载中；空 Map 表示无教材数据。
  Map<String, int>? _textbookHitCounts;

  /// 按年份统计的真题语料命中明细（{年份: [单词 + 词性/分类]}），
  /// 供检测页点击年份格展开查看。与 _yearHitCounts 同批统计。
  Map<int, List<CorpusHitWord>>? _yearHitWords;

  /// 按教材文件统计的教材语料命中明细（{教材名(去扩展名): [单词 + 词性/分类]}），
  /// 供检测页点击教材格展开查看。
  Map<String, List<CorpusHitWord>>? _textbookHitWords;
  bool _syncing = false;
  final WordSyncService _wordSyncService = WordSyncService();
  String _userId = '';

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(_onSearchFocusChanged);
    _pasteFocus.addListener(_onPasteFocusChanged);
    _initApp();
  }

  void _onSearchFocusChanged() => setState(() {});

  void _onPasteFocusChanged() => setState(() {});

  @override
  void dispose() {
    _searchFocus.dispose();
    _pasteFocus.dispose();
    _searchCtrl.dispose();
    _pasteCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _initApp() async {
    // 各项初始化相互独立，并行执行以缩短首屏等待
    await Future.wait([
      _vocab.loadStandardWords(),
      _loadConfig(),
      _refreshCorpusCount(),
      _refreshTextbookCount(),
    ]);
    if (mounted) setState(() {});
    _maybePromptSync();
    // 后台统计按年份命中单词数（不阻塞首屏，检测页显示"加载中…"直至完成）
    _refreshYearHitCounts();
  }

  /// 启动同步词库提示：首帧后弹窗提醒"词库可能不是最新"，用户可选择
  /// "去同步"（直接触发 _syncVocab）或"暂不"。
  Future<void> _maybePromptSync() async {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final goSync = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('同步词库'),
          content: const Text('词库可能不是最新，请前往词库页同步。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('暂不'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('去同步'),
            ),
          ],
        ),
      );
      if (goSync == true && mounted) {
        await _syncVocab();
      }
    });
  }

  /// 应用文档目录/corpus 下是否已有真题 txt（真题语料可用）。
  Future<bool> _hasRealCorpus() async {
    try {
      final p = await _corpusDirPath();
      final d = Directory(p);
      if (!await d.exists()) return false;
      await for (final e in d.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.txt')) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 弹窗引导用户导入真题或教材（词库同步完成/导出高频前调用）。
  /// 返回 true 表示已具备真题语料，false 表示用户未导入/取消。
  /// 未导入时明确提示"无法完成真题单词检测"。
  Future<bool> _promptCorpusImport() async {
    if (await _hasRealCorpus()) return true;
    if (!mounted) return false;
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('需要真题/教材语料'),
        content: const Text(
          '真题单词检测需要真题或教材语料支撑。请先导入真题或教材；'
          '若不导入，将无法完成真题单词检测。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, 'textbook'),
            child: const Text('导入教材'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, 'exam'),
            child: const Text('导入真题'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, 'later'),
            child: const Text('暂不'),
          ),
        ],
      ),
    );
    if (choice == 'exam') {
      await _importCorpus();
    } else if (choice == 'textbook') {
      await _importTextbook();
    }
    if (await _hasRealCorpus()) return true;
    if (mounted) {
      showAppSnackBar(context, '无法完成真题单词检测：请先导入真题或教材语料', type: AppSnackBarType.error);
    }
    return false;
  }

  /// 词库同步完成后提示导入真题/教材（未导入则提示无法完成真题单词检测）。
  Future<void> _maybePromptCorpusImport() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _promptCorpusImport();
    });
  }

  Future<String> _getConfigPath() async {
    final dir = await _appDocDir();
    return '$dir/esw_android_config.json';
  }

  Future<void> _loadConfig() async {
    try {
      final configPath = await _getConfigPath();
      final f = File(configPath);
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString());
        _vocab.fromJson(json);
        _userId = json['userId'] as String? ?? _genUserId();
      }
    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    try {
      final configPath = await _getConfigPath();
      final data = _vocab.toJson();
      data['userId'] = _userId;
      await File(configPath).writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  String _genUserId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = (now * 1103515245 + 12345) & 0x7fffffff;
    return 'android_${now.toRadixString(36)}_${rand.toRadixString(36)}';
  }

  // ---------------- 词库同步（WebDAV） ----------------

  /// 构建当前本地词库快照（决策后再次同步时需重建，反映最新的本地分类状态）。
  Map<String, Map<String, String>> _buildLocalWords() {
    final localWords = <String, Map<String, String>>{};
    for (final w in _vocab.extendWords) {
      localWords[w.toLowerCase()] = {'original_case': w, 'category': '拓展词'};
    }
    for (final w in _vocab.manualChaoGangWords) {
      localWords[w.toLowerCase()] = {'original_case': w, 'category': '超标词'};
    }
    for (final w in _vocab.manualExtraWords) {
      localWords[w.toLowerCase()] = {'original_case': w, 'category': '专有词'};
    }
    return localWords;
  }

  Future<void> _syncVocab() async {
    if (_syncing) return; // 防止重复点击导致并发同步
    setState(() => _syncing = true);
    try {
      final result = await _wordSyncService.sync(
        localWords: _buildLocalWords(),
        localExtendBaseMap: _vocab.extendBaseMap,
        source: 'android',
      );

      final remoteChanges = result['remote_changes'] as List<dynamic>;

      if (remoteChanges.isNotEmpty && mounted) {
        final decisions = await _showSyncConflictDialog(remoteChanges);
        // 取消（null）无副作用，仅保存配置
        await _saveConfig();
        if (decisions != null && decisions.isNotEmpty) {
          final reasonMap = <String, String>{
            for (final ch in remoteChanges)
              (ch['word'] as String): (ch['reason'] as String? ?? ''),
          };
          // 删除保护（对齐 Windows 主流程）：统计将传播删除到云端的词（仅 remote_only）
          // 超过 10 个 → 确认；超过 50 个 → 先自动备份云端再确认；取消则无副作用。
          final willDelete = <String>{
            for (final d in decisions)
              if (d['action'] != 'accept' && reasonMap[d['word']!] == 'remote_only')
                d['word']!,
          };
          final delCount = willDelete.length;
          final remoteCount = result['remote_count'] as int? ?? 0;
          if (delCount > 10) {
            final backedUp = delCount > 50
                ? await _wordSyncService.backupRemoteState()
                : false;
            if (!mounted) return;
            final confirmed = await _confirmLargeDelete(
              context,
              delCount,
              remoteCount,
              backedUp,
            );
            if (!confirmed) return; // 用户取消：不执行任何删除，无副作用
          }
          // 执行逐词决策
          for (final d in decisions) {
            final word = d['word']!;
            final reason = reasonMap[word];
            if (d['action'] == 'accept') {
              if (reason == 'remote_deleted') {
                // 接收云端删除 → 本地也删除（reclassify 空分类即移除），并记录删除墓碑防止再上传
                _vocab.reclassifyWord(word, '');
                _wordSyncService.markDeleted(word);
              } else {
                final cat = d['category'] ?? '';
                if (cat.isNotEmpty) _vocab.reclassifyWord(word, cat);
                _wordSyncService.markChanged(word);
              }
            } else {
              // 拒绝/上传本地：云端新增词（remote_only）→ 记墓碑传播删除；
              // 分类更新（remote_newer）→ 保留本地分类/以本地为准恢复
              if (reason == 'remote_only') {
                _wordSyncService.markDeleted(word);
              } else {
                _wordSyncService.markChanged(word);
              }
            }
          }
          await _saveConfig();
          // 决策落地后立即再同步一次把结果推送云端，避免对端反复弹窗、本端"确认后未生效"
          await _wordSyncService.sync(
            localWords: _buildLocalWords(),
            localExtendBaseMap: _vocab.extendBaseMap,
            source: 'android',
          );
        }
      }

      final ebm = result['extendBaseMap'] as Map<String, dynamic>?;
      if (ebm != null) {
        for (final entry in ebm.entries) {
          if (!_vocab.extendBaseMap.containsKey(entry.key)) {
            _vocab.extendBaseMap[entry.key] = entry.value.toString();
          }
        }
      }

      await _saveConfig();
      if (mounted) {
        setState(() {});
        final msg = remoteChanges.isEmpty ? '同步完成 (已是最新)' : '同步完成 (已处理${remoteChanges.length}条云端变更)';
        showAppSnackBar(context, msg, type: AppSnackBarType.success);
        _maybePromptCorpusImport();
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '同步失败: $e', type: AppSnackBarType.error, duration: const Duration(seconds: 4));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 删除确认弹窗（同步主流程用）：将传播删除到云端的单词超过 10 个时提示确认，
  /// 超过 50 个时云端已自动备份全部词库。返回 true=确认执行，false=取消（无副作用）。
  Future<bool> _confirmLargeDelete(
    BuildContext context,
    int delCount,
    int total,
    bool backedUp,
  ) async {
    final backupMsg = delCount > 50
        ? (backedUp
            ? '已自动在云端备份全部词库。'
            : '警告：云端备份失败，请确认网络正常后再操作！')
        : '';
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: Text(
          '本次操作将删除 $delCount 个单词（词库当前共 $total 个）。\n\n$backupMsg\n\n确认要继续执行该删除操作吗？',
          textAlign: TextAlign.left,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  /// 同步冲突弹窗：逐词接收/拒绝/上传本地云端更新。
  /// 弹窗内不做任何二次确认（删除保护统一由 _syncVocab 主流程在弹窗关闭后处理，
  /// 避免弹窗内连续嵌套 showDialog 导致 Android 路由竞态卡死）。
  /// 取消无副作用（不写墓碑）。返回逐词决策列表（null=取消，空=无实际决策），
  /// 每项 {word, action('accept'/'reject'/'upload_local'), category}。
  Future<List<Map<String, String>>?> _showSyncConflictDialog(List<dynamic> changes) async {
    final accepted = <String, bool>{};
    // 默认全部接收（应用云端更新，不会删除本地词，安全）
    for (final ch in changes) {
      accepted[ch['word'] as String] = true;
    }

    int acceptCount() => accepted.values.where((v) => v).length;
    int rejectCount() => accepted.values.where((v) => !v).length;

    // 根据当前开关状态构造决策列表：接收→accepted==true 的词；拒绝/上传本地→accepted==false 的词
    List<Map<String, String>> buildDecisions(String action) {
      final result = <Map<String, String>>[];
      for (final ch in changes) {
        final c = ch as Map<String, dynamic>;
        final w = c['word'] as String;
        final isAccepted = accepted[w] ?? true;
        final match = (action == 'accept') ? isAccepted : !isAccepted;
        if (match) {
          result.add({
            'word': w,
            'action': action,
            'category': (action == 'accept' && c['new_category'] != null)
                ? (c['new_category'] as String)
                : '',
          });
        }
      }
      return result;
    }

    // 点击按钮后的二次确认弹窗：等待用户确认后再执行主操作，
    // 通过 await 串行化避免连续 showDialog 引发的路由竞态卡死
    Future<bool> confirmAction(String title, String message) async {
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      return ok ?? false;
    }

    final decisions = await showDialog<List<Map<String, String>>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Center(child: Text('云端词库有更新')),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: double.maxFinite,
                // 自适应高度：内容区最多占屏幕可用高度的 55%，超出部分由列表滚动承载，杜绝固定高度导致的底部截断
                maxHeight: MediaQuery.of(ctx).size.height * 0.55,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 全接收/全拒绝 快捷栏（带实时计数）
                  Row(
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () async {
                          final ok = await confirmAction('全部接收', '将全部应用云端更新，不删除本地词，确认执行？');
                          if (ok) {
                            setDialogState(() {
                              for (final ch in changes) {
                                accepted[ch['word'] as String] = true;
                              }
                            });
                          }
                        },
                        child: Text('全部接收（${acceptCount()}）', style: const TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () async {
                          final ok = await confirmAction('全部拒绝', '将全部拒绝云端更新，保留本地状态，确认执行？');
                          if (ok) {
                            setDialogState(() {
                              for (final ch in changes) {
                                accepted[ch['word'] as String] = false;
                              }
                            });
                          }
                        },
                        child: Text('全部拒绝（${rejectCount()}）', style: EswText.bodySmall),
                      ),
                    ],
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: changes.length,
                      itemBuilder: (_, i) {
                        final ch = changes[i] as Map<String, dynamic>;
                        final word = ch['word'] as String? ?? '';
                        final isAccepted = accepted[word] ?? true;
                        return SwitchListTile(
                          dense: true,
                          title: Text(word, style: const TextStyle(fontWeight: FontWeight.w500)),
                          subtitle: Text(
                            (ch['reason'] as String?) == 'remote_deleted'
                                ? '云端已删除'
                                : '${ch['old_category'] ?? '无'} → ${ch['new_category'] ?? ''}',
                            style: EswText.bodySmall,
                          ),
                          value: isAccepted,
                          onChanged: (v) {
                            accepted[word] = v;
                            setDialogState(() {});
                          },
                        );
                      },
                    ),
                  ),
                  // 底部按钮：左「接收更新」「拒绝更新」，右「取消」
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      runSpacing: 0,
                      children: [
                        TextButton(
                          onPressed: () async {
                            final ok = await confirmAction('接收更新', '将应用云端更新到本地，确认执行？');
                            if (ok && ctx.mounted) {
                              Navigator.pop(ctx, buildDecisions('accept'));
                            }
                          },
                          child: const Text('接收更新'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final ok = await confirmAction('拒绝更新', '将拒绝云端更新，保留本地状态，确认执行？');
                            if (ok && ctx.mounted) {
                              Navigator.pop(ctx, buildDecisions('reject'));
                            }
                          },
                          child: const Text('拒绝更新'),
                        ),
                        // 上传本地：自动将所选单词全部拒绝云端更新并直接上传本地，
                        // 无需用户先手动点「全部拒绝」再点「上传本地」（确认后执行，由主流程删除保护兜底）
                        TextButton(
                          onPressed: () async {
                            final ok = await confirmAction('上传本地', '将自动拒绝云端更新，把本地所选单词全部上传覆盖云端，确认执行？');
                            if (ok && ctx.mounted) {
                              // 一步到位：全部标记为拒绝云端更新（accepted=false），
                              // 随后 buildDecisions('upload_local') 即收集全部单词作为上传决策
                              setDialogState(() {
                                for (final ch in changes) {
                                  accepted[ch['word'] as String] = false;
                                }
                              });
                              Navigator.pop(ctx, buildDecisions('upload_local'));
                            }
                          },
                          child: const Text('上传本地'),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, null),
                          child: const Text('取消'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    return decisions;
  }

  Future<void> _checkUpdate(BuildContext context) async {
    try {
      final apiUrl = 'https://api.github.com/repos/beenhow/ESW/releases/latest';
      // 公开仓库 Releases API 无需鉴权（与 Windows 端一致）
      final resp = await http.get(
        Uri.parse(apiUrl),
        headers: const {'Accept': 'application/vnd.github.v3+json'},
      );
      if (resp.statusCode != 200) {
        if (context.mounted) {
          showAppSnackBar(context, '检查更新失败(${resp.statusCode})', type: AppSnackBarType.error);
        }
        return;
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final tagName = (json['tag_name'] as String?)?.replaceFirst('v', '') ?? '0.0.0';
      if (_compareVersions(tagName, '1.5.8') <= 0) {
        if (context.mounted) {
          showAppSnackBar(context, '已是最新版本', type: AppSnackBarType.success);
        }
        return;
      }
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现新版本'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('当前版本: V1.5.8'),
              Text('最新版本: $tagName'),
              const SizedBox(height: 12),
              const Text('请选择下载入口：'),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final uri = Uri.parse('https://github.com/beenhow/ESW/releases');
                      try {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      } catch (e) {
                        // 打开外部浏览器失败时静默处理
                      }
                    },
                    icon: const Text('</>'),
                    label: const Text('GitHub'),
                  ),
                  const SizedBox(width: 16),
                  TextButton.icon(
                    onPressed: () async {
                      final uri = Uri.parse('https://wwbcj.lanzouu.com/b02qeywze');
                      try {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      } catch (e) {
                        // 打开外部浏览器失败时静默处理
                      }
                    },
                    icon: const Icon(Icons.cloud_download, size: 18),
                    label: const Text('蓝奏云'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('(密码 52pj)', style: EswText.caption.copyWith(color: EswColors.textSecondary)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          ],
        ),
      );
    } catch (_) {
      if (context.mounted) {
        showAppSnackBar(context, '检查更新失败，请检查网络', type: AppSnackBarType.error);
      }
    }
  }

  int _compareVersions(String a, String b) {
    final ap = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final bp = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (int i = 0; i < ap.length || i < bp.length; i++) {
      final av = i < ap.length ? ap[i] : 0;
      final bv = i < bp.length ? bp[i] : 0;
      if (av != bv) return av - bv;
    }
    return 0;
  }

  /// 返回真题语料目录路径（应用文档目录下的 corpus 子目录）。
  Future<String> _corpusDirPath() async {
    final dir = await _appDocDir();
    return '$dir/corpus';
  }

  /// 统计 corpus 目录下已导入的真题 txt 文件数并刷新界面。
  Future<void> _refreshCorpusCount() async {
    int count = 0;
    try {
      final corpusPath = await _corpusDirPath();
      final dir = Directory(corpusPath);
      if (await dir.exists()) {
        count = await dir
            .list()
            .where((e) => e is File && e.path.toLowerCase().endsWith('.txt'))
            .length;
      }
    } catch (_) {}
    if (mounted) setState(() => _corpusFileCount = count);
  }

  /// 按年份统计真题语料中词库命中单词数与命中明细（年份从文件名 4 位前缀提取，
  /// 对齐高考例句年份提取逻辑），并按教材文件统计教材语料命中数与明细，
  /// 结果供检测页"已导入语料"年份框 / 教材格展示与点击展开。
  /// null 表示尚未完成 / 加载中；空 Map 表示无对应数据。
  Future<void> _refreshYearHitCounts() async {
    // 词库索引：{小写单词: {'pos': 词性, 'cat': 分类}}，供后台 isolate 查表，
    // 一次性带出单词 + 词性/分类明细。分类优先级：专有 > 超标 > 拓展 > 课标
    // （与词库页手动分类口径一致，后面的写入覆盖前面的）。
    final vocabInfo = <String, Map<String, String>>{};
    for (final entry in _vocab.standardWords.entries) {
      final cat = entry.value['category'] ?? '';
      vocabInfo[entry.key.toLowerCase()] = {
        'pos': entry.value['pos'] ?? '',
        'cat': cat.isEmpty ? '课标词' : cat,
      };
    }
    for (final w in _vocab.extendWords) {
      vocabInfo[w.toLowerCase()] = {'pos': '', 'cat': '拓展词'};
    }
    for (final w in _vocab.manualChaoGangWords) {
      vocabInfo[w.toLowerCase()] = {'pos': '', 'cat': '超标词'};
    }
    for (final w in _vocab.manualExtraWords) {
      vocabInfo[w.toLowerCase()] = {'pos': '', 'cat': '专有词'};
    }
    final corpusPath = await _corpusDirPath();
    final textbookPath = await _textbookDirPath();
    Map<int, int> yearCounts = const <int, int>{};
    Map<String, int> textbookCounts = const <String, int>{};
    Map<int, List<CorpusHitWord>> yearWords = const <int, List<CorpusHitWord>>{};
    Map<String, List<CorpusHitWord>> textbookWords =
        const <String, List<CorpusHitWord>>{};
    try {
      final results = await Future.wait([
        Isolate.run(
          () =>
              _scanYearHitCountsWorker({'dirPath': corpusPath, 'vocab': vocabInfo}),
        ),
        Isolate.run(
          () => _scanTextbookHitCountsWorker({
            'dirPath': textbookPath,
            'vocab': vocabInfo,
          }),
        ),
      ]);
      final yearRaw = results[0];
      final textbookRaw = results[1];
      yearCounts = yearRaw['counts'].cast<int, int>();
      textbookCounts = textbookRaw['counts'].cast<String, int>();
      yearWords = _decodeYearHitWords(yearRaw['words'] as Map);
      textbookWords = _decodeTextbookHitWords(textbookRaw['words'] as Map);
    } catch (_) {
      yearCounts = const <int, int>{};
      textbookCounts = const <String, int>{};
      yearWords = const <int, List<CorpusHitWord>>{};
      textbookWords = const <String, List<CorpusHitWord>>{};
    }
    if (!mounted) return;
    setState(() {
      _yearHitCounts = yearCounts;
      _textbookHitCounts = textbookCounts;
      _yearHitWords = yearWords;
      _textbookHitWords = textbookWords;
    });
  }

  /// 将 isolate 返回的年份命中明细（{年份: [{w,p,c}]}）还原为强类型列表。
  static Map<int, List<CorpusHitWord>> _decodeYearHitWords(Map raw) {
    final out = <int, List<CorpusHitWord>>{};
    raw.forEach((key, value) {
      out[key as int] = _decodeHitWordList(value as List);
    });
    return out;
  }

  /// 将 isolate 返回的教材命中明细（{教材名: [{w,p,c}]}）还原为强类型列表。
  static Map<String, List<CorpusHitWord>> _decodeTextbookHitWords(Map raw) {
    final out = <String, List<CorpusHitWord>>{};
    raw.forEach((key, value) {
      out[key as String] = _decodeHitWordList(value as List);
    });
    return out;
  }

  static List<CorpusHitWord> _decodeHitWordList(List raw) {
    return [
      for (final e in raw)
        CorpusHitWord(
          word: (e as Map)['w'] as String? ?? '',
          pos: e['p'] as String? ?? '',
          category: e['c'] as String? ?? '',
        ),
    ];
  }

  /// 返回教材语料目录路径（应用文档目录下的 textbook 子目录）。
  Future<String> _textbookDirPath() async {
    final dir = await _appDocDir();
    return '$dir/textbook';
  }

  /// 统计 textbook 目录下已导入的教材 txt 文件数并刷新界面。
  Future<void> _refreshTextbookCount() async {
    int count = 0;
    try {
      final tbPath = await _textbookDirPath();
      final dir = Directory(tbPath);
      if (await dir.exists()) {
        count = await dir
            .list()
            .where((e) => e is File && e.path.toLowerCase().endsWith('.txt'))
            .length;
      }
    } catch (_) {}
    if (mounted) setState(() => _textbookFileCount = count);
  }

  static String jsonEncode(Map<String, dynamic> data) {
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  static dynamic jsonDecode(String s) {
    return const JsonDecoder().convert(s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EswColors.page,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildSearchTab(),
          _buildImportTab(),
          _buildVocabTab(),
        ],
      ),
      bottomNavigationBar: EswBottomNav(
        currentIndex: _currentIndex,
        onChanged: (i) => setState(() => _currentIndex = i),
        labels: const ['查词', '检测', '词库'],
        icons: const [
          Icons.search_rounded,
          Icons.description_outlined,
          Icons.bookmark_border_rounded,
        ],
        selectedIcons: const [
          Icons.search_rounded,
          Icons.description_outlined,
          Icons.bookmark_border_rounded,
        ],
      ),
    );
  }

  // ====== Tab 1: 词库概览 ======
  Widget _buildVocabTab() {
    return WordBankPage(
      vocab: _vocab,
      onSaveConfig: _saveConfig,
      showBaseWordDialog: _showBaseWordDialog,
      onSyncVocab: _syncVocab,
      onCheckUpdate: () => _checkUpdate(context),
      onImportCorpus: _importCorpus,
      onImportTextbook: _importTextbook,
      syncing: _syncing,
      wordSyncService: _wordSyncService,
      onWordTap: (word) {
        setState(() => _currentIndex = 0);
        _searchCtrl.text = word;
        _lookupWord(word);
      },
    );
  }

  // ====== Tab 2: 文本检测 ======
  Widget _buildImportTab() {
    return DetectPage(
      corpusCount: _corpusFileCount < 0 ? null : _corpusFileCount,
      textbookCount: _textbookFileCount < 0 ? null : _textbookFileCount,
      yearHits: _yearHitCounts,
      textbookHits: _textbookHitCounts,
      yearHitWords: _yearHitWords,
      textbookHitWords: _textbookHitWords,
      categoryCounts: [
        _vocab.standardWords.length,
        _vocab.extendWords.length,
        _vocab.manualChaoGangWords.length,
        _vocab.manualExtraWords.length,
      ],
      onImportCorpus: _importCorpus,
      onImportTextbook: _importTextbook,
      onImportFile: _importFile,
      pasteController: _pasteCtrl,
      pasteFocus: _pasteFocus,
      onAnalyze: (text) {
        final t = text.trim();
        if (t.isEmpty) {
          showAppSnackBar(context, '请先粘贴文本', type: AppSnackBarType.info);
          return;
        }
        _showAnalysisResult(t, '粘贴文本');
      },
      history: _detectHistory.map((h) {
        final summary = h.categoryCounts.entries
            .where((e) => e.value > 0)
            .map((e) => '${e.key}${e.value}')
            .join(' / ');
        final annotatedPart = h.annotatedCount > 0 ? ' · 标注词${h.annotatedCount}' : '';
        return DetectHistoryItem(
          fileName: h.fileName,
          subtitle:
              '${_formatTime(h.time)} · ${h.totalWords}词${summary.isNotEmpty ? ' · $summary' : ''}$annotatedPart',
          onTap: () async {
            final src = h.sourcePath;
            if (src == null || src.isEmpty) {
              showAppSnackBar(context, '该历史项未保留原文（粘贴/已清理），请重新导入原文件检测', type: AppSnackBarType.info);
              return;
            }
            try {
              // P6：历史不存全文，重看时按源路径在后台 isolate 内重新提取
              // 先提取纯数据再进闭包，避免捕获整个 _DetectHistory（自定义类不可发送）
              final name = h.fileName;
              final content = await Isolate.run(
                () => _extractImportContentFromPathWorker(
                    {'path': src, 'name': name}),
              );
              if (content.trim().isEmpty) {
                if (!mounted) return;
                showAppSnackBar(context, '原文件内容为空或不可读，请重新导入', type: AppSnackBarType.error);
                return;
              }
              _showAnalysisResult(content, h.fileName, sourcePath: src);
            } catch (e) {
              if (!mounted) return;
              showAppSnackBar(context, '重看失败（原文件可能已移动或删除）：$e', type: AppSnackBarType.error);
            }
          },
        );
      }).toList(),
      onClearHistory: () {
        setState(() => _detectHistory.clear());
      },
    );
  }

  String _formatTime(DateTime t) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${pad(t.month)}-${pad(t.day)} ${pad(t.hour)}:${pad(t.minute)}';
  }

  /// 按路径读取 PDF 并提取纯文本（Android 端 PDF 解析，主 isolate 执行）。
  /// pdfrx 的文本层提取不依赖渲染引擎，仅需 PdfDocument.openData + loadText。
  Future<String> _readPdfFileByPath(String path) async {
    final bytes = await File(path).readAsBytes();
    return _readPdfContentAndroid(bytes);
  }

  /// 从 PDF bytes 中提取纯文本（Android 端无 OCR 引擎，纯文本层提取）。
  Future<String> _readPdfContentAndroid(List<int> raw) async {
    final document =
        await PdfDocument.openData(Uint8List.fromList(raw));
    try {
      final buffer = StringBuffer();
      bool hasText = false;
      for (int i = 0; i < document.pages.length; i++) {
        final pageText = await document.pages[i].loadText();
        final text = pageText.fullText;
        if (text.isNotEmpty) {
          buffer.writeln(text);
          hasText = true;
        }
      }
      return hasText ? buffer.toString().trim() : '';
    } finally {
      document.dispose();
    }
  }

  /// 真题导入：多选 txt/doc/docx，转存为 corpus 子目录同名 .txt，
  /// 并删除 corpus_index.json 触发索引重建。词频统计与例句提取自动基于导入语料。
  Future<void> _importCorpus() async {
    // P4：Android 端不再 withData（整文件随选带回会载入 UI 堆），
    // 仅取 file.path，解析在后台 worker 内按路径读取。
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择真题文件',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['txt', 'doc', 'docx', 'pdf'],
    );
    if (result == null || result.files.isEmpty) return;

    final corpusDir = Directory(await _corpusDirPath());
    if (!await corpusDir.exists()) {
      await corpusDir.create(recursive: true);
    }

    int success = 0;
    final failed = <String>[];
    for (final f in result.files) {
      try {
        // P4：文件字节在 worker 内按 path 读取并解析，不整文件载入 UI 堆
        if (f.path == null) throw Exception('无法读取文件内容');
        // 先提取纯数据再进闭包，避免捕获整个 PlatformFile（含 XFile 等不可发送字段）
        final p = f.path;
        final n = f.name;
        // PDF 依赖 pdfrx（native + async），在主 isolate 解析；其余格式走后台 isolate worker
        final content = n.toLowerCase().endsWith('.pdf')
            ? await _readPdfFileByPath(p!)
            : await Isolate.run(
                () => _extractImportContentFromPathWorker({'path': p, 'name': n}),
              );
        if (content.trim().isEmpty) {
          failed.add('${f.name}（内容为空）');
          continue;
        }
        // 保留原名去扩展名，如 2023全国卷I.docx → 2023全国卷I.txt
        final dotIdx = f.name.lastIndexOf('.');
        final baseName = dotIdx > 0 ? f.name.substring(0, dotIdx) : f.name;
        final out = File('${corpusDir.path}/$baseName.txt');
        await out.writeAsString(content);
        success++;
      } catch (e) {
        failed.add('${f.name}（$e）');
      }
    }

    // 触发索引重建：删除旧 corpus_index.json 并清空内存缓存
    try {
      final indexFile = File('${corpusDir.path}/corpus_index.json');
      if (await indexFile.exists()) await indexFile.delete();
    } catch (_) {}

    await _refreshCorpusCount();
    // 语料变更后重新统计年份命中单词数（后台，不阻塞提示条）
    _refreshYearHitCounts();
    if (!mounted) return;
    showAppSnackBar(context, success > 0 ? '成功导入 $success 个真题文件' : '导入失败，请检查文件格式：${failed.join('；')}', type: AppSnackBarType.info);
    if (failed.isNotEmpty) {
      showAppSnackBar(context, '以下文件导入失败：${failed.join('；')}', type: AppSnackBarType.error);
    }
    setState(() {});
  }

  /// 教材导入：多选 txt/doc/docx，转存为 textbook 子目录同名 .txt，
  /// 作为教材例句源参与检测与导出（对齐 Windows 版教材导入逻辑）。
  Future<void> _importTextbook() async {
    // P4：同 _importCorpus，仅取 path，解析在 worker 内按路径读取。
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择教材文件',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['txt', 'doc', 'docx', 'pdf'],
    );
    if (result == null || result.files.isEmpty) return;

    final tbDir = Directory(await _textbookDirPath());
    if (!await tbDir.exists()) {
      await tbDir.create(recursive: true);
    }

    int success = 0;
    final failed = <String>[];
    for (final f in result.files) {
      try {
        // P4：文件字节在 worker 内按 path 读取并解析，不整文件载入 UI 堆
        if (f.path == null) throw Exception('无法读取文件内容');
        // 先提取纯数据再进闭包，避免捕获整个 PlatformFile（含 XFile 等不可发送字段）
        final p = f.path;
        final n = f.name;
        // PDF 依赖 pdfrx（native + async），在主 isolate 解析；其余格式走后台 isolate worker
        final content = n.toLowerCase().endsWith('.pdf')
            ? await _readPdfFileByPath(p!)
            : await Isolate.run(
                () => _extractImportContentFromPathWorker({'path': p, 'name': n}),
              );
        if (content.trim().isEmpty) {
          failed.add('${f.name}（内容为空）');
          continue;
        }
        // 保留原名去扩展名，如 人教版必修一.docx → 人教版必修一.txt
        final dotIdx = f.name.lastIndexOf('.');
        final baseName = dotIdx > 0 ? f.name.substring(0, dotIdx) : f.name;
        final out = File('${tbDir.path}/$baseName.txt');
        await out.writeAsString(content);
        success++;
      } catch (e) {
        failed.add('${f.name}（$e）');
      }
    }

    await _refreshTextbookCount();
    // 教材语料变更后重新统计教材与真题命中单词数（后台，不阻塞提示条）
    _refreshYearHitCounts();
    if (!mounted) return;
    showAppSnackBar(context, success > 0 ? '成功导入 $success 个教材文件' : '导入失败，请检查文件格式：${failed.join('；')}', type: AppSnackBarType.info);
    if (failed.isNotEmpty) {
      showAppSnackBar(context, '以下教材文件导入失败：${failed.join('；')}', type: AppSnackBarType.error);
    }
    setState(() {});
  }

  Future<void> _importFile() async {
    // P4：同导入流程，仅取 path，字节在 worker 内读取。
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'doc', 'docx', 'pdf'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    String content;

    try {
      final filePath = file.path;
      if (filePath == null) throw Exception('无法读取文件内容');
      // 仅取文件大小用于估算/预检，不读取全量字节到 UI 堆
      final rawLen = await File(filePath).length();

      // 大文件检测前弹窗：按字节量估算文本提取 + 分析的等待时长，避免"无提示卡住"
      final estSec = _estimateDetectSeconds(rawLen, file.name);
      final estText =
          estSec >= 60 ? '约 ${(estSec ~/ 60).toString()} 分钟' : '约 $estSec 秒';

      // 内存能力预检：估算提取字符量并对照「页数/字符 → 内存」模型，
      // 超出本机安全上限时先弹窗提示可处理页数上限，避免检测中 OOM 闪退无结果。
      final estChars = _estimateCharsOf(rawLen, file.name);
      final maxChars = _maxCapableChars();
      final overCapable = estChars > maxChars;
      if (overCapable) {
        final maxPages = (maxChars / 1800).floor(); // 按每页约 1800 字符换算
        final curPages = (estChars / 1800).ceil();
        if (mounted) {
          final goCap = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('文档超出本机处理能力'),
              content: Text(
                '本机最大可处理约 $maxPages 页（约 ${(maxChars / 10000).round()} 万字符），'
                '当前文档约 $curPages 页（约 ${(estChars / 10000).round()} 万字符），'
                '继续检测可能因内存不足闪退且无结果。\n\n'
                '建议：拆分文档（如按年份/单元拆分）或压缩后重试。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('仍然尝试'),
                ),
              ],
            ),
          );
          if (goCap != true) return;
        }
      }

      if (mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('检测大文件'),
            content: Text(
              rawLen >= 200 * 1024
                  ? '该文件较大（${(rawLen / 1024 / 1024).toStringAsFixed(1)} MB），检测需要处理完整文档内容，预计$estText。处理期间界面会保持响应，请耐心等待，不要重复点击。'
                  : '检测该文件预计需要$estText，是否继续？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('继续检测'),
              ),
            ],
          ),
        );
        if (go != true) return;
      }

      // 提取阶段进度提示框（不 await，提取完成后统一关闭）
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          content: const Row(
            children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 16),
              Expanded(child: Text('正在提取文档文本…', style: TextStyle(fontSize: 14))),
            ],
          ),
        ),
      );
      // 先提取纯数据再进闭包，避免捕获整个 PlatformFile（含 XFile 等不可发送字段）
      final p = filePath;
      final n = file.name;
      // PDF 依赖 pdfrx（native + async），在主 isolate 解析；其余格式走后台 isolate worker
      content = n.toLowerCase().endsWith('.pdf')
          ? await _readPdfFileByPath(p)
          : await Isolate.run(
              () => _extractImportContentFromPathWorker({'path': p, 'name': n}),
            );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        showAppSnackBar(context, "文件读取失败: $e", type: AppSnackBarType.error);
      }
      return;
    }

    // 导入文档前：若未同步筛选词库（extendBaseMap 为空），提醒先同步词库，确保拓展词能映射到课标词
    if (mounted && _vocab.extendBaseMap.isEmpty) {
      final goSync = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('词库未同步'),
          content: const Text('当前未检测到已同步的筛选词库，导入文档后拓展词将无法映射到课标词，导出结果可能不完整。建议先「同步词库」再导入检测。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('仍然导入'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去同步'),
            ),
          ],
        ),
      );
      if (goSync == true) {
        await _syncVocab();
        return;
      }
    }

    if (mounted) {
      _showAnalysisResult(content, file.name, sourcePath: file.path);
    }
  }

  /// 估算单文件检测总耗时（秒）：文本提取 + 分析。
  /// 提取：按源字节量估算（大 .doc/.docx 提取较慢，留余量）；
  /// 分析：按预估提取字符量估算（约每 20 万字符 1 秒，保守系数 2）。
  int _estimateDetectSeconds(int rawBytes, String name) {
    final ext = name.toLowerCase();
    final extractPerMbSec =
        (ext.endsWith('.doc') || ext.endsWith('.docx')) ? 8.0 : 2.0;
    final mb = rawBytes / 1024 / 1024;
    final extractSec = mb * extractPerMbSec;
    // 提取文本量估算：docx/doc 压缩比约 0.5，txt 按 1.0
    final estimatedChars = rawBytes * (ext.endsWith('.txt') ? 1.0 : 0.5);
    final analyzeSec = (estimatedChars / 200000) * 2.0;
    return (extractSec + analyzeSec).ceil().clamp(1, 1800);
  }

  /// 预估提取文本量（字符）：doc/docx 按字节压缩比 0.35（实测样例
  /// 3589632 字节 → 806138 字符，压缩比约 0.22，留安全裕量取 0.35），
  /// txt 按 1.0。
  int _estimateCharsOf(int rawBytes, String name) {
    final ext = name.toLowerCase();
    final ratio = ext.endsWith('.txt') ? 1.0 : 0.35;
    return (rawBytes * ratio).round();
  }

  /// 本机安全堆可承载的最大检测字符量（页数/字符 → 内存模型）。
  ///
  /// 定量依据（Dart VM 实测，Windows 上对《全国高考英语试题2017-2021.doc》
  /// 806138 字符逐阶段 RSS 增量）：doc 提取 ~11.5 B/字符、分析 ~1~4 B/字符、
  /// 标注全文 ~2.4 B/字符、导出明细构建 ~9.8 B/字符、单真题语料索引 ~2.3 B/字符。
  /// Android 侧还需叠加：后台 isolate 传输副本（文本/词表双份）、Flutter 引擎
  /// 常驻（约 60~90MB）、页面/词库常驻与 heap 碎片，按实测闪退样本
  /// （806K 字符在 192MB 级堆闪退）反标定全链路约 124 B/字符（安全系数 ≥2）。
  ///
  /// 上限取「AndroidManifest 已开启 largeHeap → 512MB 级堆的 45% 可用」；
  /// 未生效设备按 192MB 级堆的 40% 兜底。返回字符数。
  int _maxCapableChars() {
    const bpc = 124; // 全链路每字符峰值内存（字节）
    const largeHeapBytes = 512 * 1024 * 1024;
    const normalHeapBytes = 192 * 1024 * 1024;
    final safeBytes = (largeHeapBytes * 45 ~/ 100) > (normalHeapBytes * 40 ~/ 100)
        ? largeHeapBytes * 45 ~/ 100
        : normalHeapBytes * 40 ~/ 100;
    return safeBytes ~/ bpc;
  }

  Future<void> _showAnalysisResult(
    String text,
    String fileName, {
    String? sourcePath,
  }) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
      builder: (_) => _AnalysisPage(
        text: text,
        fileName: fileName,
        sourcePath: sourcePath,
        vocab: _vocab,
        onSaveConfig: _saveConfig,
        wordSyncService: _wordSyncService,
        userId: _userId,
        onWordTap: (word) {
          setState(() => _currentIndex = 0);
          _searchCtrl.text = word;
          _lookupWord(word);
        },
      ),
    ));
    // 返回后清空输入框
    _pasteCtrl.clear();
    if (result != null && mounted) {
      setState(() {
        _detectHistory.insert(0, _DetectHistory(
          fileName: result['fileName'] as String,
          time: DateTime.now(),
          totalWords: result['totalWords'] as int,
          categoryCounts: Map<String, int>.from(result['categoryCounts'] as Map),
          sourcePath: result['sourcePath'] as String?,
          annotatedCount: result['annotatedCount'] as int? ?? 0,
        ));
        // 限制历史条数，避免大文本全文驻留导致内存累积 OOM
        if (_detectHistory.length > 8) {
          _detectHistory.removeRange(8, _detectHistory.length);
        }
      });
    }
  }

  // ====== Tab 3: 查词 ======
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  final TextEditingController _pasteCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _pasteFocus = FocusNode();
  String _searchResult = '';
  String _query = '';
  Map<String, String?>? _wordInfo;
  String _wordCategory = '';
  String? _wordFormDesc;
  Map<String, dynamic>? _lastFreqData;

  Widget _buildSearchTab() {
    return PopScope(
      canPop: _searchResult.isEmpty && _query.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _searchResult = '';
          _query = '';
          _wordInfo = null;
          _searchCtrl.clear();
        });
      },
      child: SearchPage(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        onChanged: _onSearchChanged,
        onSubmitted: (w) {
          _searchDebounce?.cancel();
          _lookupWord(w);
        },
        resultVisible: _searchResult.isNotEmpty,
        resultBuilder: (_) => _buildWordResult(),
        history: _vocab.wordHistory,
        subtitleOf: _historySubtitle,
        onClearHistory: () {
          setState(() {
            _vocab.wordHistory.clear();
            _saveConfig();
          });
        },
        onHistoryTap: (w) {
          _searchCtrl.text = w;
          _query = w;
          _lookupWord(w);
        },
      ),
    );
  }

  /// 历史词副标题：词义 + 词性（取自离线词典，异步）。无数据时给兜底文案。
  Future<String> _historySubtitle(String word) async {
    final info = _vocab.lookup(word);
    final def = info['def']?.trim() ?? '';
    final pos = info['pos']?.trim() ?? '';
    final parts = <String>[];
    if (def.isNotEmpty) {
      parts.add(def.split('\n').first.trim());
    }
    if (pos.isNotEmpty) {
      parts.add(pos.split(RegExp(r'\s*/\s*')).first.trim());
    }
    if (parts.isEmpty) {
      final manualCat = _currentManualCategory(word.toLowerCase());
      if (manualCat != null) {
        parts.add(manualCat);
      } else {
        parts.add('点击查看词义与真题出处');
      }
    }
    return parts.join(' · ');
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) return;
    _searchDebounce = Timer(const Duration(seconds: 1), () {
      _lookupWord(value.trim());
    });
  }

  void _lookupWord(String word) {
    if (word.isEmpty) return;
    final info = _vocab.lookup(word);
    String cat;
    if (_vocab.isExtend(word)) {
      cat = '拓展词';
    } else if (_vocab.isChaoGang(word)) {
      cat = '超标词';
    } else if (_vocab.isExtra(word)) {
      cat = '专有词';
    } else if (info.isNotEmpty) {
      cat = info['category'] ?? '课标词';
    } else {
      cat = '未收录';
    }

    _vocab.addHistory(word);
    _saveConfig();
    setState(() {
      _searchResult = word;
      _query = word;
      _wordInfo = info.isNotEmpty ? info : null;
      _wordCategory = cat;
      _wordFormDesc = null;
    });

    // 拓展词词形说明
    if (_vocab.isExtend(word)) {
      final base = _vocab.extendBaseMap[word.toLowerCase()] ?? _vocab.extendBaseMap[word];
      if (base != null && base.isNotEmpty) {
        final formDesc = _describeForm(word, base);
        _wordFormDesc = '$base 的$formDesc';
      }
    }

    // 统一用离线词典数据（含课标词）：异步查询覆盖 pos/def/phonetic/collins
    final isStd = info.isNotEmpty;
    final savedCat = isStd ? (info['category'] ?? '课标词') : null;
    DictionaryService.lookup(word).then((entry) {
      if (!mounted || _searchResult != word) return;
      if (entry != null) {
        final dictDef = entry['definition'] ?? '';
        final dictPos = entry['pos'] ?? '';
        if (dictDef.isNotEmpty || dictPos.isNotEmpty) {
          setState(() {
            _wordInfo = {
              'def': dictDef,
              'pos': dictPos,
              'zh_def': dictDef,
              'category': isStd ? savedCat! : (_vocab.isExtend(word) ? '拓展词' : '词典'),
              'phonetic': entry['phonetic'] ?? '',
              'collins': entry['collins'] ?? '0',
            };
          });
        }
      } else if (!isStd && mounted) {
        final inferredPos = _inferPos(word);
        setState(() {
          _wordInfo = {
            'def': '',
            'pos': inferredPos,
            'zh_def': '',
            'category': _vocab.isExtend(word) ? '拓展词' : '未收录',
            'phonetic': '',
            'collins': '0',
          };
        });
      }
    });
  }

  /// 弹出关联课标词对话框，用户选择基础课标词后添加为拓展词。
  /// [onAdded] 在添加完成后（无论是否关联）回调。
  Future<void> _showBaseWordDialog(String word, VoidCallback onAdded) async {
    final controller = TextEditingController();
    final allStandard = _vocab.standardWordsLowerKeySet.toList();
    List<String> matches = _getBaseWordCandidates(word, allStandard);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('拓展词原词'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        hintText: '搜索课标词',
                        prefixIcon: Icon(Icons.search, size: 20),
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onChanged: (q) {
                        final lower = q.trim().toLowerCase();
                        setDialogState(() {
                          if (lower.isEmpty) {
                            matches = _getBaseWordCandidates(word, allStandard);
                          } else {
                            matches = _getBaseWordCandidates(lower, allStandard);
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (_, i) {
                          final w = matches[i];
                          return InkWell(
                            onTap: () {
                              _vocab.addExtendWord(word, baseWord: w);
                              Navigator.of(dialogContext).pop();
                              onAdded();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Text(w, style: const TextStyle(fontSize: 16)),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 基于英语单词后缀推断词性标签（n./v./adj./adv.），无法推断则返回空字符串。
  String _inferPos(String word) {
    final w = word.toLowerCase();
    if (RegExp(r'(tion|sion|ment|ness|ity|ance|ence|ism|ship|hood|ure|dom|th|tude)$').hasMatch(w) && w.length > 4) {
      return 'n.';
    }
    if (RegExp(r'(ive|able|ible|ial|ous|eous|ious|ful|less|ish|ant|ent|ary|ory|ic|al)$').hasMatch(w) && w.length > 4) {
      if (w.endsWith('ly') && w.length > 4) return 'adv.';
      return 'adj.';
    }
    if (w.endsWith('ly') && w.length > 4) {
      return 'adv.';
    }
    if (RegExp(r'(ize|ise|ate|ify|en)$').hasMatch(w) && w.length > 4) {
      return 'v.';
    }
    return '';
  }

  Widget _buildWordResult() {
    final canMark = !_vocab.isStandard(_searchResult);
    final isStandard = _vocab.isStandard(_searchResult);
    final categoryColor = _categoryColor(_wordCategory);

    // 统一计算分类标签与配色
    String? categoryLabel;
    Color labelColor = categoryColor;
    if (isStandard) {
      // 课标词分类标签统一加“课标词”后缀，用包含判断覆盖所有分类值
      final cat = _wordCategory;
      if (cat.contains('必修')) {
        categoryLabel = '必修课标词';
      } else if (cat.contains('初中')) {
        categoryLabel = '初中课标词';
      } else if (cat.contains('选修')) {
        categoryLabel = '选修课标词';
      } else if (cat.contains('高中')) {
        categoryLabel = '高中课标词';
      } else if (cat.contains('课标词')) {
        categoryLabel = '课标词';
      } else if (cat.isNotEmpty && cat != '未收录') {
        categoryLabel = '$cat课标词';
      } else {
        categoryLabel = null;
      }
      labelColor = categoryColor;
    } else {
      // 手动分类统一走大小写不敏感判断（与词库页/检测页一致），
      // 保证词库页已分类的单词在查词页能同步显示分类标签。
      final manualCat = _currentManualCategory(_searchResult.toLowerCase());
      if (manualCat == '拓展词') {
        categoryLabel = '拓展词';
        labelColor = AppTheme.green;
      } else if (manualCat == '超标词') {
        categoryLabel = '超标词';
        labelColor = AppTheme.red;
      } else if (manualCat == '专有词') {
        categoryLabel = '专有词';
        labelColor = AppTheme.grey;
      }
    }

    // 解析词性+释义（按 / 拆分为多行）
    final posDefPairs = _parsePosDef(_wordInfo?['pos'] ?? '');
    final phonetic = _wordInfo?['phonetic'] ?? '';
    final collins = int.tryParse(_wordInfo?['collins'] ?? '0') ?? 0;

    return Card(
      elevation: 0,
      color: AppTheme.surfaceLight,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusLg)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 分类标签 — 音标正上方，居中，长方形框，加粗
            if (categoryLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: labelColor, width: 1.5),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Text(
                    categoryLabel,
                    style: TextStyle(fontSize: 13, color: labelColor, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            if (phonetic.isNotEmpty || collins > 0)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (phonetic.isNotEmpty)
                    Text(
                      '[$phonetic]',
                      style: const TextStyle(fontSize: 15, fontFamily: 'monospace', color: AppTheme.primaryBlue),
                    ),
                  if (phonetic.isNotEmpty && collins > 0)
                    const Text(' - ', style: TextStyle(fontSize: 15)),
                  if (collins > 0) _buildCollinsStars(collins),
                ],
              ),
            if (phonetic.isNotEmpty || collins > 0) const SizedBox(height: 10),
            // 单词居中展示（修改入口移至例句单词点击，见真题查看器）
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
            Text(
              _searchResult,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: AppTheme.red,
              ),
              ),
              ],
            ),
            const SizedBox(height: 8),
            if (posDefPairs.isNotEmpty)
              ...posDefPairs.map((p) => Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: const TextStyle(fontSize: 15, color: Colors.black),
                        children: [
                          TextSpan(
                            text: '${p['pos']!} ',
                            style: const TextStyle(
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.primaryBlue,
                            ),
                          ),
                          TextSpan(text: p['def']),
                        ],
                      ),
                    ),
                  )),
            // 兜底释义
            if (posDefPairs.isEmpty || posDefPairs.every((p) => (p['def'] ?? '').isEmpty))
              Builder(builder: (_) {
                final fallback = _wordInfo?['def'] ?? '';
                if (fallback.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    fallback,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, color: Colors.black),
                  ),
                );
              }),
            // 词形说明
            if (_wordFormDesc != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _wordFormDesc!,
                  style: const TextStyle(fontSize: 13, color: AppTheme.teal),
                  textAlign: TextAlign.center,
                ),
              ),
            // 三个添加按钮
            if (canMark)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _markButton('+ 拓展词', AppTheme.green, () => _handleReclassify('拓展词')),
                    const SizedBox(width: 12),
                    _markButton('+ 超标词', AppTheme.red, () => _handleReclassify('超标词')),
                    const SizedBox(width: 12),
                    _markButton('+ 专有词', AppTheme.grey, () => _handleReclassify('专有词')),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            _buildWordFrequency(),
          ],
        ),
      ),
    );
  }

  /// 解析 pos 字段（格式: "vt. 释义 / vi. 释义"），返回 [{pos, def}] 列表
  List<Map<String, String?>> _parsePosDef(String raw) {
    if (raw.isEmpty) return [];
    final parts = raw.split(RegExp(r'\s*/\s*'));
    final results = <Map<String, String?>>[];
    for (final part in parts) {
      final match = RegExp(r'^([a-z]+\.(?:\s*&\s*[a-z]+\.)?)\s*(.*)$').firstMatch(part.trim());
      if (match != null) {
        results.add({'pos': match.group(1), 'def': match.group(2)});
      }
    }
    return results;
  }

  /// （0~5，
  Widget _buildCollinsStars(int stars) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Icon(
        i < stars ? Icons.star : Icons.star_border,
        size: 14,
        color: AppTheme.primaryYellow,
      )),
    );
  }

  /// 紧凑标记按钮
  Widget _markButton(String label, Color color, VoidCallback onPressed) {
    final isCurrent = _currentManualCategory(_searchResult.toLowerCase()) == label;
    return OutlinedButton(
      onPressed: isCurrent ? null : onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: isCurrent ? Colors.grey : color,
        side: BorderSide(color: isCurrent ? Colors.grey.shade300 : color),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  /// 判断单词当前的手动分类（拓展词/超标词/专有词），无则返回 null。
  String? _currentManualCategory(String lower) {
    if (_vocab.extendWords.any((e) => e.toLowerCase() == lower)) return '拓展词';
    if (_vocab.manualChaoGangWords.any((e) => e.toLowerCase() == lower)) return '超标词';
    if (_vocab.manualExtraWords.any((e) => e.toLowerCase() == lower)) return '专有词';
    return null;
  }

  /// 处理重新归类：若单词已有手动分类且不同于目标，弹出确认对话框。
  Future<void> _handleReclassify(String targetCategory) async {
    final lower = _searchResult.toLowerCase();
    final currentCat = _currentManualCategory(lower);

    if (currentCat != null && currentCat != targetCategory) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重新归类确认'),
          content: Text('「$_searchResult」已归类为「$currentCat」\n\n确定要改为「$targetCategory」吗？\n后续检测将按新归类执行。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认更改')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    // 拓展词需要关联基础课标词
    if (targetCategory == '拓展词') {
      _showBaseWordDialog(_searchResult, () {
        _vocab.reclassifyWord(_searchResult, '拓展词');
        _wordSyncService.markChanged(_searchResult);
        _saveConfig();
        if (mounted) setState(() => _wordCategory = '拓展词');
      });
    } else {
      _vocab.reclassifyWord(_searchResult, targetCategory);
      _wordSyncService.markChanged(_searchResult);
      _saveConfig();
      if (mounted) {
        setState(() => _wordCategory = targetCategory);
        showAppSnackBar(context, '已重新归类为：$targetCategory', type: AppSnackBarType.success);
      }
    }
  }


  /// 真题词频区域：从 corpus 目录统计当前查询单词的出现次数与逐年分布。
  Widget _buildWordFrequency() {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _corpusDirPath().then((p) => _vocab.getWordFrequency(_searchResult, p)),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SizedBox.shrink();

        final data = snap.data;
        if (data == null || (data['total'] as int) == 0) {
          return const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Center(
              child: Text(
                '本单词从未在高考真题中出现过',
                style: TextStyle(fontSize: 12, color: AppTheme.textHint),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        _lastFreqData = data;
        final total = data['total'] as int;

        final byYear = data['byYear'] as Map<String, dynamic>;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bar_chart, size: 18, color: AppTheme.primaryBlue),
                const SizedBox(width: 6),
                Text('真题词频', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  ),
                  child: Text('共 $total 次', style: const TextStyle(fontSize: 12, color: AppTheme.primaryBlue, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...(byYear.entries.toList()..sort((a, b) => b.key.compareTo(a.key))).map((e) {
              final year = e.key;
              final sentences = (e.value as List).cast<Map<String, dynamic>>();
              return ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('$year: ${sentences.length} 次', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                children: sentences.map((s) {
                  final text = s['text'] as String? ?? '';
                  final filePath = s['filePath'] as String? ?? '';
                  final offset = ((s['offset'] as num?) ?? 0).toInt();
                  return InkWell(
                    onTap: filePath.isNotEmpty
                        ? () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                              builder: (_) => _ExamPaperViewer(
                                filePath: filePath,
                                keyword: _searchResult,
                                offset: offset,
                                onLookupWord: (w) {
                                  setState(() => _currentIndex = 0);
                                  _searchCtrl.text = w;
                                  _lookupWord(w);
                                },
                              ),
                            ))
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('•', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          Expanded(child: _highlightSentence(text, _searchResult)),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            }),
          ],
        );
      },
    );
  }

  /// 将句子中匹配 [word] 的部分用黄色背景 + 加粗高亮显示，关键词可长按弹出菜单。
  Widget _highlightSentence(String sentence, String word) {
    if (word.isEmpty) {
      return Text(sentence, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary));
    }
    final regex = RegExp(r'\b' + RegExp.escape(word) + r'\b', caseSensitive: false);
    final matches = regex.allMatches(sentence).toList();
    if (matches.isEmpty) {
      return Text(sentence, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary));
    }

    final spans = <TextSpan>[];
    int lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: sentence.substring(lastEnd, m.start)));
      }
      final kw = sentence.substring(m.start, m.end);
      spans.add(TextSpan(
        text: kw,
        style: TextStyle(
          backgroundColor: Colors.yellow.withValues(alpha: 0.4),
          fontWeight: FontWeight.bold,
          color: Colors.red.shade700,
        ),
        recognizer: LongPressGestureRecognizer()
          ..onLongPress = () {
            _showWordMenu(context, kw, sentence);
          },
      ));
      lastEnd = m.end;
    }
    if (lastEnd < sentence.length) {
      spans.add(TextSpan(text: sentence.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        children: spans,
      ),
    );
  }

  /// 长按关键词弹出的菜单：复制 / 全选 / 打开真题。
  void _showWordMenu(BuildContext context, String word, String sentence) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: word));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.select_all),
              title: const Text('全部'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: sentence));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: const Text('打开真题'),
              onTap: () {
                Navigator.pop(ctx);
                // 在当前词频结果中查找匹配该关键词的真题条目并跳转
                final data = _lastFreqData;
                if (data != null) {
                  final byYear = data['byYear'] as Map<String, dynamic>? ?? {};
                  for (final entry in byYear.entries) {
                    final sentences = (entry.value as List).cast<Map<String, dynamic>>();
                    for (final s in sentences) {
                      final text = s['text'] as String? ?? '';
                      if (text.toLowerCase().contains(word.toLowerCase())) {
                        final filePath = s['filePath'] as String? ?? '';
                        final offset = ((s['offset'] as num?) ?? 0).toInt();
                        if (filePath.isNotEmpty) {
                          Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                            builder: (_) => _ExamPaperViewer(
                              filePath: filePath,
                              keyword: word,
                              offset: offset,
                              onLookupWord: (w) {
                                setState(() => _currentIndex = 0);
                                _searchCtrl.text = w;
                                _lookupWord(w);
                              },
                            ),
                          ));
                          return;
                        }
                      }
                    }
                  }
                }
                showAppSnackBar(context, '未找到对应真题', type: AppSnackBarType.error);
              },
            ),
          ],
        ),
      ),
    );
  }

  Color _categoryColor(String cat) {
    switch (cat) {
      case '课标词': return AppTheme.primaryBlue;
      case '拓展词': return AppTheme.green;
      case '超标词': return AppTheme.red;
      case '专有词': return AppTheme.grey;
      default: return AppTheme.orange;
    }
  }
}


class _ExamPaperViewer extends StatefulWidget {
  final String filePath;
  final String keyword;
  final int offset;
  final void Function(String word) onLookupWord;

  const _ExamPaperViewer({
    required this.filePath,
    required this.keyword,
    required this.offset,
    required this.onLookupWord,
  });

  @override
  State<_ExamPaperViewer> createState() => _ExamPaperViewerState();
}

class _ExamPaperViewerState extends State<_ExamPaperViewer> {
  late final ScrollController _scrollController;
  String _content = '';
  bool _loading = true;
  SelectedContent? _selectedContent;
  // 分块懒加载：全文按固定大小切成块，ListView.builder 只渲染可见块，
  // 避免整篇文本放单个 Text.rich + SelectionArea 导致的长文档布局/选区开销
  List<String> _chunks = const [];
  // 目标关键词所在块的索引（用于打开时定位滚动）
  int _highlightChunkIndex = 0;
  // 每块最大字符数；块太小 item 过多、块太大失去懒加载意义
  static const int _maxChunkChars = 1500;

  /// 按固定大小 + 空格/标点边界切块，保证各块拼接后与原文逐字符一致
  static List<String> _splitChunks(String text, {int maxChunk = _maxChunkChars}) {
    final chunks = <String>[];
    final n = text.length;
    if (n == 0) return chunks;
    // 优先在空白/常见标点处断开，避免切在单词中间
    final boundary = RegExp(r'[\s\u3000，。；：！？、,.!?;:()（）\[\]"\u0027]');
    var start = 0;
    while (start < n) {
      var end = start + maxChunk;
      if (end >= n) {
        chunks.add(text.substring(start));
        break;
      }
      // 在 end 附近向前找最近边界，但至少保留一半块长，避免退化
      final cut = text.lastIndexOf(boundary, end - 1);
      if (cut > start + maxChunk ~/ 2) {
        end = cut + 1;
      }
      chunks.add(text.substring(start, end));
      start = end;
    }
    return chunks;
  }

  /// 返回包含指定字符偏移（相对全文）的块索引
  static int _chunkIndexAt(List<String> chunks, int offset) {
    var acc = 0;
    for (var i = 0; i < chunks.length; i++) {
      acc += chunks[i].length;
      if (offset < acc) return i;
    }
    return chunks.isEmpty ? 0 : chunks.length - 1;
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        if (mounted) {
          showAppSnackBar(context, '真题文件不存在：\${widget.filePath}', type: AppSnackBarType.error);
        }
        _content = '真题文件不存在：\${widget.filePath}';
        if (mounted) setState(() => _loading = false);
        return;
      }
      final text = await file.readAsString();
      _content = text;
      // 分块懒加载
      _chunks = _splitChunks(text);
      // 计算关键词在原文中的字符范围
      final pattern = RegExp(r'\b' + RegExp.escape(widget.keyword) + r'\b', caseSensitive: false);
      final m = pattern.firstMatch(text);
      if (m != null) {
        _highlightChunkIndex = _chunkIndexAt(_chunks, m.start);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '读取真题失败：\$e', type: AppSnackBarType.error);
      }
      _content = '无法读取真题文件：\${widget.filePath}';
    }
    if (mounted) {
      setState(() => _loading = false);
      // 等待布局完成后滚动到关键单词位置
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToHighlight();
      });
    }
  }

  /// 滚动定位到目标关键词所在块（按累计字符权重粗定位，目标块会出现在视口附近）
  void _scrollToHighlight() {
    if (!_scrollController.hasClients) return;
    if (_chunks.isEmpty) return;
    if (_highlightChunkIndex >= _chunks.length) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;
    // 目标块起始字符占全文比例，映射到滚动偏移
    var charsBefore = 0;
    for (var i = 0; i < _highlightChunkIndex; i++) {
      charsBefore += _chunks[i].length;
    }
    final total = _content.length;
    final ratio = (total == 0) ? 0.0 : (charsBefore / total);
    final target = (ratio * maxScroll).clamp(0.0, maxScroll);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// 构建正文 TextSpan：每个英文单词独立可点击，keyword 高亮」
  /// 构建正文 TextSpan：仅 keyword 拆为高亮 span，其余整段保留，
  /// 避免逐词拆分导致大量 span 造成卡顿；点击命中由 GestureDetector 统一处理」
  List<TextSpan> _buildChunkSpans(String chunk) {
    if (chunk.isEmpty) return const [];
    final keyword = widget.keyword;
    if (keyword.isEmpty) return [TextSpan(text: chunk)];
    // 直接定位目标关键词（预编译局部正则），避免逐词扫描全文导致长文档卡顿
    final pattern = RegExp(r'\b' + RegExp.escape(keyword) + r'\b', caseSensitive: false);
    final matches = pattern.allMatches(chunk).toList();
    if (matches.isEmpty) return [TextSpan(text: chunk)];
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: chunk.substring(cursor, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(0)!,
        style: const TextStyle(
          backgroundColor: Color(0x66FFEB3B),
          fontWeight: FontWeight.bold,
          color: Colors.red,
        ),
      ));
      cursor = m.end;
    }
    if (cursor < chunk.length) {
      spans.add(TextSpan(text: chunk.substring(cursor)));
    }
    return spans;
  }

  /// 长按选中单词后的自定义菜单：复制 / 修改 / 查词」
  /// 位置由系统按选区自动定位（选区上方），避免手动命中测试因分辨率导致偏移」
  Widget _buildWordContextMenu(BuildContext context, SelectableRegionState state) {
    final content = _selectedContent;
    final word = content?.plainText.trim() ?? '';
    if (word.isEmpty) return const SizedBox.shrink();
    final isWord = RegExp(r"^[a-zA-Z]+(?:['“][a-zA-Z]+)*$").hasMatch(word);
    if (!isWord) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: [
          ContextMenuButtonItem(
            label: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: word));
              state.hideToolbar();
            },
          ),
        ],
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: word));
            state.hideToolbar();
            showAppSnackBar(context, '已复制 $word', type: AppSnackBarType.success);
          },
        ),
        ContextMenuButtonItem(
          label: '修改',
          onPressed: () {
            state.hideToolbar();
            _editWord(word);
          },
        ),
        ContextMenuButtonItem(
          label: '查词',
          onPressed: () {
            state.hideToolbar();
            Navigator.of(context).pop();
            widget.onLookupWord(word);
          },
        ),
      ],
    );
  }

  /// 编辑标注单词：将真题文件原文中所有该词替换为新拼写并写回文件，
  /// 重新高亮新词（对齐分析页/Windows 版仅改语料文本语义，不修改词库分类）」
  Future<void> _editWord(String oldWord) async {
    final controller = TextEditingController(text: oldWord);
    final newWord = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑此词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新拼写（将替换真题文件中所有该词）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newWord == null || newWord.isEmpty || newWord == oldWord) return;
    if (!RegExp(r'^[a-zA-Z]+$').hasMatch(newWord)) {
      if (!mounted) return;
      showAppSnackBar(context, '$newWord 不是合法的英文单词', type: AppSnackBarType.info);
      return;
    }
    final replaced = _content.replaceAllMapped(
      RegExp('\\b${RegExp.escape(oldWord)}\\b', caseSensitive: false),
      (_) => newWord,
    );
    if (replaced == _content) {
      if (!mounted) return;
      showAppSnackBar(context, '文本中未找到 $oldWord', type: AppSnackBarType.error);
      return;
    }
    try {
      await File(widget.filePath).writeAsString(replaced);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, '写入真题文件失败 $e', type: AppSnackBarType.error);
      return;
    }
    if (!mounted) return;
    setState(() {
      _content = replaced;
      // 重建分块并重新定位新词高亮块
      _chunks = _splitChunks(replaced);
      final pattern = RegExp(r'\b' + RegExp.escape(newWord) + r'\b', caseSensitive: false);
      final m = pattern.firstMatch(_content);
      _highlightChunkIndex = (m != null) ? _chunkIndexAt(_chunks, m.start) : 0;
    });
    showAppSnackBar(context, '已将真题文件中 $oldWord 改为 $newWord', type: AppSnackBarType.success);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.filePath.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: AppTheme.surfaceLight,
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Scrollbar(
              controller: _scrollController,
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _chunks.length,
                // 懒加载：仅构建可见块，单帧布局/选区开销只与可见块相关
                itemBuilder: (context, index) {
                  final chunk = _chunks[index];
                  return RepaintBoundary(
                    child: SelectionArea(
                      onSelectionChanged: (content) => _selectedContent = content,
                      contextMenuBuilder: _buildWordContextMenu,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text.rich(
                          TextSpan(
                            style: const TextStyle(fontSize: 15, height: 1.6, color: Colors.black87),
                            children: _buildChunkSpans(chunk),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// 文本检测历史记录项
class _DetectHistory {
  final String fileName;
  final DateTime time;
  final int totalWords;
  final Map<String, int> categoryCounts;
  final String? sourcePath; // P6：不存全文，仅存导入源路径，重看时按需重新提取
  final int annotatedCount;

  _DetectHistory({
    required this.fileName,
    required this.time,
    required this.totalWords,
    required this.categoryCounts,
    required this.sourcePath,
    required this.annotatedCount,
  });
}

class _AnalysisPage extends StatefulWidget {
  final String text;
  final String fileName;
  final String? sourcePath; // 导入源文件绝对路径（docx 时可原地标注保留原排版）
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final ValueChanged<String>? onWordTap;
  final WordSyncService wordSyncService;
  final String userId;

  const _AnalysisPage({required this.text, required this.fileName, this.sourcePath, required this.vocab, required this.onSaveConfig, this.onWordTap, required this.wordSyncService, required this.userId});

  @override
  State<_AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<_AnalysisPage> {
  late List<_AnalyzedWord> _words;
  late Map<String, int> _categoryCounts;
  int _annotatedCount = 0;
  String _filter = '全部';
  List<_AnalyzedWord> _cachedFiltered = [];
  bool _batchMode = false;
  final Set<String> _selectedOthers = {};
  late String _text;

  final Map<String, int?> _realFreq = {};
  bool _freqLoading = false;
  bool _analyzing = false;

  static final RegExp _wordRegex = RegExp(r'\b[a-zA-Z]{2,}\b');
  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _analyzing = true;
    _analyzeInBackground();
  }

  /// 首屏大文本分析走后台 isolate：避免在 UI isolate 同步执行
  /// 全量正则遍历 + 分类 + 中文注解回溯导致界面冻结/ANR，同时
  /// 分析完成后释放 isolate 内的临时大对象，降低 OOM 风险。
  Future<void> _analyzeInBackground() async {
    try {
      final vocab = widget.vocab;
      final args = <String, dynamic>{
        'text': _text,
        'standard': vocab.standardWordsLowerKeySet.toList(),
        'extend': vocab.extendWordsLowerSet.toList(),
        'chaogang': vocab.chaoGangLowerSet.toList(),
        'extra': vocab.extraLowerSet.toList(),
        'classMem': Map<String, String>.from(vocab.classificationMemory),
      };
      final result = await Isolate.run(() => _analyzeTextWorker(args));
      if (!mounted) return;
      setState(() {
        _words = [
          for (final w in (result['words'] as List))
            _AnalyzedWord(
              word: w['word'] as String,
              frequency: w['frequency'] as int,
              category: w['category'] as String,
            ),
        ];
        _categoryCounts = Map<String, int>.from(result['categoryCounts'] as Map);
        _annotatedCount = result['annotatedCount'] as int;
        _analyzing = false;
      });
      _loadRealFreq();
      _rebuildFiltered();
    } catch (e) {
      // 后台分析异常时回退到同步分析，避免功能不可用
      if (mounted) setState(() => _analyzing = false);
      try {
        _analyze();
      } catch (_) {
        _words = [];
        _categoryCounts = {};
        _annotatedCount = 0;
        _rebuildFiltered();
      }
    }
  }

  void _analyze() {
    try {
      final freqMap = <String, int>{};
    final caseMap = <String, String>{};

    // 剥离真题选项字母粘连（如 hostedB 还原为 hosted），与 Windows 导出侧 filterGluedRe 同款
    final gluedLetterRe = RegExp(r'^([a-zA-Z]{3,})([A-H])$');
    for (final m in _wordRegex.allMatches(_text)) {
      final original = m.group(0)!;
      if (_digitsOnly.hasMatch(original)) continue;
      var lower = original.toLowerCase();
      var display = original;
      final glued = gluedLetterRe.firstMatch(original);
      if (glued != null) {
        lower = glued.group(1)!.toLowerCase();
        display = glued.group(1)!;
      }
      freqMap[lower] = (freqMap[lower] ?? 0) + 1;
      if (!caseMap.containsKey(lower)) caseMap[lower] = display;
    }

    _words = freqMap.entries.map((e) {
      final lower = e.key;
      final original = caseMap[lower] ?? lower;
      String cat;
      if (widget.vocab.classificationMemory.containsKey(lower)) {
        cat = widget.vocab.classificationMemory[lower]!;
      } else if (widget.vocab.isStandard(original)) {
        cat = '课标词';
      } else if (widget.vocab.isExtend(original)) {
        cat = '拓展词';
      } else if (widget.vocab.isChaoGang(original)) {
        cat = '超标词';
      } else if (widget.vocab.isExtra(original)) {
        cat = '专有词';
      } else {
        cat = '其他';
      }
      return _AnalyzedWord(word: original, frequency: e.value, category: cat);
    }).toList()
      ..sort((a, b) => b.frequency.compareTo(a.frequency));

    _categoryCounts = {};
    for (final w in _words) {
      _categoryCounts[w.category] = (_categoryCounts[w.category] ?? 0) + 1;
    }

    // 构建汉语标注词集合（统计用，仅计数不加色）
    // O(N) 实现：避免对全文反复 substring + firstMatch 造成 O(N^2) 卡顿
    final parenChineseRegex = RegExp(r'^\s*[\(（][^)）]*[\u4e00-\u9fa5]+[^)）]*[\)）]');
    final importedWordsLower = _words.map((aw) => aw.word.toLowerCase()).toSet();
    final annotatedPhrases = <String>{};
    final wordPattern = RegExp(r'\b[a-zA-Z]{2,}\b');
    bool isAsciiLetter(int u) =>
        (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
    bool isSep(int u) =>
        u == 0x20 || u == 0x09 || u == 0x2D; // 空格 / 制表 / 连字符
    // 用 allMatches 遍历所有词（替代逐位指针推进，避免 O(N^2) 与跨行跳词）
    for (final m in wordPattern.allMatches(_text)) {
      final w = m.group(0)!;
      if (!importedWordsLower.contains(w.toLowerCase())) { continue; }
      // 直接从原文本 m.end 处匹配中文注解，避免创建 O(N) 子串
      if (parenChineseRegex.matchAsPrefix(_text, m.end) == null) continue;
      // 向前回溯合并短语：跳过空白连字符，取前面一段连续字母作为前一词
      int phraseStart = m.start;
      while (phraseStart > 0) {
        int p = phraseStart;
        while (p > 0 && isSep(_text.codeUnitAt(p - 1))) {
          p--;
        }
        int q = p;
        while (q > 0 && isAsciiLetter(_text.codeUnitAt(q - 1))) {
          q--;
        }
        if (q == p) break; // 前方不是单词，停止回溯
        final pw = _text.substring(q, p);
        if (!importedWordsLower.contains(pw.toLowerCase())) break;
        phraseStart = q;
      }
      annotatedPhrases.add(_text.substring(phraseStart, m.end).trim());
    }
    _annotatedCount = annotatedPhrases.length;
    } catch (_) {
      // 分析异常时兜底为空结果，避免闪退
      _words = [];
      _categoryCounts = {};
      _annotatedCount = 0;
    }
    // 异步获取真题词频（不阻塞分析主流程）
    _loadRealFreq();
    _rebuildFiltered();
  }

  /// 获取真题语料库目录路径（应用文档目录下的 corpus 子目录）。
  Future<String> _corpusDirPath() async {
    final dir = await _appDocDir();
    return '$dir/corpus';
  }

  /// 获取教材语料目录路径（应用文档目录下的 textbook 子目录）。
  Future<String> _textbookDirPath() async {
    final dir = await _appDocDir();
    return '$dir/textbook';
  }

  /// 从 corpus 全量索引（corpus_index.json）查表获取每个已识别词的真实出现次数。
  /// 索引首次构建时扫描全部 txt 并写入磁盘，后续直接读内存 Map，毫秒级响应。
  Future<void> _loadRealFreq() async {
    if (mounted) setState(() => _freqLoading = true);
    try {
      final corpusPath = await _corpusDirPath();
      final index = await _loadCorpusIndex(corpusPath);
      for (final aw in _words) {
        _realFreq[aw.word.toLowerCase()] = index[aw.word.toLowerCase()] ?? 0;
      }
    } catch (_) {
      // 词频查询失败不影响主流程
    } finally {
      if (mounted) setState(() => _freqLoading = false);
    }
  }

  List<_AnalyzedWord> get _filtered => _cachedFiltered;

  void _rebuildFiltered() {
    _cachedFiltered = _filter == '全部'
        ? _words
        : _words.where((w) => w.category == _filter).toList();
  }
  @override
  void dispose() {
    super.dispose();
  }

  Map<String, dynamic> _buildResult() {
    return {
      'fileName': widget.fileName,
      'totalWords': _words.length,
      'categoryCounts': Map<String, int>.from(_categoryCounts),
      'sourcePath': widget.sourcePath, // P6：历史仅存源路径，不存全文
      'annotatedCount': _annotatedCount,
    };
  }

  void _popWithResult() {
    Navigator.of(context).pop(_buildResult());
  }

  @override
  Widget build(BuildContext context) {
    if (_analyzing) {
      return Scaffold(
        backgroundColor: AppTheme.surfaceLight,
        appBar: AppBar(
          backgroundColor: AppTheme.surfaceLight,
          title: Text(widget.fileName, style: const TextStyle(fontSize: 16)),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _popWithResult),
          actions: [
            TextButton(onPressed: _popWithResult, child: const Text('完成')),
          ],
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('正在分析文本…', style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              SizedBox(height: 4),
              Text('大文档首次分析较慢，请耐心等待', style: TextStyle(fontSize: 12, color: AppTheme.textHint)),
            ],
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popWithResult();
      },
      child: Scaffold(
      backgroundColor: AppTheme.surfaceLight,
      appBar: AppBar(
        backgroundColor: AppTheme.surfaceLight,
        title: Text(widget.fileName, style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _popWithResult,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: '导出结果',
            onPressed: _exportResult,
          ),
          TextButton(
            onPressed: _popWithResult,
            child: const Text('完成'),
          ),
        ],
      ),
      body: Column(
        children: [
          // 筛选标签（固定高度，紧凑）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterChip(label: '全部', count: _words.length, selected: _filter == '全部', onTap: () => setState(() { _filter = '全部'; _rebuildFiltered(); })),
                  ...['课标词', '拓展词', '超标词', '专有词', '其他'].map((cat) => _FilterChip(
                    label: cat, count: _categoryCounts[cat] ?? 0,
                    selected: _filter == cat,
                    onTap: () => setState(() { _filter = cat; _rebuildFiltered(); }),
                  )),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (_filter == '其他' && (_categoryCounts['其他'] ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _batchMode = !_batchMode;
                      if (!_batchMode) _selectedOthers.clear();
                    }),
                    icon: Icon(_batchMode ? Icons.close : Icons.checklist, size: 18),
                    label: Text(_batchMode ? '退出批量归类' : '批量归类'),
                  ),
                  if (!_batchMode) ...[
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _startClassifyBatch,
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('连续筛选'),
                    ),
                  ],
                ],
              ),
            ),
          // 筛选单词列表（填充可用空间）
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inbox_outlined, size: 36, color: AppTheme.textHint),
                        const SizedBox(height: AppTheme.spacingSm),
                        Text('暂无 ${_filter == '全部' ? '单词' : _filter}', style: TextStyle(color: AppTheme.textSecondary)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) {
                      final aw = _filtered[i];
                      final showCheckbox = _batchMode && aw.category == '其他';
                      final realFreq = _realFreq[aw.word.toLowerCase()];
                      return ListTile(
                        leading: showCheckbox
                            ? Checkbox(
                                value: _selectedOthers.contains(aw.word),
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selectedOthers.add(aw.word);
                                  } else {
                                    _selectedOthers.remove(aw.word);
                                  }
                                }),
                              )
                            : CircleAvatar(
                                radius: 14,
                                backgroundColor: _chipColor(aw.category),
                                child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                        title: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: _chipColor(aw.category).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                              ),
                              child: Text(
                                aw.category,
                                style: TextStyle(fontSize: 11, color: _chipColor(aw.category), fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => _openSourcePopup(aw.word),
                              child: Text(aw.word, style: const TextStyle(fontWeight: FontWeight.w500)),
                            ),
                            const Spacer(),
                            if (_freqLoading)
                              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            else if (realFreq != null && realFreq > 0)
                              GestureDetector(
                                onTap: () => _openSourcePopup(aw.word),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                                  ),
                                  child: Text('$realFreq', style: TextStyle(fontSize: 11, color: Colors.blue.shade700, fontWeight: FontWeight.w600)),
                                ),
                              ),
                          ],
                        ),
                        trailing: aw.category == '其他'
                            ? PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, size: 18),
                                onSelected: (cat) async {
                                  if (cat == '修改') {
                                    await _showEditDetectedWordDialog(aw.word);
                                    return;
                                  }
                                  switch (cat) {
                                    case '拓展词': await _showBaseWordDialog(aw.word); break;
                                    case '超标词':
                                      widget.vocab.addChaoGangWord(aw.word);
                                      widget.wordSyncService.markChanged(aw.word);
                                      break;
                                    case '专有词':
                                      widget.vocab.addExtraWord(aw.word);
                                      widget.wordSyncService.markChanged(aw.word);
                                      break;
                                  }
                                  widget.onSaveConfig();
                                  _analyze();
                                  if (mounted) setState(() {});
                                },
                                itemBuilder: (_) => [
                                  if (aw.category == '其他') ...[
                                  const PopupMenuItem(value: '拓展词', child: Text('设为拓展词')),
                                  const PopupMenuItem(value: '超标词', child: Text('设为超标词')),
                                  const PopupMenuItem(value: '专有词', child: Text('设为专有词')),
                                  ],
                                ],
                              )
                            : null,
                      );
                    },
                  ),
          ),
          if (_batchMode && _selectedOthers.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceLight,
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text('已选 ${_selectedOthers.length} 个', style: const TextStyle(fontSize: 13, color: Colors.black87)),
                  ),
                  Expanded(child: TextButton(onPressed: _batchExtendDialog, child: const Text('拓展词', style: TextStyle(fontSize: 13)))),
                  Expanded(child: TextButton(onPressed: _batchSetChaoGang, child: const Text('超标词', style: TextStyle(fontSize: 13)))),
                  Expanded(child: TextButton(onPressed: _batchSetExtra, child: const Text('专有词', style: TextStyle(fontSize: 13)))),
                ],
              ),
            ),
        ],
      ),
    ),
  );
  }


  /// 弹出关联课标词对话框，用户选择基础课标词后添加为拓展词。
  /// 弹出时根据添加单词自动搜索并排序匹配课标词。
  Future<void> _showBaseWordDialog(String word) async {
    final controller = TextEditingController(text: word);
    final lowerWord = word.toLowerCase();

    final allStandard = widget.vocab.standardWordsLowerKeySet.toList();
    List<String> matches = _getBaseWordCandidates(lowerWord, allStandard);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('拓展词原词'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        hintText: '搜索课标词',
                        prefixIcon: Icon(Icons.search, size: 20),
                        border: OutlineInputBorder(),
                        isDense: true,
                        filled: true,
                        fillColor: AppTheme.surfaceLight,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onChanged: (q) {
                        final lower = q.trim().toLowerCase();
                        setDialogState(() {
                          matches = lower.isEmpty
                              ? _getBaseWordCandidates(lowerWord, allStandard)
                              : _getBaseWordCandidates(lower, allStandard);
                        });
                      },
                      onSubmitted: (q) {
                        // 回车且只有一个完全匹配时自动选择并关闭
                        final lower = q.trim().toLowerCase();
                        if (matches.length == 1 && matches.first.toLowerCase() == lower) {
                          widget.vocab.addExtendWord(word, baseWord: matches.first);
                          widget.wordSyncService.markChanged(word);
                          Navigator.of(dialogContext).pop();
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (_, i) {
                          final w = matches[i];
                          return InkWell(
                            onTap: () {
                              widget.vocab.addExtendWord(word, baseWord: w);
                              widget.wordSyncService.markChanged(word);
                              Navigator.of(dialogContext).pop();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Text(w, style: const TextStyle(fontSize: 16)),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 批量设为拓展词：弹一次关联词对话框，选中基词后应用到所有选中的单词
  void _batchExtendDialog() async {
    final words = _selectedOthers.toList();
    final firstWord = words.first;
    final controller = TextEditingController(text: firstWord);
    final lowerWord = firstWord.toLowerCase();
    final allStandard = widget.vocab.standardWordsLowerKeySet.toList();
    List<String> matches = _getBaseWordCandidates(lowerWord, allStandard);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('批量拓展词原词（${words.length}个单词）'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        hintText: '搜索课标词',
                        prefixIcon: Icon(Icons.search, size: 20),
                        border: OutlineInputBorder(),
                        isDense: true,
                        filled: true,
                        fillColor: AppTheme.surfaceLight,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onChanged: (q) {
                        final lower = q.trim().toLowerCase();
                        setDialogState(() {
                          matches = lower.isEmpty
                              ? _getBaseWordCandidates(lowerWord, allStandard)
                              : _getBaseWordCandidates(lower, allStandard);
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (_, i) {
                          final w = matches[i];
                          return InkWell(
                            onTap: () {
                              for (final word in words) {
                                widget.vocab.addExtendWord(word, baseWord: w);
                                widget.wordSyncService.markChanged(word);
                              }
                              Navigator.of(dialogContext).pop();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Text(w, style: const TextStyle(fontSize: 16)),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );

    widget.onSaveConfig();
    _analyze();
    _selectedOthers.clear();
    _batchMode = false;
    if (mounted) setState(() {});
  }

  void _batchSetChaoGang() {
    for (final word in _selectedOthers.toList()) {
      widget.vocab.addChaoGangWord(word);
    }
    widget.onSaveConfig();
    _analyze();
    _selectedOthers.clear();
    _batchMode = false;
    if (mounted) setState(() {});
  }

  void _batchSetExtra() {
    for (final word in _selectedOthers.toList()) {
      widget.vocab.addExtraWord(word);
    }
    widget.onSaveConfig();
    _analyze();
    _selectedOthers.clear();
    _batchMode = false;
    if (mounted) setState(() {});
  }


  /// 连续筛选：单一弹窗含输入框+候选词+按钮；分类计数实时更新，时间戳精确到秒。
  Future<void> _startClassifyBatch() async {
    while (true) {
      final others = _words.where((w) => w.category == '其他').toList();
      if (others.isEmpty) {
        if (mounted) {
          showAppSnackBar(context, '所有待筛选单词已处理完毕', type: AppSnackBarType.success);
        }
        break;
      }

      final word = others.first.word;
      final remaining = others.length;
      final allStandard = widget.vocab.standardWordsLowerKeySet.toList();
      final lowerWord = word.toLowerCase();

      final result = await showDialog<_DialogResult>(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) {
          final controller = TextEditingController(text: word);
          List<String> matches = _getBaseWordCandidates(lowerWord, allStandard);

          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              void tryAutoComplete() {
                final input = controller.text.trim().toLowerCase();
                for (final m in matches) {
                  if (m.toLowerCase() == input) {
                    widget.vocab.addExtendWord(word, baseWord: m);
                    widget.wordSyncService.markChanged(word);
                    Navigator.of(dialogCtx).pop(_DialogResult(action: '拓展词', baseWord: m));
                    return;
                  }
                }
              }

              return AlertDialog(
                title: Text('将 "$word" 筛选归类'),
                content: SizedBox(
                  width: double.maxFinite,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('剩余 $remaining 个待处理', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: controller,
                              decoration: const InputDecoration(
                                hintText: '输入课标词搜索',
                                prefixIcon: Icon(Icons.search, size: 20),
                                border: OutlineInputBorder(),
                                isDense: true,
                                filled: true,
                                fillColor: AppTheme.surfaceLight,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                              onChanged: (q) {
                                final lower = q.trim().toLowerCase();
                                setDialogState(() {
                                  matches = lower.isEmpty
                                      ? _getBaseWordCandidates(lowerWord, allStandard)
                                      : _getBaseWordCandidates(lower, allStandard);
                                });
                                tryAutoComplete();
                              },
                              onSubmitted: (_) => tryAutoComplete(),
                            ),
                            const SizedBox(height: 8),
                            Flexible(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 200),
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: matches.length,
                                  itemBuilder: (_, i) {
                                    final w = matches[i];
                                    return InkWell(
                                      onTap: () {
                                        widget.vocab.addExtendWord(word, baseWord: w);
                                        widget.wordSyncService.markChanged(word);
                                        Navigator.of(dialogCtx).pop(_DialogResult(action: '拓展词', baseWord: w));
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Text(w, style: const TextStyle(fontSize: 15)),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: ElevatedButton(
                                onPressed: () => Navigator.of(dialogCtx).pop(_DialogResult(action: '专有词')),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.grey[700],
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(80, 36),
                                ),
                                child: const Text('专有词', style: TextStyle(fontSize: 14)),
                              ),
                            ),
                            const SizedBox(height: 8),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: ElevatedButton(
                                onPressed: () => Navigator.of(dialogCtx).pop(_DialogResult(action: '超标词')),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.orange,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(80, 36),
                                ),
                                child: const Text('超标词', style: TextStyle(fontSize: 14)),
                              ),
                            ),
                            const SizedBox(height: 8),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: TextButton(
                                onPressed: () => Navigator.of(dialogCtx).pop(null),
                                child: const Text('退出'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

      if (result == null) break;

      if (result.action != '拓展词') {
        if (result.action == '超标词') {
          widget.vocab.addChaoGangWord(word);
          widget.wordSyncService.markChanged(word);
        } else if (result.action == '专有词') {
          widget.vocab.addExtraWord(word);
          widget.wordSyncService.markChanged(word);
        }
      }

      widget.onSaveConfig();
      _analyze();
    }

    if (mounted) setState(() {});
  }


  /// 导出分析结果：先让用户选择 TXT 或 DOCX 格式，再生成文件。
  Future<void> _exportResult() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('导出结果'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'txt'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('导出为 TXT（纯文本）'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'docx'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('导出为 DOCX（Word 文档）'),
            ),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (!mounted) return;

    ExportProgressOverlay? progress;
    String? exportPath;
    try {
      final dir = await _pickExportDir(context, isVocab: false);
      final exportDir = dir;
      final ts = DateTime.now();
      final stamp = '${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}'
          '_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}${ts.second.toString().padLeft(2, '0')}';

      final totalRawCount = _words.fold<int>(0, (sum, w) => sum + w.frequency);
      // 1.5.7 行为：导出数据在主 isolate 同步构建并直接写盘，不再跨 isolate，
      // 规避 Isolate.run/compute 消息合法性检查（object is unsendable）导致的
      // 导出完全不可用问题；进度提示兜底大文档等待，异常全捕获落盘日志。
      if (!mounted) return;
      // 统一导出等待提示：延迟 500ms 未完成才浮出，含阶段文案与实时已用时
      progress = ExportProgressOverlay.begin(
        context,
        stage: '正在生成导出文档…请稍候',
        hint: '文档越大耗时越长，请耐心等待',
      );
      try {
        await progress.setStage('正在整理检测数据…');
        final exportData = await _buildExportTableDataAndroid(_text);
        final baseName = _exportBaseName(widget.fileName, stamp);
        final path = '${exportDir.path}/$baseName.${choice == 'txt' ? 'txt' : 'docx'}';
        await progress.setStage('正在写入${choice == 'txt' ? 'TXT' : 'DOCX'}文件…');
        if (choice == 'txt') {
          await _writeTxtExportWorker(
            path,
            _text,
            <Map<String, dynamic>>[
              for (final w in _words)
                {'word': w.word, 'frequency': w.frequency, 'category': w.category},
            ],
            Map<String, int>.from(_categoryCounts),
            _annotatedCount,
            totalRawCount,
            widget.fileName,
            _exportTableDataToMap(exportData),
          );
        } else {
          await _exportDocx(path, exportData);
        }
        exportPath = path;
      } finally {
        // 无论成功或异常，导出结束立即收起提示层，绝不残留
        progress.close();
        progress = null;
      }
      if (mounted) {
        showAppSnackBar(
          context,
          '已导出至: $exportPath',
          type: AppSnackBarType.success,
        );
      }
    } catch (e, st) {
      progress?.close();
      progress = null;
      // 导出失败落盘日志，便于用户回传精确定位（含 isolate 消息不可发送等异常）
      try {
        final docs = await _appDocDir();
        final log = File('$docs/esw_export_error.log');
        await log.writeAsString(
          '${DateTime.now().toIso8601String()} EXPORT_ERROR: $e\n$st\n---\n',
          mode: FileMode.append,
        );
      } catch (_) {}
      if (mounted) {
        showAppSnackBar(context, '导出失败: $e', type: AppSnackBarType.error);
      }
    }
  }

  /// 将导出表格数据序列化为纯 Map（供后台 isolate 传参）。
  Map<String, dynamic> _exportTableDataToMap(_ExportTableData data) {
    return {
      'extend': [
        for (final sec in data.extend)
          {
            'name': sec.name,
            'items': [
              for (final it in sec.items)
                {
                  'word': it.word,
                  'baseWord': it.baseWord,
                  'originalExample': it.originalExample,
                  'gaokaoExamples': [
                    for (final g in it.gaokaoExamples)
                      {'word': g.word, 'example': g.example, 'year': g.year},
                  ],
                  'textbookExample': it.textbookExample,
                },
            ],
          },
      ],
      'overLimit': [
        for (final sec in data.overLimit)
          {
            'name': sec.name,
            'items': [
              for (final it in sec.items)
                {'word': it.word, 'posDef': it.posDef, 'originalExample': it.originalExample},
            ],
          },
      ],
    };
  }

  /// 判断单词是否为课标词（小写匹配课标词库键）。
  bool _isStandardWordAndroid(String word) =>
      widget.vocab.standardWordsLower.containsKey(word.toLowerCase());

  /// 拓展词 → 课标原词：优先用户关联映射（extendBaseMap，小写键优先），
  /// 其次反向索引，最后课标词库本身。
  String _baseWordOfAndroid(String word) {
    final linked =
        widget.vocab.extendBaseMap[word.toLowerCase()] ?? widget.vocab.extendBaseMap[word];
    if (linked != null && linked.isNotEmpty) return linked;
    final b = widget.vocab.extendReverseIndex[word.toLowerCase()];
    if (b == null) {
      final ms2 = widget.vocab.standardWordsLower[word.toLowerCase()];
      return (ms2 != null && ms2.isNotEmpty) ? ms2.first : '';
    }
    final ms = widget.vocab.standardWordsLower[b];
    return (ms != null && ms.isNotEmpty) ? ms.first : b;
  }

  /// 获取单词"词性.释义"组合文本（课标词库 def 优先，其次词典 lookup）。
  Future<String> _posDefOfAndroid(String word) async {
    final lowerList = widget.vocab.standardWordsLower[word.toLowerCase()];
    if (lowerList != null && lowerList.isNotEmpty) {
      final sw = widget.vocab.standardWords[lowerList.first];
      final def = sw?['def'] ?? '';
      if (def.isNotEmpty) return def;
    }
    final entry = await DictionaryService.lookup(word);
    return entry?['definition'] ?? '';
  }

  /// 构建导出用新格式表格数据：拓展词明细（仅真题词频 < 400）+ 超标词表。
  /// 原文例句取自导入原文，高考例句取自真题语料目录，教材例句留空（安卓端无教材语料）。
  Future<_ExportTableData> _buildExportTableDataAndroid(String originalText) async {
    // 拓展词明细：仅保留真题词频 < 400 的单词（保留原文大小写、全局去重）
    final lowFreqExtend = <String>[];
    final seenLow = <String>{};
    for (final iw in _words) {
      if (iw.category != '拓展词') continue;
      final lw = iw.word.toLowerCase();
      // _realFreq 为真题词频（corpus 索引），未加载成功时按 0 处理不拦截
      if ((_realFreq[lw] ?? 0) >= 400) continue;
      if (seenLow.add(lw)) lowFreqExtend.add(iw.word);
    }
    // 过滤简单屈折变形（名词复数/第三人称单数/规则过去式等），
    // 其课标原词已在拓展词明细中单独呈现，避免重复列出。
    // 另：凡课标原词解析为 be 或 ok 的一律不进明细（覆盖 was/were/am/is/are
    // 及其缩略拆词 wasn/weren/isn/aren、okay 等所有变体），按课标原词判断而非枚举。
    final filterGluedRe = RegExp(r'^([a-zA-Z]{3,})([A-H])$');
    lowFreqExtend.removeWhere((w) {
      final glued = filterGluedRe.firstMatch(w);
      final base =
          resolveBaseWord(glued != null ? glued.group(1)! : w, _baseWordOfAndroid)
              .toLowerCase();
      if (base == 'be' || base == 'ok') return true;
      return isSimpleInflection(w, _isStandardWordAndroid);
    });
    // 按题型分组（原文按题型标题行归属区间，组内同句多词合并成一行）
    List<ExtendSection> sections = buildExtendSections(
      text: originalText,
      extendWords: lowFreqExtend,
      baseWordOf: _baseWordOfAndroid,
      mergeSameSentenceRows: true,
    );
    // 原文无题型标题时降级为单组"全部"（仍按纯文本编号输出）
    if (sections.isEmpty && lowFreqExtend.isNotEmpty) {
      sections = [
        ExtendSection(
          name: '全部',
          rows: [
            for (final w in lowFreqExtend)
              ExtendRowData(
                word: w,
                example: pickShortExample(originalText, w),
                baseWord: _baseWordOfAndroid(w),
              ),
          ],
        ),
      ];
    }
    // 教材例句源：合并 textbook 目录下已导入教材文本（对齐 Windows 版教材导入）
    final tbSb = StringBuffer();
    try {
      final tbPath = await _textbookDirPath();
      final tbDir = Directory(tbPath);
      if (await tbDir.exists()) {
        await for (final entity in tbDir.list()) {
          if (entity is! File) continue;
          if (!entity.path.toLowerCase().endsWith('.txt')) continue;
          try {
            tbSb.writeln(await entity.readAsString());
          } catch (_) {}
        }
      }
    } catch (_) {}
    final textbookText = tbSb.toString();
    // 教材例句索引惰性构建：仅当存在词需降级到词组/结构时才 buildSentenceIndex，
    // 避免教材全文的 flat/flatLower 双份副本常驻（峰值优化）。
    SentenceIndex? textbookIndex;

    // 高考例句：逐真题文件建索引并提取年份（文件名前缀），为每个词收集候选，
    // 跨文件择优各取一句，保证"原文多词时每个词都有独立高考例句并标注年份"。
    final gluedLetterRe = RegExp(r'^([a-zA-Z]{3,})([A-H])$');
    final extendQueryWords = <String>{};
    for (final sec in sections) {
      for (final r in sec.rows) {
        for (final w in r.word.split(' ')) {
          if (w.isEmpty) continue;
          final glued = gluedLetterRe.firstMatch(w);
          extendQueryWords.add((glued != null ? glued.group(1)! : w).toLowerCase());
        }
      }
    }
    final gaokaoByWord =
        <String, List<({String example, String year, bool isPhrase})>>{
      for (final w in extendQueryWords)
        w: <({String example, String year, bool isPhrase})>[],
    };
    final fileWordRe = RegExp(r'[a-zA-Z]+');
    final yearPrefixRe = RegExp(r'^(\d{4})');
    String corpusPath = '';
    try {
      corpusPath = await _corpusDirPath();
    } catch (_) {}
    if (corpusPath.isNotEmpty) {
      final corpusDir = Directory(corpusPath);
      if (await corpusDir.exists()) {
        await for (final entity in corpusDir.list()) {
          if (entity is! File) continue;
          if (!entity.path.toLowerCase().endsWith('.txt')) continue;
          final String fileText;
          try {
            fileText = await entity.readAsString();
          } catch (_) {
            continue;
          }
          final year = yearPrefixRe.firstMatch(entity.uri.pathSegments.last)?.group(1) ?? '';
          // 整文件预检：拆词后只保留出现在目标词集合里的词，避免无谓建索引/切句
          final hitQueries = <String>{};
          for (final m in fileWordRe.allMatches(fileText)) {
            final raw = m.group(0)!;
            final glued = gluedLetterRe.firstMatch(raw);
            final q = (glued != null ? glued.group(1)! : raw).toLowerCase();
            if (extendQueryWords.contains(q)) hitQueries.add(q);
          }
          if (hitQueries.isEmpty) continue;
          final idx = buildSentenceIndex(fileText);
          // 一次扫描收集所有命中词的整句候选，替代逐词全量扫描（大幅提速）
          final candsByWord = collectSentenceCandidates(idx, hitQueries);
          for (final q in hitQueries) {
            final cands = candsByWord[q];
            final ex = (cands != null && cands.isNotEmpty)
                ? pickBestCandidate(cands, q)
                : '';
            if (ex.isNotEmpty) {
              gaokaoByWord[q]!.add((example: ex, year: year, isPhrase: false));
            }
            // 整句提取失败时备选：词组/结构级降级（bestGaokaoFor 按词性选用）
            final ph = pickPhraseFromIndex(idx, [q]);
            if (ph.isNotEmpty && ph != ex) {
              gaokaoByWord[q]!.add((example: ph, year: year, isPhrase: true));
            }
          }
        }
      }
    }
    // 例句偏好评分（宁缺毋滥口径）：不含汉字 > 无下划线 > 词数>=3 > 句子短
    final hanRe = RegExp(r'[\u4e00-\u9fff]');
    final enWordRe = RegExp(r'[a-zA-Z]+');
    int wordCountOfUsage(String s) => enWordRe.allMatches(s).length;
    int gaokaoScore(String s) {
      var score = 0;
      if (!hanRe.hasMatch(s)) score += 1000;
      if (!s.contains('_')) score += 100;
      if (enWordRe.allMatches(s).length >= 3) score += 10;
      score -= (s.length > 200 ? 200 : s.length) ~/ 5;
      return score;
    }

    List<_GaokaoExampleItem> bestGaokaoFor(String w, bool isNounAdj) {
      final glued = gluedLetterRe.firstMatch(w);
      final q = (glued != null ? glued.group(1)! : w).toLowerCase();
      final cands = gaokaoByWord[q] ??
          const <({String example, String year, bool isPhrase})>[];
      if (cands.isEmpty) return const [];
      final sentences = cands.where((c) => !c.isPhrase).toList();
      final phrases = cands.where((c) => c.isPhrase).toList();
      List<({String example, String year, bool isPhrase})> pool;
      if (isNounAdj) {
        // 名/形：整句合适（词数<=12）时优先整句，否则降级取词组
        final goodSentences =
            sentences.where((c) => wordCountOfUsage(c.example) <= 12).toList();
        pool = goodSentences.isNotEmpty
            ? goodSentences
            : (phrases.isNotEmpty ? phrases : sentences);
      } else {
        // 动/副：整句优先，整句无才用词组
        pool = sentences.isNotEmpty ? sentences : phrases;
      }
      if (pool.isEmpty) return const [];
      final best = pool.reduce((a, b) =>
          gaokaoScore(b.example) > gaokaoScore(a.example) ? b : a);
      return [_GaokaoExampleItem(word: w, example: best.example, year: best.year)];
    }

    // 词性判断缓存（名/形时整句过长降级为词组/结构）
    final nounAdjCache = <String, bool>{};
    Future<bool> isNounAdjOf(String w) async {
      final lw = w.toLowerCase();
      final cached = nounAdjCache[lw];
      if (cached != null) return cached;
      final def = await _posDefOfAndroid(lw);
      final t = def.trim().toLowerCase();
      // 释义含动词义项（vi./vt./v. 等）时按动词处理：整句优先，不降级词组
      final hasVerbSense = t.contains('\nvi.') ||
          t.contains('\nvt.') ||
          RegExp(r'\bv\.').hasMatch(t) ||
          RegExp(r'\bvi\.').hasMatch(t) ||
          RegExp(r'\bvt\.').hasMatch(t);
      final v = !hasVerbSense &&
          (t.startsWith('n.') ||
              t.startsWith('adj.') ||
              (t.startsWith('a.') && !t.startsWith('adv.')));
      nounAdjCache[lw] = v;
      return v;
    }

    // 教材用法：完整句子优先（到句号/问号/感叹号等真正结束符为止，
    // 不做逗号/分号细分、不因连词开头判为不合格），完整句缺失时才降级词组/结构
    String resolveUsageFromIndex(String word) {
      if (textbookText.isEmpty) return '';
      final ws = word.split(' ').where((w) => w.isNotEmpty).toList();
      final sentence = pickFullSentenceFromText(
        textbookText,
        ws,
        fallbackToFirst: true,
      );
      if (sentence.isNotEmpty) return sentence;
      textbookIndex ??= buildSentenceIndex(textbookText);
      return pickPhraseFromIndex(textbookIndex!, ws);
    }

    final extendSections = <_ExportExtendSection>[];
    for (final sec in sections) {
      final items = <_ExportExtendItem>[];
      for (final r in sec.rows) {
        final isNA = await isNounAdjOf(r.word);
        final gaokaoItems = <_GaokaoExampleItem>[];
        for (final w in r.word.split(' ')) {
          if (w.isNotEmpty) gaokaoItems.addAll(bestGaokaoFor(w, isNA));
        }
        items.add(_ExportExtendItem(
          word: r.word,
          baseWord: r.baseWord,
          originalExample:
              resolveUsageText(originalText, r.example, r.word, isNA),
          gaokaoExamples: gaokaoItems,
          textbookExample: resolveUsageFromIndex(r.word),
        ));
      }
      extendSections.add(_ExportExtendSection(name: sec.name, items: items));
    }

    // 拓展词 sections 已消费完毕，显式释放引用便于 GC 回收大对象，
    // 避免与后续超标词 sections 同时驻留推高峰值。
    sections = const [];
    textbookIndex = null;

    // 超标词表：按题型分组（复用 buildExtendSections，课标原词回调对超标词返回空串），
    // 每词输出 单词 / 词性.释义 / 原文例句（例句取所在题型区间的较短句）
    final overLimitWords = <String>[];
    final seenOver = <String>{};
    for (final iw in _words) {
      if (iw.category != '超标词') continue;
      final lw = iw.word.toLowerCase();
      if (seenOver.add(lw)) overLimitWords.add(iw.word);
    }
    List<ExtendSection> overSections = buildExtendSections(
      text: originalText,
      extendWords: overLimitWords,
      baseWordOf: (w) => '',
      mergeSameSentenceRows: false,
    );
    // 原文无题型标题时降级为单组"全部"
    if (overSections.isEmpty && overLimitWords.isNotEmpty) {
      overSections = [
        ExtendSection(
          name: '全部',
          rows: [
            for (final w in overLimitWords)
              ExtendRowData(
                word: w,
                example: pickShortExample(originalText, w),
                baseWord: '',
              ),
          ],
        ),
      ];
    }
    final overLimitSections = <_ExportOverLimitSection>[];
    for (final sec in overSections) {
      final items = <_ExportOverLimitItem>[];
      for (final r in sec.rows) {
        final def = await _posDefOfAndroid(r.word);
        final t = def.trim().toLowerCase();
        final isNA = t.startsWith('n.') ||
            t.startsWith('adj.') ||
            (t.startsWith('a.') && !t.startsWith('adv.'));
        items.add(_ExportOverLimitItem(
          word: r.word,
          posDef: def,
          originalExample:
              resolveUsageText(originalText, r.example, r.word, isNA),
        ));
      }
      overLimitSections.add(
          _ExportOverLimitSection(name: sec.name, items: items));
    }
    return _ExportTableData(
      extend: extendSections,
      overLimit: overLimitSections,
    );
  }

  Future<void> _exportDocx(String path, _ExportTableData exportData) async {
    // 源文件为 .docx 时原地标注：只改写 word/document.xml 追加高亮/颜色，
    // 其余部件原样保留，完整保留原文档排版格式；文末追加分页明细节。
    final srcPath = widget.sourcePath;
    if (srcPath != null &&
        srcPath.toLowerCase().endsWith('.docx') &&
        await File(srcPath).exists()) {
      try {
        final srcBytes = await File(srcPath).readAsBytes();
        final catByLower = <String, String>{};
        for (final w in _words) {
          catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
        }
        final preamble = _buildDocxPreambleAndroid(
          fileName: widget.fileName,
          exportData: exportData,
        );
        final appendix = _buildDocxAppendixAndroid(
          exportData: exportData,
        );
        final bytes = annotateDocxBytes(
          srcBytes: srcBytes,
          catByLower: catByLower,
          preambleParagraphsXml: preamble,
          appendixParagraphsXml: appendix,
        );
        await File(path).writeAsBytes(bytes);
        return;
      } catch (_) {
        // 原地标注失败（异常 docx）时回退到重新生成模式
      }
    }
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('ESW 文本检测导出', heading: 1));
    bodyParts.add(_docxParagraph('文件名: ${widget.fileName}'));
    final cc = _categoryCounts;
    final docxTotalRawCount = _words.fold<int>(0, (sum, w) => sum + w.frequency);
    bodyParts.add(_docxParagraph('全套题词数: $docxTotalRawCount | 去重总词数: ${_words.length} | 课标词: ${cc['课标词'] ?? 0} | 拓展词: ${cc['拓展词'] ?? 0} | 超标词: ${cc['超标词'] ?? 0} | 专有词: ${cc['专有词'] ?? 0} | 其他: ${cc['其他'] ?? 0} | 汉语标注词: $_annotatedCount'));
    bodyParts.add(_docxParagraph('【标注说明】', heading: 2));
    bodyParts.add(_docxParagraph('拓展词：浅黄高亮+加粗；超标词：浅粉高亮；专有词：浅绿高亮；课标词：无标记'));
    bodyParts.add(_docxParagraph('带标注全文', heading: 2));
    bodyParts.add(_docxAnnotatedParagraph());
    bodyParts.addAll(_buildDocxDetailParagraphsAndroid(exportData));

    final documentXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
${bodyParts.join('\n')}
<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
</w:body>
</w:document>''';

    final contentTypes = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';

    final rels = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

    final archive = Archive();
    archive.addFile(ArchiveFile('[Content_Types].xml', utf8.encode(contentTypes).length, utf8.encode(contentTypes)));
    archive.addFile(ArchiveFile('_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)));
    archive.addFile(ArchiveFile('word/document.xml', utf8.encode(documentXml).length, utf8.encode(documentXml)));

    final encoder = ZipEncoder();
    final bytes = encoder.encode(archive);
    if (bytes == null) throw Exception('DOCX 生成失败');
    await File(path).writeAsBytes(bytes);
  }

  /// 构建 DOCX 正文前汇总段（原地标注用）：标题 + 文件名 + 统计 + 标注说明。
  List<String> _buildDocxPreambleAndroid({
    required String fileName,
    required _ExportTableData exportData,
  }) {
    final cc = _categoryCounts;
    final docxTotalRawCount = _words.fold<int>(0, (sum, w) => sum + w.frequency);
    return [
      _docxParagraph('ESW 文本检测导出', heading: 1),
      _docxParagraph('文件名: $fileName'),
      _docxParagraph('全套题词数: $docxTotalRawCount | 去重总词数: ${_words.length} | 课标词: ${cc['课标词'] ?? 0} | 拓展词: ${cc['拓展词'] ?? 0} | 超标词: ${cc['超标词'] ?? 0} | 专有词: ${cc['专有词'] ?? 0} | 其他: ${cc['其他'] ?? 0} | 汉语标注词: $_annotatedCount'),
      _docxParagraph('【标注说明】', heading: 2),
      _docxParagraph('拓展词：浅黄高亮+加粗；超标词：浅粉高亮；专有词：浅绿高亮；课标词：无标记'),
    ];
  }

  /// 构建 DOCX 文末明细节段落（原地标注追加用）：分页 + 拓展词明细 + 超标词。
  List<String> _buildDocxAppendixAndroid({
    required _ExportTableData exportData,
  }) {
    return [
      '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
      ..._buildDocxDetailParagraphsAndroid(exportData),
    ];
  }

  /// 构建 DOCX 明细节段落（拓展词明细 + 超标词表，供导出与原地标注共用）。
  List<String> _buildDocxDetailParagraphsAndroid(_ExportTableData exportData) {
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('【拓展词明细】', heading: 2));
    if (exportData.extend.isEmpty) {
      bodyParts.add(_docxParagraph('本套题无真题词频低于 400 次的拓展词'));
    } else {
      var firstSection = true;
      for (final sec in exportData.extend) {
        if (sec.items.isEmpty) continue; // 无词的题型区块不输出
        if (!firstSection) bodyParts.add(_docxParagraph('')); // 题型之间空一行
        firstSection = false;
        bodyParts.add(_docxParagraph(sec.name)); // 题型名单独一行
        for (var i = 0; i < sec.items.length; i++) {
          final it = sec.items[i];
          final no = i + 1;
          bodyParts.add(_docxParagraph('$no. ${it.word}'));
          bodyParts.add(_docxParagraph('课标原词：${it.baseWord}'));
          final boldWords = it.word.split(' ');
          bodyParts.add(
            _docxParagraphWithBoldWords('原文用法：${it.originalExample}', boldWords),
          );
          if (it.gaokaoExamples.isEmpty) {
            bodyParts.add(_docxParagraph('高考用法：'));
          } else {
            for (final g in it.gaokaoExamples) {
              final prefix = boldWords.length > 1 ? '高考用法·${g.word}：' : '高考用法：';
              bodyParts.add(_docxParagraphWithBoldWords(
                '$prefix${g.example}${g.year.isNotEmpty ? '（${g.year}）' : ''}',
                [g.word],
              ));
            }
          }
          bodyParts.add(_docxParagraphWithBoldWords(
            '教材用法：${it.textbookExample.isEmpty ? '无' : it.textbookExample}',
            boldWords,
          ));
        }
      }
    }
    bodyParts.add(_docxParagraph('【超标词】', heading: 2));
    if (exportData.overLimit.isEmpty) {
      bodyParts.add(_docxParagraph('本套题未检测到超标词'));
    } else {
      var firstOverSection = true;
      for (final sec in exportData.overLimit) {
        if (sec.items.isEmpty) continue; // 无词的题型区块不输出
        if (!firstOverSection) bodyParts.add(_docxParagraph('')); // 题型之间空一行
        firstOverSection = false;
        bodyParts.add(_docxParagraph(sec.name)); // 题型名单独一行
        for (var i = 0; i < sec.items.length; i++) {
          final it = sec.items[i];
          final no = i + 1;
          bodyParts.add(_docxParagraph('$no. ${it.word}'));
          bodyParts.add(_docxParagraph(it.posDef));
          // 超标词加粗（含剥离完形粘连字母后的词干，兼容原文两种形态）
          final overBold = <String>[it.word];
          final glued = RegExp(r'^([a-zA-Z]{3,})([A-H])$').firstMatch(it.word);
          if (glued != null) overBold.add(glued.group(1)!);
          bodyParts.add(_docxParagraphWithBoldWords(it.originalExample, overBold));
        }
      }
    }
    return bodyParts;
  }

  /// 生成单个 DOCX 段落 XML。
  String _docxParagraph(String text, {int? heading}) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final runs = '<w:r><w:t xml:space="preserve">$escaped</w:t></w:r>';
    final style = heading != null ? ' w:val="Heading$heading"' : '';
    return '<w:p><w:pPr><w:pStyle$style/></w:pPr>$runs</w:p>';
  }

  /// 生成带标注全文的 DOCX 段落：按行拆分生成独立 `<w:p>` 保留原文换行；
  /// 按分类用规范字色 + 字重着色，**不加底纹/高亮**（Word 导出统一口径，
  /// 底纹只用于 PDF 导出）。
  String _docxAnnotatedParagraph() {
    final catByLower = <String, String>{};
    for (final w in _words) {
      catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
    }
    // 分类 -> (文字颜色, 加粗)；原荧光高亮底纹已按口径去除，改用规范字色标注。
    (String, bool) styleOf(String cat) {
      switch (cat) {
        case '拓展词':
          return ('006400', true);
        case '超标词':
          return ('FF0000', false);
        case '专有词':
          return ('800080', false);
        default:
          return ('000000', false);
      }
    }

    // 单行着色生成一个 <w:p>
    String oneLine(String line) {
      final regex = RegExp(r'[a-zA-Z]+');
      final runs = <String>[];
      int lastEnd = 0;
      for (final m in regex.allMatches(line)) {
        final word = m.group(0)!;
        final cat = catByLower[word.toLowerCase()];
        final plain = line.substring(lastEnd, m.start);
        if (plain.isNotEmpty) {
          runs.add(_docxRun(plain, '000000'));
        }
        final st = styleOf(cat ?? '');
        runs.add(_docxRun(word, st.$1, bold: st.$2));
        lastEnd = m.end;
      }
      final tail = line.substring(lastEnd);
      if (tail.isNotEmpty) runs.add(_docxRun(tail, '000000'));
      return '<w:p>${runs.join('')}</w:p>';
    }

    return _text.split('\n').map(oneLine).join('\n');
  }

  /// 生成单个 DOCX run（仅字色 + 可选加粗；不含底纹/高亮，Word 导出统一不加底纹）。
  String _docxRun(String text, String color, {bool bold = false}) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final b = bold ? '<w:b/>' : '';
    return '<w:r><w:rPr><w:color w:val="$color"/>$b</w:rPr>'
           '<w:t xml:space="preserve">$escaped</w:t></w:r>';
  }

  /// 生成带目标词加粗的 DOCX 段落：按单词切分 run，命中目标词（忽略大小写）时加粗。
  String _docxParagraphWithBoldWords(String text, List<String> words) {
    final targets = words.map((w) => w.toLowerCase()).toSet();
    final regex = RegExp(r'[a-zA-Z]+');
    final runs = <String>[];
    int lastEnd = 0;
    for (final m in regex.allMatches(text)) {
      final word = m.group(0)!;
      final plain = text.substring(lastEnd, m.start);
      if (plain.isNotEmpty) runs.add(_docxRun(plain, '000000'));
      runs.add(_docxRun(word, '000000', bold: targets.contains(word.toLowerCase())));
      lastEnd = m.end;
    }
    final tail = text.substring(lastEnd);
    if (tail.isNotEmpty) runs.add(_docxRun(tail, '000000'));
    return '<w:p>${runs.join('')}</w:p>';
  }

  Color _chipColor(String cat) {
    switch (cat) {
      case '课标词': return AppTheme.primaryBlue;
      case '拓展词': return AppTheme.green;
      case '超标词': return AppTheme.red;
      case '专有词': return AppTheme.grey;
      default: return AppTheme.orange;
    }
  }

  /// 修改真题文档文本中查到的单词：将 _text 中所有该词替换为新拼写并重新检测
  /// （对齐Windows 版“编辑语料文本后保存重检”语义，不修改词库分类集合）」
  Future<void> _showEditDetectedWordDialog(String oldWord) async {
    final controller = TextEditingController(text: oldWord);
    final newWord = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改该词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新拼写（将替换真题文本中所有该词）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newWord == null || newWord.isEmpty || newWord == oldWord) return;
    if (!RegExp(r'^[a-zA-Z]+$').hasMatch(newWord)) {
      if (!mounted) return;
      showAppSnackBar(context, '$newWord 不是合法的英文单词', type: AppSnackBarType.info);
      return;
    }
    final replaced = _text.replaceAllMapped(
      RegExp('\\b${RegExp.escape(oldWord)}\\b', caseSensitive: false),
      (_) => newWord,
    );
    if (replaced == _text) {
      if (!mounted) return;
      showAppSnackBar(context, '文本中未找到 $oldWord', type: AppSnackBarType.error);
      return;
    }
    setState(() => _text = replaced);
    _analyze();
    if (mounted) {
      showAppSnackBar(context, '已将真题文本中 $oldWord 改为 $newWord', type: AppSnackBarType.success);
    }
  }

  void _openSourcePopup(String keyword) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SourcePopupViewer(
        text: _text,
        keyword: keyword,
        words: _words,
        chipColor: _chipColor,
        onLookupWord: (word) {
          Navigator.of(context).pop();
          widget.onWordTap?.call(word);
        },
        onTextChanged: (t) {
          _text = t;
          _analyze();
        },
      ),
    ));
  }
}

/// 原文全屏查看器：按行渲染被检测文档，高亮已识别词，关键词特殊高亮并用 Scrollable.ensureVisible 精确定位。
class _SourcePopupViewer extends StatefulWidget {
  final String text;
  final String keyword;
  final List<_AnalyzedWord> words;
  final Color Function(String category) chipColor;
  final void Function(String word) onLookupWord;
  final void Function(String text) onTextChanged;

  const _SourcePopupViewer({
    required this.text,
    required this.keyword,
    required this.words,
    required this.chipColor,
    required this.onLookupWord,
    required this.onTextChanged,
  });

  @override
  State<_SourcePopupViewer> createState() => _SourcePopupViewerState();
}

class _SourcePopupViewerState extends State<_SourcePopupViewer> {
  static const double _fontSize = 16.0;
  static final _wordRegex = RegExp(r'\b[a-zA-Z]{2,}\b');

  final ScrollController _scrollCtrl = ScrollController();

  // 分块懒加载：全文按固定大小切成块，ListView.builder 只渲染可见块，
  // 每块独立 SelectionArea，避免整篇文本放单个 SelectionArea 导致 O(全文) 布局/选区开销
  List<String> _chunks = const [];
  late final Map<String, String> _catByLower;
  late final String _lowerKey;
  // 目标关键词所在块的索引（用于打开时定位滚动）
  int _targetChunkIndex = -1;
  SelectedContent? _selectedContent;
  late String _text;
  // 每块最大字符数；块太小 item 过多、块太大失去懒加载意义
  static const int _maxChunkChars = 1500;

  /// 按固定大小 + 空格/标点边界切块，保证各块拼接后与原文逐字符一致
  static List<String> _splitChunks(String text, {int maxChunk = _maxChunkChars}) {
    final chunks = <String>[];
    final n = text.length;
    if (n == 0) return chunks;
    final boundary = RegExp(r'[\s\u3000，。；：！？、,.!?;:()（）\[\]"\u0027]');
    var start = 0;
    while (start < n) {
      var end = start + maxChunk;
      if (end >= n) {
        chunks.add(text.substring(start));
        break;
      }
      final cut = text.lastIndexOf(boundary, end - 1);
      if (cut > start + maxChunk ~/ 2) {
        end = cut + 1;
      }
      chunks.add(text.substring(start, end));
      start = end;
    }
    return chunks;
  }

  /// 返回包含指定字符偏移（相对全文）的块索引
  static int _chunkIndexAt(List<String> chunks, int offset) {
    var acc = 0;
    for (var i = 0; i < chunks.length; i++) {
      acc += chunks[i].length;
      if (offset < acc) return i;
    }
    return chunks.isEmpty ? 0 : chunks.length - 1;
  }

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _lowerKey = widget.keyword.toLowerCase();
    _chunks = _splitChunks(_text);

    _catByLower = <String, String>{};
    for (final w in widget.words) {
      _catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
    }

    final offset = _locateTargetOffset();
    _targetChunkIndex = (offset != -1) ? _chunkIndexAt(_chunks, offset) : -1;

    if (_targetChunkIndex != -1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTargetChunk());
    }
  }

  /// 返回目标关键词首次命中的字符偏移（相对全文），未命中返回 -1
  int _locateTargetOffset() {
    var acc = 0;
    for (final line in _text.split('\n')) {
      for (final m in _wordRegex.allMatches(line.toLowerCase())) {
        if (m.group(0) == _lowerKey) return acc + m.start;
      }
      acc += line.length + 1; // +1 换行符
    }
    return -1;
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 滚动定位到目标关键词所在块（按累计字符权重粗定位，目标块会出现在视口附近）
  void _scrollToTargetChunk() {
    if (!_scrollCtrl.hasClients) return;
    if (_chunks.isEmpty) return;
    if (_targetChunkIndex >= _chunks.length) return;
    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    if (maxScroll <= 0) return;
    var charsBefore = 0;
    for (var i = 0; i < _targetChunkIndex; i++) {
      charsBefore += _chunks[i].length;
    }
    final total = _text.length;
    final ratio = (total == 0) ? 0.0 : (charsBefore / total);
    final target = (ratio * maxScroll).clamp(0.0, maxScroll);
    _scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// 构建单个块内的高亮 TextSpan：keyword 黄底红字粗体、分类词着色、其余普通
  List<TextSpan> _buildChunkSpan(String line) {
    final spans = <TextSpan>[];
    int lastEnd = 0;
    for (final m in _wordRegex.allMatches(line)) {
      final word = m.group(0)!;
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: line.substring(lastEnd, m.start)));
      }
      if (word.toLowerCase() == _lowerKey) {
        spans.add(TextSpan(
          text: word,
          style: TextStyle(
            backgroundColor: Colors.yellow.shade300,
            color: Colors.red.shade800,
            fontWeight: FontWeight.bold,
            fontSize: _fontSize,
          ),
        ));
      } else {
        final cat = _catByLower[word.toLowerCase()];
        if (cat != null && cat != '课标词' && cat != '其他') {
          spans.add(TextSpan(
            text: word,
            style: TextStyle(
              color: widget.chipColor(cat),
              fontWeight: FontWeight.w600,
              fontSize: _fontSize,
            ),
          ));
        } else {
          spans.add(TextSpan(text: word, style: const TextStyle(fontSize: _fontSize)));
        }
      }
      lastEnd = m.end;
    }
    if (lastEnd < line.length) {
      spans.add(TextSpan(text: line.substring(lastEnd)));
    }

    if (spans.isEmpty) {
      return [TextSpan(text: line)];
    }

    return spans;
  }

  /// 自定义长按菜单：复制 / 修改 / 查词
  Widget _buildWordContextMenu(BuildContext context, SelectableRegionState state) {
    final word = _selectedContent?.plainText.trim() ?? '';
    final isWord = RegExp(r"^[a-zA-Z]+(?:['’\-][a-zA-Z]+)*$").hasMatch(word);
    if (!isWord) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: [
          ContextMenuButtonItem(
            label: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: word));
              state.hideToolbar();
            },
          ),
        ],
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: word));
            state.hideToolbar();
            showAppSnackBar(context, '已复制 $word', type: AppSnackBarType.success);
          },
        ),
        ContextMenuButtonItem(
          label: '修改',
          onPressed: () {
            state.hideToolbar();
            _editWord(word);
          },
        ),
        ContextMenuButtonItem(
          label: '查词',
          onPressed: () {
            state.hideToolbar();
            Navigator.of(context).pop();
            widget.onLookupWord(word);
          },
        ),
      ],
    );
  }

  Future<void> _editWord(String oldWord) async {
    final controller = TextEditingController(text: oldWord);
    final newWord = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑此词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新拼写（将替换原文中所有该词）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newWord == null || newWord.isEmpty || newWord == oldWord) return;
    if (!RegExp(r'^[a-zA-Z]+$').hasMatch(newWord)) {
      if (mounted) {
        showAppSnackBar(context, '$newWord 不是合法的英文单词', type: AppSnackBarType.info);
      }
      return;
    }
    final replaced = _text.replaceAllMapped(
      RegExp('\\b${RegExp.escape(oldWord)}\\b', caseSensitive: false),
      (_) => newWord,
    );
    if (replaced == _text) {
      if (mounted) {
        showAppSnackBar(context, '文本中未找到 $oldWord', type: AppSnackBarType.error);
      }
      return;
    }
    setState(() {
      _text = replaced;
      // 重建分块并重新定位目标词所在块
      _chunks = _splitChunks(replaced);
      _catByLower.clear();
      for (final w in widget.words) {
        _catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
      }
      final offset = _locateTargetOffset();
      _targetChunkIndex = (offset != -1) ? _chunkIndexAt(_chunks, offset) : -1;
    });
    widget.onTextChanged(_text);
    if (mounted) {
      showAppSnackBar(context, '已将原文中 $oldWord 改为 $newWord', type: AppSnackBarType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceLight,
      appBar: AppBar(
        title: Text('"${widget.keyword}" 在原文中的位置'),
        titleTextStyle: const TextStyle(fontSize: 16, color: Colors.white),
        backgroundColor: AppTheme.primaryBlue,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Scrollbar(
        controller: _scrollCtrl,
        child: ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(16),
          itemCount: _chunks.length,
          // 懒加载：仅构建可见块，单帧布局/选区开销只与可见块相关
          itemBuilder: (context, index) {
            final chunk = _chunks[index];
            return RepaintBoundary(
              child: SelectionArea(
                onSelectionChanged: (content) => _selectedContent = content,
                contextMenuBuilder: _buildWordContextMenu,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: _fontSize, color: Colors.black87),
                      children: _buildChunkSpan(chunk),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AnalyzedWord {
  final String word;
  final int frequency;
  final String category;

  _AnalyzedWord({required this.word, required this.frequency, required this.category});
}

// ==================== 导出表格数据（与 Windows 版对齐） ====================
/// 高考例句条目：单词 + 例句 + 来源年份（年份从文件名前缀提取，无则空）
class _GaokaoExampleItem {
  final String word; // 单词（合并行时为其中的一个词）
  final String example; // 高考例句
  final String year; // 高考年份（如 2019；无法识别则为空）
  const _GaokaoExampleItem({
    required this.word,
    required this.example,
    required this.year,
  });
}

/// 新格式拓展词明细项（仅真题词频 < 400 的拓展词，按题型分组内的一行）
class _ExportExtendItem {
  final String word; // 单词
  final String baseWord; // 课标原词（无则空）
  final String originalExample; // 原文例句
  final List<_GaokaoExampleItem> gaokaoExamples; // 高考例句（逐词各一句，带年份）
  final String textbookExample; // 教材例句（无则"无"）
  const _ExportExtendItem({
    required this.word,
    required this.baseWord,
    required this.originalExample,
    required this.gaokaoExamples,
    required this.textbookExample,
  });
}

/// 新格式拓展词题型分区（听力/阅读/七选五/完形填空/语法填空/改错/写作）
class _ExportExtendSection {
  final String name; // 题型名
  final List<_ExportExtendItem> items; // 该题型下的拓展词
  const _ExportExtendSection({required this.name, required this.items});
}

/// 超标词项（按题型分组内的一行）
class _ExportOverLimitItem {
  final String word; // 词汇
  final String posDef; // 词性.释义（参照查词页来源：课标词库 pos/def 优先，其次词典 lookup）
  final String originalExample; // 原文例句
  const _ExportOverLimitItem({
    required this.word,
    required this.posDef,
    required this.originalExample,
  });
}

/// 超标词题型分区（听力/阅读/七选五/完形填空/语法填空/改错/写作）
class _ExportOverLimitSection {
  final String name; // 题型名
  final List<_ExportOverLimitItem> items; // 该题型下的超标词
  const _ExportOverLimitSection({required this.name, required this.items});
}

/// 导出表格数据集合（拓展词明细 + 超标词表）
class _ExportTableData {
  final List<_ExportExtendSection> extend;
  final List<_ExportOverLimitSection> overLimit;
  const _ExportTableData({required this.extend, required this.overLimit});
}

class _DialogResult {
  final String action; // '拓展词' | '超标词' | '专有词'
  final String? baseWord;
  _DialogResult({required this.action, this.baseWord});
}

const _knownPrefixes = {
    'anti', 'un', 're', 'dis', 'pre', 'mis', 'over', 'under', 'out', 'up',
    'down', 'in', 'im', 'il', 'ir', 'non', 'ex', 'de', 'en', 'em', 'sub',
    'inter', 'trans', 'super', 'semi', 'mid', 'co', 'counter', 'extra',
    'hyper', 'micro', 'mini', 'multi', 'post', 'pro', 'auto', 'bio', 'geo',
    'tele', 'mono', 'poly', 'uni', 'bi', 'tri', 'self', 'fore', 'with',
    'per', 'a', 'ab', 'ad', 'be', 'com', 'con', 'ob', 'se',
  };

  /// 候选词匹配：双端统一逻辑（见 shared/base_word_candidates.dart）
  List<String> _getBaseWordCandidates(String word, List<String> allStandardWords) {
    return baseWordCandidates(word, allStandardWords);
  }



/// 根据词形差异判断拓展词相对于原词的语法形式。
/// 返回中文描述，如 "第三人称单数 / 复数"、"过去式 / 过去分词" 等。
String _describeForm(String word, String base) {
  final w = word.toLowerCase();
  final b = base.toLowerCase();
  if (w == b) return '原形';

  // 复数 / 三单：+s, +es, y→ies
  if (w == '${b}s') return '第三人称单数 / 复数';
  if (w == '${b}es' && !b.endsWith('s')) return '第三人称单数 / 复数';
  if (b.endsWith('y') && w == '${b.substring(0, b.length - 1)}ies') return '第三人称单数 / 复数';

  // 过去式 / 过去分词：+ed, +d, y→ied, 双写+ed
  if (w == '${b}ed') return '过去式 / 过去分词';
  if (w == '${b}d') return '过去式 / 过去分词';
  if (b.endsWith('y') && w == '${b.substring(0, b.length - 1)}ied') return '过去式 / 过去分词';
  // 双写辅音 +ed：stopped→stop, planned→plan
  if (w.length == b.length + 2 && w.endsWith('ed') && w.substring(0, b.length - 1) == b.substring(0, b.length - 1) && w[b.length - 1] == b[b.length - 1]) {
    return '过去式 / 过去分词';
  }

  // 现在分词：+ing, 去e+ing, 双写+ing
  if (w == '${b}ing') return '现在分词';
  if (b.endsWith('e') && w == '${b.substring(0, b.length - 1)}ing') return '现在分词';
  if (w.length == b.length + 3 && w.endsWith('ing') && w.substring(0, b.length - 1) == b.substring(0, b.length - 1) && w[b.length - 1] == b[b.length - 1]) {
    return '现在分词';
  }

  // 比较级：+er, 去e+r, 双写+er
  if (w == '${b}er') return '比较级';
  if (b.endsWith('e') && w == '${b}r') return '比较级';

  // 最高级：+est, 去e+st, 双写+est
  if (w == '${b}est') return '最高级';
  if (b.endsWith('e') && w == '${b}st') return '最高级';

  // 副词：+ly
  if (w == '${b}ly') return '副词形式';

  // 名词化：+ness
  if (w == '${b}ness') return '名词形式';

  // 前缀派生（各种前缀）
  for (final p in _knownPrefixes) {
    if (w.startsWith(p) && b == w.substring(p.length)) {
      return '派生词（加前缀 $p-）';
    }
  }

  return '变形';
}

/// 获取导出目录：优先使用外部存储 Download 目录，失败回退到应用文档目录。
Future<Directory> _downloadDir() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      // ext.path 形如 /storage/emulated/0/Android/data/com.exam.esw/files
      // 需往上两级到 /storage/emulated/0，再进入系统 Download 目录
final download = Directory('${ext.path}/../../Download');
      if (!await download.exists()) {
        await download.create(recursive: true);
      }
      // 在 Download 下创建 esw_exports 子目录组织导出文件
      final eswDir = Directory('${download.path}/esw_exports');
      if (!await eswDir.exists()) {
        await eswDir.create(recursive: true);
      }
      return eswDir;
    }
  } catch (_) {
    // 忽略，回退到应用文档目录
  }
  return Directory(await _appDocDir());
}

/// 选择导出目录：直接弹出系统目录选择器，选择后记忆路径。
/// 用户取消选择时，若有记忆路径则使用记忆路径，否则回退到默认 Download/esw_exports。
Future<Directory> _pickExportDir(BuildContext context, {required bool isVocab}) async {
  final picked = await FilePicker.getDirectoryPath();
  if (picked != null && picked.isNotEmpty) {
    if (isVocab) {
      _lastVocabExportPath = picked;
    } else {
      _lastExportPath = picked;
    }
    return Directory(picked);
  }

  // 用户取消，若有记忆路径则使用
  final remembered = isVocab ? _lastVocabExportPath : _lastExportPath;
  if (remembered != null && remembered.isNotEmpty) {
    final dir = Directory(remembered);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // 都没有则回退默认 Download
  return _downloadDir();
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({required this.label, required this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text('$label $count'),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}



/// 异步扫描所有 corpus 语料文件，统计给定单词的出现次数。
/// 只遍历文件一次，使用联合正则一次性匹配所有单词，避免逐个单词重复扫描。
/// 使用 readAsString（异步）+ 每 10 个文件让出事件循环，避免阻塞 UI 线程。
/// 加载 corpus 全量词频索引。
/// 首次调用时扫描 corpus 目录下所有 .txt，按单词（长度>=3）统计出现次数并写入 corpus_index.json；后续调用直接读内容字 Map，毫秒级响应，彻底解决逐文件扫描转圈问题。
Future<Map<String, int>> _loadCorpusIndex(String corpusPath) async {
  final indexFile = File('$corpusPath/corpus_index.json');
  if (indexFile.existsSync()) {
    try {
      final json = await indexFile.readAsString();
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return {for (final e in decoded.entries) e.key: (e.value as num).toInt()};
    } catch (_) {
      // 索引损坏则重建
    }
  }

  // 首次构建（逐文件扫描 + split 词频统计）移入后台 isolate，
  // 避免大语料在 UI isolate 同步执行导致界面冻结/ANR。
  try {
    final _ = await Isolate.run(() => _buildCorpusIndexSync(corpusPath));
  } catch (_) {
    // isolate 派发失败时回退到同步构建，保证功能可用
    _buildCorpusIndexSync(corpusPath);
  }

  // worker 写盘后由 UI 侧统一读回（避免大 Map 跨 isolate 拷贝驻留内存）
  if (!indexFile.existsSync()) return {};
  try {
    final json = await indexFile.readAsString();
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return {for (final e in decoded.entries) e.key: (e.value as num).toInt()};
  } catch (_) {
    return {};
  }
}

/// 语料索引构建（isolate 版，同步 IO 可在后台 isolate 安全执行）：
/// 扫描 corpus 目录全部 .txt，统计 3+ 字母词频并写盘 corpus_index.json。
Map<String, int> _buildCorpusIndexSync(String corpusPath) {
  final indexFile = File('$corpusPath/corpus_index.json');
  final index = <String, int>{};
  final dir = Directory(corpusPath);
  if (!dir.existsSync()) return index;

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.txt'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (int fi = 0; fi < files.length; fi++) {
    try {
      final text = files[fi].readAsStringSync();
      final words = text.toLowerCase().split(RegExp(r'\W+'));
      for (final w in words) {
        if (w.length >= 3) {
          index[w] = (index[w] ?? 0) + 1;
        }
      }
    } catch (_) {
      // 单个文件读取出错，跳过继续
    }
  }

  try {
    indexFile.writeAsStringSync(jsonEncode(index));
  } catch (_) {
    // 写盘失败不阻塞调用方
  }
  return index;
}

// ==================== 后台 isolate worker（顶层函数，可被 Isolate.run 派发） ====================

/// P4：按 path 在 worker 内读取并解析导入文件（不整文件载入 UI 堆）。
String _extractImportContentFromPathWorker(Map<String, dynamic> args) {
  final path = args['path'] as String;
  final name = args['name'] as String;
  final raw = File(path).readAsBytesSync();
  return _extractImportContentWorker(raw, name);
}

/// 按年份统计真题语料中词库命中单词数与命中明细（年份从文件名 4 位前缀提取，
/// 对齐高考例句年份提取逻辑），供检测页"已导入语料"年份框展示与点击展开。
/// 返回 {'counts': {年份: 命中次数}, 'words': {年份: [{w,p,c}]}}；
/// 明细按小写单词去重（保留原大小写、词性与分类）并按单词字母序排列。
/// 目录不存在或无法识别年份的文件忽略。
Map<String, dynamic> _scanYearHitCountsWorker(Map<String, dynamic> args) {
  final dirPath = args['dirPath'] as String;
  final vocab = (args['vocab'] as Map).cast<String, Map<String, String>>();
  final yearRe = RegExp(r'^(\d{4})');
  final wordRe = RegExp(r"[a-zA-Z']+");
  final counts = <int, int>{};
  final hits = <int, Map<String, Map<String, String>>>{};
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return {'counts': counts, 'words': <int, List<Map<String, String>>>{}};
  }
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.txt')) continue;
    final m = yearRe.firstMatch(f.uri.pathSegments.last);
    if (m == null) continue;
    final year = int.tryParse(m.group(1)!);
    if (year == null) continue;
    String text;
    try {
      text = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    var count = 0;
    for (final wm in wordRe.allMatches(text)) {
      final raw = wm.group(0)!;
      final lower = raw.toLowerCase();
      final info = vocab[lower];
      if (info == null) continue;
      count++;
      hits
          .putIfAbsent(year, () => <String, Map<String, String>>{})[lower] = {
        'w': raw,
        'p': info['pos'] ?? '',
        'c': info['cat'] ?? '',
      };
    }
    counts[year] = (counts[year] ?? 0) + count;
  }
  final words = <int, List<Map<String, String>>>{};
  for (final entry in hits.entries) {
    final list = entry.value.values.toList()
      ..sort(
        (a, b) => (a['w'] ?? '')
            .toLowerCase()
            .compareTo((b['w'] ?? '').toLowerCase()),
      );
    words[entry.key] = list;
  }
  return {'counts': counts, 'words': words};
}

/// 统计 textbook 目录下各教材 txt 文件中词库命中单词数与命中明细
/// （键为教材文件名去扩展名），供检测页"已导入语料"教材格展示与点击展开。
/// 返回 {'counts': {教材名: 命中次数}, 'words': {教材名: [{w,p,c}]}}。
Map<String, dynamic> _scanTextbookHitCountsWorker(Map<String, dynamic> args) {
  final dirPath = args['dirPath'] as String;
  final vocab = (args['vocab'] as Map).cast<String, Map<String, String>>();
  final wordRe = RegExp(r"[a-zA-Z']+");
  final counts = <String, int>{};
  final hits = <String, Map<String, Map<String, String>>>{};
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return {'counts': counts, 'words': <String, List<Map<String, String>>>{}};
  }
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.txt')) continue;
    final fileName = f.uri.pathSegments.last;
    final dotIdx = fileName.lastIndexOf('.');
    final name = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;
    String text;
    try {
      text = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    var count = 0;
    for (final wm in wordRe.allMatches(text)) {
      final raw = wm.group(0)!;
      final lower = raw.toLowerCase();
      final info = vocab[lower];
      if (info == null) continue;
      count++;
      hits
          .putIfAbsent(name, () => <String, Map<String, String>>{})[lower] = {
        'w': raw,
        'p': info['pos'] ?? '',
        'c': info['cat'] ?? '',
      };
    }
    counts[name] = (counts[name] ?? 0) + count;
  }
  final words = <String, List<Map<String, String>>>{};
  for (final entry in hits.entries) {
    final list = entry.value.values.toList()
      ..sort(
        (a, b) => (a['w'] ?? '')
            .toLowerCase()
            .compareTo((b['w'] ?? '').toLowerCase()),
      );
    words[entry.key] = list;
  }
  return {'counts': counts, 'words': words};
}

/// 导入文件内容统一分流解析（isolate 版）：与 _extractImportContent 同逻辑，
/// 但全程不依赖插件（docx 走内存解压，不写临时文件），可安全在后台 isolate 执行。
String _extractImportContentWorker(List<int> raw, String name) {
  final lowerName = name.toLowerCase();
  final isZip = _isZipBytesTop(raw);
  final isOle = _isOleBytesTop(raw);
  if (lowerName.endsWith('.docx') || isZip) {
    try {
      return _readDocxContentBytes(raw);
    } catch (e) {
      if (isOle) {
        final t = extractDocText(raw);
        if (t.trim().isEmpty) throw Exception('暂不支持旧版 .doc 或内容为空，请转为 txt/docx');
        return t;
      }
      if (isZip) throw Exception('文件不是有效的 DOCX（ZIP 结构损坏）：$e');
      return _decodeTextBytesTop(raw);
    }
  }
  if (lowerName.endsWith('.doc') || isOle) {
    final t = extractDocText(raw);
    if (t.trim().isEmpty) throw Exception('暂不支持旧版 .doc 或内容为空，请转为 txt/docx');
    return t;
  }
  return _decodeTextBytesTop(raw);
}

bool _isZipBytesTop(List<int> b) =>
    b.length >= 4 &&
    b[0] == 0x50 && b[1] == 0x4B &&
    (b[2] == 0x03 || b[2] == 0x05 || b[2] == 0x07) &&
    b[3] == 0x04;

bool _isOleBytesTop(List<int> b) =>
    b.length >= 8 &&
    b[0] == 0xD0 && b[1] == 0xCF && b[2] == 0x11 && b[3] == 0xE0;

String _decodeTextBytesTop(List<int> raw) {
  try {
    final s = utf8.decode(raw);
    if (!s.contains('\uFFFD')) return s;
  } catch (e) {
    // 编码无法识别时回退 GBK 解码，仍失败则给出明确提示而非崩溃/乱码
  }
  try {
    return gbk.decode(raw);
  } catch (e) {
    throw Exception('文本编码无法识别，请转为 UTF-8 编码的 txt 文件');
  }
}

/// 从 DOCX bytes 内存解压提取纯文本（isolate 版，不写临时文件）。
String _readDocxContentBytes(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final f in archive) {
    if (f.name == 'word/document.xml') {
      final content = utf8.decode(f.content as List<int>);
      final document = XmlDocument.parse(content);
      final paragraphs = document.findAllElements('w:p');
      final lines = paragraphs.map((p) {
        final texts = p.findAllElements('w:t');
        return texts.map((t) => t.innerText).join('');
      }).where((line) => line.trim().isNotEmpty);
      return lines.join('\n');
    }
  }
  throw Exception('word/document.xml not found in docx');
}

/// 文本分析 worker：词频统计 + 课标/拓展/超标/专有分类 + 汉语标注词回溯计数。
/// 与 _AnalysisPageState._analyze 同逻辑，运行于后台 isolate，
/// 输入输出均为可发送的基础类型，避免大文本/大集合跨 isolate 拷贝后驻留 UI。
Map<String, dynamic> _analyzeTextWorker(Map<String, dynamic> args) {
  final text = args['text'] as String;
  final standard = (args['standard'] as List).cast<String>().toSet();
  final extend = (args['extend'] as List).cast<String>().toSet();
  final chaogang = (args['chaogang'] as List).cast<String>().toSet();
  final extra = (args['extra'] as List).cast<String>().toSet();
  final classMem = Map<String, String>.from(args['classMem'] as Map);

  final freqMap = <String, int>{};
  final caseMap = <String, String>{};

  // 剥离真题选项字母粘连（如 hostedB 还原为 hosted），与 Windows 导出侧 filterGluedRe 同款
  final gluedLetterRe = RegExp(r'^([a-zA-Z]{3,})([A-H])$');
  final wordRegex = RegExp(r'\b[a-zA-Z]{2,}\b');
  final digitsOnly = RegExp(r'^\d+$');
  for (final m in wordRegex.allMatches(text)) {
    final original = m.group(0)!;
    if (digitsOnly.hasMatch(original)) continue;
    var lower = original.toLowerCase();
    var display = original;
    final glued = gluedLetterRe.firstMatch(original);
    if (glued != null) {
      lower = glued.group(1)!.toLowerCase();
      display = glued.group(1)!;
    }
    freqMap[lower] = (freqMap[lower] ?? 0) + 1;
    if (!caseMap.containsKey(lower)) caseMap[lower] = display;
  }

  final words = freqMap.entries.map((e) {
    final lower = e.key;
    final original = caseMap[lower] ?? lower;
    String cat;
    if (classMem.containsKey(lower)) {
      cat = classMem[lower]!;
    } else if (standard.contains(lower)) {
      cat = '课标词';
    } else if (extend.contains(lower)) {
      cat = '拓展词';
    } else if (chaogang.contains(lower)) {
      cat = '超标词';
    } else if (extra.contains(lower)) {
      cat = '专有词';
    } else {
      cat = '其他';
    }
    return <String, dynamic>{
      'word': original,
      'frequency': e.value,
      'category': cat,
    };
  }).toList()
    ..sort((a, b) => (b['frequency'] as int).compareTo(a['frequency'] as int));

  final categoryCounts = <String, int>{};
  for (final w in words) {
    final c = w['category'] as String;
    categoryCounts[c] = (categoryCounts[c] ?? 0) + 1;
  }

  // 构建汉语标注词集合（统计用，仅计数不加色）
  // O(N) 实现：避免对全文反复 substring + firstMatch 造成 O(N^2) 卡顿
  final parenChineseRegex = RegExp(r'^\s*[\(（][^)）]*[\u4e00-\u9fa5]+[^)）]*[\)）]');
  final importedWordsLower = words
      .map((w) => (w['word'] as String).toLowerCase())
      .toSet();
  final annotatedPhrases = <String>{};
  bool isAsciiLetter(int u) =>
      (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
  bool isSep(int u) =>
      u == 0x20 || u == 0x09 || u == 0x2D; // 空格 / 制表 / 连字符
  for (final m in wordRegex.allMatches(text)) {
    final w = m.group(0)!;
    if (!importedWordsLower.contains(w.toLowerCase())) continue;
    if (parenChineseRegex.matchAsPrefix(text, m.end) == null) continue;
    int phraseStart = m.start;
    while (phraseStart > 0) {
      int p = phraseStart;
      while (p > 0 && isSep(text.codeUnitAt(p - 1))) {
        p--;
      }
      int q = p;
      while (q > 0 && isAsciiLetter(text.codeUnitAt(q - 1))) {
        q--;
      }
      if (q == p) break;
      final pw = text.substring(q, p);
      if (!importedWordsLower.contains(pw.toLowerCase())) break;
      phraseStart = q;
    }
    annotatedPhrases.add(text.substring(phraseStart, m.end).trim());
  }

  return {
    'words': words,
    'categoryCounts': categoryCounts,
    'annotatedCount': annotatedPhrases.length,
  };
}

// ==================== 导出后台 worker（1.5.7+14 隔离化） ====================
// 导出的文件生成 / 打包 / 写盘全部在此后台 isolate 中执行，UI 只等待结果。
// 策略：先在应用缓存目录生成（必定可写），成功后复制到用户所选目录；
// 复制失败（分区存储/SAF 无权限）时保留缓存副本并返回 warning 提示。

/// P2：导出表格数据后台构建（isolate 版）。
/// 输入纯 Map（text/words/realFreq/课标词三索引/教材与真题目录/dbPath），
/// 输出与 _exportTableDataToMap 同构的纯 Map。整体在独立 isolate 执行：
/// 同步读全量语料、逐词词典查询、例句索引构建均不占用 UI isolate；
/// 内部全捕获，异常时返回空表结构而非抛出，杜绝 isolate 崩溃冒泡。
/// 例句候选限容：每个目标词跨文件最多保留 6 条候选，避免小语料大量同词
/// 候选无限累积推高峰值。
/// TXT 导出：流式写盘（不产生全文副本）。
Future<void> _writeTxtExportWorker(
  String path,
  String text,
  List<Map<String, dynamic>> words,
  Map<String, int> categoryCounts,
  int annotatedCount,
  int totalRawCount,
  String fileName,
  Map<String, dynamic> exportData,
) async {
  final sink = File(path).openWrite();
  try {
    final ts = DateTime.now();
    sink.writeln('ESW 文本检测导出');
    sink.writeln('分析时间: ${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}');
    sink.writeln('文件名: $fileName');
    final cc = categoryCounts;
    sink.writeln('全套题词数： $totalRawCount | 去重总词数： ${words.length} | 课标词： ${cc['课标词'] ?? 0} | 拓展词： ${cc['拓展词'] ?? 0} | 超标词： ${cc['超标词'] ?? 0} | 专有词： ${cc['专有词'] ?? 0} | 其他: ${cc['其他'] ?? 0} | 汉语标注词: $annotatedCount');
    sink.writeln('');
    sink.writeln('=' * 64);
    sink.writeln('【标注说明】');
    sink.writeln('[课标词]：单词本身（无标记）');
    sink.writeln('{拓展词}：用花括号标记');
    sink.writeln('<超标词>：用尖括号标记');
    sink.writeln('(专有词)：用圆括号标记');
    sink.writeln('=' * 64);
    sink.writeln('');
    // 标注全文流式生成
    final catByLower2 = <String, String>{};
    for (final w in words) {
      catByLower2.putIfAbsent((w['word'] as String).toLowerCase(), () => w['category'] as String);
    }
    final aText = text;
    final aRe = RegExp(r'[a-zA-Z]+');
    int aEnd = 0;
    for (final m in aRe.allMatches(aText)) {
      final word = m.group(0)!;
      final cat = catByLower2[word.toLowerCase()];
      sink.write(aText.substring(aEnd, m.start));
      if (cat == null || cat == '课标词' || cat == '其他') {
        sink.write(word);
      } else if (cat == '拓展词') {
        sink.write('{$word}');
      } else if (cat == '超标词') {
        sink.write('<$word>');
      } else if (cat == '专有词') {
        sink.write('($word)');
      } else {
        sink.write(word);
      }
      aEnd = m.end;
    }
    sink.write(aText.substring(aEnd));
    sink.writeln('');
    sink.writeln('【拓展词明细】');
    sink.writeln(_buildExtendDetailPlainTop(exportData));
    sink.writeln('');
    sink.writeln('【超标词】');
    sink.writeln(_buildOverLimitPlainTop(exportData));
  } finally {
    await sink.close();
  }
}

/// DOCX 导出：源文件为 .docx 时优先原地标注（annotateDocxBytes），
/// 失败或非 docx 源则重建轻量 docx；全程后台执行并全捕获。
/// 源 docx 超过 15MB 直接跳过原地标注走重建：原地标注需全量解压 zip +
/// DOM + 序列化 + 重打包，多副本内存峰值随源文件增大线性攀升，是
/// 真机大文档 OOM 闪退的最可能根因；重建轻量 docx 内存可控。
String _buildExtendDetailPlainTop(Map<String, dynamic> exportData) {
  final sections = (exportData['extend'] as List).cast<Map<String, dynamic>>();
  if (sections.isEmpty) return '本套题无真题词频低于 400 次的拓展词';
  final sb = StringBuffer();
  var first = true;
  for (final sec in sections) {
    final items = (sec['items'] as List).cast<Map<String, dynamic>>();
    if (items.isEmpty) continue;
    if (!first) sb.writeln();
    first = false;
    sb.writeln(sec['name'] as String);
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final no = i + 1;
      sb.writeln('$no. ${it['word']}');
      sb.writeln('课标原词：${it['baseWord']}');
      sb.writeln('原文用法：${it['originalExample']}');
      final words = (it['word'] as String).split(' ');
      final gks = (it['gaokaoExamples'] as List).cast<Map<String, dynamic>>();
      if (gks.isEmpty) {
        sb.writeln('高考用法：');
      } else {
        for (final g in gks) {
          final prefix = words.length > 1 ? '高考用法·${g['word']}：' : '高考用法：';
          sb.writeln('$prefix${g['example']}${(g['year'] as String).isNotEmpty ? '（${g['year']}）' : ''}');
        }
      }
      sb.writeln('教材用法：${(it['textbookExample'] as String).isEmpty ? '无' : it['textbookExample']}');
    }
  }
  return sb.toString();
}

String _buildOverLimitPlainTop(Map<String, dynamic> exportData) {
  final sections = (exportData['overLimit'] as List).cast<Map<String, dynamic>>();
  if (sections.isEmpty) return '本套题未检测到超标词';
  final sb = StringBuffer();
  var first = true;
  for (final sec in sections) {
    final items = (sec['items'] as List).cast<Map<String, dynamic>>();
    if (items.isEmpty) continue;
    if (!first) sb.writeln();
    first = false;
    sb.writeln(sec['name'] as String);
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final no = i + 1;
      sb.writeln('$no. ${it['word']}');
      sb.writeln(it['posDef'] as String);
      sb.writeln(it['originalExample'] as String);
    }
  }
  return sb.toString();
}


