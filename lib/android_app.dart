import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle, Clipboard, ClipboardData;
import 'package:flutter/gestures.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'theme/app_theme.dart';
import 'shared/vocab_service.dart';
import 'shared/word_sync_service.dart';
import 'shared/doc_extractor.dart';
import 'shared/export_extra_table.dart';
import 'shared/base_word_candidates.dart';
import 'dictionary_service.dart';

/// 涓婃瀵煎嚭璺緞锛堟ā鍧楃骇璁板繂锛岄伩鍏嶆瘡娆￠噸鏂伴€夋嫨锛?
String? _lastExportPath;
String? _lastVocabExportPath;

final RegExp _controlCharRegex = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');
final RegExp _whitespaceRegex = RegExp(r'\s+');

class AndroidEswApp extends StatefulWidget {
  const AndroidEswApp({super.key});

  @override
  State<AndroidEswApp> createState() => _AndroidEswAppState();
}

class _AndroidEswAppState extends State<AndroidEswApp> {
  int _currentIndex = 0;
  final VocabService _vocab = VocabService();

  /// 文本检测嬪巻鍙茶褰?
  final List<_DetectHistory> _detectHistory = [];

  /// corpus 词频索引缓存（O(1) 查表，替代 getWordFrequency 全量扫描）
  Map<String, int>? _corpusIndex;
  bool _corpusIndexLoading = false;
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
    // 三项初始化相互独立，并行执行以缩短首屏等待
    await Future.wait([
      _vocab.loadStandardWords(),
      _extractCorpus(),
      _loadConfig(),
    ]);
    if (mounted) setState(() {});
  }

  Future<String> _getConfigPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/esw_android_config.json';
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e'), duration: const Duration(seconds: 4)),
        );
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
                        child: Text('全部拒绝（${rejectCount()}）', style: const TextStyle(fontSize: 12)),
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
                            style: const TextStyle(fontSize: 12),
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
                            if (ok) {
                              Navigator.pop(ctx, buildDecisions('accept'));
                            }
                          },
                          child: const Text('接收更新'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final ok = await confirmAction('拒绝更新', '将拒绝云端更新，保留本地状态，确认执行？');
                            if (ok) {
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
                            if (ok) {
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('检查更新失败(${resp.statusCode})')),
          );
        }
        return;
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final tagName = (json['tag_name'] as String?)?.replaceFirst('v', '') ?? '0.0.0';
      if (_compareVersions(tagName, '1.5.2') <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已是最新版本')),
          );
        }
        return;
      }
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现新版本'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('当前版本: 1.5.2'),
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
              const Text('(密码 52pj)', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('检查更新失败，请检查网络')),
        );
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

  Future<void> _extractCorpus() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final corpusDir = Directory('${dir.path}/corpus');
      final marker = File('${corpusDir.path}/.extracted');
      if (await marker.exists()) return;
      final bytes = await rootBundle.load('assets/corpus.zip');
      final buffer = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      final archive = ZipDecoder().decodeBytes(buffer);
      if (!await corpusDir.exists()) {
        await corpusDir.create(recursive: true);
      }
      for (final file in archive) {
        final filePath = '${corpusDir.path}/${file.name}';
        if (file.isFile) {
          final out = File(filePath);
          await out.create(recursive: true);
          await out.writeAsBytes(file.content as Uint8List);
        } else {
          await Directory(filePath).create(recursive: true);
        }
      }
      await marker.create(recursive: true);
    } catch (_) {}
  }

  /// 杩斿洖宸茶В鍘嬬殑鐪熼璇枡鐩綍璺緞锛堜笌 _extractCorpus 淇濇寔涓€鑷达級銆?
  Future<String> _corpusDirPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/corpus';
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
      backgroundColor: const Color(0xFFFFF8E1),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildSearchTab(),
          _buildImportTab(),
          _buildVocabTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFFFFF8E1),
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: '查词'),
          NavigationDestination(icon: Icon(Icons.file_open_outlined), selectedIcon: Icon(Icons.file_open), label: '检测'),
          NavigationDestination(icon: Icon(Icons.book_outlined), selectedIcon: Icon(Icons.book), label: '词库'),
        ],
      ),
    );
  }

  // ====== Tab 1: 词库姒傝 ======
  Widget _buildVocabTab() {
    return _VocabTabPage(
      vocab: _vocab,
      onSaveConfig: _saveConfig,
      showBaseWordDialog: _showBaseWordDialog,
      onSyncVocab: _syncVocab,
      onCheckUpdate: () => _checkUpdate(context),
      syncing: _syncing,
      wordSyncService: _wordSyncService,
      onWordTap: (word) {
        setState(() => _currentIndex = 0);
        _searchCtrl.text = word;
        _lookupWord(word);
      },
    );
  }

  // ====== Tab 2: 文本检测?======
  Widget _buildImportTab() {
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          const SliverAppBar(
            backgroundColor: Color(0xFFFFF8E1),
            title: Text('文本检测', style: TextStyle(fontWeight: FontWeight.bold)),
            centerTitle: true,
            pinned: true,
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    elevation: 0,
                    color: const Color(0xFFFFF8E1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Column(children: [
                              Text('真题库文件数：', style: const TextStyle(fontSize: 15, color: AppTheme.primaryBlue)),
                              Text('2005-2026，共计271套', style: const TextStyle(fontSize: 15, color: AppTheme.primaryBlue, fontWeight: FontWeight.w500)),
                            ]),
                          ),
                          const SizedBox(height: 8),
                          Text('检测文本后将自动与真题库和词库对比',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _importFile,
                    icon: const Icon(Icons.file_open),
                    label: const Text('选择文件检测'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pasteCtrl,
                    focusNode: _pasteFocus,
                    maxLines: 8,
                    minLines: 4,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: _pasteFocus.hasFocus ? null : '粘贴文本到这里',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: const Color(0xFFFFF8E1),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: () {
                      final text = _pasteCtrl.text.trim();
                      if (text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先粘贴文本')));
                        return;
                      }
                      _showAnalysisResult(text, '粘贴文本');
                    },
                    icon: const Icon(Icons.analytics_outlined),
                    label: const Text('开始分析'),
                    style: const ButtonStyle(
                      backgroundColor: WidgetStatePropertyAll(Color(0xFFFFF8E1)),
                      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('支持格式: .txt / .docx', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  const SizedBox(height: 28),
                  // 检测历史记录?
                  Row(
                    children: [
                      Expanded(
                        child: Center(child: Text('最近检测', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                      ),
                      if (_detectHistory.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.delete_sweep, size: 20),
                          tooltip: '清空历史',
                          onPressed: () {
                            setState(() => _detectHistory.clear());
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_detectHistory.isEmpty)
                    Text('暂无检测记录', style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
                  else
                    ..._detectHistory.map((h) {
                      final summary = h.categoryCounts.entries
                          .where((e) => e.value > 0)
                          .map((e) => '${e.key}${e.value}')
                          .join(' / ');
                      final annotatedPart = h.annotatedCount > 0 ? ' · 标注词${h.annotatedCount}' : '';
                      return Card(
                        elevation: 0,
                        color: const Color(0xFFFFF8E1),
                        margin: const EdgeInsets.only(bottom: 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        child: ListTile(
                          leading: const Icon(Icons.history, size: 20, color: AppTheme.textSecondary),
                          title: Text(h.fileName, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                          subtitle: Text(
                            '${_formatTime(h.time)} · ${h.totalWords}词${summary.isNotEmpty ? ' · $summary' : ''}$annotatedPart',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => _showAnalysisResult(h.text, h.fileName),
                          dense: true,
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${pad(t.month)}-${pad(t.day)} ${pad(t.hour)}:${pad(t.minute)}';
  }

  /// 瑙ｆ瀽 DOCX 鏂囦欢涓虹函鏂囨湰锛欴OCX 鏈川鏄?ZIP 鍖咃紝鍐呭惈 word/document.xml銆?
  Future<String> _readDocxContent(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
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

  Future<void> _importFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'doc', 'docx'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final lowerName = file.name.toLowerCase();
    String content;

    try {
      if (lowerName.endsWith('.doc')) {
        // 鏃х増 .doc 涓轰簩杩涘埗鏍煎紡锛屾棤娉曠洿鎺ヨВ鏋愶紝灏濊瘯鎻愬彇鍙鏂囨湰娈点€?
        if (file.bytes != null) {
          content = extractDocText(file.bytes!);
        } else if (file.path != null) {
          final raw = await File(file.path!).readAsBytes();
          content = extractDocText(raw);
        } else {
          throw Exception('无法读取文件内容');
        }
        if (content.trim().isEmpty) {
          throw Exception('暂不支持旧版 .doc，请转换专.docx 成.txt');
        }
      } else if (lowerName.endsWith('.docx')) {
        // DOCX 涓?ZIP 鍖咃紝瑙ｅ帇鍚庤В鏋?word/document.xml 鎻愬彇鏂囨湰
        if (file.path != null) {
          content = await _readDocxContent(file.path!);
        } else if (file.bytes != null) {
          final tmp = File('${(await getTemporaryDirectory()).path}/_import_${DateTime.now().microsecondsSinceEpoch}.docx');
          await tmp.writeAsBytes(file.bytes!);
          content = await _readDocxContent(tmp.path);
          await tmp.delete();
        } else {
          throw Exception('无法读取文件内容');
        }
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else {
        throw Exception('无法读取文件内容');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("文件读取失败: $e")),
        );
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
      _showAnalysisResult(content, file.name);
    }
  }

  Future<void> _showAnalysisResult(String text, String fileName) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
      builder: (_) => _AnalysisPage(
        text: text,
        fileName: fileName,
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
    // 杩斿洖鍚庢竻绌鸿緭鍏ユ
    _pasteCtrl.clear();
    if (result != null && mounted) {
      setState(() {
        _detectHistory.insert(0, _DetectHistory(
          fileName: result['fileName'] as String,
          time: DateTime.now(),
          totalWords: result['totalWords'] as int,
          categoryCounts: Map<String, int>.from(result['categoryCounts'] as Map),
          text: result['text'] as String,
          annotatedCount: result['annotatedCount'] as int? ?? 0,
        ));
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
  bool _hasFreq = false;

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
      child: SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: const Color(0xFFFFF8E1),
            title: const Text('真题查词', style: TextStyle(fontWeight: FontWeight.bold)),
            centerTitle: true,
            pinned: true,
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_query.isEmpty && _searchResult.isEmpty && _vocab.wordHistory.isEmpty)
                    const Spacer(flex: 3),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: _searchCtrl,
                        focusNode: _searchFocus,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16),
                        decoration: InputDecoration(
                          hintText: _searchFocus.hasFocus ? null : '输入英文单词',
                          hintStyle: const TextStyle(color: Colors.grey, fontSize: 15),
                          prefixIcon: const Padding(
                            padding: EdgeInsets.only(left: 12, right: 4),
                            child: Icon(Icons.search, color: Colors.grey, size: 22),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {
                                _query = '';
                                _searchResult = '';
                                _wordInfo = null;
                              });
                            },
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: const Color(0xFFFFF8E1),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        ),
                        onChanged: _onSearchChanged,
                        onSubmitted: (w) {
                          _searchDebounce?.cancel();
                          _lookupWord(w);
                        },
                        textInputAction: TextInputAction.search,
                      ),
                    ),
                  ),
                  if (_query.isEmpty && _searchResult.isEmpty && _vocab.wordHistory.isEmpty)
                    const Spacer(flex: 5),
                  if (_searchResult.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    _buildWordResult(),
                  ],
                  if (_query.isEmpty && _searchResult.isEmpty && _vocab.wordHistory.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: Center(child: Text('最近查询', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: AppTheme.textSecondary))),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_sweep, size: 20),
                          tooltip: '清除历史',
                          onPressed: () {
                            setState(() {
                              _vocab.wordHistory.clear();
                              _saveConfig();
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._vocab.wordHistory.map((w) => _HistoryTile(word: w, onTap: () {
                      _searchCtrl.text = w;
                      _query = w;
                      _lookupWord(w);
                    })),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) return;
    _searchDebounce = Timer(const Duration(seconds: 1), () {
      _lookupWord(value.trim());
    });
  }

  // 懒加载 corpus 词频索引（仅首次触发扫描，之后 O(1) 查表）
  Future<bool> _loadCorpusFreq(String word) async {
    if (_corpusIndex != null) {
      return (_corpusIndex![word.toLowerCase()] ?? 0) > 0;
    }
    if (_corpusIndexLoading) return false;
    _corpusIndexLoading = true;
    try {
      final corpusPath = await _corpusDirPath();
      final indexFile = File('$corpusPath/corpus_index.json');
      if (indexFile.existsSync()) {
        final json = await indexFile.readAsString();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        _corpusIndex = {for (final e in decoded.entries) e.key: (e.value as num).toInt()};
      }
    } catch (_) {
    } finally {
      _corpusIndexLoading = false;
    }
    return (_corpusIndex?[word.toLowerCase()] ?? 0) > 0;
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
      _hasFreq = false;
    });

    // 查 corpus 词频索引（O(1)，懒加载一次）
    _loadCorpusFreq(word).then((hasFreq) {
      if (mounted && _searchResult == word) {
        setState(() => _hasFreq = hasFreq);
      }
    });

    // 拓展词词形说明
    if (_vocab.isExtend(word)) {
      final base = _vocab.extendBaseMap[word] ?? _vocab.extendBaseMap[word.toLowerCase()];
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

  /// 寮瑰嚭鍏宠仈课标词嶅璇濇锛岀敤鎴烽€夋嫨鍩虹课标词嶅悗娣诲姞涓烘嫇灞曡瘝銆?
  /// [onAdded] 鍦ㄦ坊鍔犲畬鎴愬悗锛堟棤璁烘槸鍚﹀叧鑱旓級鍥炶皟銆?
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

    // 缁熶竴璁＄畻鍒嗙被鏍囩涓庨鑹?
    String? categoryLabel;
    Color labelColor = categoryColor;
    if (isStandard) {
      // 课标词嶅垎绫绘爣绛剧粺涓€鍔?课标词?鍚庣紑锛岀敤鍖呭惈鍒ゆ柇瑕嗙洊鎵€鏈夊垎绫诲€?
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
      color: const Color(0xFFFFF8E1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                    borderRadius: BorderRadius.circular(4),
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
                      style: const TextStyle(fontSize: 15, fontFamily: 'monospace', color: Color(0xFF0066CC)),
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
                color: Color(0xFFB20000),
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
                              color: Color(0xFF0000FF),
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
                  style: const TextStyle(fontSize: 13, color: Color(0xFF008080)),
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
        color: const Color(0xFFFFD700),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已重新归类为：$targetCategory')),
        );
      }
    }
  }


  /// 真题词频鍖哄煙锛氫粠 corpus 鐩綍缁熻褰撳墠鏌ヨ鍗曡瘝鐨勫嚭鐜版鏁颁笌閫愬勾鍒嗗竷銆?
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
                style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
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
                    borderRadius: BorderRadius.circular(12),
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
                  final offset = (s['offset'] as num).toInt() ?? 0;
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

  /// 灏嗗彞瀛愪腑鍖归厤 [word] 鐨勯儴鍒嗙敤榛勮壊鑳屾櫙 + 鍔犵矖楂樹寒鏄剧ず锛屽叧閿瘝鍙暱鎸夊脊鍑鸿彍鍗曘€?
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

  /// 闀挎寜鍏抽敭璇嶅脊鍑虹殑鑿滃崟锛氬鍒?/ 鍏ㄩ€?/ 打开真题銆?
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
                // 鍦ㄥ綋鍓嶈瘝棰戠粨鏋滀腑鏌ユ壘鍖归厤璇ュ叧閿瘝鐨勭湡棰樻潯鐩苟璺宠测
                final data = _lastFreqData;
                if (data != null) {
                  final byYear = data['byYear'] as Map<String, dynamic>? ?? {};
                  for (final entry in byYear.entries) {
                    final sentences = (entry.value as List).cast<Map<String, dynamic>>();
                    for (final s in sentences) {
                      final text = s['text'] as String? ?? '';
                      if (text.toLowerCase().contains(word.toLowerCase())) {
                        final filePath = s['filePath'] as String? ?? '';
                        final offset = (s['offset'] as num).toInt() ?? 0;
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('未找到对应真题')),
                );
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
  int _highlightStart = -1;
  int _highlightEnd = -1;
  SelectedContent? _selectedContent;

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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('真题文件不存在：\${widget.filePath}')),
          );
        }
        _content = '真题文件不存在：\${widget.filePath}';
        if (mounted) setState(() => _loading = false);
        return;
      }
      final text = await file.readAsString();
      _content = text;
      // 璁＄畻鍏抽敭璇嶅湪鍘熸枃涓殑瀛楃鑼冨洿
      final pattern = RegExp(r'\b' + RegExp.escape(widget.keyword) + r'\b', caseSensitive: false);
      final m = pattern.firstMatch(text);
      if (m != null) {
        _highlightStart = m.start;
        _highlightEnd = m.end;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取真题失败：\$e')),
        );
      }
      _content = '无法读取真题文件：\${widget.filePath}';
    }
    if (mounted) {
      setState(() => _loading = false);
      // 绛夊緟甯冨眬完成鍚庢粴鍔ㄥ埌鍏抽敭璇嶄綅缃?
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients && _highlightStart >= 0) {
          // 浼扮畻婊氬姩浣嶇疆锛氭寜瀛楃鏁扮矖鐣ユ槧灏勫埌婊氬姩鍋忕В
          final total = _content.length;
          final maxScroll = _scrollController.position.maxScrollExtent;
          final ratio = _highlightStart / total;
          final target = (ratio * maxScroll).clamp(0.0, maxScroll);
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  /// 构建正文 TextSpan：每个英文单词独立可点击，keyword 高亮」
  /// 构建正文 TextSpan：仅 keyword 拆为高亮 span，其余整段保留，
  /// 避免逐词拆分导致大量 span 造成卡顿；点击命中由 GestureDetector 统一处理」
  List<TextSpan> _buildSpans() {
    if (_content.isEmpty) return const [];
    final keyword = widget.keyword;
    if (keyword.isEmpty) return [TextSpan(text: _content)];
    // 直接定位目标关键词（预编译局部正则），避免逐词扫描全文导致长文档卡顿
    final pattern = RegExp(r'\b' + RegExp.escape(keyword) + r'\b', caseSensitive: false);
    final matches = pattern.allMatches(_content).toList();
    if (matches.isEmpty) return [TextSpan(text: _content)];
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: _content.substring(cursor, m.start)));
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
    if (cursor < _content.length) {
      spans.add(TextSpan(text: _content.substring(cursor)));
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已复制 $word')),
            );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$newWord 不是合法的英文单词')),
      );
      return;
    }
    final replaced = _content.replaceAllMapped(
      RegExp('\\b${RegExp.escape(oldWord)}\\b', caseSensitive: false),
      (_) => newWord,
    );
    if (replaced == _content) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文本中未找到 $oldWord')),
      );
      return;
    }
    try {
      await File(widget.filePath).writeAsString(replaced);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('写入真题文件失败 $e')),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _content = replaced;
      // 重新定位新词高亮范围
      final pattern = RegExp(r'\b' + RegExp.escape(newWord) + r'\b', caseSensitive: false);
      final m = pattern.firstMatch(_content);
      _highlightStart = m?.start ?? -1;
      _highlightEnd = m?.end ?? -1;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已将真题文件中 $oldWord 改为 $newWord')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.filePath.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8E1),
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                child: SelectionArea(
                  onSelectionChanged: (content) => _selectedContent = content,
                  contextMenuBuilder: _buildWordContextMenu,
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 15, height: 1.6, color: Colors.black87),
                      children: _buildSpans(),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// 缁熻鍗＄墖
class _StatCard extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final VoidCallback? onTap;

  const _StatCard({required this.label, required this.count, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final card = Card(
      elevation: 0,
      color: color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('$count', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: card,
    );
  }
}

/// 文本检测嬪巻鍙茶褰曢」
class _DetectHistory {
  final String fileName;
  final DateTime time;
  final int totalWords;
  final Map<String, int> categoryCounts;
  final String text;
  final int annotatedCount;

  _DetectHistory({
    required this.fileName,
    required this.time,
    required this.totalWords,
    required this.categoryCounts,
    required this.text,
    required this.annotatedCount,
  });
}

class _HistoryTile extends StatelessWidget {
  final String word;
  final VoidCallback onTap;

  const _HistoryTile({required this.word, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: const Color(0xFFFFF8E1),
      margin: const EdgeInsets.only(bottom: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        leading: const Icon(Icons.history, size: 20, color: AppTheme.textSecondary),
        title: Text(word, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: onTap,
        dense: true,
      ),
    );
  }
}

class _AnalysisPage extends StatefulWidget {
  final String text;
  final String fileName;
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final ValueChanged<String>? onWordTap;
  final WordSyncService wordSyncService;
  final String userId;

  const _AnalysisPage({required this.text, required this.fileName, required this.vocab, required this.onSaveConfig, this.onWordTap, required this.wordSyncService, required this.userId});

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
  String _lastClassificationTime = '';
  late String _text;

  final Map<String, int?> _realFreq = {};
  bool _freqLoading = false;

  static final RegExp _wordRegex = RegExp(r'\b[a-zA-Z]{2,}\b');
  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _analyze();
  }

  void _analyze() {
    final freqMap = <String, int>{};
    final caseMap = <String, String>{};

    for (final m in _wordRegex.allMatches(widget.text)) {
      final original = m.group(0)!;
      if (_digitsOnly.hasMatch(original)) continue;
      final lower = original.toLowerCase();
      freqMap[lower] = (freqMap[lower] ?? 0) + 1;
      if (!caseMap.containsKey(lower)) caseMap[lower] = original;
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
    final _parenChineseRegex = RegExp(r'^\s*[\(（][^)）]*[\u4e00-\u9fa5]+[^)）]*[\)）]');
    final _importedWordsLower = _words.map((aw) => aw.word.toLowerCase()).toSet();
    final annotatedPhrases = <String>{};
    final wordPattern = RegExp(r'\b[a-zA-Z]{2,}\b');
    bool isAsciiLetter(int u) =>
        (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
    bool isSep(int u) =>
        u == 0x20 || u == 0x09 || u == 0x2D; // 空格 / 制表 / 连字符
    // 用 allMatches 遍历所有词（替代逐位指针推进，避免 O(N^2) 与跨行跳词）
    for (final m in wordPattern.allMatches(_text)) {
      final w = m.group(0)!;
      if (!_importedWordsLower.contains(w.toLowerCase())) { continue; }
      // 直接从原文本 m.end 处匹配中文注解，避免创建 O(N) 子串
      if (_parenChineseRegex.matchAsPrefix(_text, m.end) == null) continue;
      // 向前回溯合并短语：跳过空白连字符，取前面一段连续字母作为前一词
      int phraseStart = m.start;
      while (phraseStart > 0) {
        int p = phraseStart;
        while (p > 0 && isSep(_text.codeUnitAt(p - 1))) p--;
        int q = p;
        while (q > 0 && isAsciiLetter(_text.codeUnitAt(q - 1))) q--;
        if (q == p) break; // 前方不是单词，停止回溯
        final pw = _text.substring(q, p);
        if (!_importedWordsLower.contains(pw.toLowerCase())) break;
        phraseStart = q;
      }
      annotatedPhrases.add(widget.text.substring(phraseStart, m.end).trim());
    }
    _annotatedCount = annotatedPhrases.length;
    // 寮傛鑾峰彇真题词频锛堜笉闃诲鍒嗘瀽涓绘祦绋嬶級
    _loadRealFreq();
    _rebuildFiltered();
  }

  /// 鑾峰彇鐪熼璇枡搴撶洰褰曡矾寰勶紙搴旂敤鏂囨。鐩綍涓嬬殑 corpus 瀛愮洰褰曪級銆?
  Future<String> _corpusDirPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/corpus';
  }

  /// 浠?corpus 鍏ㄩ噺绱㈠紩锛坈orpus_index.json锛夋煡琛ㄨ幏鍙栨瘡涓凡璇嗗埆璇嶇殑鐪熼鍑虹幇娆℃暟銆?
  /// 绱㈠紩棣栨鏋勫缓鏃舵壂鎻忓叏閮?txt 骞跺啓鍏ョ鐩橈紝鍚庣画鐩存帴璇诲唴瀛?Map锛屾绉掔骇鍝嶅簲銆?
  Future<void> _loadRealFreq() async {
    if (mounted) setState(() => _freqLoading = true);
    try {
      final corpusPath = await _corpusDirPath();
      final index = await _loadCorpusIndex(corpusPath);
      for (final aw in _words) {
        _realFreq[aw.word.toLowerCase()] = index[aw.word.toLowerCase()] ?? 0;
      }
    } catch (_) {
      // 词频查询澶辫触涓嶅奖鍝嶄富娴佺▼
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
      'text': widget.text,
      'annotatedCount': _annotatedCount,
    };
  }

  void _popWithResult() {
    Navigator.of(context).pop(_buildResult());
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popWithResult();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFFFF8E1),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFF8E1),
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
                ? Center(child: Text('暂无 ${_filter == '全部' ? '单词' : _filter}', style: TextStyle(color: Colors.grey.shade400)))
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
                                borderRadius: BorderRadius.circular(4),
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
                                    borderRadius: BorderRadius.circular(10),
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
                color: const Color(0xFFFFF8E1),
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


  /// 寮瑰嚭鍏宠仈课标词嶅璇濇锛岀敤鎴烽€夋嫨鍩虹课标词嶅悗娣诲姞涓烘嫇灞曡瘝銆?
  /// 寮瑰嚭鏃舵牴鎹娣诲姞鍗曡瘝鑷姩鎼滅储骞舵帓搴忓尮閰嶈鏍囪瘝銆?
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
                        fillColor: Color(0xFFFFF8E1),
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
                        // 鍥炶溅涓斿彧鏈変竴涓畬鍏ㄥ尮閰嶆椂鑷姩閫夋嫨骞跺叧闂?
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
                        fillColor: Color(0xFFFFF8E1),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('所有待筛选单词已处理完毕')),
          );
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
                                fillColor: Color(0xFFFFF8E1),
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

      // 分类计数实时更新 + 时间戳精确到秒
      final now = DateTime.now();
      _lastClassificationTime = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      widget.onSaveConfig();
      _analyze();
    }

    if (mounted) setState(() {});
  }


  String _buildAnnotatedText() {
    final catByLower = <String, String>{};
    for (final w in _words) {
      catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
    }

    final buffer = StringBuffer();
    final text = widget.text;
    final regex = RegExp(r'[a-zA-Z]+');
    int lastEnd = 0;
    for (final m in regex.allMatches(text)) {
      final word = m.group(0)!;
      final cat = catByLower[word.toLowerCase()];
      buffer.write(text.substring(lastEnd, m.start));
      if (cat == null || cat == '课标词' || cat == '其他') {
        buffer.write(word);
      } else if (cat == '拓展词') {
        buffer.write('{$word}');
      } else if (cat == '超标词') {
        buffer.write('<$word>');
      } else if (cat == '专有词') {
        buffer.write('($word)');
      } else {
        buffer.write(word);
      }
      lastEnd = m.end;
    }
    buffer.write(text.substring(lastEnd));
    return buffer.toString();
  }

  /// 瀵煎嚭鍒嗘瀽缁撴灉锛氬厛璁╃敤鎴烽€夋嫨 TXT 鎴?DOCX 鏍煎紡锛屽啀鐢熸垚鏂囦欢銆?
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

    try {
      final dir = await _pickExportDir(context, isVocab: false);
      final exportDir = dir;
      final ts = DateTime.now();
      final stamp = '${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}'
          '_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}${ts.second.toString().padLeft(2, '0')}';

      final totalRawCount = _words.fold<int>(0, (sum, w) => sum + w.frequency);
      if (choice == 'txt') {
        final path = '${exportDir.path}/analysis_$stamp.txt';
        final buffer = StringBuffer();
        buffer.writeln('ESW 文本检测导出');
        buffer.writeln('分析时间: ${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}');
        buffer.writeln('文件名: ${widget.fileName}');
        final cc = _categoryCounts;
        buffer.writeln('全套题词数： $totalRawCount | 去重总词数： ${_words.length} | 课标词： ${cc['课标词'] ?? 0} | 拓展词： ${cc['拓展词'] ?? 0} | 超标词： ${cc['超标词'] ?? 0} | 专有词： ${cc['专有词'] ?? 0} | 其他: ${cc['其他'] ?? 0} | 汉语标注词: $_annotatedCount');
        buffer.writeln('');
        buffer.writeln('=' * 64);
        buffer.writeln('【标注说明】');
        buffer.writeln('[课标词]：单词本身（无标记）');
        buffer.writeln('{拓展词}：用花括号标记');
        buffer.writeln('<超标词>：用尖括号标记');
        buffer.writeln('(专有词)：用圆括号标记');
        buffer.writeln('=' * 64);
        buffer.writeln('');
        buffer.writeln(_buildAnnotatedText());
        buffer.writeln('');
        buffer.writeln(buildExtendTableText(_buildExtendSections()));
        await File(path).writeAsString(buffer.toString());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出至: $path')));
        }
      } else {
        final path = '${exportDir.path}/analysis_$stamp.docx';
        await _exportDocx(path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出至: $path')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  /// 鐢熸垚 DOCX 鏂囨。锛氬惈带标注全文囷紙鎸夊垎绫荤潃鑹诧級+ 鍒嗙被璇嶆眹琛ㄣ€?
  /// DOCX 鏈川鏄?ZIP 鍖咃紝鍐呭惈 OOXML銆傝繖閲岀敤 archive 鍖呮墜鍐欐渶灏忓彲鐢ㄦ枃妗ｃ€?
  /// 构建拓展词按题型分组的明细（导出表格用）」
  List<ExtendSection> _buildExtendSections() {
    final extendWords = _words
        .where((w) => w.category == '拓展词')
        .map((w) => w.word)
        .toList();
    return buildExtendSections(
      text: _text,
      extendWords: extendWords,
      baseWordOf: (w) {
        // 优先取用户筛选拓展词时手动关联的课标词（extendBaseMap），保证导出列表课标词列非空
        final linked = widget.vocab.extendBaseMap[w] ?? widget.vocab.extendBaseMap[w.toLowerCase()];
        if (linked != null && linked.isNotEmpty) return linked;
        final b = widget.vocab.extendReverseIndex[w.toLowerCase()];
        if (b == null) {
          // 词本身是课标词（如 discussing 还原后的 discuss）时直接返回
          final ms2 = widget.vocab.standardWordsLower[w.toLowerCase()];
          return (ms2 != null && ms2.isNotEmpty) ? ms2.first : '';
        }
        final ms = widget.vocab.standardWordsLower[b];
        return (ms != null && ms.isNotEmpty) ? ms.first : b;
      },
    );
  }

  Future<void> _exportDocx(String path) async {
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('ESW 文本检测导出', heading: 1));
    bodyParts.add(_docxParagraph('文件名: ${widget.fileName}'));
    final cc = _categoryCounts;
    final docxTotalRawCount = _words.fold<int>(0, (sum, w) => sum + w.frequency);
    bodyParts.add(_docxParagraph('全套题词数: $docxTotalRawCount | 去重总词数: ${_words.length} | 课标词: ${cc['课标词'] ?? 0} | 拓展词: ${cc['拓展词'] ?? 0} | 超标词: ${cc['超标词'] ?? 0} | 专有词: ${cc['专有词'] ?? 0} | 其他: ${cc['其他'] ?? 0} | 汉语标注词: $_annotatedCount'));
    bodyParts.add(_docxParagraph('【标注说明】', heading: 2));
    bodyParts.add(_docxParagraph('课标词：黑色（无标记）；拓展词：绿色；超标词：红色；专有词：灰色'));
    bodyParts.add(_docxParagraph('带标注全文', heading: 2));
    bodyParts.add(_docxAnnotatedParagraph());
    bodyParts.add(_docxParagraph('拓展词明细（按题型）', heading: 2));
    bodyParts.add(buildExtendTableXml(_buildExtendSections()));

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

  /// 鐢熸垚鍗曚釜 DOCX 娈佃惤 XML銆?
  String _docxParagraph(String text, {int? heading}) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final runs = '<w:r><w:t xml:space="preserve">$escaped</w:t></w:r>';
    final style = heading != null ? ' w:val="Heading$heading"' : '';
    return '<w:p><w:pPr><w:pStyle$style/></w:pPr>$runs</w:p>';
  }

  /// 鐢熸垚带标注全文囩殑 DOCX 娈佃惤锛氭寜鍒嗙被鐢ㄤ笉鍚岄鑹?run 鐫€鑹层€?
  String _docxAnnotatedParagraph() {
    final catByLower = <String, String>{};
    for (final w in _words) {
      catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
    }
    // 鍒嗙被 -> 鍗佸叚杩涘埗棰滆壊锛堟棤 # 鍓嶇紑锛?
    String colorOf(String cat) {
      switch (cat) {
        case '拓展词': return '2E7D32';
        case '超标词': return 'C62828';
        case '专有词': return '616161';
        default: return '000000';
      }
    }

    final text = widget.text;
    final regex = RegExp(r'[a-zA-Z]+');
    final runs = <String>[];
    int lastEnd = 0;
    for (final m in regex.allMatches(text)) {
      final word = m.group(0)!;
      final cat = catByLower[word.toLowerCase()];
      final plain = text.substring(lastEnd, m.start);
      if (plain.isNotEmpty) {
        runs.add(_docxRun(plain, '000000'));
      }
      if (cat == null || cat == '课标词' || cat == '其他') {
        runs.add(_docxRun(word, '000000'));
      } else {
        runs.add(_docxRun(word, colorOf(cat), highlight: cat == '超标词' ? 'yellow' : null));
      }
      lastEnd = m.end;
    }
    final tail = text.substring(lastEnd);
    if (tail.isNotEmpty) runs.add(_docxRun(tail, '000000'));
    return '<w:p>${runs.join('')}</w:p>';
  }

  /// 鐢熸垚鍗曚釜 DOCX run锛堝甫棰滆壊锛夈€?
  String _docxRun(String text, String color, {String? highlight}) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final hl = highlight != null ? '<w:highlight w:val="$highlight"/>' : '';
    return '<w:r><w:rPr><w:color w:val="$color"/>$hl</w:rPr>'
           '<w:t xml:space="preserve">$escaped</w:t></w:r>';
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$newWord 不是合法的英文单词')),
      );
      return;
    }
    final replaced = _text.replaceAllMapped(
      RegExp('\\b${RegExp.escape(oldWord)}\\b', caseSensitive: false),
      (_) => newWord,
    );
    if (replaced == _text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文本中未找到 $oldWord')),
      );
      return;
    }
    setState(() => _text = replaced);
    _analyze();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将真题文本中 $oldWord 改为 $newWord')),
      );
    }
  }

  void _openSourcePopup(String keyword) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SourcePopupViewer(
        text: widget.text,
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

  late final List<String> _lines;
  late final Map<String, String> _catByLower;
  late final String _lowerKey;
  late final int _targetLine;
  GlobalKey? _targetKey;
  SelectedContent? _selectedContent;
  late String _text;

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _lowerKey = widget.keyword.toLowerCase();
    _lines = widget.text.split('\n');

    _catByLower = <String, String>{};
    for (final w in widget.words) {
      _catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
    }

    _targetLine = _locateTargetLine();

    if (_targetLine != -1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _positionToTarget());
    }
  }

  int _locateTargetLine() {
    for (int i = 0; i < _lines.length; i++) {
      for (final m in _wordRegex.allMatches(_lines[i].toLowerCase())) {
        if (m.group(0) == _lowerKey) return i;
      }
    }
    return -1;
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _positionToTarget() {
    final ctx = _targetKey?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.15,
      duration: Duration.zero,
    );
  }

  Widget _buildLine(int index, String line) {
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
      return Text(line, style: const TextStyle(fontSize: _fontSize, color: Colors.black87));
    }

    return Text.rich(
      TextSpan(
        style: const TextStyle(fontSize: _fontSize, color: Colors.black87),
        children: spans,
      ),
    );
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已复制 $word')),
            );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$newWord 不是合法的英文单词')),
        );
      }
      return;
    }
    final replaced = _text.replaceAllMapped(
      RegExp('\\b${RegExp.escape(oldWord)}\\b', caseSensitive: false),
      (_) => newWord,
    );
    if (replaced == _text) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文本中未找到 $oldWord')),
        );
      }
      return;
    }
    setState(() {
      _text = replaced;
      _lines
        ..clear()
        ..addAll(_text.split('\n'));
      _catByLower.clear();
      for (final w in widget.words) {
        _catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
      }
      _targetLine = _locateTargetLine();
    });
    widget.onTextChanged(_text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将原文中 $oldWord 改为 $newWord')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8E1),
      appBar: AppBar(
        title: Text('"${widget.keyword}" 在原文中的位置'),
        titleTextStyle: const TextStyle(fontSize: 16, color: Colors.white),
        backgroundColor: AppTheme.primaryBlue,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        controller: _scrollCtrl,
        padding: const EdgeInsets.all(16),
        child: SelectionArea(
          onSelectionChanged: (content) => _selectedContent = content,
          contextMenuBuilder: _buildWordContextMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(_lines.length, (i) => Padding(
            key: i == _targetLine ? (_targetKey ??= GlobalKey()) : null,
            padding: const EdgeInsets.only(bottom: 2),
            child: _buildLine(i, _lines[i]),
          )),
        ),
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

/// 鑾峰彇瀵煎嚭鐩爞鐩綍锛氫紭鍏堜娇鐢ㄥ閮ㄥ瓨鍌?Download 鐩綍锛屽け璐ュ洖閫€鍒板簲鐢ㄦ枃妗ｇ洰褰曘€?
Future<Directory> _downloadDir() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      // ext.path 褰㈠ /storage/emulated/0/Android/data/com.exam.esw/files
      // 闇€寰€涓婁袱绾у基/storage/emulated/0锛屽啀杩涘叆绯荤粺 Download 鐩綍
final download = Directory('${ext.path}/../../Download');
      if (!await download.exists()) {
        await download.create(recursive: true);
      }
      // 鍦?Download 涓嬪垱寤?esw_exports 瀛愮洰褰曠粍缁囧鍑烘枃浠?
      final eswDir = Directory('${download.path}/esw_exports');
      if (!await eswDir.exists()) {
        await eswDir.create(recursive: true);
      }
      return eswDir;
    }
  } catch (_) {
    // 蹇界暐锛屽洖閫€鍒板簲鐢ㄦ枃妗ｇ洰褰?
  }
  final dir = await getApplicationDocumentsDirectory();
  return dir;
}

/// 閫夋嫨瀵煎嚭鐩綍锛氱洿鎺ュ脊鍑虹郴缁熺洰褰曢€夋嫨鍣紝閫夋嫨鍚庤蹇嗚矾寰勩€?
/// 鐢ㄦ埛鍙栨秷閫夋嫨鏃讹紝鑻ユ湁璁板繂璺緞鍒欎娇鐢ㄨ蹇嗚矾寰勶紝鍚﹀垯鍥為€€鍒伴粯璁?Download/esw_exports銆?
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

  // 鐢ㄦ埛鍙栨秷锛岃嫢鏈夎蹇嗚矾寰勫垯浣跨敤
  final remembered = isVocab ? _lastVocabExportPath : _lastExportPath;
  if (remembered != null && remembered.isNotEmpty) {
    final dir = Directory(remembered);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // 閮芥病鏈夊垯鍥為€€榛樿 Download
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



/// 词库椤碉細鎼滅储妗'+ 鍥涚被璇嶆暟鍗＄墖 + 瀵煎叆瀵煎嚭鎸夐挳
/// 使用说明椤?
class _HelpItem {
  final IconData icon;
  final String title;
  final String content;

  const _HelpItem({
    required this.icon,
    required this.title,
    required this.content,
  });
}

class _HelpPage extends StatelessWidget {
  const _HelpPage();

  @override
  Widget build(BuildContext context) {
    final items = [
      _HelpItem(
        icon: Icons.description,
        title: '文档导入',
        content: '点击「文档导入」按钮，选择 TXT/DOCX/PDF 等格式文件，系统自动提取英文文本、分词并分析各词类覆盖占比。',
      ),
      _HelpItem(
        icon: Icons.search,
        title: '单词搜索',
        content: '在搜索框输入单词后回车，即可查看课标释义、词性、真题频次及历年分布，同时展示真题例句。支持历史搜索记录快速回查。',
      ),
      _HelpItem(
        icon: Icons.category,
        title: '词库分类',
        content: '单词按课标要求分为「课标词」「拓展词」「超标词」「专有词」四类，可手动调整分类，自动记忆跨平台导入的分类选择。',
      ),
      _HelpItem(
        icon: Icons.save_alt,
        title: '导出结果',
        content: '点击「导出结果」按钮，将当前分析结果导出为 Word 文档（.docx），不同词类以不同颜色高亮标注并附带分类统计汇总表。',
      ),
      _HelpItem(
        icon: Icons.sync,
        title: '同步词库',
        content: '点击「同步词库」可将本地积累的分类词库上传至坚果云云端，也可从云端拉取他人共享的词库，实现多人协作共享。',
      ),
      _HelpItem(
        icon: Icons.system_update,
        title: '检查更新',
        content: '点击「检查更新」，自动检测最新版本，支持跳转 GitHub Releases 或蓝奏云（密码 52pj）下载更新。',
      ),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFFFF8E1),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFF8E1),
        title: const Text('使用说明', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (_, i) {
          final item = items[i];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 1,
            color: const Color(0xFFFFF8E1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(item.icon, size: 28, color: Colors.blue.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.content,
                          style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.5),
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
  }
}

class _VocabTabPage extends StatefulWidget {
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final Future<void> Function(String word, VoidCallback onAdded) showBaseWordDialog;
  final ValueChanged<String>? onWordTap;
  final VoidCallback onSyncVocab;
  final VoidCallback onCheckUpdate;
  final bool syncing;
  final WordSyncService wordSyncService;

  const _VocabTabPage({required this.vocab, required this.onSaveConfig, required this.showBaseWordDialog, this.onWordTap, required this.onSyncVocab, required this.onCheckUpdate, required this.syncing, required this.wordSyncService});

  @override
  State<_VocabTabPage> createState() => _VocabTabPageState();
}

class _VocabTabPageState extends State<_VocabTabPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 鍚堝苟全部词库鍗曡瘝锛岃繑鍥'{word: category}銆?
  Map<String, String> _allWordsWithCategory() {
    final map = <String, String>{};
    for (final w in widget.vocab.standardWords.keys) {
      map[w] = '课标词';
    }
    for (final w in widget.vocab.extendWords) {
      map[w] = '拓展词';
    }
    for (final w in widget.vocab.manualChaoGangWords) {
      map[w] = '超标词';
    }
    for (final w in widget.vocab.manualExtraWords) {
      map[w] = '专有词';
    }
    return map;
  }

  Color _catColor(String cat) {
    switch (cat) {
      case '课标词': return AppTheme.primaryBlue;
      case '拓展词': return AppTheme.green;
      case '超标词': return AppTheme.red;
      case '专有词': return AppTheme.grey;
      default: return AppTheme.orange;
    }
  }

  /// 鎵撳紑鏌愮被词库璇︽儏椤?
  void _openWordList(String category) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _WordListPage(
        category: category,
        vocab: widget.vocab,
        onSaveConfig: widget.onSaveConfig,
        showBaseWordDialog: widget.showBaseWordDialog,
        wordSyncService: widget.wordSyncService,
        onWordTap: widget.onWordTap,
      ),
    ));
  }

  /// 导出词库涓?JSON 澶囦唤鍒颁笅杞界洰褰曘€?
  Future<void> _exportVocab() async {
    if (!mounted) return;
    try {
      final dir = await _pickExportDir(context, isVocab: true);
      final backupDir = dir;
      final now = DateTime.now();
      final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final path = '${backupDir.path}/esw_vocab_backup_$dateStr.json';
      final data = widget.vocab.toJson();
      await File(path).writeAsString(jsonEncode(data));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('词库已导出: $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  /// 浠?JSON 鏂囦欢导入词库锛岃拷鍔犲悎骞讹紙涓嶈鐩栧凡鏈夛級銆?
  Future<void> _importVocab() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final content = file.path != null
          ? await File(file.path!).readAsString()
          : utf8.decode(file.bytes!);
      final json = jsonDecode(content) as Map<String, dynamic>;
      widget.vocab.mergeFromJson(json);
      widget.onSaveConfig();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('词库导入完成（已合并）')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalStandard = widget.vocab.standardWords.length;
    final totalExtend = widget.vocab.extendWords.length;
    final totalChaoGang = widget.vocab.manualChaoGangWords.length;
    final totalExtra = widget.vocab.manualExtraWords.length;

    final allMap = _allWordsWithCategory();
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? <MapEntry<String, String>>[]
        : allMap.entries.where((e) => e.key.toLowerCase().contains(q)).toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return SafeArea(
      child: Column(
        children: [
          // 涓诲唴瀹瑰尯鍩燂紙鍗犳弧鍓╀綑绌洪棿锛屽彲婊氬姩锛?
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  backgroundColor: const Color(0xFFFFF8E1),
                  title: const Text('ESW词库', style: TextStyle(fontWeight: FontWeight.bold)),
                  centerTitle: true,
                  pinned: true,
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  const SizedBox(height: 20),
                  // 鎼滅储妗?
                  TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: _searchFocus.hasFocus ? null : '搜索已积累的词库单词...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() {});
                        },
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: const Color(0xFFFFF8E1),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  // 导入导出按钮
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _importVocab,
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('导入词库'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _exportVocab,
                          icon: const Icon(Icons.upload_file, size: 18),
                          label: const Text('导出词库'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (q.isEmpty) ...[
                    Center(child: Text('词库积累', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _StatCard(
                          label: '课标词', count: totalStandard, color: AppTheme.primaryBlue,
                          onTap: () => _openWordList('课标词'),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: _StatCard(
                          label: '拓展词', count: totalExtend, color: AppTheme.green,
                          onTap: () => _openWordList('拓展词'),
                        )),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _StatCard(
                          label: '超标词', count: totalChaoGang, color: AppTheme.red,
                          onTap: () => _openWordList('超标词'),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: _StatCard(
                          label: '专有词', count: totalExtra, color: AppTheme.grey,
                          onTap: () => _openWordList('专有词'),
                        )),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ] else ...[
                    Text('搜索结果 (${filtered.length})', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    ...filtered.map((e) {
                      final color = _catColor(e.value);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          border: Border(left: BorderSide(color: color, width: 4)),
                          borderRadius: BorderRadius.circular(8),
                          color: const Color(0xFFFFF8E1),
                        ),
                        child: ListTile(
                          onTap: widget.onWordTap == null ? null : () => widget.onWordTap!(e.key),
                          title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w500)),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(e.value, style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                          ),
                          dense: true,
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
          ),
          // 搴曢儴鍥哄畾锛堝缁堝湪椤甸潰鏈€涓嬫柟锛夛細使用说明 + 鐗堟湰鍙'+ Github 浠撳簱锛堜笁琛屽眳涓級
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16, top: 8),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const _HelpPage()),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.description, size: 18),
                            SizedBox(width: 4),
                            Text('使用说明'),
                          ],
                        ),
                      ),
                      const Text('  '),
                      TextButton(
                        onPressed: widget.syncing ? null : widget.onSyncVocab,
                        child: widget.syncing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.sync, size: 18),
                                  SizedBox(width: 4),
                                  Text('同步词库'),
                                ],
                              ),
                      ),
                      const Text('  '),
                      TextButton(
                        onPressed: widget.onCheckUpdate,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.system_update, size: 18),
                            SizedBox(width: 4),
                            Text('检查更新'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Text('V 1.5.2', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  SizedBox(height: 4),
                  GestureDetector(
                    onTap: () async {
                      final uri = Uri.parse('https://github.com/beenhow/ESW');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                    child: const Text(
                      'Github仓库：https://github.com/beenhow/ESW',
                      style: TextStyle(color: Colors.blueGrey, fontSize: 11, decoration: TextDecoration.none),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 鏌愮被词库璇︽儏椤碉細鍊掑簭灞曠ず璇ョ被鎵€鏈夊崟璇嶏紝姣忚鍙充晶鎻愪緵杞崲鎿嶄綔銆?
class _WordListPage extends StatefulWidget {
  final String category;
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final Future<void> Function(String word, VoidCallback onAdded) showBaseWordDialog;
  final ValueChanged<String>? onWordTap;
  final WordSyncService wordSyncService;

  const _WordListPage({
    required this.category,
    required this.vocab,
    required this.onSaveConfig,
    required this.showBaseWordDialog,
    required this.wordSyncService,
    this.onWordTap,
  });

  @override
  State<_WordListPage> createState() => _WordListPageState();
}

class _WordListPageState extends State<_WordListPage> {
  late List<String> _words;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    switch (widget.category) {
      case '课标词':
        _words = widget.vocab.standardWords.keys.toList();
        break;
      case '拓展词':
        _words = List.from(widget.vocab.extendWords);
        break;
      case '超标词':
        _words = List.from(widget.vocab.manualChaoGangWords);
        break;
      case '专有词':
        _words = List.from(widget.vocab.manualExtraWords);
        break;
      default:
        _words = [];
    }
    // 非课标词保持倒序（最新添加的在最前面）；课标词按词库原始顺序正序显示
    if (widget.category != '课标词') {
      _words = _words.reversed.toList();
    }
  }

  Color _colorFor(String cat) {
    switch (cat) {
      case '课标词': return AppTheme.primaryBlue;
      case '拓展词': return AppTheme.green;
      case '超标词': return AppTheme.red;
      case '专有词': return AppTheme.grey;
      default: return AppTheme.orange;
    }
  }

  /// 批量转为目标分类（接入 markChanged 同步本地变更）
  void _applyBatchReclassify(String target) {
    final words = _selected.toList();
    if (words.isEmpty) return;
    for (final w in words) {
      widget.vocab.reclassifyWord(w, target);
      widget.wordSyncService.markChanged(w);
    }
    widget.onSaveConfig();
    setState(() {
      _selected.clear();
      _load();
    });
  }

  /// 从三个手动词库列表中彻底移除该词（删除前清理）
  void _removeFromLists(String word) {
    final lower = word.toLowerCase();
    widget.vocab.extendWords.removeWhere((e) => e.toLowerCase() == lower);
    widget.vocab.extendBaseMap.remove(word);
    widget.vocab.extendReverseIndex.remove(lower);
    widget.vocab.manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
    widget.vocab.manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
  }

  /// 批量删除所选单词（接入 markDeleted 删除墓碑，同步传播到云端）
  /// 大范围删除保护：删除超过 10 个 → 确认；超过 50 个 → 先自动备份云端再确认；取消无副作用
  Future<bool> _applyBatchDelete() async {
    final words = _selected.toList();
    if (words.isEmpty) return false;
    if (words.length > 10) {
      final total = widget.vocab.extendWords.length +
          widget.vocab.manualChaoGangWords.length +
          widget.vocab.manualExtraWords.length;
      final backedUp = words.length > 50
          ? await widget.wordSyncService.backupRemoteState()
          : false;
      if (!mounted) return false;
      final confirmed = await _confirmLargeDelete(
        context,
        words.length,
        total,
        backedUp,
      );
      if (!confirmed) return false; // 取消：无副作用，不写墓碑
    }
    if (!mounted) return false;
    for (final w in words) {
      _removeFromLists(w);
      widget.wordSyncService.markDeleted(w);
    }
    widget.onSaveConfig();
    setState(() {
      _selected.clear();
      _load();
    });
    return true;
  }

  /// 删除确认弹窗：删除单词超过 10 个时提示用户确认，
  /// 超过 50 个时云端已自动备份全部词库。
  /// 返回 true=确认执行，false=取消（无副作用）。
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

  void _toggleWord(String w, bool? v) {
    setState(() {
      if (v == true) {
        _selected.add(w);
      } else {
        _selected.remove(w);
      }
    });
  }

  void _toggleAll(bool? v) {
    setState(() {
      if (v == true) {
        _selected.addAll(_words);
      } else {
        _selected.clear();
      }
    });
  }

  /// 按当前词库动态生成可转换的目标词库（不含自身词库）
  List<String> get _batchTargets {
    return switch (widget.category) {
      '拓展词' => const ['超标词', '专有词'],
      '超标词' => const ['拓展词', '专有词'],
      '专有词' => const ['拓展词', '超标词'],
      _ => const <String>[],
    };
  }

  void _doCancelSelect() {
    setState(() {
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(widget.category);
    final bool editable = widget.category != '课标词';
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8E1),
      appBar: AppBar(
        title: Text(
          _selected.isEmpty
              ? '${widget.category}（共${_words.length}个）'
              : '${widget.category}（已选${_selected.length}个）',
          style: const TextStyle(fontSize: 16),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFFFFF8E1),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: editable
            ? [
                const SizedBox(width: 4),
                const Text('全选', style: TextStyle(fontSize: 13)),
                Checkbox(
                  value: _words.isNotEmpty && _selected.length == _words.length,
                  activeColor: color,
                  onChanged: _toggleAll,
                ),
              ]
            : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: _words.isEmpty
                ? Center(child: Text('暂无${widget.category}', style: TextStyle(color: Colors.grey.shade500)))
                : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _words.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final w = _words[i];
                return ListTile(
                  leading: editable
                      ? Checkbox(
                          value: _selected.contains(w),
                          activeColor: color,
                          onChanged: (v) => _toggleWord(w, v),
                        )
                      : CircleAvatar(
                          radius: 16,
                          backgroundColor: color.withValues(alpha: 0.15),
                          child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
                        ),
                  title: Text(w, style: const TextStyle(fontWeight: FontWeight.w500)),
                  trailing: editable ? null : const Text('仅查看', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  dense: true,
                  onTap: widget.onWordTap == null
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          widget.onWordTap!(w);
                        },
                );
              },
            ),
          ),
          if (_selected.isNotEmpty)
            SafeArea(
              child: Container(
                color: const Color(0xFFFFF8E1),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    for (final t in _batchTargets) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _applyBatchReclassify(t),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('转为$t', style: const TextStyle(fontSize: 13)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          _applyBatchDelete();
                        },
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('删除所选单词', style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextButton(
                        onPressed: _doCancelSelect,
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('取消选择', style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 寮傛鎵弿鎵€鏈?corpus 璇枡鏂囦欢锛岀粺璁＄粰瀹氬崟璇嶇殑鍑虹幇娆℃暟銆?
/// 鍙亶鍘嗘枃浠朵竴娆★紝浣跨敤鑱斿悎姝ｅ垯涓€娆℃€у尮閰嶆墍鏈夊崟璇嶏紝閬垮厤閫愪釜鍗曡瘝閲嶅鎵弿銆?
/// 浣跨敤 readAsString锛堝紓姝ワ級+ 姣?10 涓枃浠惰鍑轰簨浠跺惊鐜紝閬垮厤闃诲 UI 绾跨▼銆?
/// 鍔犺浇 corpus 鍏ㄩ噺璇嶉绱㈠紩銆?
/// 棣栨璋冪敤鏃舵壂鎻?corpus 鐩綍涓嬫墍鏂.txt锛屾寜鍗曡瘝锛堥暱搴?=3锛夌粺璁″嚭鐜版鏁板苟鍐欏取/// corpus_index.json锛涘悗缁皟鐢ㄧ洿鎺ヨ鍐呭瓧Map锛屾绉掔骇鍝嶅簲锛屽交搴曡В鍐抽€愭枃浠舵壂鎻忚浆鍦堥棶棰樸€
Future<Map<String, int>> _loadCorpusIndex(String corpusPath) async {
  final indexFile = File('$corpusPath/corpus_index.json');
  if (indexFile.existsSync()) {
    try {
      final json = await indexFile.readAsString();
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return {for (final e in decoded.entries) e.key: (e.value as num).toInt()};
    } catch (_) {
      // 绱㈠紩鎹熷潖鍒欓噸寤?
    }
  }

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
      final text = await files[fi].readAsString();
      final words = text.toLowerCase().split(RegExp(r'\W+'));
      for (final w in words) {
        if (w.length >= 3) {
          index[w] = (index[w] ?? 0) + 1;
        }
      }
    } catch (_) {
      // 鍗曚釜鏂囦欢璇诲彇鍑洪敊锛岃烦杩囩户缁?
    }
    // 姣?20 涓枃浠惰鍑轰簨浠跺惊鐜紝閬垮厤闃诲 UI
    if (fi > 0 && fi % 20 == 0) {
      await Future.delayed(Duration.zero);
    }
  }

  try {
    await indexFile.writeAsString(jsonEncode(index));
  } catch (_) {

  }
  return index;
}

class _DottedLinePainter extends CustomPainter {
  final Color color;
  _DottedLinePainter({this.color = const Color(0xFFB20000)});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const dashWidth = 4.0;
    const dashSpace = 3.0;
    double startX = 0;
    while (startX < size.width) {
      canvas.drawLine(Offset(startX, 1), Offset(startX + dashWidth, 1), paint);
      startX += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
