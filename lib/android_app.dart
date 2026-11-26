import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:isolate' show Isolate;
import 'dart:typed_data';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel, rootBundle;
import 'package:flutter/gestures.dart';
import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart' as pwpdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'theme/app_theme.dart';
import 'theme/esw_tokens.dart';
import 'theme/responsive.dart';
import 'widgets/esw_widgets.dart';
import 'widgets/esw_app_dialog.dart';
import 'pages/search_page.dart';
import 'pages/detect_page.dart';
import 'pages/word_bank_page.dart';
import 'shared/vocab_service.dart';
import 'shared/word_sync_service.dart';
import 'shared/webdav_client.dart';
import 'shared/doc_extractor.dart';
import 'shared/text_normalize.dart';
import 'shared/builtin_corpus.dart';
import 'shared/imported_corpus.dart';
import 'shared/export_extra_table.dart';
import 'shared/base_word_candidates.dart';
import 'utils/android_open_file.dart';
import 'shared/inplace_docx_annotator.dart';
import 'shared/export_annotate_markup.dart';
import 'shared/export_word_style.dart';
import 'export_summary.dart';
import 'shared/app_snack_bar.dart';
import 'shared/export_progress_overlay.dart';
import 'shared/scan_camera_page.dart';
import 'shared/scan_photo_page.dart';
import 'shared/scan_ocr_service.dart';
import 'dictionary_service.dart';

/// 安卓端当前版本号（显示与更新比较的唯一来源，发布版需与 pubspec 保持一致）。
const String kAndroidAppVersion = '1.6.3';

/// 原生 docx→PDF 通道：WebView 按 docx 原排版渲染后逐页写出 PDF。
const MethodChannel _docxPdfChannel = MethodChannel('esw/docx_pdf');

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

  /// 当前由内置释放写入 corpus 的文件名（导入时避让，避免覆盖内置）。
  Set<String> _builtinManagedNames = <String>{};

  /// 本次启动中用户主动导入的真题文件名。
  ///
  /// 启动时由配置 `userCorpusNames` 恢复（仅本应用内主动导入且仍存在于
  /// corpus 目录的文件）；历史遗留/外部路径不会进入这里。
  final Set<String> _userActiveNames = <String>{};

  /// 启动时从配置读出的用户导入文件名，待 corpus 目录就绪后校验存在性再启用。
  List<String> _savedUserCorpusNames = <String>[];

  /// 当前参与检测/统计的真题文件名 = 内置 + 本次主动导入。
  Set<String> get _activeCorpusNames {
    final names = <String>{};
    names.addAll(_builtinManagedNames);
    names.addAll(_userActiveNames);
    return names;
  }

  /// 按年份统计的真题语料词库命中单词数（{年份: 命中次数}）。
  /// null 表示尚未统计完成 / 加载中；空 Map 表示无年份数据。
  Map<int, int>? _yearHitCounts;

  /// 按教材文件统计的教材语料词库命中单词数（{教材名(去扩展名): 命中次数}）。
  /// null 表示尚未统计完成 / 加载中；空 Map 表示无教材数据。
  Map<String, int>? _textbookHitCounts;
  bool _syncing = false;

  /// 扫描文档识别中（防重复点击，同时驱动按钮文案）
  bool _scanning = false;
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
    // 词库/配置/教材统计互不依赖，并行执行；内置真题释放依赖配置里的隐藏状态，
    // 必须在 _loadConfig 之后，因此单独串行，最后再统计语料文件数。
    await Future.wait([
      _vocab.loadStandardWords(),
      _loadConfig(),
      _refreshTextbookCount(),
    ]);
    await _initBuiltinCorpus();
    // 内置释放完成后再恢复用户导入项：两者分开持有，同名文件由内置链路避让，
    // 不会互相覆盖；路径已不存在的条目静默跳过。
    await _restoreUserCorpusNames();
    await _refreshCorpusCount();
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
      final goSync = await showEswConfirm(
        context,
        title: '同步词库',
        message: '词库可能不是最新，建议先同步再开始检测，避免拓展词无法映射到课标词。',
        icon: Icons.sync_rounded,
        cancelLabel: '暂不',
        okLabel: '去同步',
      );
      if (goSync && mounted) {
        await _syncVocab();
      }
    });
  }

  /// 应用文档目录/corpus 下是否存在当前生效的真题 txt。
  /// 生效集 = 内置文件 + 配置中记录且仍存在的用户导入文件（对齐 Windows）。
  Future<bool> _hasRealCorpus() async {
    final names = _activeCorpusNames;
    if (names.isEmpty) return false;
    try {
      final p = await _corpusDirPath();
      final d = Directory(p);
      if (!await d.exists()) return false;
      await for (final e in d.list()) {
        if (e is File &&
            e.path.toLowerCase().endsWith('.txt') &&
            names.contains(e.uri.pathSegments.last)) {
          return true;
        }
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
    final choice = await showEswChoice<String>(
      context,
      title: '需要真题/教材语料',
      message: '真题单词检测需要真题或教材语料支撑。请先导入真题或教材；若不导入，将无法完成真题单词检测。',
      icon: Icons.folder_open_rounded,
      choices: const [
        EswDialogChoice(label: '导入教材', value: 'textbook'),
        EswDialogChoice(label: '导入真题', value: 'exam'),
        EswDialogChoice(label: '暂不', value: 'later'),
      ],
    );
    if (choice == 'exam') {
      await _importCorpus();
    } else if (choice == 'textbook') {
      await _importTextbook();
    }
    if (await _hasRealCorpus()) return true;
    if (mounted) {
      showAppSnackBar(
        context,
        '无法完成真题单词检测：请先导入真题或教材语料',
        type: AppSnackBarType.error,
      );
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
        final saved = json['userCorpusNames'];
        if (saved is List) {
          _savedUserCorpusNames = saved
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    try {
      final configPath = await _getConfigPath();
      final data = _vocab.toJson();
      data['userId'] = _userId;
      // 仅记录用户主动导入的真题文件名（内置文件由 .builtin_corpus.json 管理）
      data['userCorpusNames'] = _userActiveNames.toList();
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

      // 同步失败（无凭据 / 鉴权被拒 / 网络 / 超时 / 云端错误）：
      // 历史实现直接取 remote_changes，失败时该字段为 null 会抛异常，
      // 最终只弹一句 "同步失败: type 'Null' is not a subtype..."，
      // 用户既看不出是没账号还是账号错，也始终拿不到云端词库。
      if (result['success'] != true) {
        await _handleSyncFailure(result);
        return;
      }

      // 本机词库为空但云端已有词库：服务端返回整库恢复（bootstrap），
      // remote_changes 恒为空列表。历史实现只处理 remote_changes，
      // 于是提示"同步完成"却一个词也没落库，拓展/超标/专有词长期显示 0。
      if (result['bootstrap'] == true) {
        final raw = result['bootstrap_words'];
        final words = <String, Map<String, String>>{};
        if (raw is Map) {
          for (final e in raw.entries) {
            final v = e.value;
            if (v is! Map) continue;
            final cat = (v['category'] ?? '').toString();
            if (cat.isEmpty) continue;
            words[e.key.toString()] = {
              'original_case': (v['original_case'] ?? e.key).toString(),
              'category': cat,
            };
          }
        }
        final restored = _vocab.applyBootstrapWords(words);
        final bootstrapEbm = result['extendBaseMap'] as Map<String, dynamic>?;
        if (bootstrapEbm != null) {
          for (final entry in bootstrapEbm.entries) {
            _vocab.extendBaseMap[entry.key] = entry.value.toString();
          }
        }
        await _saveConfig();
        if (mounted) {
          setState(() {});
          showAppSnackBar(
            context,
            '已从云端恢复 $restored 个词条',
            type: AppSnackBarType.success,
          );
        }
        return;
      }

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
              if (d['action'] != 'accept' &&
                  reasonMap[d['word']!] == 'remote_only')
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
        final msg = remoteChanges.isEmpty
            ? '同步完成 (已是最新)'
            : '同步完成 (已处理${remoteChanges.length}条云端变更)';
        showAppSnackBar(context, msg, type: AppSnackBarType.success);
        _maybePromptCorpusImport();
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          '同步失败: $e',
          type: AppSnackBarType.error,
          duration: const Duration(seconds: 4),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 同步失败的分类提示（对齐 Windows 主流程）。
  ///
  /// 历史实现把无凭据 / 鉴权失败一律吞成"已是最新"，用户无法判断是没账号、
  /// 账号错、还是云端没数据，也就永远拿不到云端词库。
  Future<void> _handleSyncFailure(Map<String, dynamic> result) async {
    final kind = result['error_kind']?.toString() ?? 'unknown';
    final msg = result['error']?.toString() ?? '未知原因';
    if (!mounted) return;

    if (kind == 'no_config' || kind == 'auth') {
      final open = await showEswConfirm(
        context,
        title: kind == 'no_config' ? '未配置同步账号' : '同步账号无效',
        message: kind == 'no_config'
            ? '本机没有找到可用的坚果云同步账号，因此无法同步词库。\n\n'
                  '可以直接填写坚果云账号与应用密码（只保存在本机，不随安装包分发）。'
            : '坚果云拒绝了当前同步账号：$msg\n\n'
                  '请在坚果云「安全设置」里重新生成应用密码后填写。',
        icon: Icons.key_off_rounded,
        danger: kind != 'no_config',
        dismissible: false,
        cancelLabel: '稍后',
        okLabel: '填写同步账号',
      );
      if (open) await _showSyncAccountDialog();
      return;
    }

    final hint = kind == 'timeout'
        ? '同步超时：网络较慢或云端无响应，请稍后重试。'
        : kind == 'network'
        ? '网络不可用：请检查网络连接后重试。'
        : kind == 'http'
        ? '云端返回错误：$msg'
        : '同步失败：$msg';
    showAppSnackBar(
      context,
      hint,
      type: AppSnackBarType.error,
      duration: const Duration(seconds: 6),
    );
  }

  /// 手动填写同步账号（换机 / 换密码 / 内置凭据失效时的兜底入口）。
  Future<void> _showSyncAccountDialog() async {
    final cfg = await WebDavConfig.load();
    final baseCtrl = TextEditingController(
      text: (cfg != null && cfg.baseUrl.isNotEmpty)
          ? cfg.baseUrl
          : 'https://dav.jianguoyun.com/dav/esw_sync',
    );
    final userCtrl = TextEditingController(text: cfg?.username ?? '');
    final pwdCtrl = TextEditingController(text: cfg?.password ?? '');
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        var testing = false;
        var status = '';
        var statusOk = false;
        return StatefulBuilder(
          builder: (ctx2, setDialogState) => AlertDialog(
            title: const Text('同步账号'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '填写坚果云账号与「应用密码」（坚果云 → 账户信息 → 安全设置 → 添加应用），'
                    '保存后只写入本机存储，不随安装包分发。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: baseCtrl,
                    decoration: const InputDecoration(
                      labelText: '服务地址',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: userCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: '账号（邮箱）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: pwdCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '应用密码',
                      isDense: true,
                    ),
                  ),
                  if (status.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: 12,
                        color: statusOk ? EswColors.green : EswColors.red,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: testing
                    ? null
                    : () async {
                        setDialogState(() {
                          testing = true;
                          status = '';
                        });
                        final testCfg = WebDavConfig(
                          baseUrl: baseCtrl.text.trim(),
                          username: userCtrl.text.trim(),
                          password: pwdCtrl.text,
                        );
                        final probe = await _wordSyncService.verifyAccount(
                          testCfg,
                        );
                        if (!mounted) return;
                        setDialogState(() {
                          testing = false;
                          statusOk = probe['ok'] == true;
                          status = probe['message']?.toString() ?? '';
                        });
                      },
                child: Text(testing ? '测试中…' : '测试连接'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存并同步'),
              ),
            ],
          ),
        );
      },
    );

    if (saved == true) {
      final base = baseCtrl.text.trim();
      final user = userCtrl.text.trim();
      final pwd = pwdCtrl.text;
      if (base.isEmpty || user.isEmpty || pwd.isEmpty) {
        if (mounted) {
          showAppSnackBar(
            context,
            '服务地址 / 账号 / 应用密码都不能为空',
            type: AppSnackBarType.error,
          );
        }
        return;
      }
      final ok = await WebDavConfig(
        baseUrl: base,
        username: user,
        password: pwd,
        source: 'user',
      ).save();
      // 凭据变更后必须重建客户端，否则仍用旧 header 请求
      _wordSyncService.resetClient();
      if (!mounted) return;
      if (!ok) {
        showAppSnackBar(
          context,
          '账号保存失败：无法写入本机存储',
          type: AppSnackBarType.error,
        );
        return;
      }
      showAppSnackBar(
        context,
        '同步账号已保存，正在同步词库…',
        type: AppSnackBarType.success,
      );
      await _syncVocab();
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
        ? (backedUp ? '已自动在云端备份全部词库。' : '警告：云端备份失败，请确认网络正常后再操作！')
        : '';
    return showEswConfirm(
      context,
      title: '删除确认',
      message:
          '本次操作将删除 $delCount 个单词（词库当前共 $total 个）。\n\n$backupMsg\n\n确认要继续执行该删除操作吗？',
      icon: Icons.delete_outline_rounded,
      danger: true,
      okLabel: '确认删除',
      dismissible: false,
    );
  }

  /// 同步冲突弹窗：逐词接收/拒绝/上传本地云端更新。
  /// 弹窗内不做任何二次确认（删除保护统一由 _syncVocab 主流程在弹窗关闭后处理，
  /// 避免弹窗内连续嵌套 showDialog 导致 Android 路由竞态卡死）。
  /// 取消无副作用（不写墓碑）。返回逐词决策列表（null=取消，空=无实际决策），
  /// 每项 {word, action('accept'/'reject'/'upload_local'), category}。
  Future<List<Map<String, String>>?> _showSyncConflictDialog(
    List<dynamic> changes,
  ) async {
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
    Future<bool> confirmAction(String title, String message) {
      return showEswConfirm(
        context,
        title: title,
        message: message,
        icon: Icons.sync_rounded,
        okLabel: '确认',
        dismissible: false,
      );
    }

    final decisions = await showDialog<List<Map<String, String>>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Center(child: Text('云端词库有更新')),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
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
                          final ok = await confirmAction(
                            '全部接收',
                            '将全部应用云端更新，不删除本地词，确认执行？',
                          );
                          if (ok) {
                            setDialogState(() {
                              for (final ch in changes) {
                                accepted[ch['word'] as String] = true;
                              }
                            });
                          }
                        },
                        child: Text(
                          '全部接收（${acceptCount()}）',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () async {
                          final ok = await confirmAction(
                            '全部拒绝',
                            '将全部拒绝云端更新，保留本地状态，确认执行？',
                          );
                          if (ok) {
                            setDialogState(() {
                              for (final ch in changes) {
                                accepted[ch['word'] as String] = false;
                              }
                            });
                          }
                        },
                        child: Text(
                          '全部拒绝（${rejectCount()}）',
                          style: EswText.bodySmall,
                        ),
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
                          title: Text(
                            word,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
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
                            final ok = await confirmAction(
                              '接收更新',
                              '将应用云端更新到本地，确认执行？',
                            );
                            if (ok && ctx.mounted) {
                              Navigator.pop(ctx, buildDecisions('accept'));
                            }
                          },
                          child: const Text('接收更新'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final ok = await confirmAction(
                              '拒绝更新',
                              '将拒绝云端更新，保留本地状态，确认执行？',
                            );
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
                            final ok = await confirmAction(
                              '上传本地',
                              '将自动拒绝云端更新，把本地所选单词全部上传覆盖云端，确认执行？',
                            );
                            if (ok && ctx.mounted) {
                              // 一步到位：全部标记为拒绝云端更新（accepted=false），
                              // 随后 buildDecisions('upload_local') 即收集全部单词作为上传决策
                              setDialogState(() {
                                for (final ch in changes) {
                                  accepted[ch['word'] as String] = false;
                                }
                              });
                              Navigator.pop(
                                ctx,
                                buildDecisions('upload_local'),
                              );
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
          showAppSnackBar(
            context,
            '检查更新失败(${resp.statusCode})',
            type: AppSnackBarType.error,
          );
        }
        return;
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final tagName =
          (json['tag_name'] as String?)?.replaceFirst('v', '') ?? '0.0.0';
      if (_compareVersions(tagName, kAndroidAppVersion) <= 0) {
        if (context.mounted) {
          showAppSnackBar(context, '已是最新版本', type: AppSnackBarType.success);
        }
        return;
      }
      if (!context.mounted) return;
      Future<void> openExternal(String url) async {
        try {
          await launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          );
        } catch (_) {
          // 打开外部浏览器失败时静默处理
        }
      }

      showEswCustom<void>(
        context,
        title: '发现新版本',
        message: '当前 V$kAndroidAppVersion → 最新 V$tagName',
        icon: Icons.system_update_rounded,
        content: Padding(
          padding: const EdgeInsets.only(top: EswSpace.md),
          child: Text(
            '请选择下载入口，蓝奏云密码 52pj。',
            textAlign: TextAlign.center,
            style: EswText.caption.copyWith(color: EswColors.textSecondary),
          ),
        ),
        actions: [
          eswDialogAction(
            label: 'GitHub',
            onPressed: () => openExternal('https://github.com/beenhow/ESW/releases'),
          ),
          eswDialogAction(
            label: '蓝奏云',
            primary: true,
            onPressed: () => openExternal('https://wwbcj.lanzouu.com/b02qeywze'),
          ),
        ],
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

  /// 首启释放内置真题（119 套）到应用私有 corpus 目录，并复用现有扫描/统计链路。
  ///
  /// - 版本标记 + 原子写由 [BuiltinCorpus.installFlat] 负责；
  /// - 用户自行导入的同名文件不覆盖（改写为「{id}（内置）.txt」）；
  /// - 任何失败静默降级：没有内置真题时，手动导入/检测仍照常可用。
  Future<void> _initBuiltinCorpus() async {
    try {
      final index = await BuiltinCorpus.loadIndex();
      if (index == null) return;
      final corpusDir = await _corpusDirPath();
      await BuiltinCorpus.installFlat(
        corpusDir: corpusDir,
        version: index.version,
        papers: index.papers,
      );
      _builtinManagedNames = await BuiltinCorpus.flatNames(corpusDir);
      // 上一轮索引可能包含已失效的文件，启动时失效重建；用户导入项在
      // _restoreUserCorpusNames 中按配置恢复后重新参与统计。
      await _deleteCorpusIndex(corpusDir);
    } catch (_) {
      // 静默降级：内置释放失败不影响手动导入与检测
    }
  }

  /// 启动时恢复用户主动导入的真题文件名（仅本应用内导入并写入配置的项）。
  ///
  /// 只认 corpus 目录中仍存在的 .txt；已删除/失效的条目静默丢弃并回写配置，
  /// 保证用户移除后重启不再出现。内置文件不在配置里，由内置链路单独管理。
  Future<void> _restoreUserCorpusNames() async {
    if (_savedUserCorpusNames.isEmpty) return;
    try {
      final valid = await ImportedCorpusRestore.existingNames(
        recorded: _savedUserCorpusNames,
        dir: await _corpusDirPath(),
        builtinNames: _builtinManagedNames,
      );
      _userActiveNames.addAll(valid);
      if (valid.length != _savedUserCorpusNames.length) {
        _savedUserCorpusNames = valid;
        await _saveConfig();
      }
    } catch (_) {
      // 静默降级：恢复失败不影响启动与手动导入
    }
  }

  /// 语料变化后删除词频索引，触发下次查询重建。
  Future<void> _deleteCorpusIndex(String corpusDir) async {
    try {
      final indexFile = File('$corpusDir/corpus_index.json');
      if (await indexFile.exists()) await indexFile.delete();
    } catch (_) {}
  }

  /// 统计当前生效的真题 txt 文件数（内置 + 本次主动导入）并刷新界面。
  Future<void> _refreshCorpusCount() async {
    int count = 0;
    final names = _activeCorpusNames;
    try {
      if (names.isNotEmpty) {
        final corpusPath = await _corpusDirPath();
        final dir = Directory(corpusPath);
        if (await dir.exists()) {
          count = await dir
              .list()
              .where(
                (e) =>
                    e is File &&
                    e.path.toLowerCase().endsWith('.txt') &&
                    names.contains(e.uri.pathSegments.last),
              )
              .length;
        }
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

    Map<int, int> parseYearCounts(Map raw) {
      final out = <int, int>{};
      final counts = raw['counts'];
      if (counts is Map) {
        counts.forEach((k, v) {
          final year = k is int ? k : int.tryParse('$k');
          final cnt = v is int ? v : int.tryParse('$v');
          if (year != null && cnt != null) out[year] = cnt;
        });
      }
      return out;
    }

    Map<String, int> parseTextbookCounts(Map raw) {
      final out = <String, int>{};
      final counts = raw['counts'];
      if (counts is Map) {
        counts.forEach((k, v) {
          final cnt = v is int ? v : int.tryParse('$v');
          if (k != null && cnt != null) out['$k'] = cnt;
        });
      }
      return out;
    }

    Map<int, int>? yearCounts;
    Map<String, int>? textbookCounts;
    try {
      final results = await Future.wait([
        // 走顶层包装：State 内的 Isolate.run 闭包会捕获 this，一旦存在 _Timer
        // 等 unsendable 字段即抛 illegal argument in isolate message
        _scanYearHitCountsAsync({
          'dirPath': corpusPath,
          'names': _activeCorpusNames.toList(),
          'vocab': vocabInfo,
        }),
        _scanTextbookHitCountsAsync({
          'dirPath': textbookPath,
          'vocab': vocabInfo,
        }),
      ]);
      yearCounts = parseYearCounts(results[0]);
      textbookCounts = parseTextbookCounts(results[1]);
    } catch (_) {
      // 留空表示"未知"，不当作"无数据"，稍后回退主 isolate 重算
      yearCounts = null;
      textbookCounts = null;
    }

    // 后台 isolate 结果异常或为空、但语料目录确有文件时，回退主 isolate 重算一次，
    // 杜绝"已导入语料却提示暂无年份数据"的假空统计。
    if (yearCounts == null || (yearCounts.isEmpty && _corpusFileCount > 0)) {
      try {
        yearCounts = parseYearCounts(
          _scanYearHitCountsWorker({
            'dirPath': corpusPath,
            'names': _activeCorpusNames.toList(),
            'vocab': vocabInfo,
          }),
        );
      } catch (_) {}
    }
    if (textbookCounts == null ||
        (textbookCounts.isEmpty && _textbookFileCount > 0)) {
      try {
        textbookCounts = parseTextbookCounts(
          _scanTextbookHitCountsWorker({
            'dirPath': textbookPath,
            'vocab': vocabInfo,
          }),
        );
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _yearHitCounts = yearCounts;
      _textbookHitCounts = textbookCounts;
    });
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

  /// 切换 tab：先释放当前焦点与键盘，再切换页面。
  ///
  /// IndexedStack 会同时构建三个页面，隐藏页的输入框若持有焦点，其 TextInput
  /// 连接会继续占用输入法，切换到新页面后点击输入框拿不到键盘，表现为
  /// 「点了输入框却打不进字」。切换前统一 unfocus 可彻底规避。
  void _switchTab(int i) {
    if (i == _currentIndex) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _currentIndex = i);
  }

  /// 焦点隔离：非当前 tab 的输入控件一律不允许获取焦点。
  Widget _focusGuard(int index, Widget child) =>
      ExcludeFocus(excluding: _currentIndex != index, child: child);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EswColors.page,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _focusGuard(0, _buildSearchTab()),
          _focusGuard(1, _buildImportTab()),
          _focusGuard(2, _buildVocabTab()),
        ],
      ),
      bottomNavigationBar: EswBottomNav(
        currentIndex: _currentIndex,
        onChanged: _switchTab,
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
      corpusNames: _activeCorpusNames,
      corpusNamesProvider: () async => _activeCorpusNames,
      onWordTap: (word) {
        _switchTab(0);
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
      categoryCounts: [
        _vocab.standardWords.length,
        _vocab.extendWords.length,
        _vocab.manualChaoGangWords.length,
        _vocab.manualExtraWords.length,
      ],
      onImportCorpus: _importCorpus,
      onImportTextbook: _importTextbook,
      onImportFile: _importFile,
      onScanDocument: _scanDocument,
      scanning: _scanning,
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
      // 只过滤「异常文案型」脏记录；乱码文件名属于有效记录，改名后仍展示。
      history: _detectHistory.where((h) => !_isErrorJunkName(h.fileName)).map((
        h,
      ) {
        final summary = h.categoryCounts.entries
            .where((e) => e.value > 0)
            .map((e) => '${e.key}${e.value}')
            .join(' / ');
        final annotatedPart = h.annotatedCount > 0
            ? ' · 标注词${h.annotatedCount}'
            : '';
        return DetectHistoryItem(
          fileName: _safeDocName(h.fileName),
          onPhotoTap: (h.photoPath == null || h.photoPath!.isEmpty)
              ? null
              : () => ScanPhotoPage.open(
                    context,
                    imagePath: h.photoPath!,
                    title: '原图 · ${_safeDocName(h.fileName)}',
                  ),
          subtitle:
              '${_formatTime(h.time)} · ${h.totalWords}词${summary.isNotEmpty ? ' · $summary' : ''}$annotatedPart',
          onTap: () async {
            final src = h.sourcePath;
            // ① 已导出过检测结果文档 → 直接用系统应用打开该文档
            final exported = h.exportPath;
            if (exported != null && exported.isNotEmpty) {
              if (await File(exported).exists()) {
                final ok = await AndroidOpenFile.open(exported);
                if (ok) return;
                if (!mounted) return;
                showAppSnackBar(
                  context,
                  '未找到可打开该文档的应用，已为你重新打开检测结果页',
                  type: AppSnackBarType.info,
                );
              } else {
                if (!mounted) return;
                showAppSnackBar(
                  context,
                  '导出文档已被移动或删除，已为你重新检测',
                  type: AppSnackBarType.info,
                );
              }
            }
            // ② 未导出 / 导出文件已失效 → 跳转到重新检测（检测结果页）
            if (src == null || src.isEmpty) {
              if (!mounted) return;
              // 粘贴文本类记录不保留原文（避免大文本常驻内存），回到检测页聚焦粘贴框
              showAppSnackBar(
                context,
                '该记录未保留原文，请重新粘贴或导入后检测',
                type: AppSnackBarType.info,
              );
              _pasteCtrl.clear();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _pasteFocus.requestFocus();
              });
              return;
            }
            try {
              // P6：历史不存全文，重看时按源路径在后台 isolate 内重新提取。
              // 必须走顶层包装函数，绝不能在 State 方法内直接写 Isolate.run 闭包
              // （否则 _AndroidEswAppState 连同 Timer 被打包发送 → unsendable 崩溃红屏）。
              final name = h.fileName;
              final content = await _extractImportContentFromPathAsync(
                src,
                name,
              );
              if (content.trim().isEmpty) {
                if (!mounted) return;
                showAppSnackBar(
                  context,
                  '原文件内容为空或不可读，请重新导入',
                  type: AppSnackBarType.error,
                );
                return;
              }
              _showAnalysisResult(
                content,
                h.fileName,
                sourcePath: src,
                historyExportPath: exported,
                photoPath: h.photoPath,
                origin: h,
              );
            } catch (e) {
              if (!mounted) return;
              showAppSnackBar(
                context,
                '重看失败（原文件可能已移动或删除）：$e',
                type: AppSnackBarType.error,
              );
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

  /// 文档名安全化：去掉控制字符；若混入异常/报错文案（历史版本曾把 isolate
  /// 异常字符串当成文件名写进记录，列表里表现为一长串乱码），统一回退为
  /// 「未命名文档」，保证「最近检测」列表只显示正常文档名。
  String _safeDocName(String? raw) {
    var s = (raw ?? '').replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    // 异常文案 / 乱码文件名一律不直接展示：异常文案条目会被上层过滤，
    // 乱码条目保留但显示为「未命名文档」，避免列表出现一串方块/问号。
    if (s.isEmpty || _isErrorJunkName(s) || _isGarbledDocName(s)) {
      return '未命名文档';
    }
    if (s.length > 60) s = '${s.substring(0, 60)}…';
    return s;
  }

  /// 是否为「异常文案型」脏名：历史版本误把 isolate / 解析异常字符串当成
  /// 文件名写入。这类记录没有任何参考价值，直接在「最近检测」列表里过滤掉。
  static bool _isErrorJunkName(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return true;
    final lower = s.toLowerCase();
    const badMarkers = <String>[
      'invalid argument',
      'illegal argument',
      'unsendable',
      'isolate message',
      'exception',
      'stack trace',
      'cannot send',
      'error:',
    ];
    for (final m in badMarkers) {
      if (lower.contains(m)) return true;
    }
    return false;
  }

  /// 是否为「乱码型」脏名（问题：最近检测列表项显示乱码）。
  ///
  /// 成因：文件选择器 / 三方应用回传的 GBK 文件名被按 UTF-8 解码，产生
  /// U+FFFD 替换符、"锟斤拷"、问号方块等典型乱码；也可能混入大量不可读符号。
  /// 判定用两条互补规则，宁宽勿漏：① 命中典型乱码标记；② 可读字符（中英文、
  /// 数字、常见标点）占比过低。
  static bool _isGarbledDocName(String raw) {
    if (raw.isEmpty) return true;
    if (raw.contains('\uFFFD')) return true;
    if (raw.contains('\uFFFE') || raw.contains('\uFEFF')) return true;
    const markers = <String>['锟斤拷', '锟', '拷', '烫烫', 'ï¿½', 'Ã¤', 'Ã¥', 'â'];
    for (final m in markers) {
      if (raw.contains(m)) return true;
    }
    final runes = raw.runes.toList();
    if (runes.length < 4) return false;
    var readable = 0;
    for (final r in runes) {
      final isCjk = r >= 0x4E00 && r <= 0x9FFF;
      final isAscii = (r >= 0x30 && r <= 0x39) ||
          (r >= 0x41 && r <= 0x5A) ||
          (r >= 0x61 && r <= 0x7A);
      final isCommonPunct = ' ._-()[]（）【】《》、，。：:·+#%&'.codeUnits.contains(r);
      if (isCjk || isAscii || isCommonPunct) readable++;
    }
    return readable / runes.length < 0.5;
  }

  /// 按路径读取 PDF 并提取纯文本（Android 端 PDF 解析，主 isolate 执行）。
  /// pdfrx 的文本层提取不依赖渲染引擎，仅需 PdfDocument.openData + loadText。
  Future<String> _readPdfFileByPath(String path) async {
    final bytes = await File(path).readAsBytes();
    return _readPdfContentAndroid(bytes);
  }

  /// 从 PDF bytes 中提取纯文本（Android 端无 OCR 引擎，纯文本层提取）。
  Future<String> _readPdfContentAndroid(List<int> raw) async {
    final document = await PdfDocument.openData(Uint8List.fromList(raw));
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
      return hasText ? normalizeText(buffer.toString()) : '';
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
            : await _extractImportContentFromPathAsync(p!, n);
        if (content.trim().isEmpty) {
          failed.add('${f.name}（内容为空）');
          continue;
        }
        // 保留原名去扩展名，如 2023全国卷I.docx → 2023全国卷I.txt；
        // 若该名字已由内置真题占用，则改用「（用户导入）」后缀，互不覆盖。
        final dotIdx = f.name.lastIndexOf('.');
        var baseName = dotIdx > 0 ? f.name.substring(0, dotIdx) : f.name;
        var outName = '$baseName.txt';
        if (_builtinManagedNames.contains(outName)) {
          outName = '$baseName（用户导入）.txt';
          var i = 2;
          while (_builtinManagedNames.contains(outName)) {
            outName = '$baseName（用户导入$i）.txt';
            i++;
          }
        }
        final out = File('${corpusDir.path}/$outName');
        await out.writeAsString(content);
        // 用户主动导入的文件加入生效集，立即参与统计与显示；
        // 该集合会写入配置，重启后自动恢复（仅本应用内导入的文件）。
        _userActiveNames.add(outName);
        success++;
      } catch (e) {
        failed.add('${f.name}（$e）');
      }
    }

    // 持久化用户主动导入的文件名，重启后自动恢复
    if (success > 0) await _saveConfig();
    // 触发索引重建：删除旧 corpus_index.json 并清空内存缓存
    await _deleteCorpusIndex(corpusDir.path);

    await _refreshCorpusCount();
    // 语料变更后重新统计年份命中单词数（后台，不阻塞提示条）
    _refreshYearHitCounts();
    if (!mounted) return;
    showAppSnackBar(
      context,
      success > 0 ? '成功导入 $success 个真题文件' : '导入失败，请检查文件格式：${failed.join('；')}',
      type: AppSnackBarType.info,
    );
    if (failed.isNotEmpty) {
      showAppSnackBar(
        context,
        '以下文件导入失败：${failed.join('；')}',
        type: AppSnackBarType.error,
      );
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
            : await _extractImportContentFromPathAsync(p!, n);
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
    showAppSnackBar(
      context,
      success > 0 ? '成功导入 $success 个教材文件' : '导入失败，请检查文件格式：${failed.join('；')}',
      type: AppSnackBarType.info,
    );
    if (failed.isNotEmpty) {
      showAppSnackBar(
        context,
        '以下教材文件导入失败：${failed.join('；')}',
        type: AppSnackBarType.error,
      );
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
      final estText = estSec >= 60
          ? '约 ${(estSec ~/ 60).toString()} 分钟'
          : '约 $estSec 秒';

      // 内存能力预检：估算提取字符量并对照「页数/字符 → 内存」模型，
      // 超出本机安全上限时先弹窗提示可处理页数上限，避免检测中 OOM 闪退无结果。
      final estChars = _estimateCharsOf(rawLen, file.name);
      final maxChars = _maxCapableChars();
      final overCapable = estChars > maxChars;
      if (overCapable) {
        final maxPages = (maxChars / 1800).floor(); // 按每页约 1800 字符换算
        final curPages = (estChars / 1800).ceil();
        if (mounted) {
          final goCap = await showEswConfirm(
            context,
            title: '文档超出本机处理能力',
            message:
                '本机最大可处理约 $maxPages 页（约 ${(maxChars / 10000).round()} 万字符），'
                '当前文档约 $curPages 页（约 ${(estChars / 10000).round()} 万字符），'
                '继续检测可能因内存不足闪退且无结果。\n\n'
                '建议：拆分文档（如按年份/单元拆分）或压缩后重试。',
            icon: Icons.warning_amber_rounded,
            danger: true,
            cancelLabel: '取消',
            okLabel: '仍然尝试',
          );
          if (!goCap) return;
        }
      }

      if (mounted) {
        final go = await showEswConfirm(
          context,
          title: '检测大文件',
          message: rawLen >= 200 * 1024
              ? '该文件较大（${(rawLen / 1024 / 1024).toStringAsFixed(1)} MB），检测需要处理完整文档内容，预计$estText。处理期间界面会保持响应，请耐心等待，不要重复点击。'
              : '检测该文件预计需要$estText，是否继续？',
          icon: Icons.schedule_rounded,
          cancelLabel: '取消',
          okLabel: '继续检测',
        );
        if (!go) return;
      }

      // 提取阶段进度提示框（不 await，提取完成后统一关闭）
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) =>
            eswProgressDialog(title: '正在提取文档文本', message: '文档较大时可能需要数秒，请稍候…'),
      );
      // 先提取纯数据再进闭包，避免捕获整个 PlatformFile（含 XFile 等不可发送字段）
      final p = filePath;
      final n = file.name;
      // PDF 依赖 pdfrx（native + async），在主 isolate 解析；其余格式走后台 isolate worker
      content = n.toLowerCase().endsWith('.pdf')
          ? await _readPdfFileByPath(p)
          : await _extractImportContentFromPathAsync(p, n);
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
      final goSync = await showEswChoice<String>(
        context,
        title: '词库未同步',
        message: '当前未检测到已同步的筛选词库，导入文档后拓展词将无法映射到课标词，导出结果可能不完整。建议先「同步词库」再导入检测。',
        icon: Icons.cloud_sync_rounded,
        choices: const [
          EswDialogChoice(label: '仍然导入', value: 'import'),
          EswDialogChoice(label: '去同步', value: 'sync', primary: true),
        ],
      );
      if (goSync == 'sync') {
        await _syncVocab();
        return;
      }
    }

    if (mounted) {
      // 检测口径：文档里只要有英文单词就照常检测，中文等其他文字一律略过
      // （切词正则本身即 [A-Za-z]{2,}，非英文内容不参与统计）。
      // 完全没有英文的文档提前给出明确提示，避免进入空结果页后再导出空文件，
      // 把「文档里没有可检测的词」误判成「导出失败」。
      if (!RegExp(r'[A-Za-z]{2,}').hasMatch(content)) {
        showAppSnackBar(
          context,
          '该文档未检测到英文单词，无需检测',
          type: AppSnackBarType.info,
        );
        return;
      }
      _showAnalysisResult(content, file.name, sourcePath: file.path);
    }
  }

  /// 扫描文档内容：调起系统相机拍一页文档 → 本地离线识别文字 →
  /// 自动填入文本框并直接进入检测（与「选择文件检测」走同一检测流程）。
  ///
  /// 连拍多页：识别结果追加到已有文本后面，最后一次即可检测整份文档。
  Future<void> _scanDocument() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      while (mounted) {
        // ① 自定义实时预览页：自动识别文档边界，可拖动四角微调，
        //    点快门即按当前边界做透视校正并返回裁切后的图片
        final cropped = await ScanCameraPage.open(context);
        if (!mounted) return;
        if (cropped == null) return;

        // ③ 识别期间给出明确进度
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => eswProgressDialog(
            title: '正在识别文字',
            message: '正在识别页面与段落，请稍候…',
          ),
        );
        ScanTextResult result;
        try {
          result = await ScanOcrService.recognizeImage(cropped);
        } finally {
          if (mounted) Navigator.of(context, rootNavigator: true).pop();
        }
        if (!mounted) return;

        // ④ 与已有文本合并：便于连续扫描多页后一次检测
        final previous = _pasteCtrl.text.trim();
        final merged = previous.isEmpty ? result.text : '$previous\n\n${result.text}';
        _pasteCtrl.text = merged;
        _pasteCtrl.selection = TextSelection.collapsed(offset: merged.length);
        if (result.latinWordCount == 0) {
          showAppSnackBar(context, '识别到的内容里没有英文单词，已填入文本框，可补充内容后再检测',
              type: AppSnackBarType.info);
          return;
        }

        // ⑤ 落一份临时 txt：让「最近检测」记录可回看原文，与文件导入体验一致
        final now = DateTime.now();
        final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
            '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}'
            '${now.second.toString().padLeft(2, '0')}';
        String? saved;
        try {
          saved = await ScanOcrService.saveTempText(merged, name: '扫描文档_$stamp');
        } catch (_) {
          saved = null; // 临时文件失败不影响检测
        }
        // ⑥ 另存裁切原图：识别可能不准，检测页/历史上可随时调出原图比对
        final photo = await ScanOcrService.savePhoto(
          cropped,
          name: '扫描文档_$stamp',
        );
        if (!mounted) return;

        showAppSnackBar(
          context,
          '已识别 ${result.paragraphs} 段、${result.latinWordCount} 个英文词，开始检测',
          type: AppSnackBarType.success,
        );
        _showAnalysisResult(
          merged,
          '扫描文档_$stamp',
          sourcePath: saved,
          photoPath: photo,
        );
        return;
      }
    } on ScanException catch (e) {
      if (mounted) {
        showAppSnackBar(context, e.message, type: AppSnackBarType.error);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '扫描失败：$e', type: AppSnackBarType.error);
      }
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      } else {
        _scanning = false;
      }
    }
  }

  /// 估算单文件检测总耗时（秒）：文本提取 + 分析。
  /// 提取：按源字节量估算（大 .doc/.docx 提取较慢，留余量）；
  /// 分析：按预估提取字符量估算（约每 20 万字符 1 秒，保守系数 2）。
  int _estimateDetectSeconds(int rawBytes, String name) {
    final ext = name.toLowerCase();
    final extractPerMbSec = (ext.endsWith('.doc') || ext.endsWith('.docx'))
        ? 8.0
        : 2.0;
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
    final safeBytes =
        (largeHeapBytes * 45 ~/ 100) > (normalHeapBytes * 40 ~/ 100)
        ? largeHeapBytes * 45 ~/ 100
        : normalHeapBytes * 40 ~/ 100;
    return safeBytes ~/ bpc;
  }

  Future<void> _showAnalysisResult(
    String text,
    String fileName, {
    String? sourcePath,
    String? historyExportPath,
    String? photoPath,
    _DetectHistory? origin,
  }) async {
    // 三条入口（内置/导入的 txt·docx·pdf、粘贴文本、扫描识别）在进入分析前
    // 统一规范化一次：制表符当分隔、软换行当断行、选项标记前紧邻字母强制断开，
    // 避免分词产出 itB / ofB / toC / AsC 这类粘连 token。
    text = normalizeText(text);
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => _AnalysisPage(
          text: text,
          fileName: fileName,
          sourcePath: sourcePath,
          historyExportPath: historyExportPath,
          photoPath: photoPath,
          vocab: _vocab,
          onSaveConfig: _saveConfig,
          wordSyncService: _wordSyncService,
          userId: _userId,
          corpusNames: _activeCorpusNames,
          onImportCorpus: _importCorpus,
          onImportTextbook: _importTextbook,
          onWordTap: (word) {
            _switchTab(0);
            _searchCtrl.text = word;
            _lookupWord(word);
          },
        ),
      ),
    );
    // 返回后清空输入框
    _pasteCtrl.clear();
    if (result != null && mounted) {
      final counts = Map<String, int>.from(result['categoryCounts'] as Map);
      final exported = result['exportPath'] as String?;
      final annotated = result['annotatedCount'] as int? ?? 0;
      setState(() {
        if (origin != null) {
          // 从「最近检测」历史项进入的重新检测：原地更新该条目，避免重复堆叠
          origin
            ..time = DateTime.now()
            ..totalWords = result['totalWords'] as int
            ..annotatedCount = annotated
            ..exportPath = exported;
          origin.categoryCounts
            ..clear()
            ..addAll(counts);
          _detectHistory
            ..remove(origin)
            ..insert(0, origin);
          return;
        }
        _detectHistory.insert(
          0,
          _DetectHistory(
            fileName: _safeDocName(result['fileName'] as String?),
            time: DateTime.now(),
            totalWords: result['totalWords'] as int,
            categoryCounts: counts,
            sourcePath: result['sourcePath'] as String?,
            annotatedCount: annotated,
            photoPath: photoPath,
            exportPath: exported,
          ),
        );
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
      final base =
          _vocab.extendBaseMap[word.toLowerCase()] ??
          _vocab.extendBaseMap[word];
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
              'category': isStd
                  ? savedCat!
                  : (_vocab.isExtend(word) ? '拓展词' : '词典'),
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
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      onChanged: (q) {
                        final lower = q.trim().toLowerCase();
                        setDialogState(() {
                          if (lower.isEmpty) {
                            matches = _getBaseWordCandidates(word, allStandard);
                          } else {
                            matches = _getBaseWordCandidates(
                              lower,
                              allStandard,
                            );
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Text(
                                w,
                                style: const TextStyle(fontSize: 16),
                              ),
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
    if (RegExp(
          r'(tion|sion|ment|ness|ity|ance|ence|ism|ship|hood|ure|dom|th|tude)$',
        ).hasMatch(w) &&
        w.length > 4) {
      return 'n.';
    }
    if (RegExp(
          r'(ive|able|ible|ial|ous|eous|ious|ful|less|ish|ant|ent|ary|ory|ic|al)$',
        ).hasMatch(w) &&
        w.length > 4) {
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: labelColor, width: 1.5),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Text(
                    categoryLabel,
                    style: TextStyle(
                      fontSize: 13,
                      color: labelColor,
                      fontWeight: FontWeight.bold,
                    ),
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
                      style: const TextStyle(
                        fontSize: 15,
                        fontFamily: 'monospace',
                        color: AppTheme.primaryBlue,
                      ),
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
              ...posDefPairs.map(
                (p) => Padding(
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
                ),
              ),
            // 兜底释义
            if (posDefPairs.isEmpty ||
                posDefPairs.every((p) => (p['def'] ?? '').isEmpty))
              Builder(
                builder: (_) {
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
                },
              ),
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
                    _markButton(
                      '+ 拓展词',
                      AppTheme.green,
                      () => _handleReclassify('拓展词'),
                    ),
                    const SizedBox(width: 12),
                    _markButton(
                      '+ 超标词',
                      AppTheme.red,
                      () => _handleReclassify('超标词'),
                    ),
                    const SizedBox(width: 12),
                    _markButton(
                      '+ 专有词',
                      AppTheme.grey,
                      () => _handleReclassify('专有词'),
                    ),
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
      final match = RegExp(
        r'^([a-z]+\.(?:\s*&\s*[a-z]+\.)?)\s*(.*)$',
      ).firstMatch(part.trim());
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
      children: List.generate(
        5,
        (i) => Icon(
          i < stars ? Icons.star : Icons.star_border,
          size: 14,
          color: AppTheme.primaryYellow,
        ),
      ),
    );
  }

  /// 紧凑标记按钮
  Widget _markButton(String label, Color color, VoidCallback onPressed) {
    final isCurrent =
        _currentManualCategory(_searchResult.toLowerCase()) == label;
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
    if (_vocab.manualChaoGangWords.any((e) => e.toLowerCase() == lower)) {
      return '超标词';
    }
    if (_vocab.manualExtraWords.any((e) => e.toLowerCase() == lower)) {
      return '专有词';
    }
    return null;
  }

  /// 处理重新归类：若单词已有手动分类且不同于目标，弹出确认对话框。
  Future<void> _handleReclassify(String targetCategory) async {
    final lower = _searchResult.toLowerCase();
    final currentCat = _currentManualCategory(lower);

    if (currentCat != null && currentCat != targetCategory) {
      final confirmed = await showEswConfirm(
        context,
        title: '重新归类确认',
        message:
            '「$_searchResult」已归类为「$currentCat」\n\n确定要改为「$targetCategory」吗？后续检测将按新归类执行。',
        icon: Icons.swap_horiz_rounded,
        cancelLabel: '取消',
        okLabel: '确认更改',
      );
      if (!confirmed) return;
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
        showAppSnackBar(
          context,
          '已重新归类为：$targetCategory',
          type: AppSnackBarType.success,
        );
      }
    }
  }

  /// 真题词频区域：从 corpus 目录统计当前查询单词的出现次数与逐年分布。
  Widget _buildWordFrequency() {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _corpusDirPath().then(
        (p) => _vocab.getWordFrequency(
          _searchResult,
          p,
          onlyNames: _activeCorpusNames,
        ),
      ),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }

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
                const Icon(
                  Icons.bar_chart,
                  size: 18,
                  color: AppTheme.primaryBlue,
                ),
                const SizedBox(width: 6),
                Text(
                  '真题词频',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  ),
                  child: Text(
                    '共 $total 次',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.primaryBlue,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...(byYear.entries.toList()..sort((a, b) => b.key.compareTo(a.key)))
                .map((e) {
                  final year = e.key;
                  final sentences = (e.value as List)
                      .cast<Map<String, dynamic>>();
                  return ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '$year: ${sentences.length} 次',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    children: sentences.map((s) {
                      final text = s['text'] as String? ?? '';
                      final filePath = s['filePath'] as String? ?? '';
                      final offset = ((s['offset'] as num?) ?? 0).toInt();
                      return InkWell(
                        onTap: filePath.isNotEmpty
                            ? () => Navigator.of(context, rootNavigator: true)
                                  .push(
                                    MaterialPageRoute(
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
                                    ),
                                  )
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12, bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '•',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              Expanded(
                                child: _highlightSentence(text, _searchResult),
                              ),
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
      return Text(
        sentence,
        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
      );
    }
    final regex = RegExp(
      r'\b' + RegExp.escape(word) + r'\b',
      caseSensitive: false,
    );
    final matches = regex.allMatches(sentence).toList();
    if (matches.isEmpty) {
      return Text(
        sentence,
        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
      );
    }

    final spans = <TextSpan>[];
    int lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: sentence.substring(lastEnd, m.start)));
      }
      final kw = sentence.substring(m.start, m.end);
      spans.add(
        TextSpan(
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
        ),
      );
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
                    final sentences = (entry.value as List)
                        .cast<Map<String, dynamic>>();
                    for (final s in sentences) {
                      final text = s['text'] as String? ?? '';
                      if (text.toLowerCase().contains(word.toLowerCase())) {
                        final filePath = s['filePath'] as String? ?? '';
                        final offset = ((s['offset'] as num?) ?? 0).toInt();
                        if (filePath.isNotEmpty) {
                          Navigator.of(context, rootNavigator: true).push(
                            MaterialPageRoute(
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
                            ),
                          );
                          return;
                        }
                      }
                    }
                  }
                }
                showAppSnackBar(
                  context,
                  '未找到对应真题',
                  type: AppSnackBarType.error,
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
      case '课标词':
        return AppTheme.primaryBlue;
      case '拓展词':
        return AppTheme.green;
      case '超标词':
        return AppTheme.red;
      case '专有词':
        return AppTheme.grey;
      default:
        return AppTheme.orange;
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
  static List<String> _splitChunks(
    String text, {
    int maxChunk = _maxChunkChars,
  }) {
    final chunks = <String>[];
    final n = text.length;
    if (n == 0) return chunks;
    // 优先在空白/常见标点处断开，避免切在单词中间（撇号是词内字符，不在此断开）
    final boundary = RegExp(r'[\s\u3000，。；：！？、,.!?;:()（）\[\]"]');
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
          showAppSnackBar(
            context,
            '真题文件不存在：\${widget.filePath}',
            type: AppSnackBarType.error,
          );
        }
        _content = '真题文件不存在：\${widget.filePath}';
        if (mounted) setState(() => _loading = false);
        return;
      }
      final text = decodeTextBytes(await file.readAsBytes());
      _content = text;
      // 分块懒加载
      _chunks = _splitChunks(text);
      // 计算关键词在原文中的字符范围
      final pattern = RegExp(
        r'\b' + RegExp.escape(widget.keyword) + r'\b',
        caseSensitive: false,
      );
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
    final pattern = RegExp(
      r'\b' + RegExp.escape(keyword) + r'\b',
      caseSensitive: false,
    );
    final matches = pattern.allMatches(chunk).toList();
    if (matches.isEmpty) return [TextSpan(text: chunk)];
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: chunk.substring(cursor, m.start)));
      }
      spans.add(
        TextSpan(
          text: m.group(0)!,
          style: const TextStyle(
            backgroundColor: Color(0x66FFEB3B),
            fontWeight: FontWeight.bold,
            color: Colors.red,
          ),
        ),
      );
      cursor = m.end;
    }
    if (cursor < chunk.length) {
      spans.add(TextSpan(text: chunk.substring(cursor)));
    }
    return spans;
  }

  /// 长按选中单词后的自定义菜单：复制 / 修改 / 查词」
  /// 位置由系统按选区自动定位（选区上方），避免手动命中测试因分辨率导致偏移」
  Widget _buildWordContextMenu(
    BuildContext context,
    SelectableRegionState state,
  ) {
    final content = _selectedContent;
    final word = content?.plainText.trim() ?? '';
    if (word.isEmpty) return const SizedBox.shrink();
    final isWord = RegExp(
      r"^(?:[a-zA-Z]+(?:\.[a-zA-Z]+)+\.?|[a-zA-Z]+(?:['“][a-zA-Z]+)*)$",
    ).hasMatch(word);
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
            showAppSnackBar(
              context,
              '已复制 $word',
              type: AppSnackBarType.success,
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
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newWord == null || newWord.isEmpty || newWord == oldWord) return;
    if (!RegExp(r'^[a-zA-Z]+$').hasMatch(newWord)) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        '$newWord 不是合法的英文单词',
        type: AppSnackBarType.info,
      );
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
      final pattern = RegExp(
        r'\b' + RegExp.escape(newWord) + r'\b',
        caseSensitive: false,
      );
      final m = pattern.firstMatch(_content);
      _highlightChunkIndex = (m != null) ? _chunkIndexAt(_chunks, m.start) : 0;
    });
    showAppSnackBar(
      context,
      '已将真题文件中 $oldWord 改为 $newWord',
      type: AppSnackBarType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.filePath.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: AppTheme.surfaceLight,
      appBar: AppBar(
        title: Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
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
                      onSelectionChanged: (content) =>
                          _selectedContent = content,
                      contextMenuBuilder: _buildWordContextMenu,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text.rich(
                          TextSpan(
                            style: const TextStyle(
                              fontSize: 15,
                              height: 1.6,
                              color: Colors.black87,
                            ),
                            children: _buildChunkSpans(chunk),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded, size: 22),
              label: const Text(
                '返回段落分析',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 语料栏（手机端全高底部面板）。
///
/// 按检测结果类型只展示一列：真题结果 → 真题列表；教材结果 → 教材列表。
/// - 列表占满可用高度，底部面板可整体滚动；
/// - 点击条目在该行下方就地展开原文，原文区可滚动并定位高亮被查单词；
/// - 打开时若指定了文件，列表自动滚动到该项并居中高亮；
/// - 默认不展开任何条目（查词时阅读区保持空白，不自动打开上次内容）。
class CorpusSheet extends StatefulWidget {
  const CorpusSheet({
    super.key,
    required this.isTextbook,
    required this.dirPath,
    required this.highlightPath,
    required this.keyword,
    required this.onImportCorpus,
    required this.onImportTextbook,
  });

  final bool isTextbook;
  final String dirPath;
  final String? highlightPath;
  final String? keyword;
  final Future<void> Function() onImportCorpus;
  final Future<void> Function() onImportTextbook;

  @override
  State<CorpusSheet> createState() => _CorpusSheetState();
}

class _CorpusSheetState extends State<CorpusSheet> {
  List<String> _files = const [];
  Set<String> _builtinNames = const <String>{};
  bool _loading = true;
  String? _searchingKeywordFor;

  String? _expandedName;
  String? _expandedContent;
  bool _contentLoading = false;
  bool _truncated = false;

  /// 原文内被查词所在段落的 Key：展开后滚动到该段。
  GlobalKey? _keywordLineKey;
  final ScrollController _readerScroll = ScrollController();
  final ScrollController _listScroll = ScrollController();

  final Map<String, GlobalKey> _rowKeys = {};

  static const int _kReaderMaxChars = 60000;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  @override
  void dispose() {
    _readerScroll.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  Future<void> _loadFiles() async {
    List<String> files = const [];
    Set<String> builtin = const <String>{};
    try {
      final dir = Directory(widget.dirPath);
      if (await dir.exists()) {
        final names = <String>[];
        await for (final e in dir.list(followLinks: false)) {
          if (e is! File) continue;
          final name = e.path.split(RegExp(r'[\\/]')).last;
          if (name.toLowerCase().endsWith('.txt')) names.add(name);
        }
        names.sort((a, b) => b.compareTo(a));
        files = names;
      }
      if (!widget.isTextbook) {
        builtin = await BuiltinCorpus.flatNames(widget.dirPath);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _files = files;
      _builtinNames = builtin;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealOnOpen());
  }

  String? get _highlightName {
    final p = widget.highlightPath;
    if (p == null || p.isEmpty) return null;
    var name = p.split(RegExp(r'[\\/]')).last;
    if (_files.contains(name)) return name;
    // 源文件可能是 docx/pdf，实际落盘为同名 .txt（导入时统一转 txt）
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      name = '${name.substring(0, dot)}.txt';
      if (_files.contains(name)) return name;
    }
    return null;
  }

  /// 打开时滚动到指定文件并居中高亮；带被查词时自动展开并定位到词。
  Future<void> _revealOnOpen() async {
    if (!mounted) return;
    var target = _highlightName;
    final keyword = widget.keyword?.trim() ?? '';
    if (target != null) {
      await _scrollToName(target, alignment: 0.42);
      if (keyword.isNotEmpty) await _expand(target);
      return;
    }
    if (keyword.isEmpty) return;
    // 无来源路径（粘贴/扫描结果）时按内容查找首个包含该词的语料。
    setState(() => _searchingKeywordFor = keyword);
    String? found;
    for (final name in _files) {
      try {
        final text = await File('${widget.dirPath}/$name').readAsString();
        if (text.toLowerCase().contains(keyword.toLowerCase())) {
          found = name;
          break;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _searchingKeywordFor = null);
    if (found != null) await _expand(found);
  }

  /// 列表采用惰性构建，远处条目的 context 可能尚未创建：先用估算偏移把
  /// 目标行滚入视口，再在下一帧用 ensureVisible 精确居中。
  Future<void> _scrollToName(String name, {double alignment = 0.42}) async {
    final flatIndex = _flatRowIndex(name);
    if (flatIndex == null) return;
    if (_listScroll.hasClients) {
      const estimatedItemExtent = 46.0;
      final max = _listScroll.position.maxScrollExtent;
      final viewport = _listScroll.position.viewportDimension;
      final targetOffset = (flatIndex * estimatedItemExtent -
              viewport * alignment)
          .clamp(0.0, max);
      await _listScroll.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    final ctx = _rowKeys[name]?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: alignment,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
  }

  int? _flatRowIndex(String name) {
    if (!_files.contains(name)) return null;
    final builtin = _files
        .where((n) => _builtinNames.contains(n))
        .toList(growable: false);
    final user = _files
        .where((n) => !_builtinNames.contains(n))
        .toList(growable: false);
    var index = 0;
    if (builtin.isNotEmpty) index++; // 分组标题
    final bi = builtin.indexOf(name);
    if (bi >= 0) return index + bi;
    index += builtin.length;
    if (user.isNotEmpty) index++; // 分组标题
    final ui = user.indexOf(name);
    return ui >= 0 ? index + ui : null;
  }

  Future<void> _expand(String name) async {
    if (!mounted) return;
    setState(() {
      _expandedName = name;
      _expandedContent = null;
      _contentLoading = true;
      _truncated = false;
      _keywordLineKey = null;
    });
    String content = '';
    try {
      content = await File('${widget.dirPath}/$name').readAsString();
    } catch (_) {
      content = '';
    }
    final keyword = widget.keyword?.trim() ?? '';
    if (content.length > _kReaderMaxChars) {
      if (keyword.isNotEmpty) {
        final idx = content.toLowerCase().indexOf(keyword.toLowerCase());
        if (idx >= 0) {
          final start = (idx - _kReaderMaxChars ~/ 3).clamp(0, content.length);
          content = content.substring(
            start,
            (start + _kReaderMaxChars).clamp(0, content.length),
          );
        } else {
          content = content.substring(0, _kReaderMaxChars);
        }
      } else {
        content = content.substring(0, _kReaderMaxChars);
      }
      _truncated = true;
    }
    if (!mounted) return;
    setState(() {
      _expandedContent = content;
      _contentLoading = false;
    });
    if (!mounted || _expandedName != name) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // 新展开的原文从顶部开始读；再按需滚动到被查词所在段落
      if (_readerScroll.hasClients) _readerScroll.jumpTo(0);
      await _scrollToName(name, alignment: 0.12);
      if (!mounted) return;
      final kwCtx = _keywordLineKey?.currentContext;
      if (kwCtx != null && kwCtx.mounted) {
        await Scrollable.ensureVisible(
          kwCtx,
          alignment: 0.22,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _toggle(String name) {
    if (_expandedName == name) {
      setState(() {
        _expandedName = null;
        _expandedContent = null;
        _keywordLineKey = null;
      });
      return;
    }
    _expand(name);
  }

  Future<void> _import({required bool textbook}) async {
    if (textbook) {
      await widget.onImportTextbook();
    } else {
      await widget.onImportCorpus();
    }
    await _loadFiles();
  }

  /// 原文段落：目标词高亮；首个命中段落挂 Key 以便滚动定位。
  List<Widget> _buildReaderLines(double f) {
    final content = _expandedContent ?? '';
    final keyword = widget.keyword?.trim() ?? '';
    final lines = content.split('\n');
    final widgets = <Widget>[];
    final pattern = keyword.isEmpty
        ? null
        : RegExp(RegExp.escape(keyword), caseSensitive: false);
    var keyPlaced = false;
    for (final line in lines) {
      if (line.isEmpty) {
        widgets.add(SizedBox(height: 6 * f));
        continue;
      }
      final spans = <TextSpan>[];
      var lineHasKeyword = false;
      if (pattern == null) {
        spans.add(TextSpan(text: line));
      } else {
        var last = 0;
        for (final m in pattern.allMatches(line)) {
          if (m.start > last) {
            spans.add(TextSpan(text: line.substring(last, m.start)));
          }
          spans.add(TextSpan(
            text: line.substring(m.start, m.end),
            style: const TextStyle(
              backgroundColor: Color(0xFFFFE082),
              fontWeight: FontWeight.w700,
            ),
          ));
          last = m.end;
          lineHasKeyword = true;
        }
        if (last < line.length) {
          spans.add(TextSpan(text: line.substring(last)));
        }
      }
      Widget text = Padding(
        padding: EdgeInsets.only(bottom: 4 * f),
        child: Text.rich(
          TextSpan(
            style: TextStyle(
              fontSize: 13.5 * f,
              height: 1.65,
              color: Colors.black87,
            ),
            children: spans,
          ),
        ),
      );
      if (lineHasKeyword && !keyPlaced) {
        keyPlaced = true;
        _keywordLineKey ??= GlobalKey();
        text = KeyedSubtree(key: _keywordLineKey!, child: text);
      }
      widgets.add(text);
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    final builtinFiles = _files
        .where((n) => _builtinNames.contains(n))
        .toList(growable: false);
    final userFiles = _files
        .where((n) => !_builtinNames.contains(n))
        .toList(growable: false);

    return Container(
      decoration: BoxDecoration(
        color: EswColors.page,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(EswRadius.card * f),
        ),
      ),
      child: Column(
        children: [
          // 拖拽把手
          Container(
            margin: EdgeInsets.only(top: 8 * f, bottom: 4 * f),
            width: 40 * f,
            height: 4 * f,
            decoration: BoxDecoration(
              color: EswColors.border,
              borderRadius: BorderRadius.circular(2 * f),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              EswSpace.lg * f,
              2 * f,
              EswSpace.lg * f,
              6 * f,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      widget.isTextbook
                          ? Icons.menu_book_rounded
                          : Icons.folder_copy_outlined,
                      color: EswColors.primary,
                      size: 20 * f,
                    ),
                    SizedBox(width: 8 * f),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.isTextbook ? '教材语料' : '真题语料',
                            style: EswText.titleSmall.copyWith(
                              fontSize: 17 * f,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _searchingKeywordFor == null
                                ? '点击条目展开原文；长按检测列表中的单词可定位'
                                : '正在查找「$_searchingKeywordFor」所在语料…',
                            style: EswText.caption.copyWith(
                              fontSize: 11.5 * f,
                              color: EswColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6 * f),
                // 返回段落分析：显著放大、一眼可见的返回入口。
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.arrow_back_rounded, size: 22 * f),
                    label: Text(
                      '返回段落分析',
                      style: TextStyle(
                        fontSize: 16 * f,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 6 * f),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _import(textbook: false),
                        icon: Icon(Icons.playlist_add_rounded, size: 18 * f),
                        label: const Text('导入真题'),
                      ),
                    ),
                    SizedBox(width: EswSpace.sm * f),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _import(textbook: true),
                        icon: Icon(Icons.library_add_outlined, size: 18 * f),
                        label: const Text('导入教材'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.folder_off_outlined,
                              size: 40 * f,
                              color: AppTheme.textHint,
                            ),
                            SizedBox(height: 8 * f),
                            Text(
                              widget.isTextbook ? '暂无教材文件' : '暂无真题文件',
                              style: EswText.bodySmall.copyWith(
                                color: EswColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        controller: _listScroll,
                        padding: EdgeInsets.only(bottom: 16 * f),
                        children: [
                          if (builtinFiles.isNotEmpty) ...[
                            _groupHeader('内置真题', builtinFiles.length, f),
                            for (final name in builtinFiles)
                              _buildRow(name, isBuiltin: true, f: f),
                          ],
                          if (userFiles.isNotEmpty) ...[
                            _groupHeader(
                              widget.isTextbook ? '教材文件' : '我的导入',
                              userFiles.length,
                              f,
                            ),
                            for (final name in userFiles)
                              _buildRow(name, isBuiltin: false, f: f),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(String title, int count, double f) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        EswSpace.lg * f,
        EswSpace.sm * f,
        8 * f,
        4 * f,
      ),
      child: Text(
        '$title（$count）',
        style: EswText.caption.copyWith(
          fontSize: 12 * f,
          fontWeight: FontWeight.w600,
          color: EswColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildRow(String name, {required bool isBuiltin, required double f}) {
    final selected = _expandedName == name;
    final highlighted = _highlightName == name;
    final rowKey = _rowKeys.putIfAbsent(name, () => GlobalKey());
    final display = name.toLowerCase().endsWith('.txt')
        ? name.substring(0, name.length - 4)
        : name;
    return Column(
      children: [
        Material(
          color: highlighted
              ? EswColors.primarySoft
              : (selected ? EswColors.primary.withValues(alpha: 0.05) : Colors.white),
          child: InkWell(
            key: rowKey,
            onTap: () => _toggle(name),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: EswSpace.lg * f,
                vertical: 11 * f,
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 20 * f,
                    color: EswColors.textSecondary,
                  ),
                  SizedBox(width: 6 * f),
                  Expanded(
                    child: Text(
                      display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EswText.bodySmall.copyWith(
                        fontSize: 14 * f,
                        fontWeight:
                            highlighted ? FontWeight.w700 : FontWeight.w500,
                        color: highlighted
                            ? EswColors.primary
                            : EswColors.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(width: 6 * f),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 6 * f,
                      vertical: 1 * f,
                    ),
                    decoration: BoxDecoration(
                      color: (isBuiltin ? EswColors.blue : EswColors.green)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(EswRadius.small),
                    ),
                    child: Text(
                      isBuiltin ? '内置' : '我的',
                      style: EswText.caption.copyWith(
                        fontSize: 10.5 * f,
                        color: isBuiltin ? EswColors.blue : EswColors.green,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (selected) _buildReader(f),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildReader(double f) {
    if (_contentLoading) {
      return SizedBox(
        height: 160 * f,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return Container(
      color: const Color(0xFFFBFBFD),
      padding: EdgeInsets.fromLTRB(
        EswSpace.lg * f,
        EswSpace.sm * f,
        EswSpace.lg * f,
        EswSpace.sm * f,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: (MediaQuery.sizeOf(context).height * 0.36)
                .clamp(220.0, 420.0)
                .toDouble(),
            child: SelectionArea(
              child: Scrollbar(
                controller: _readerScroll,
                child: SingleChildScrollView(
                  controller: _readerScroll,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildReaderLines(f),
                  ),
                ),
              ),
            ),
          ),
          if (_truncated)
            Padding(
              padding: EdgeInsets.only(top: 4 * f),
              child: Text(
                '原文较长，仅显示包含目标词的片段；完整内容请在真题文件中查看。',
                style: EswText.caption.copyWith(
                  fontSize: 11 * f,
                  color: AppTheme.textHint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 文本检测历史记录项
class _DetectHistory {
  final String fileName;
  DateTime time;
  int totalWords;
  final Map<String, int> categoryCounts;
  final String? sourcePath; // P6：不存全文，仅存导入源路径，重看时按需重新提取

  /// 扫描来源的原图（裁切后）绝对路径：识别可能不准，供人工比对；非扫描为 null。
  final String? photoPath;
  int annotatedCount;

  /// 最近一次导出到本机磁盘的检测结果文档绝对路径（未导出为 null）。
  /// 点击历史项时优先打开该文档；不存在/已失效则回到检测结果页重新检测。
  String? exportPath;

  _DetectHistory({
    required this.fileName,
    required this.time,
    required this.totalWords,
    required this.categoryCounts,
    required this.sourcePath,
    required this.annotatedCount,
    this.photoPath,
    this.exportPath,
  });
}

class _AnalysisPage extends StatefulWidget {
  final String text;
  final String fileName;
  final String? sourcePath; // 导入源文件绝对路径（docx 时可原地标注保留原排版）

  /// 从「最近检测」历史进入时，该历史项此前导出过的文档路径（可空）。
  final String? historyExportPath;

  /// 扫描来源的原图路径：识别可能不准，提供入口调出原图比对（可空）。
  final String? photoPath;
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final ValueChanged<String>? onWordTap;
  final WordSyncService wordSyncService;
  final String userId;

  /// 本次分析生效的真题文件名（内置 + 本次主动导入）；历史导入文件不参与。
  final Set<String> corpusNames;

  /// 语料栏内的导入入口：复用主页面已有的导入链路，不在分析页复制一套。
  final Future<void> Function() onImportCorpus;
  final Future<void> Function() onImportTextbook;

  const _AnalysisPage({
    required this.text,
    required this.fileName,
    this.sourcePath,
    this.historyExportPath,
    this.photoPath,
    required this.vocab,
    required this.onSaveConfig,
    this.onWordTap,
    required this.wordSyncService,
    required this.userId,
    required this.corpusNames,
    required this.onImportCorpus,
    required this.onImportTextbook,
  });

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

  /// 本页最后一次成功导出到磁盘的检测结果文档路径（点击历史项时用于直接打开）。
  String? _lastExportPath;

  /// 语料栏上下文：按检测结果来源自动切到真题列或教材列。
  String? _corpusDir;
  String? _textbookDir;
  bool _textbookMode = false;
  List<String> _corpusFiles = const [];
  List<String> _textbookFiles = const [];

  /// 带标注全文的导出预算（字符数）。超出则 DOCX 不再附带标注全文，
  /// 仅输出统计/说明/明细——非试题类长文本的标注 XML 可达原文的 15~25 倍，
  /// 是 Android 端导出时 OOM 闪退的直接来源。
  static const int _kExportAnnotateBudgetChars = 200000;

  /// 源 docx 超过该字节数时跳过原地标注（多副本内存峰值过高）。
  static const int _kInplaceDocxMaxBytes = 15 * 1024 * 1024;

  /// 拓展词/超标词明细单次导出的最大词条数：非试题文本可能命中上千词，
  /// 逐词查词典 + 提取例句会长时间卡住甚至失败，超量部分在明细中注明未列出。
  static const int _kExportDetailMaxWords = 1200;

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _analyzing = true;
    _resolveCorpusContext();
    _analyzeInBackground();
  }

  /// 解析真题 / 教材目录，并按本次检测来源决定语料栏展示哪一列：
  /// 处理真题结果 → 真题列表；处理教材结果 → 教材列表。
  Future<void> _resolveCorpusContext() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final corpus = '${docs.path}/corpus';
      final textbook = '${docs.path}/textbook';
      final src = widget.sourcePath ?? '';
      final isTextbook = src.isNotEmpty && src.startsWith(textbook);
      final corpusFiles = await _listTxtNames(corpus);
      final textbookFiles = await _listTxtNames(textbook);
      if (!mounted) return;
      setState(() {
        _corpusDir = corpus;
        _textbookDir = textbook;
        _textbookMode = isTextbook;
        _corpusFiles = corpusFiles;
        _textbookFiles = textbookFiles;
      });
    } catch (_) {
      // 目录不可用时静默降级：不影响检测结果本身
    }
  }

  Future<List<String>> _listTxtNames(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return const [];
      final names = <String>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.path.split(RegExp(r'[\\/]')).last;
        if (name.toLowerCase().endsWith('.txt')) names.add(name);
      }
      names.sort((a, b) => b.compareTo(a));
      return names;
    } catch (_) {
      return const [];
    }
  }

  /// 打开语料栏：手机端为全高底部面板（可滚动列表 + 就地展开原文）。
  /// 默认不展开任何条目，避免自动打开上次阅读或上次导入的文本。
  Future<void> _openCorpusSheet({String? keyword}) async {
    if (_corpusDir == null || _textbookDir == null) {
      await _resolveCorpusContext();
    }
    if (!mounted) return;
    final isTextbook = _textbookMode;
    final dirPath = isTextbook ? _textbookDir! : _corpusDir!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: CorpusSheet(
          isTextbook: isTextbook,
          dirPath: dirPath,
          highlightPath: widget.sourcePath,
          keyword: keyword,
          onImportCorpus: () async {
            await widget.onImportCorpus();
            await _resolveCorpusContext();
          },
          onImportTextbook: () async {
            await widget.onImportTextbook();
            await _resolveCorpusContext();
          },
        ),
      ),
    );
    if (mounted) await _resolveCorpusContext();
  }

  /// 首屏大文本分析走后台 isolate：避免在 UI isolate 同步执行
  /// 全量正则遍历 + 分类 + 中文注解回溯导致界面冻结/ANR，同时
  /// 分析完成后释放 isolate 内的临时大对象，降低 OOM 风险。
  Future<void> _analyzeInBackground() async {
    try {
      final vocab = widget.vocab;
      final args = <String, dynamic>{
        'text': _text,
        'standard': vocab.standardWords.keys.toList(),
        'extend': vocab.extendWordKeySet.toList(),
        'chaogang': vocab.chaoGangWordKeySet.toList(),
        'extra': vocab.extraWordKeySet.toList(),
        'classMem': Map<String, String>.from(vocab.classificationMemory),
      };
      final result = await _analyzeTextAsync(args);
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
        _categoryCounts = Map<String, int>.from(
          result['categoryCounts'] as Map,
        );
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

      // 与后台 worker / Windows 端共用同一分词实现
      for (final original in extractWordTokens(_text)) {
        final lower = original.toLowerCase();
        freqMap[lower] = (freqMap[lower] ?? 0) + 1;
        if (!caseMap.containsKey(lower)) caseMap[lower] = original;
      }

      _words = freqMap.entries.map((e) {
        final lower = e.key;
        final original = caseMap[lower] ?? lower;
        // 词形保留完整（couldn't / China's），查表按「完整词形 → 基形」回退，
        // 否则所有格与缩略形式会整段丢失课标/拓展/超标/专有分类。
        final keys = wordLookupKeys(original);
        final standardHit = widget.vocab.isStandard(original);
        String? cat;
        if (apostropheBaseInStandard(original, standardHit)) {
          // 常见缩写/所有格按基形归课标：I'm / can't / you've 不被历史分类
          // 或专有词误判
          cat = '课标词';
        } else {
          for (final key in keys) {
            final remembered = widget.vocab.classificationMemory[key];
            if (remembered != null) {
              cat = remembered;
              break;
            }
          }
          if (cat == null) {
            if (isProperNounHit(widget.vocab.extraLowerSet, original)) {
              // 首字母大写 / 全大写写法优先命中专有词；小写写法留给用户确认
              cat = '专有词';
            } else {
              for (final key in keys) {
                if (widget.vocab.isStandard(key)) {
                  cat = '课标词';
                  break;
                } else if (widget.vocab.isExtend(key)) {
                  cat = '拓展词';
                  break;
                } else if (widget.vocab.isChaoGang(key)) {
                  cat = '超标词';
                  break;
                }
              }
            }
          }
        }
        return _AnalyzedWord(
          word: original,
          frequency: e.value,
          category: cat ?? '其他',
        );
      }).toList()..sort((a, b) => b.frequency.compareTo(a.frequency));

      _categoryCounts = {};
      for (final w in _words) {
        _categoryCounts[w.category] = (_categoryCounts[w.category] ?? 0) + 1;
      }

      // 构建汉语标注词集合（统计用，仅计数不加色）
      // O(N) 实现：避免对全文反复 substring + firstMatch 造成 O(N^2) 卡顿
      final parenChineseRegex = RegExp(
        r'^\s*[\(（][^)）]*[\u4e00-\u9fa5]+[^)）]*[\)）]',
      );
      final importedWordsLower = _words
          .map((aw) => aw.word.toLowerCase())
          .toSet();
      final annotatedPhrases = <String>{};
      // 与分词口径一致：撇号缩略形式（couldn't）整体当作一个词，不在此处切断
      final wordPattern = wordTokenRegExp;
      bool isAsciiLetter(int u) =>
          (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
      bool isSep(int u) => u == 0x20 || u == 0x09 || u == 0x2D; // 空格 / 制表 / 连字符
      // 用 allMatches 遍历所有词（替代逐位指针推进，避免 O(N^2) 与跨行跳词）
      for (final m in wordPattern.allMatches(_text)) {
        final w = m.group(0)!;
        if (w.length < 2) continue;
        if (!wordLookupKeys(w).any(importedWordsLower.contains)) {
          continue;
        }
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
          if (!importedWordsLower.contains(wordLookupKey(pw))) break;
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
      final index = await _loadCorpusIndex(
        corpusPath,
        onlyNames: widget.corpusNames.toList(),
      );
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
      // 本次页面生命周期内最后一次成功导出的文档路径；未导出则沿用历史项旧值
      'exportPath': _lastExportPath ?? widget.historyExportPath,
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
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _popWithResult,
          ),
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
              Text(
                '正在分析文本…',
                style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
              ),
              SizedBox(height: 4),
              Text(
                '大文档首次分析较慢，请耐心等待',
                style: TextStyle(fontSize: 12, color: AppTheme.textHint),
              ),
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                _textbookMode
                    ? '教材语料 · ${_textbookFiles.length} 份'
                    : '真题语料 · ${_corpusFiles.length} 套',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _popWithResult,
          ),
          actions: [
            if ((widget.photoPath ?? '').isNotEmpty)
              IconButton(
                icon: const Icon(Icons.image_outlined),
                tooltip: '查看原图比对',
                onPressed: () => ScanPhotoPage.open(
                  context,
                  imagePath: widget.photoPath!,
                  text: widget.text,
                  title: '原图 · ${widget.fileName}',
                ),
              ),
            IconButton(
              icon: const Icon(Icons.folder_copy_outlined),
              tooltip: _textbookMode ? '教材语料' : '真题语料',
              onPressed: _openCorpusSheet,
            ),
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: '导出结果',
              onPressed: _exportResult,
            ),
            TextButton(onPressed: _popWithResult, child: const Text('完成')),
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
                    _FilterChip(
                      label: '全部',
                      count: _words.length,
                      selected: _filter == '全部',
                      onTap: () => setState(() {
                        _filter = '全部';
                        _rebuildFiltered();
                      }),
                    ),
                    ...['课标词', '拓展词', '超标词', '专有词', '其他'].map(
                      (cat) => _FilterChip(
                        label: cat,
                        count: _categoryCounts[cat] ?? 0,
                        selected: _filter == cat,
                        onTap: () => setState(() {
                          _filter = cat;
                          _rebuildFiltered();
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            if (_filter == '其他' && (_categoryCounts['其他'] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _batchMode = !_batchMode;
                        if (!_batchMode) _selectedOthers.clear();
                      }),
                      icon: Icon(
                        _batchMode ? Icons.close : Icons.checklist,
                        size: 18,
                      ),
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
                          Icon(
                            Icons.inbox_outlined,
                            size: 36,
                            color: AppTheme.textHint,
                          ),
                          const SizedBox(height: AppTheme.spacingSm),
                          Text(
                            '暂无 ${_filter == '全部' ? '单词' : _filter}',
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
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
                          // 去掉序号圆点：结果列表只保留「词 + 词库标签 + 真题频次」，
                          // 减少视觉噪音；批量归类时才显示勾选框。
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
                              : null,
                          title: Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: _chipColor(aw.category),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => _openSourcePopup(aw.word),
                                // 长按：在语料栏展开该单词所在的真题/教材原文并定位高亮
                                onLongPress: () =>
                                    _openCorpusSheet(keyword: aw.word),
                                child: Text(
                                  aw.word,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _chipColor(
                                    aw.category,
                                  ).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(
                                    AppTheme.radiusSm,
                                  ),
                                ),
                                child: Text(
                                  aw.category,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _chipColor(aw.category),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (_freqLoading)
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else if (realFreq != null && realFreq > 0)
                                GestureDetector(
                                  onTap: () => _openSourcePopup(aw.word),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade50,
                                      borderRadius: BorderRadius.circular(
                                        AppTheme.radiusMd,
                                      ),
                                    ),
                                    child: Text(
                                      '$realFreq',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.blue.shade700,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: aw.category == '其他'
                              ? PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert, size: 18),
                                  onSelected: (cat) async {
                                    if (cat == '修改') {
                                      await _showEditDetectedWordDialog(
                                        aw.word,
                                      );
                                      return;
                                    }
                                    switch (cat) {
                                      case '拓展词':
                                        await _showBaseWordDialog(aw.word);
                                        break;
                                      case '超标词':
                                        widget.vocab.addChaoGangWord(aw.word);
                                        widget.wordSyncService.markChanged(
                                          aw.word,
                                        );
                                        break;
                                      case '专有词':
                                        widget.vocab.addExtraWord(aw.word);
                                        widget.wordSyncService.markChanged(
                                          aw.word,
                                        );
                                        break;
                                    }
                                    widget.onSaveConfig();
                                    _analyze();
                                    if (mounted) setState(() {});
                                  },
                                  itemBuilder: (_) => [
                                    if (aw.category == '其他') ...[
                                      const PopupMenuItem(
                                        value: '拓展词',
                                        child: Text('设为拓展词'),
                                      ),
                                      const PopupMenuItem(
                                        value: '超标词',
                                        child: Text('设为超标词'),
                                      ),
                                      const PopupMenuItem(
                                        value: '专有词',
                                        child: Text('设为专有词'),
                                      ),
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
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: Offset(0, -2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已选 ${_selectedOthers.length} 个',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextButton(
                        onPressed: _batchExtendDialog,
                        child: const Text(
                          '拓展词',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextButton(
                        onPressed: _batchSetChaoGang,
                        child: const Text(
                          '超标词',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextButton(
                        onPressed: _batchSetExtra,
                        child: const Text(
                          '专有词',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
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
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
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
                        if (matches.length == 1 &&
                            matches.first.toLowerCase() == lower) {
                          widget.vocab.addExtendWord(
                            word,
                            baseWord: matches.first,
                          );
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Text(
                                w,
                                style: const TextStyle(fontSize: 16),
                              ),
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
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Text(
                                w,
                                style: const TextStyle(fontSize: 16),
                              ),
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
          showAppSnackBar(
            context,
            '所有待筛选单词已处理完毕',
            type: AppSnackBarType.success,
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
                    Navigator.of(
                      dialogCtx,
                    ).pop(_DialogResult(action: '拓展词', baseWord: m));
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
                            Text(
                              '剩余 $remaining 个待处理',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 13,
                              ),
                            ),
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
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                              onChanged: (q) {
                                final lower = q.trim().toLowerCase();
                                setDialogState(() {
                                  matches = lower.isEmpty
                                      ? _getBaseWordCandidates(
                                          lowerWord,
                                          allStandard,
                                        )
                                      : _getBaseWordCandidates(
                                          lower,
                                          allStandard,
                                        );
                                });
                                tryAutoComplete();
                              },
                              onSubmitted: (_) => tryAutoComplete(),
                            ),
                            const SizedBox(height: 8),
                            Flexible(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 200,
                                ),
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: matches.length,
                                  itemBuilder: (_, i) {
                                    final w = matches[i];
                                    return InkWell(
                                      onTap: () {
                                        widget.vocab.addExtendWord(
                                          word,
                                          baseWord: w,
                                        );
                                        widget.wordSyncService.markChanged(
                                          word,
                                        );
                                        Navigator.of(dialogCtx).pop(
                                          _DialogResult(
                                            action: '拓展词',
                                            baseWord: w,
                                          ),
                                        );
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                        child: Text(
                                          w,
                                          style: const TextStyle(fontSize: 15),
                                        ),
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
                                onPressed: () => Navigator.of(
                                  dialogCtx,
                                ).pop(_DialogResult(action: '专有词')),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.grey[700],
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(80, 36),
                                ),
                                child: const Text(
                                  '专有词',
                                  style: TextStyle(fontSize: 14),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: ElevatedButton(
                                onPressed: () => Navigator.of(
                                  dialogCtx,
                                ).pop(_DialogResult(action: '超标词')),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.orange,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(80, 36),
                                ),
                                child: const Text(
                                  '超标词',
                                  style: TextStyle(fontSize: 14),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: TextButton(
                                onPressed: () =>
                                    Navigator.of(dialogCtx).pop(null),
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

  /// 导出前「单词标注方案」选择弹窗（返回 null 表示用户取消）。
  ///
  /// 方案一「彩色标注」为第一项且默认选中，用户可切到方案二「字体格式标注」；
  /// 弹窗内的说明随选择实时切换，与最终文档里的标注说明同源。
  Future<ExportAnnotateScheme?> _promptAnnotateScheme() {
    var picked = ExportAnnotateScheme.color;
    return showEswCustom<ExportAnnotateScheme>(
      context,
      title: '选择单词标注方案',
      message: '导出时按所选方案标注原文中的单词：',
      icon: Icons.text_fields_rounded,
      content: StatefulBuilder(
        builder: (innerCtx, innerSetState) {
          final f = EswResponsive.factorOf(innerCtx);
          Widget tile({
            required String label,
            required String desc,
            required ExportAnnotateScheme value,
          }) {
            final selected = picked == value;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => innerSetState(() => picked = value),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: EswSpace.sm * f,
                    vertical: EswSpace.md * f,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? EswColors.primarySoft : EswColors.page,
                    borderRadius: BorderRadius.circular(EswRadius.control * f),
                    border: Border.all(
                      color: selected ? EswColors.primary : EswColors.border,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: EswText.label.copyWith(
                          fontSize: 15 * f,
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? EswColors.primary
                              : EswColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: 2 * f),
                      Text(
                        desc,
                        style: EswText.caption.copyWith(
                          fontSize: 12 * f,
                          color: EswColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: EswSpace.md * f),
              Row(
                children: [
                  tile(
                    label: '方案一',
                    desc: '彩色标注（默认）',
                    value: ExportAnnotateScheme.color,
                  ),
                  SizedBox(width: EswSpace.sm * f),
                  tile(
                    label: '方案二',
                    desc: '字体格式标注',
                    value: ExportAnnotateScheme.typography,
                  ),
                ],
              ),
              SizedBox(height: EswSpace.sm * f),
              Container(
                padding: EdgeInsets.all(EswSpace.sm * f),
                decoration: BoxDecoration(
                  color: EswColors.page,
                  borderRadius: BorderRadius.circular(EswRadius.small * f),
                ),
                child: Text(
                  picked == ExportAnnotateScheme.color
                      ? '方案一：仅用颜色区分类型——初中课标词黑色、必修课标词深蓝、'
                          '选修课标词浅蓝、拓展词深绿、超标词红色、专有词紫色；'
                          '不加粗、不加底纹，原文自带加粗保持原样。'
                      : '方案二（黑白打印友好）：课标词默认不标注；拓展词 加粗；'
                          '超标词 单线下划线；专有词 30% 灰底纹；未筛选词不标注；'
                          '全文西文统一 Times New Roman。',
                  style: EswText.bodySmall.copyWith(
                    fontSize: 12 * f,
                    height: 1.6,
                    color: EswColors.textSecondary,
                  ),
                ),
              ),
              SizedBox(height: EswSpace.lg * f),
              Row(
                children: [
                  Expanded(
                    child: eswDialogAction(
                      label: '取消',
                      onPressed: () => Navigator.of(innerCtx).pop(),
                    ),
                  ),
                  SizedBox(width: EswSpace.sm * f),
                  Expanded(
                    child: eswDialogAction(
                      label: '下一步',
                      primary: true,
                      onPressed: () => Navigator.of(innerCtx).pop(picked),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// 导出前提示：存在未筛选词时，用户可先去「其他（未筛选）」筛选，也可直接继续导出。
  ///
  /// 返回 true 表示用户选择「继续导出」。
  Future<bool> _promptUnfilteredBeforeExport(int count) async {
    if (!mounted) return false;
    final choice = await showEswChoice<String>(
      context,
      title: '还有未筛选的词',
      message: '当前检测结果中仍有 $count 个未筛选的词。未筛选词不参与导出标注，'
          '你可以先去筛选列把它们归类到课标词 / 拓展词 / 超标词 / 专有词，'
          '也可以直接继续导出。',
      icon: Icons.filter_alt_off_rounded,
      choices: const [
        EswDialogChoice(label: '继续导出', value: 'continue', primary: true),
        EswDialogChoice(label: '去筛选', value: 'filter'),
        EswDialogChoice(label: '取消', value: 'cancel'),
      ],
    );
    if (choice == 'filter' && mounted) {
      setState(() {
        _filter = '其他';
        _rebuildFiltered();
      });
    }
    return choice == 'continue';
  }

  /// 导出分析结果：标注方案 → 导出格式（docx / pdf）→ 生成文件。
  Future<void> _exportResult() async {
    // 导出前提示：仍有未筛选（安卓侧分类键为「其他」）的词时询问用户，
    // 选择继续则照常导出（未筛选词不标注）。
    final unfilteredCount = _categoryCounts['其他'] ?? 0;
    if (unfilteredCount > 0) {
      final proceed = await _promptUnfilteredBeforeExport(unfilteredCount);
      if (!proceed || !mounted) return;
    }
    // 标注方案：方案一（彩色）第一项且默认选中，可切方案二（字体格式）。
    final scheme = await _promptAnnotateScheme();
    if (scheme == null || !mounted) return;

    final choice = await showEswChoice<String>(
      context,
      title: '导出结果',
      message: '选择导出格式，导出后可直接在「最近检测」中打开。',
      icon: Icons.ios_share_rounded,
      choices: const [
        EswDialogChoice(
          label: '导出为 DOCX（Word 文档）',
          value: 'docx',
          primary: true,
        ),
        EswDialogChoice(label: '导出为 PDF（打印版）', value: 'pdf'),
      ],
    );
    if (choice == null) return;
    if (!mounted) return;

    ExportProgressOverlay? progress;
    String? exportPath;
    try {
      final dir = await _pickExportDir(context, isVocab: false);
      final exportDir = dir;
      final ts = DateTime.now();
      final stamp =
          '${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}'
          '_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}${ts.second.toString().padLeft(2, '0')}';

      // 导出数据在主 isolate 同步构建并直接写盘，规避 isolate 消息合法性检查
      // （object is unsendable）导致的导出不可用；进度提示兜底长文档等待。
      if (!mounted) return;
      progress = ExportProgressOverlay.begin(
        context,
        stage: '正在生成导出文档…请稍候',
        hint: '文档越大耗时越长，请耐心等待',
      );
      try {
        await progress.setStage('正在整理检测数据…');
        final exportData = await _buildExportTableDataAndroid(_text);
        final baseName = _exportBaseName(widget.fileName, stamp);
        final isPdf = choice == 'pdf';
        final path = '${exportDir.path}/$baseName.${isPdf ? 'pdf' : 'docx'}';
        await progress.setStage('正在写入${isPdf ? 'PDF' : 'DOCX'}文件…');
        if (isPdf) {
          await _writeResultPdf(path, exportData, scheme);
        } else {
          await _exportDocx(path, exportData, scheme);
        }
        exportPath = path;
        // 记录本次导出文档，供「最近检测」列表点击时直接打开
        _lastExportPath = path;
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
      // 导出失败落盘日志，便于用户回传精确定位
      try {
        final docs = await _appDocDir();
        final log = File('$docs/esw_export_error.log');
        await log.writeAsString(
          '${DateTime.now().toIso8601String()} EXPORT_ERROR: $e\n$st\n---\n',
          mode: FileMode.append,
        );
      } catch (_) {}
      if (!mounted) return;
      showAppSnackBar(context, '导出失败: $e', type: AppSnackBarType.error);
    }
  }

  /// 判断单词是否为课标词（小写匹配课标词库键）。
  bool _isStandardWordAndroid(String word) =>
      widget.vocab.standardWordsLower.containsKey(word.toLowerCase());

  /// 拓展词 → 课标原词：优先用户关联映射（extendBaseMap，小写键优先），
  /// 其次反向索引，最后课标词库本身。
  String _baseWordOfAndroid(String word) {
    final linked =
        widget.vocab.extendBaseMap[word.toLowerCase()] ??
        widget.vocab.extendBaseMap[word];
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
  Future<_ExportTableData> _buildExportTableDataAndroid(
    String originalText,
  ) async {
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
      final base = resolveBaseWord(
        glued != null ? glued.group(1)! : w,
        _baseWordOfAndroid,
      ).toLowerCase();
      if (base == 'be' || base == 'ok') return true;
      return isSimpleInflection(w, _isStandardWordAndroid);
    });
    // 明细容量上限：非试题类长文本可能命中上千个拓展词，逐词查词典 + 取例句的
    // 耗时会到分钟级，叠加 DOCX 明细体量后极易触发 OOM；超出部分在此截断，
    // 统计数字仍按全量输出，并在明细开头说明。
    final extendDropped = lowFreqExtend.length > _kExportDetailMaxWords
        ? lowFreqExtend.length - _kExportDetailMaxWords
        : 0;
    if (extendDropped > 0) {
      lowFreqExtend.removeRange(_kExportDetailMaxWords, lowFreqExtend.length);
    }
    // 按题型分组（原文按题型标题行归属区间，组内同句多词合并成一行）
    List<ExtendSection> sections = buildExtendSections(
      text: originalText,
      extendWords: lowFreqExtend,
      baseWordOf: _baseWordOfAndroid,
      mergeSameSentenceRows: true,
    );
    // 原文无题型标题（典型是非试题类的英文段落/其他文本）时降级为单组"全部"。
    // 例句统一走一次性的句子索引：pickShortExample 每词都会对全文做一次空格
    // 归一化 + 小写化，词数上千时是 O(词数×全文)，导出会长时间卡死直至闪退。
    if (sections.isEmpty && lowFreqExtend.isNotEmpty) {
      final idx = buildSentenceIndex(originalText);
      sections = [
        ExtendSection(
          name: '全部',
          rows: [
            for (final w in lowFreqExtend)
              ExtendRowData(
                word: w,
                example: pickExampleFromIndex(idx, [w], fallbackToFirst: true),
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
            tbSb.writeln(decodeTextBytes(await entity.readAsBytes()));
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
          extendQueryWords.add(
            (glued != null ? glued.group(1)! : w).toLowerCase(),
          );
        }
      }
    }
    final gaokaoByWord =
        <String, List<({String example, String year, bool isPhrase})>>{
          for (final w in extendQueryWords)
            w: <({String example, String year, bool isPhrase})>[],
        };
    final fileWordRe = wordTokenRegExp;
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
          if (!widget.corpusNames.contains(entity.uri.pathSegments.last)) {
            continue;
          }
          final String fileText;
          try {
            fileText = decodeTextBytes(await entity.readAsBytes());
          } catch (_) {
            continue;
          }
          final year =
              yearPrefixRe.firstMatch(entity.uri.pathSegments.last)?.group(1) ??
              '';
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
    final enWordRe = wordTokenRegExp;
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
      final cands =
          gaokaoByWord[q] ??
          const <({String example, String year, bool isPhrase})>[];
      if (cands.isEmpty) return const [];
      final sentences = cands.where((c) => !c.isPhrase).toList();
      final phrases = cands.where((c) => c.isPhrase).toList();
      List<({String example, String year, bool isPhrase})> pool;
      if (isNounAdj) {
        // 名/形：整句合适（词数<=12）时优先整句，否则降级取词组
        final goodSentences = sentences
            .where((c) => wordCountOfUsage(c.example) <= 12)
            .toList();
        pool = goodSentences.isNotEmpty
            ? goodSentences
            : (phrases.isNotEmpty ? phrases : sentences);
      } else {
        // 动/副：整句优先，整句无才用词组
        pool = sentences.isNotEmpty ? sentences : phrases;
      }
      if (pool.isEmpty) return const [];
      final best = pool.reduce(
        (a, b) => gaokaoScore(b.example) > gaokaoScore(a.example) ? b : a,
      );
      return [
        _GaokaoExampleItem(word: w, example: best.example, year: best.year),
      ];
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
      final hasVerbSense =
          t.contains('\nvi.') ||
          t.contains('\nvt.') ||
          RegExp(r'\bv\.').hasMatch(t) ||
          RegExp(r'\bvi\.').hasMatch(t) ||
          RegExp(r'\bvt\.').hasMatch(t);
      final v =
          !hasVerbSense &&
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
        items.add(
          _ExportExtendItem(
            word: r.word,
            baseWord: r.baseWord,
            originalExample: resolveUsageText(
              originalText,
              r.example,
              r.word,
              isNA,
            ),
            gaokaoExamples: gaokaoItems,
            textbookExample: resolveUsageFromIndex(r.word),
          ),
        );
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
    // 超标词明细同样限量，避免非试题长文本导出时无限膨胀
    final overDropped = overLimitWords.length > _kExportDetailMaxWords
        ? overLimitWords.length - _kExportDetailMaxWords
        : 0;
    if (overDropped > 0) {
      overLimitWords.removeRange(_kExportDetailMaxWords, overLimitWords.length);
    }
    List<ExtendSection> overSections = buildExtendSections(
      text: originalText,
      extendWords: overLimitWords,
      baseWordOf: (w) => '',
      mergeSameSentenceRows: false,
    );
    // 原文无题型标题（非试题文本）时降级为单组"全部"，同样走一次性句子索引
    if (overSections.isEmpty && overLimitWords.isNotEmpty) {
      final idx = buildSentenceIndex(originalText);
      overSections = [
        ExtendSection(
          name: '全部',
          rows: [
            for (final w in overLimitWords)
              ExtendRowData(
                word: w,
                example: pickExampleFromIndex(idx, [w], fallbackToFirst: true),
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
        final isNA =
            t.startsWith('n.') ||
            t.startsWith('adj.') ||
            (t.startsWith('a.') && !t.startsWith('adv.'));
        items.add(
          _ExportOverLimitItem(
            word: r.word,
            posDef: def,
            originalExample: resolveUsageText(
              originalText,
              r.example,
              r.word,
              isNA,
            ),
          ),
        );
      }
      overLimitSections.add(
        _ExportOverLimitSection(name: sec.name, items: items),
      );
    }
    final noticeParts = <String>[
      if (extendDropped > 0)
        '拓展词明细仅列出前 $_kExportDetailMaxWords 条，另有 $extendDropped 条未列出（统计数字仍按全量）',
      if (overDropped > 0)
        '超标词明细仅列出前 $_kExportDetailMaxWords 条，另有 $overDropped 条未列出（统计数字仍按全量）',
    ];
    return _ExportTableData(
      extend: extendSections,
      overLimit: overLimitSections,
      notice: noticeParts.isEmpty ? null : noticeParts.join('；'),
    );
  }

  Future<void> _exportDocx(
    String path,
    _ExportTableData exportData,
    ExportAnnotateScheme scheme,
  ) async {
    final bytes = await _buildExportDocxBytes(exportData, scheme);
    await File(path).writeAsBytes(bytes);
  }

  /// 生成标注后的 docx 字节：源文件为 docx 时原地标注，完整保留原排版；
  /// 否则重建轻量 docx。PDF 导出也复用这份结果，再转成 PDF。
  Future<List<int>> _buildExportDocxBytes(
    _ExportTableData exportData,
    ExportAnnotateScheme scheme,
  ) async {
    // 源文件为 .docx 时原地标注：只改写 word/document.xml 追加高亮/颜色，
    // 其余部件原样保留，完整保留原文档排版格式；文末追加分页明细节。
    //
    // 大源文件直接跳过原地标注：原地标注要全量解压 zip + DOM 解析 + 序列化 +
    // 重打包，内存峰值随源文件线性攀升，是真机导出 OOM 闪退的主要来源；
    // 改为重建轻量 docx，内存可控。
    final srcPath = widget.sourcePath;
    if (srcPath != null &&
        srcPath.toLowerCase().endsWith('.docx') &&
        await File(srcPath).exists()) {
      final srcLen = await File(srcPath).length();
      if (srcLen <= _kInplaceDocxMaxBytes) {
        try {
          final srcBytes = await File(srcPath).readAsBytes();
          final catByLower = _exportCatByLower();
          final preamble = _buildDocxPreambleAndroid(
            fileName: widget.fileName,
            exportData: exportData,
            scheme: scheme,
          );
          final appendix = _buildDocxAppendixAndroid(exportData: exportData);
          final bytes = annotateDocxBytes(
            srcBytes: srcBytes,
            catByLower: catByLower,
            preambleParagraphsXml: preamble,
            appendixParagraphsXml: appendix,
            scheme: scheme,
            // 方案一只靠颜色区分：不加粗，避免与原文自带加粗混淆；
            // 未筛选词在任何方案下都不标注（导出前会提示，选择继续时仍不标注）。
            colorBold: false,
            annotateUnfiltered: false,
          );
          return bytes;
        } catch (_) {
          // 原地标注失败（异常 docx）时回退到重新生成模式
        }
      }
    }
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('ESW 文本检测导出', heading: 1));
    bodyParts.add(_docxParagraph('文件名: ${widget.fileName}'));
    // 标注说明只保留一份：方案一用彩色统计行；方案二用带样式的图例行。
    bodyParts.add(_docxParagraph('【标注说明】', heading: 2));
    bodyParts.add(
      scheme == ExportAnnotateScheme.color
          ? _docxSummaryParagraphAndroid()
          : _docxAnnotateLegendParagraphAndroid(scheme),
    );
    bodyParts.add(_docxParagraph('带标注全文', heading: 2));
    if (_text.length <= _kExportAnnotateBudgetChars) {
      bodyParts.add(_docxAnnotatedParagraph(scheme));
    } else {
      // 超大文本（典型是非试题类英文/其他长文本）不附带标注全文：
      // 标注 XML 体积约为原文的 15~25 倍，超出 Android 堆预算会 OOM 闪退。
      bodyParts.add(
        _docxParagraph(
          '（原文共 ${_text.length} 字符，超出带标注全文的导出容量上限，'
          '本文件仅输出统计、标注说明与拓展词/超标词明细。）',
        ),
      );
    }
    bodyParts.addAll(_buildDocxDetailParagraphsAndroid(exportData));

    final documentXml =
        '''
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
    // 每个部件只 utf8.encode 一次并存成字节：此前同一串被 encode 三次，
    // document.xml 本可到数 MB，重复编码会让导出峰值内存翻倍（长文本导出
    // 闪退的诱因之一）。
    final ctBytes = utf8.encode(contentTypes);
    final relsBytes = utf8.encode(rels);
    final docBytes = utf8.encode(documentXml);
    archive.addFile(
      ArchiveFile('[Content_Types].xml', ctBytes.length, ctBytes),
    );
    archive.addFile(ArchiveFile('_rels/.rels', relsBytes.length, relsBytes));
    archive.addFile(
      ArchiveFile('word/document.xml', docBytes.length, docBytes),
    );

    final encoder = ZipEncoder();
    final bytes = encoder.encode(archive);
    if (bytes == null) throw Exception('DOCX 生成失败');
    return bytes;
  }

  /// 构建 DOCX 正文前汇总段（原地标注用）：标题 + 文件名 + 标注说明。
  ///
  /// 标注说明只保留一份：方案一用彩色统计行；方案二用带样式的图例行。
  List<String> _buildDocxPreambleAndroid({
    required String fileName,
    required _ExportTableData exportData,
    required ExportAnnotateScheme scheme,
  }) {
    return [
      _docxParagraph('ESW 文本检测导出', heading: 1),
      _docxParagraph('文件名: $fileName'),
      _docxParagraph('【标注说明】', heading: 2),
      if (scheme == ExportAnnotateScheme.color)
        _docxSummaryParagraphAndroid()
      else
        _docxAnnotateLegendParagraphAndroid(scheme),
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
    if (exportData.notice != null && exportData.notice!.isNotEmpty) {
      bodyParts.add(_docxParagraph('说明：${exportData.notice}'));
    }
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
            _docxParagraphWithBoldWords(
              '原文用法：${it.originalExample}',
              boldWords,
            ),
          );
          if (it.gaokaoExamples.isEmpty) {
            bodyParts.add(_docxParagraph('高考用法：'));
          } else {
            for (final g in it.gaokaoExamples) {
              final prefix = boldWords.length > 1 ? '高考用法·${g.word}：' : '高考用法：';
              bodyParts.add(
                _docxParagraphWithBoldWords(
                  '$prefix${g.example}${g.year.isNotEmpty ? '（${g.year}）' : ''}',
                  [g.word],
                ),
              );
            }
          }
          bodyParts.add(
            _docxParagraphWithBoldWords(
              '教材用法：${it.textbookExample.isEmpty ? '无' : it.textbookExample}',
              boldWords,
            ),
          );
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
          bodyParts.add(
            _docxParagraphWithBoldWords(it.originalExample, overBold),
          );
        }
      }
    }
    return bodyParts;
  }

  /// 生成单个 DOCX 段落 XML。
  String _docxParagraph(String text, {int? heading}) {
    // 先清理 XML 1.0 非法控制字符（非试题文本常带 \f、\u0001 等），再转义，
    // 否则生成的 document.xml 非法，Word 打开报「文件已损坏」。
    final escaped = sanitizeXmlText(
      text,
    ).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final runs = '<w:r><w:t xml:space="preserve">$escaped</w:t></w:r>';
    final style = heading != null ? ' w:val="Heading$heading"' : '';
    return '<w:p><w:pPr><w:pStyle$style/></w:pPr>$runs</w:p>';
  }

  /// 原文标注用的「小写单词 → 导出分类」映射，与 Windows 版共用同一口径
  /// （[exportAnnotateCategoryOfDetected]，单点落地于 shared/export_word_style.dart）。
  ///
  /// - 课标词按课标级别细分为「初中课标词 / 必修课标词 / 选修课标词」，与导出
  ///   汇总统计（[_exportStandardCategoryCounts]）逐类对齐：统计分三类，标注也分三类；
  /// - 拓展词 / 超标词 / 专有词原样；
  /// - 安卓「其他」在 Windows 侧写作「未筛选」：真题语料出现过 → 真题词（不配色），
  ///   否则 → 未筛选（土红色），与 Windows 的 `isInCorpus` 判定同义。
  Map<String, String> _exportCatByLower() {
    final map = <String, String>{};
    for (final w in _words) {
      final lower = w.word.toLowerCase();
      final level = w.category == '课标词'
          ? (widget.vocab.lookup(w.word)['category'] ?? '')
          : '';
      map.putIfAbsent(
        lower,
        () => exportAnnotateCategoryOfDetected(
          category: w.category,
          standardLevel: level,
          // _realFreq 为真题语料词频，>0 等价于 Windows 的 isInCorpus
          isInCorpus: (_realFreq[lower] ?? 0) > 0,
        ),
      );
    }
    return map;
  }

  /// 导出用分类计数：安卓检测侧把「四库均不收录」的词记作分类「其他」，
  /// 而 Windows 侧同名分类叫「未筛选」。导出（汇总条目 + 标注说明 + 正文标注）
  /// 统一按 Windows 口径呈现，避免同一份文档在两端出现「其他 / 未筛选」
  /// 两套叫法、两套统计。
  ///
  /// 注意只影响导出，不改动检测页筛选条的分类键（UI 仍显示「其他」）。
  Map<String, int> _exportFilterCounts() {
    final out = Map<String, int>.from(_categoryCounts);
    final other = out.remove('其他') ?? 0;
    if (other > 0) {
      out['未筛选'] = (out['未筛选'] ?? 0) + other;
    }
    return out;
  }

  /// 课标词按课标级别（初中 / 必修 / 选修）计数，供导出汇总与标注说明使用。
  /// 三个级别必须先以 0 初始化，否则查不到级别的键会把课标词全部漏计。
  Map<String, int> _exportStandardCategoryCounts() {
    final counts = <String, int>{'初中': 0, '必修': 0, '选修': 0};
    for (final w in _words) {
      if (w.category != '课标词') continue;
      final cat = widget.vocab.lookup(w.word)['category'] ?? '';
      if (counts.containsKey(cat)) counts[cat] = counts[cat]! + 1;
    }
    return counts;
  }

  /// 导出汇总条目（顺序、名称、配色与 Windows 版共用同一份构建逻辑）。
  List<ExportSummaryItem> _buildExportSummaryItemsAndroid() =>
      buildExportSummaryItems(
        totalRawCount: _words.fold<int>(0, (sum, w) => sum + w.frequency),
        dedupCount: _words.length,
        filterCounts: _exportFilterCounts(),
        standardCategoryCounts: _exportStandardCategoryCounts(),
      );

  /// DOCX 汇总段：七类条目按规范色 + 字重着色，竖线分隔（与 Windows 版同款）。
  String _docxSummaryParagraphAndroid() {
    final items = _buildExportSummaryItemsAndroid();
    final runs = <String>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) runs.add(docxRunXml(' | ', ExportSummaryItem.black));
      runs.add(
        docxRunXml(
          '${items[i].label}: ${items[i].value}',
          items[i].colorHex,
          bold: items[i].bold,
        ),
      );
    }
    return '<w:p>${runs.join('')}</w:p>';
  }

  /// DOCX 标注说明段（方案二）：逐项呈现全部统计条目——
  /// 总数类（全套词词数 / 去重总词数 / 真题词 / 其他）以「名称: 数值」中性黑输出，
  /// 七类词以「名称（n 词）」并按方案二样式（加粗 / 单线 / 灰底纹）呈现。
  /// 不遗漏项目，也不与方案一的彩色统计行同时出现。
  String _docxAnnotateLegendParagraphAndroid(ExportAnnotateScheme scheme) {
    final items = _buildExportSummaryItemsAndroid();
    final runs = <String>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (i > 0) runs.add(docxRunXml(' | ', ExportSummaryItem.black));
      if (!ExportCategory.all.contains(item.label)) {
        runs.add(
          docxRunXml(
            '${item.label}: ${item.value}',
            ExportSummaryItem.black,
          ),
        );
        continue;
      }
      final text = '${item.label}（${item.value} 词）';
      if (scheme == ExportAnnotateScheme.typography) {
        final style = exportScheme2StyleOf(item.label);
        runs.add(
          docxRunXml(
            text,
            ExportSummaryItem.black,
            fontName: kExportTypographyFont,
            bold: style?.bold ?? false,
            underline: style?.underline,
            shadeFill: style?.shadeFill,
          ),
        );
      } else {
        runs.add(docxRunXml(text, item.colorHex));
      }
    }
    return '<w:p>${runs.join('')}</w:p>';
  }

  /// 生成带标注全文的 DOCX 段落：按所选方案标注（配色 / 字体格式），**不加底纹**。
  ///
  /// 实现单点落地于 shared/export_annotate_markup.dart，与 Windows 版
  /// 共用同一份标注实现，杜绝双端配色 / 字重漂移。
  /// 方案一只靠颜色区分（`colorBold: false`），未筛选词不标注。
  String _docxAnnotatedParagraph(ExportAnnotateScheme scheme) =>
      docxAnnotatedParagraphXml(
        _text,
        _exportCatByLower(),
        scheme: scheme,
        colorBold: false,
        annotateUnfiltered: false,
      );

  /// 生成带目标词加粗的 DOCX 段落：命中目标词（忽略大小写）时加粗。
  String _docxParagraphWithBoldWords(String text, List<String> words) =>
      docxParagraphWithBoldWordsXml(text, words);

  // ==================== PDF 导出（与 DOCX 同一套标注口径） ====================
  //
  // Android 没有 Windows 的系统中文字体可选，PDF 依赖随包内置的
  // Noto Sans SC（SIL OFL，TTF 轮廓，pdf 包可解析）；西文方案二用 PDF
  // 标准字体 Times-Roman / Times-Bold，避免额外字体体积。

  static pw.Font? _pdfCjkRegular;
  static pw.Font? _pdfCjkBold;

  Future<void> _ensurePdfCjkFonts() async {
    if (_pdfCjkRegular != null && _pdfCjkBold != null) return;
    final regular = await rootBundle.load(
      'assets/fonts/NotoSansSC-Regular.ttf',
    );
    final bold = await rootBundle.load('assets/fonts/NotoSansSC-Bold.ttf');
    _pdfCjkRegular ??= pw.Font.ttf(regular);
    _pdfCjkBold ??= pw.Font.ttf(bold);
  }

  /// 拓展词明细纯文本（与 Windows 版同格式：按题型分组 + 每词五行）。
  String _buildExtendDetailPlainAndroid(List<_ExportExtendSection> sections) {
    if (sections.isEmpty) return '本套题无真题词频低于 400 次的拓展词';
    final sb = StringBuffer();
    var first = true;
    for (final sec in sections) {
      if (sec.items.isEmpty) continue;
      if (!first) sb.writeln();
      first = false;
      sb.writeln(sec.name);
      for (var i = 0; i < sec.items.length; i++) {
        final it = sec.items[i];
        sb.writeln('${i + 1}. ${it.word}');
        sb.writeln('课标原词：${it.baseWord}');
        sb.writeln('原文用法：${it.originalExample}');
        if (it.gaokaoExamples.isEmpty) {
          sb.writeln('高考用法：');
        } else {
          final words = it.word.split(' ');
          for (final g in it.gaokaoExamples) {
            final prefix = words.length > 1 ? '高考用法·${g.word}：' : '高考用法：';
            sb.writeln(
              '$prefix${g.example}${g.year.isNotEmpty ? '（${g.year}）' : ''}',
            );
          }
        }
        sb.writeln(
          '教材用法：${it.textbookExample.isEmpty ? '无' : it.textbookExample}',
        );
      }
    }
    return sb.toString();
  }

  /// 超标词纯文本（与 Windows 版同格式：按题型分组 + 每词三行）。
  String _buildOverLimitPlainAndroid(List<_ExportOverLimitSection> sections) {
    if (sections.isEmpty) return '本套题未检测到超标词';
    final sb = StringBuffer();
    var first = true;
    for (final sec in sections) {
      if (sec.items.isEmpty) continue;
      if (!first) sb.writeln();
      first = false;
      sb.writeln(sec.name);
      for (var i = 0; i < sec.items.length; i++) {
        final it = sec.items[i];
        sb.writeln('${i + 1}. ${it.word}');
        sb.writeln(it.posDef);
        sb.writeln(it.originalExample);
      }
    }
    return sb.toString();
  }

  /// 调用原生把「已标注 docx」按原排版渲染为 PDF。
  /// 返回 false 表示原生转换不可用，由调用方回退到文本重排 PDF。
  Future<bool> _convertDocxToPdf(String docxPath, String outPath) async {
    try {
      final ok = await _docxPdfChannel.invokeMethod<bool>('convert', {
        'docxPath': docxPath,
        'outPath': outPath,
      });
      if (ok != true) return false;
      final f = File(outPath);
      return await f.exists() && await f.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 导出 PDF：源文件是 docx 时，先按原排版生成「已标注 docx」，再交给原生
  /// WebView 渲染并逐页写出 PDF——PDF 与 docx 导出的段落/字体/表格/图片一致；
  /// 非 docx 源（粘贴文本等）回退到 MultiPage 文本排版。
  Future<void> _writeResultPdf(
    String path,
    _ExportTableData exportData,
    ExportAnnotateScheme scheme,
  ) async {
    if (widget.sourcePath != null &&
        widget.sourcePath!.toLowerCase().endsWith('.docx')) {
      try {
        final docxBytes = await _buildExportDocxBytes(exportData, scheme);
        final tmp = File('${await _appDocDir()}/.esw_pdf_src.docx');
        await tmp.writeAsBytes(docxBytes);
        final ok = await _convertDocxToPdf(tmp.path, path);
        try {
          await tmp.delete();
        } catch (_) {}
        if (ok) return;
      } catch (_) {
        // 原生转换异常 → 回退到文本重排 PDF，保证导出仍可用
      }
    }
    await _ensurePdfCjkFonts();
    final font = _pdfCjkRegular!;
    final cjkBold = _pdfCjkBold!;
    final typography = scheme == ExportAnnotateScheme.typography;
    // 方案二：西文统一 Times New Roman（PDF 标准字体，无需额外资产）。
    final wordFont = typography ? pw.Font.times() : null;
    final wordBoldFont = typography ? pw.Font.timesBold() : null;
    final black = pwpdf.PdfColor.fromInt(0xFF000000);

    pw.Widget oneLine(String line) => pdfAnnotatedLine(
          line,
          _exportCatByLower(),
          font,
          scheme: scheme,
          colorBold: false,
          annotateUnfiltered: false,
          // 方案一只靠字色区分：不加底纹，避免与原文底色混淆。
          annotateShade: false,
          wordFont: wordFont,
          boldFont: wordBoldFont,
        );

    /// 方案一汇总行：条目按规范色 + 字重着色（中文用内置粗体字重）。
    pw.Widget summaryWidget() {
      final items = _buildExportSummaryItemsAndroid();
      final spans = <pw.TextSpan>[];
      for (var i = 0; i < items.length; i++) {
        if (i > 0) {
          spans.add(pw.TextSpan(
            text: ' | ',
            style: pw.TextStyle(font: font, fontSize: 10, color: black),
          ));
        }
        final isBold = items[i].bold;
        spans.add(pw.TextSpan(
          text: '${items[i].label}: ${items[i].value}',
          style: pw.TextStyle(
            font: isBold ? cjkBold : font,
            fontSize: 10,
            color: pwpdf.PdfColor.fromHex('#${items[i].colorHex}'),
          ),
        ));
      }
      return pw.RichText(
        text: pw.TextSpan(
          style: pw.TextStyle(font: font, fontSize: 10),
          children: spans,
        ),
        textDirection: pw.TextDirection.ltr,
      );
    }

    /// 方案二图例：全部统计条目，七类词按加粗 / 单线 / 灰底纹呈现。
    pw.Widget legendWidget() {
      final items = _buildExportSummaryItemsAndroid();
      final spans = <pw.TextSpan>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (i > 0) {
          spans.add(pw.TextSpan(
            text: ' | ',
            style: pw.TextStyle(font: font, fontSize: 10),
          ));
        }
        if (!ExportCategory.all.contains(item.label)) {
          spans.add(pw.TextSpan(
            text: '${item.label}: ${item.value}',
            style: pw.TextStyle(font: font, fontSize: 10, color: black),
          ));
          continue;
        }
        final style = exportScheme2StyleOf(item.label);
        final isBold = style?.bold ?? false;
        spans.add(pw.TextSpan(
          text: '${item.label}（${item.value} 词）',
          style: pw.TextStyle(
            font: isBold ? cjkBold : font,
            fontSize: 10,
            color: black,
            decoration: style?.underline == 'single'
                ? pw.TextDecoration.underline
                : null,
            decorationStyle: style?.underline == 'single'
                ? pw.TextDecorationStyle.solid
                : null,
            decorationColor: black,
            background: style?.shadeFill == null
                ? null
                : pw.BoxDecoration(
                    color: pwpdf.PdfColor.fromHex('#${style!.shadeFill!}'),
                  ),
          ),
        ));
      }
      return pw.RichText(
        text: pw.TextSpan(
          style: pw.TextStyle(font: font, fontSize: 10),
          children: spans,
        ),
        textDirection: pw.TextDirection.ltr,
      );
    }

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: pwpdf.PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font, bold: cjkBold),
        build: (context) {
          final widgets = <pw.Widget>[
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(
                'ESW 文本检测导出',
                style: pw.TextStyle(
                  font: cjkBold,
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Text(
              '文件名: ${widget.fileName}',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: pw.Text(
                '【标注说明】',
                style: pw.TextStyle(
                  font: cjkBold,
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4, bottom: 8),
              child: scheme == ExportAnnotateScheme.color
                  ? summaryWidget()
                  : legendWidget(),
            ),
            pw.Text(
              '【带标注全文】',
              style: pw.TextStyle(
                font: cjkBold,
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            // 带标注全文：逐行作为 MultiPage 的直接子项展开（与 Windows 一致），
            // 分页由 pdf 包处理；不能整段包在 Column/Padding 里，长文会整块超高。
            pw.SizedBox(height: 2),
            if (_text.length <= _kExportAnnotateBudgetChars)
              ..._text.split('\n').map(
                    (line) => pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 1),
                      child: oneLine(line),
                    ),
                  )
            else
              pw.Text(
                '（原文共 ${_text.length} 字符，超出带标注全文的导出容量上限，'
                '本文件仅输出统计、标注说明与拓展词/超标词明细。）',
                style: pw.TextStyle(font: font, fontSize: 9),
              ),
            pw.SizedBox(height: 8),
            pw.Text(
              '【拓展词明细】',
              style: pw.TextStyle(
                font: cjkBold,
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 4),
            ..._buildExtendDetailPlainAndroid(exportData.extend)
                .split('\n')
                .map(
                  (line) => pw.Text(line, style: pw.TextStyle(font: font, fontSize: 9)),
                ),
            pw.SizedBox(height: 12),
            pw.Text(
              '【超标词】',
              style: pw.TextStyle(
                font: cjkBold,
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 4),
            ..._buildOverLimitPlainAndroid(exportData.overLimit)
                .split('\n')
                .map(
                  (line) => pw.Text(line, style: pw.TextStyle(font: font, fontSize: 10)),
                ),
          ];
          return widgets;
        },
      ),
    );
    final outBytes = await doc.save();
    await File(path).writeAsBytes(outBytes);
  }

  Color _chipColor(String cat) {
    switch (cat) {
      case '课标词':
        return AppTheme.primaryBlue;
      case '拓展词':
        return AppTheme.green;
      case '超标词':
        return AppTheme.red;
      case '专有词':
        return AppTheme.grey;
      default:
        return AppTheme.orange;
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
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newWord == null || newWord.isEmpty || newWord == oldWord) return;
    if (!RegExp(r'^[a-zA-Z]+$').hasMatch(newWord)) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        '$newWord 不是合法的英文单词',
        type: AppSnackBarType.info,
      );
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
      showAppSnackBar(
        context,
        '已将真题文本中 $oldWord 改为 $newWord',
        type: AppSnackBarType.success,
      );
    }
  }

  void _openSourcePopup(String keyword) {
    Navigator.of(context).push(
      MaterialPageRoute(
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
      ),
    );
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
  static List<String> _splitChunks(
    String text, {
    int maxChunk = _maxChunkChars,
  }) {
    final chunks = <String>[];
    final n = text.length;
    if (n == 0) return chunks;
    // 撇号不参与切块：撇号是词内字符（couldn't），在此切断会把一个词分到两个块
    final boundary = RegExp(r'[\s\u3000，。；：！？、,.!?;:()（）\[\]"]');
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
    _lowerKey = wordLookupKey(widget.keyword);
    _chunks = _splitChunks(_text);

    _catByLower = <String, String>{};
    for (final w in widget.words) {
      _catByLower.putIfAbsent(wordLookupKey(w.word), () => w.category);
    }

    final offset = _locateTargetOffset();
    _targetChunkIndex = (offset != -1) ? _chunkIndexAt(_chunks, offset) : -1;

    if (_targetChunkIndex != -1) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToTargetChunk(),
      );
    }
  }

  /// 返回目标关键词首次命中的字符偏移（相对全文），未命中返回 -1
  int _locateTargetOffset() {
    var acc = 0;
    for (final line in _text.split('\n')) {
      for (final m in wordTokenRegExp.allMatches(line.toLowerCase())) {
        if (wordLookupKey(m.group(0)!) == _lowerKey) return acc + m.start;
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
    for (final m in wordTokenRegExp.allMatches(line)) {
      final word = m.group(0)!;
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: line.substring(lastEnd, m.start)));
      }
      if (isSameLookupWord(word, _lowerKey)) {
        spans.add(
          TextSpan(
            text: word,
            style: TextStyle(
              backgroundColor: Colors.yellow.shade300,
              color: Colors.red.shade800,
              fontWeight: FontWeight.bold,
              fontSize: _fontSize,
            ),
          ),
        );
      } else {
        final cat = categoryOfWord(_catByLower, word);
        if (cat != null && cat != '课标词' && cat != '其他') {
          spans.add(
            TextSpan(
              text: word,
              style: TextStyle(
                color: widget.chipColor(cat),
                fontWeight: FontWeight.w600,
                fontSize: _fontSize,
              ),
            ),
          );
        } else {
          spans.add(
            TextSpan(
              text: word,
              style: const TextStyle(fontSize: _fontSize),
            ),
          );
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
  Widget _buildWordContextMenu(
    BuildContext context,
    SelectableRegionState state,
  ) {
    final word = _selectedContent?.plainText.trim() ?? '';
    final isWord = RegExp(
      r"^(?:[a-zA-Z]+(?:\.[a-zA-Z]+)+\.?|[a-zA-Z]+(?:['’\-][a-zA-Z]+)*)$",
    ).hasMatch(word);
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
            showAppSnackBar(
              context,
              '已复制 $word',
              type: AppSnackBarType.success,
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
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newWord == null || newWord.isEmpty || newWord == oldWord) return;
    if (!RegExp(r'^[a-zA-Z]+$').hasMatch(newWord)) {
      if (mounted) {
        showAppSnackBar(
          context,
          '$newWord 不是合法的英文单词',
          type: AppSnackBarType.info,
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
        showAppSnackBar(
          context,
          '文本中未找到 $oldWord',
          type: AppSnackBarType.error,
        );
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
      showAppSnackBar(
        context,
        '已将原文中 $oldWord 改为 $newWord',
        type: AppSnackBarType.success,
      );
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
                      style: const TextStyle(
                        fontSize: _fontSize,
                        color: Colors.black87,
                      ),
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

  _AnalyzedWord({
    required this.word,
    required this.frequency,
    required this.category,
  });
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

  /// 明细截断提示（非空时在明细开头输出一行说明）。
  final String? notice;

  const _ExportTableData({
    required this.extend,
    required this.overLimit,
    this.notice,
  });
}

class _DialogResult {
  final String action; // '拓展词' | '超标词' | '专有词'
  final String? baseWord;
  _DialogResult({required this.action, this.baseWord});
}

const _knownPrefixes = {
  'anti',
  'un',
  're',
  'dis',
  'pre',
  'mis',
  'over',
  'under',
  'out',
  'up',
  'down',
  'in',
  'im',
  'il',
  'ir',
  'non',
  'ex',
  'de',
  'en',
  'em',
  'sub',
  'inter',
  'trans',
  'super',
  'semi',
  'mid',
  'co',
  'counter',
  'extra',
  'hyper',
  'micro',
  'mini',
  'multi',
  'post',
  'pro',
  'auto',
  'bio',
  'geo',
  'tele',
  'mono',
  'poly',
  'uni',
  'bi',
  'tri',
  'self',
  'fore',
  'with',
  'per',
  'a',
  'ab',
  'ad',
  'be',
  'com',
  'con',
  'ob',
  'se',
};

/// 候选词匹配：双端统一逻辑（见 shared/base_word_candidates.dart）
List<String> _getBaseWordCandidates(
  String word,
  List<String> allStandardWords,
) {
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
  if (b.endsWith('y') && w == '${b.substring(0, b.length - 1)}ies') {
    return '第三人称单数 / 复数';
  }

  // 过去式 / 过去分词：+ed, +d, y→ied, 双写+ed
  if (w == '${b}ed') return '过去式 / 过去分词';
  if (w == '${b}d') return '过去式 / 过去分词';
  if (b.endsWith('y') && w == '${b.substring(0, b.length - 1)}ied') {
    return '过去式 / 过去分词';
  }
  // 双写辅音 +ed：stopped→stop, planned→plan
  if (w.length == b.length + 2 &&
      w.endsWith('ed') &&
      w.substring(0, b.length - 1) == b.substring(0, b.length - 1) &&
      w[b.length - 1] == b[b.length - 1]) {
    return '过去式 / 过去分词';
  }

  // 现在分词：+ing, 去e+ing, 双写+ing
  if (w == '${b}ing') return '现在分词';
  if (b.endsWith('e') && w == '${b.substring(0, b.length - 1)}ing') {
    return '现在分词';
  }
  if (w.length == b.length + 3 &&
      w.endsWith('ing') &&
      w.substring(0, b.length - 1) == b.substring(0, b.length - 1) &&
      w[b.length - 1] == b[b.length - 1]) {
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
Future<Directory> _pickExportDir(
  BuildContext context, {
  required bool isVocab,
}) async {
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

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

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
/// 语料索引的格式版本。分词规则变更（如撇号缩略形式整体作为一个词元）后，
/// 必须让设备上已写盘的 corpus_index.json 失效重建，否则词频仍按旧词元查表，
/// `couldn't` 会一直命中 0 次。
const int _corpusIndexSchema = 2;

/// 解析语料索引文件；格式版本不符或内容损坏返回 null（触发重建）。
Map<String, int>? _decodeCorpusIndex(String json) {
  try {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    if (decoded['schema'] != _corpusIndexSchema) return null;
    final words = decoded['words'];
    if (words is! Map) return null;
    return <String, int>{
      for (final e in words.entries) e.key.toString(): (e.value as num).toInt(),
    };
  } catch (_) {
    return null;
  }
}

/// 加载 corpus 全量词频索引。
/// 首次调用时扫描 corpus 目录下所有 .txt，按单词（长度>=3）统计出现次数并写入 corpus_index.json；后续调用直接读内容字 Map，毫秒级响应，彻底解决逐文件扫描转圈问题。
Future<Map<String, int>> _loadCorpusIndex(
  String corpusPath, {
  List<String>? onlyNames,
}) async {
  final indexFile = File('$corpusPath/corpus_index.json');
  if (indexFile.existsSync()) {
    try {
      final cached = _decodeCorpusIndex(await indexFile.readAsString());
      if (cached != null) return cached;
      // 旧版索引：分词口径已变，删除后重建
      try {
        await indexFile.delete();
      } catch (_) {}
    } catch (_) {
      // 索引读失败则重建
    }
  }

  // 首次构建（逐文件扫描 + split 词频统计）移入后台 isolate，
  // 避免大语料在 UI isolate 同步执行导致界面冻结/ANR。
  try {
    final _ = await _buildCorpusIndexAsync(corpusPath, onlyNames: onlyNames);
  } catch (_) {
    // isolate 派发失败时回退到同步构建，保证功能可用
    _buildCorpusIndexSync(corpusPath, onlyNames: onlyNames);
  }

  // worker 写盘后由 UI 侧统一读回（避免大 Map 跨 isolate 拷贝驻留内存）
  if (!indexFile.existsSync()) return {};
  try {
    return _decodeCorpusIndex(await indexFile.readAsString()) ?? {};
  } catch (_) {
    return {};
  }
}

/// 语料索引构建（isolate 版，同步 IO 可在后台 isolate 安全执行）：
/// 扫描 corpus 目录全部 .txt，统计 3+ 字母词频并写盘 corpus_index.json。
Map<String, int> _buildCorpusIndexSync(
  String corpusPath, {
  List<String>? onlyNames,
}) {
  final indexFile = File('$corpusPath/corpus_index.json');
  final index = <String, int>{};
  final dir = Directory(corpusPath);
  if (!dir.existsSync()) return index;
  final only = onlyNames?.toSet();

  final files =
      dir
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.toLowerCase().endsWith('.txt') &&
                (only == null || only.contains(f.uri.pathSegments.last)),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (int fi = 0; fi < files.length; fi++) {
    try {
      final text = decodeTextBytes(files[fi].readAsBytesSync());
      // 与文本检测/年份统计共用同一分词实现（连字/变音折叠、选项粘连剥离）
      for (final token in extractWordTokens(text, minLength: 3)) {
        final w = token.toLowerCase();
        index[w] = (index[w] ?? 0) + 1;
      }
    } catch (_) {
      // 单个文件读取出错，跳过继续
    }
  }

  try {
    indexFile.writeAsStringSync(
      jsonEncode({'schema': _corpusIndexSchema, 'words': index}),
    );
  } catch (_) {
    // 写盘失败不阻塞调用方
  }
  return index;
}

// ==================== 后台 isolate worker（顶层函数，可被 Isolate.run 派发） ====================
//
// ⚠️ 铁律：`Isolate.run(...)` 的闭包**必须在本文件的顶层函数内创建**，绝不可直接写在
// State 的方法体里。写在 State 方法内时，Dart 会把该方法的接收者一并打包进 isolate
// 消息；一旦 State 里持有 `Timer`（如输入防抖计时器）等 unsendable 对象，就会抛出
// `Invalid argument(s): illegal argument in isolate message: object is unsendable
// - _Timer / _AndroidEswAppState`，并让当前页面整片变成红底报错（表现为"点击后乱码/
// 花屏、输入框全部失效"）。统一走下面的顶层 async 包装函数即可彻底避免。

/// 安全地把导入文件解析派发到后台 isolate（见上方铁律）。
Future<String> _extractImportContentFromPathAsync(String path, String name) {
  return Isolate.run(
    () => _extractImportContentFromPathWorker({'path': path, 'name': name}),
  );
}

/// 安全地把真题年份命中统计派发到后台 isolate。
Future<Map<String, dynamic>> _scanYearHitCountsAsync(
  Map<String, dynamic> args,
) {
  final safeArgs = Map<String, dynamic>.from(args);
  return Isolate.run(() => _scanYearHitCountsWorker(safeArgs));
}

/// 安全地把教材命中统计派发到后台 isolate。
Future<Map<String, dynamic>> _scanTextbookHitCountsAsync(
  Map<String, dynamic> args,
) {
  final safeArgs = Map<String, dynamic>.from(args);
  return Isolate.run(() => _scanTextbookHitCountsWorker(safeArgs));
}

/// 安全地把语料索引构建派发到后台 isolate（见上方铁律）。
Future<void> _buildCorpusIndexAsync(
  String corpusPath, {
  List<String>? onlyNames,
}) {
  return Isolate.run(
    () => _buildCorpusIndexSync(corpusPath, onlyNames: onlyNames),
  );
}

/// 安全地把文本分析派发到后台 isolate。
Future<Map<String, dynamic>> _analyzeTextAsync(Map<String, dynamic> args) {
  final safeArgs = Map<String, dynamic>.from(args);
  return Isolate.run(() => _analyzeTextWorker(safeArgs));
}

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
  // isolate 传输后嵌套 Map 的泛型实参可能退化为 dynamic，
  // 这里不做 cast，统一按 dynamic 读取，避免 CastError 导致整段统计失败。
  final vocabRaw = args['vocab'] as Map;
  final namesRaw = args['names'];
  final Set<String>? onlyNames = namesRaw is List
      ? namesRaw.map((e) => '$e').toSet()
      : null;
  final yearRe = RegExp(r'(?<!\d)((?:19|20)\d{2})(?!\d)');
  final counts = <int, int>{};
  final hits = <int, Map<String, Map<String, String>>>{};
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return {'counts': counts, 'words': <int, List<Map<String, String>>>{}};
  }
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.txt')) continue;
    if (onlyNames != null && !onlyNames.contains(f.uri.pathSegments.last)) {
      continue;
    }
    // 年份允许出现在文件名任意位置（2023全国卷 / 全国卷-2023 / 2019-2023 均取首个）
    final m = yearRe.firstMatch(f.path.split(RegExp(r'[/\\]')).last);
    if (m == null) continue;
    final year = int.tryParse(m.group(1)!);
    if (year == null) continue;
    String text;
    try {
      // 与 Windows 共用同一解码：兼容 UTF-16 BOM / GBK 的手工拷贝语料
      text = decodeTextBytes(f.readAsBytesSync());
    } catch (_) {
      continue;
    }
    var count = 0;
    // 与文本检测共用同一分词实现，避免年份命中数与检测结果口径不一致
    for (final raw in extractWordTokens(text)) {
      final lower = raw.toLowerCase();
      final infoRaw = vocabRaw[lower];
      if (infoRaw is! Map) continue;
      count++;
      hits.putIfAbsent(year, () => <String, Map<String, String>>{})[lower] = {
        'w': raw,
        'p': infoRaw['pos']?.toString() ?? '',
        'c': infoRaw['cat']?.toString() ?? '',
      };
    }
    counts[year] = (counts[year] ?? 0) + count;
  }
  final words = <int, List<Map<String, String>>>{};
  for (final entry in hits.entries) {
    final list = entry.value.values.toList()
      ..sort(
        (a, b) => (a['w'] ?? '').toLowerCase().compareTo(
          (b['w'] ?? '').toLowerCase(),
        ),
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
  // 同 _scanYearHitCountsWorker：避免 isolate 传输后泛型退化引发的 CastError
  final vocabRaw = args['vocab'] as Map;
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
      // 与 Windows 共用同一解码：兼容 UTF-16 BOM / GBK 的手工拷贝语料
      text = decodeTextBytes(f.readAsBytesSync());
    } catch (_) {
      continue;
    }
    var count = 0;
    for (final raw in extractWordTokens(text)) {
      final lower = raw.toLowerCase();
      final infoRaw = vocabRaw[lower];
      if (infoRaw is! Map) continue;
      count++;
      hits.putIfAbsent(name, () => <String, Map<String, String>>{})[lower] = {
        'w': raw,
        'p': infoRaw['pos']?.toString() ?? '',
        'c': infoRaw['cat']?.toString() ?? '',
      };
    }
    counts[name] = (counts[name] ?? 0) + count;
  }
  final words = <String, List<Map<String, String>>>{};
  for (final entry in hits.entries) {
    final list = entry.value.values.toList()
      ..sort(
        (a, b) => (a['w'] ?? '').toLowerCase().compareTo(
          (b['w'] ?? '').toLowerCase(),
        ),
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
      // 统一走共用提取：w:tab/w:br 保留为分隔 + 选项标记断行（与 Windows 同一实现）
      return extractDocxText(raw);
    } catch (e) {
      if (isOle) {
        final t = normalizeText(extractDocText(raw));
        if (t.trim().isEmpty) throw Exception('暂不支持旧版 .doc 或内容为空，请转为 txt/docx');
        return t;
      }
      if (isZip) throw Exception('文件不是有效的 DOCX（ZIP 结构损坏）：$e');
      return normalizeText(_decodeTextBytesTop(raw));
    }
  }
  if (lowerName.endsWith('.doc') || isOle) {
    final t = normalizeText(extractDocText(raw));
    if (t.trim().isEmpty) throw Exception('暂不支持旧版 .doc 或内容为空，请转为 txt/docx');
    return t;
  }
  return normalizeText(_decodeTextBytesTop(raw));
}

bool _isZipBytesTop(List<int> b) =>
    b.length >= 4 &&
    b[0] == 0x50 &&
    b[1] == 0x4B &&
    (b[2] == 0x03 || b[2] == 0x05 || b[2] == 0x07) &&
    b[3] == 0x04;

bool _isOleBytesTop(List<int> b) =>
    b.length >= 8 &&
    b[0] == 0xD0 &&
    b[1] == 0xCF &&
    b[2] == 0x11 &&
    b[3] == 0xE0;

String _decodeTextBytesTop(List<int> raw) {
  try {
    return decodeTextBytes(raw);
  } catch (e) {
    throw Exception('文本编码无法识别，请转为 UTF-8 编码的 txt 文件');
  }
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
  // 专有词大小写不敏感：存 Messy / MESSY 视为同一条
  final extraLower = properNounKeySet(extra);
  final classMem = Map<String, String>.from(args['classMem'] as Map);

  final freqMap = <String, int>{};
  final caseMap = <String, String>{};

  // 与 Windows / 语料统计共用同一分词实现：连字、变音、全角折叠 +
  // 选项字母粘连剥离，避免同一份文档在不同功能里词边界不一致。
  for (final original in extractWordTokens(text)) {
    final lower = original.toLowerCase();
    freqMap[lower] = (freqMap[lower] ?? 0) + 1;
    if (!caseMap.containsKey(lower)) caseMap[lower] = original;
  }

  final words =
      freqMap.entries.map((e) {
        final lower = e.key;
        final original = caseMap[lower] ?? lower;
        // 与 UI 侧一致：完整词形查不到时回退基形（China's → China）
        final keys = wordLookupKeys(original);
        final standardHit = isWordSetHit(standard, original);
        String? cat;
        if (apostropheBaseInStandard(original, standardHit)) {
          // 常见缩写按基形归课标：I'm / can't / you've
          cat = '课标词';
        } else {
          for (final key in keys) {
            final remembered = classMem[key];
            if (remembered != null) {
              cat = remembered;
              break;
            }
          }
          if (cat == null) {
            if (isProperNounHit(extraLower, original)) {
              // 首字母大写 / 全大写写法优先命中专有词；小写写法留给用户确认
              cat = '专有词';
            } else if (standardHit) {
              cat = '课标词';
            } else if (matchWordEntryKey(extend, original) != null) {
              cat = '拓展词';
            } else if (matchWordEntryKey(chaogang, original) != null) {
              cat = '超标词';
            }
          }
        }
        return <String, dynamic>{
          'word': original,
          'frequency': e.value,
          'category': cat ?? '其他',
        };
      }).toList()..sort(
        (a, b) => (b['frequency'] as int).compareTo(a['frequency'] as int),
      );

  final categoryCounts = <String, int>{};
  for (final w in words) {
    final c = w['category'] as String;
    categoryCounts[c] = (categoryCounts[c] ?? 0) + 1;
  }

  // 构建汉语标注词集合（统计用，仅计数不加色）
  // O(N) 实现：避免对全文反复 substring + firstMatch 造成 O(N^2) 卡顿
  final parenChineseRegex = RegExp(
    r'^\s*[\(（][^)）]*[\u4e00-\u9fa5]+[^)）]*[\)）]',
  );
  final importedWordsLower = words
      .map((w) => (w['word'] as String).toLowerCase())
      .toSet();
  final annotatedPhrases = <String>{};
  bool isAsciiLetter(int u) =>
      (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
  bool isSep(int u) => u == 0x20 || u == 0x09 || u == 0x2D; // 空格 / 制表 / 连字符
  for (final m in wordTokenRegExp.allMatches(text)) {
    final w = m.group(0)!;
    if (w.length < 2) continue;
    if (!wordLookupKeys(w).any(importedWordsLower.contains)) continue;
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
      if (!importedWordsLower.contains(wordLookupKey(pw))) break;
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

// ==================== 导出文件生成 ====================

/// DOCX 导出：源文件为 .docx 时优先原地标注（annotateDocxBytes），
/// 失败或非 docx 源则重建轻量 docx；全程后台执行并全捕获。
/// 源 docx 超过 15MB 直接跳过原地标注走重建：原地标注需全量解压 zip +
/// DOM + 序列化 + 重打包，多副本内存峰值随源文件增大线性攀升，是
/// 真机大文档 OOM 闪退的最可能根因；重建轻量 docx 内存可控。
