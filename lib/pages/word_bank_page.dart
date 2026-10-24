import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/services.dart' show rootBundle;
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/esw_tokens.dart';
import '../widgets/esw_widgets.dart';
import '../shared/vocab_service.dart';
import '../shared/word_sync_service.dart';
import '../shared/app_snack_bar.dart';
import '../shared/export_progress_overlay.dart';
import '../dictionary_service.dart';
import '../high_freq_export.dart';

// ---------------------------------------------------------------------------
// 本地辅助（自 android_app.dart 迁移，避免循环 import；逻辑保持一致）
// ---------------------------------------------------------------------------

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

/// 获取导出目录：优先使用外部存储 Download 目录，失败回退到应用文档目录。
Future<Directory> _downloadDir() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      final download = Directory('${ext.path}/../../Download');
      if (!await download.exists()) {
        await download.create(recursive: true);
      }
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
Future<Directory> _pickExportDir(BuildContext context,
    {required bool isVocab}) async {
  final picked = await FilePicker.getDirectoryPath();
  if (picked != null && picked.isNotEmpty) {
    if (isVocab) {
      _lastVocabExportPath = picked;
    } else {
      _lastExportPath = picked;
    }
    return Directory(picked);
  }

  final remembered = isVocab ? _lastVocabExportPath : _lastExportPath;
  if (remembered != null && remembered.isNotEmpty) {
    final dir = Directory(remembered);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  return _downloadDir();
}

// ---------------------------------------------------------------------------
// 词库页
// ---------------------------------------------------------------------------

/// 词库页：ESW 词库（标题 + 副标题 + 搜索 + 四卡统计 + 设置列表）。
/// 业务逻辑（导入导出 / 高频导出 / 详情页跳转）迁移自原 _VocabTabPage，不改动。
class WordBankPage extends StatefulWidget {
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final Future<void> Function(String word, VoidCallback onAdded)
      showBaseWordDialog;
  final ValueChanged<String>? onWordTap;
  final VoidCallback onSyncVocab;
  final VoidCallback onCheckUpdate;
  final Future<void> Function() onImportCorpus;
  final Future<void> Function() onImportTextbook;
  final bool syncing;
  final WordSyncService wordSyncService;

  const WordBankPage({
    super.key,
    required this.vocab,
    required this.onSaveConfig,
    required this.showBaseWordDialog,
    this.onWordTap,
    required this.onSyncVocab,
    required this.onCheckUpdate,
    required this.onImportCorpus,
    required this.onImportTextbook,
    required this.syncing,
    required this.wordSyncService,
  });

  @override
  State<WordBankPage> createState() => _WordBankPageState();
}

class _WordBankPageState extends State<WordBankPage> {
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

  /// 合并全部词库单词，返回 '{word: category}'。
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
      case '课标词':
        return EswColors.blue;
      case '拓展词':
        return EswColors.green;
      case '超标词':
        return EswColors.red;
      case '专有词':
        return EswColors.grey;
      default:
        return EswColors.orange;
    }
  }

  /// 打开某类词库详情页
  void _openWordList(String category) {
    Navigator.of(context).push(CupertinoPageRoute<void>(
      builder: (_) => WordListPage(
        category: category,
        vocab: widget.vocab,
        onSaveConfig: widget.onSaveConfig,
        showBaseWordDialog: widget.showBaseWordDialog,
        wordSyncService: widget.wordSyncService,
        onWordTap: widget.onWordTap,
      ),
    ));
  }

  /// 导出词库为 JSON 备份到下载目录。
  /// 统一接入导出等待提示：目录选择阶段不遮挡系统选择器，
  /// 进入写入阶段后延迟 500ms 未完成才浮现提示层（含阶段文案与实时已用时）。
  Future<void> _exportVocab() async {
    if (!mounted) return;
    ExportProgressOverlay? progress;
    String? okMessage;
    String? errorMessage;
    try {
      final dir = await _pickExportDir(context, isVocab: true);
      if (!mounted) return;
      progress = ExportProgressOverlay.begin(
        context,
        stage: '正在导出词库…请稍候',
        hint: '词库条目较多时耗时更长',
      );
      await progress.setStage('正在写入词库备份文件…');
      final backupDir = dir;
      final now = DateTime.now();
      final dateStr =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final path = '${backupDir.path}/esw_vocab_backup_$dateStr.json';
      final data = widget.vocab.toJson();
      await File(path).writeAsString(jsonEncode(data));
      okMessage = '词库已导出: $path';
    } catch (e) {
      errorMessage = '导出失败: $e';
    } finally {
      // 无论成功、异常还是提前返回，提示层必须收起，绝不残留
      progress?.close();
    }
    if (!mounted) return;
    if (okMessage != null) {
      showAppSnackBar(context, okMessage);
    } else if (errorMessage != null) {
      showAppSnackBar(context, errorMessage, type: AppSnackBarType.error);
    }
  }

  /// 从 JSON 文件导入词库，追加合并（不覆盖已有）。
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
        showAppSnackBar(context, '词库导入完成（已合并）');
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '导入失败: $e', type: AppSnackBarType.error);
      }
    }
  }

  /// 应用文档目录/corpus 下是否已有真题 txt（真题语料可用）。
  Future<bool> _hasRealCorpus() async {
    try {
      final dir = await _appDocDir();
      final d = Directory('$dir/corpus');
      if (!await d.exists()) return false;
      await for (final e in d.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.txt')) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 弹窗引导用户导入真题或教材（导出高频前调用）。
  /// 返回 true 表示已具备真题语料，false 表示用户未导入/取消。
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
      await widget.onImportCorpus();
    } else if (choice == 'textbook') {
      await widget.onImportTextbook();
    }
    if (await _hasRealCorpus()) return true;
    if (mounted) {
      showAppSnackBar(context, '无法完成真题单词检测：请先导入真题或教材语料',
          type: AppSnackBarType.error);
    }
    return false;
  }

  bool _exportingHighFreq = false;

  /// 导出高频词表（Word(docx) / Excel(xlsx) 可选）：复用 HighFreqExporter
  /// 核心逻辑（词频口径、课标/拓展归属、停用词与星期月份序数词排除、例句
  /// 精确匹配、双格式生成），保存到 Download/esw_exports 并提示完整路径。
  Future<void> _exportHighFreq() async {
    if (_exportingHighFreq) return;
    final format = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('选择导出格式'),
        content: const Text('请选择高频词表的导出格式：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, 'docx'),
            child: const Text('Word(docx)'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, 'xlsx'),
            child: const Text('Excel(xlsx)'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (format == null) return;
    _exportingHighFreq = true;
    if (mounted) setState(() {});
    ExportProgressOverlay? progress;
    try {
      final docsDir = await _appDocDir();
      final corpusDir = '$docsDir/corpus';
      if (!await _hasRealCorpus()) {
        final imported = await _promptCorpusImport();
        if (!imported) return;
        if (!await _hasRealCorpus()) {
          if (mounted) {
            showAppSnackBar(context,
                '未找到真题语料目录（应用文档目录/corpus），请先导入真题语料',
                type: AppSnackBarType.error);
          }
          return;
        }
      }
      // 预估导出耗时（对齐 Windows 版）：按 corpus 目录 .txt 总字节数估算（约 7 秒/MB）
      int corpusBytes = 0;
      try {
        final cDir = Directory(corpusDir);
        if (cDir.existsSync()) {
          for (final f in cDir.listSync().whereType<File>()) {
            if (f.path.toLowerCase().endsWith('.txt')) {
              corpusBytes += f.lengthSync();
            }
          }
        }
      } catch (_) {}
      final estMin = ((corpusBytes / 1024 / 1024) * 7 / 60).ceil().clamp(1, 999);
      if (!mounted) return;
      // 统一导出等待提示：延迟 500ms 未完成才浮出，保留原「预计用时」信息
      progress = ExportProgressOverlay.begin(
        context,
        stage: '正在统计真题词频并生成词表…请稍候',
        hint: '预计用时约$estMin 分钟，请耐心等待',
      );

      final standardWordsRaw =
          await rootBundle.loadString('assets/standard_words.json');
      // 词典库须走 DictionaryService 统一部署路径（应用文档目录/ESW/ecdict.db）
      final dbPath = await DictionaryService.ensureDeployedDbPath();
      final extendWordsLower =
          widget.vocab.extendWords.map((w) => w.toLowerCase()).toList();
      final extendBaseMapRaw = jsonEncode(
        Map<String, String>.fromEntries(
          widget.vocab.extendBaseMap.entries
              .where((e) => extendWordsLower.contains(e.key.toLowerCase())),
        ),
      );
      final extendWordsRaw = jsonEncode(extendWordsLower);

      final result = await HighFreqExporter.export(
        corpusDir: corpusDir,
        standardWordsRaw: standardWordsRaw,
        dbPath: dbPath,
        extendBaseMapRaw: extendBaseMapRaw,
        extendWordsRaw: extendWordsRaw,
        format: format,
      );
      final outBytes =
          result.format == 'docx' ? result.docxBytes! : result.xlsxBytes;
      // 统计与文档生成已结束：先收起提示层，避免遮挡随后的目录选择器
      progress.close();
      progress = null;
      if (!mounted) return;
      final dir = await _pickExportDir(context, isVocab: false);
      final ext = result.format == 'docx' ? 'docx' : 'xlsx';
      final now = DateTime.now();
      final stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final savePath = '${dir.path}/ESW-高考高频词表_$stamp.$ext';
      await File(savePath).writeAsBytes(outBytes);

      if (mounted) {
        final fmtName = result.format == 'docx' ? 'Word(docx)' : 'Excel(xlsx)';
        showAppSnackBar(
          context,
          '导出高频完成（$fmtName）：${result.exportedWords} 词（${result.corpusFileCount} 篇真题语料，已排除星期/月份/序数词 ${result.calendarOrdinalExcluded.length} 个），已保存至 $savePath',
        );
      }
    } catch (e, st) {
      debugPrint('[ExportHighFreq-Android] error: $e\n$st');
      progress?.close();
      progress = null;
      if (mounted) {
        showAppSnackBar(context, '导出高频失败：$e', type: AppSnackBarType.error);
      }
    } finally {
      // 兜底：任何提前 return / 异常路径都收起提示层，绝不残留
      progress?.close();
      _exportingHighFreq = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalStandard = widget.vocab.standardWords.length;
    final totalExtend = widget.vocab.extendWords.length;
    final totalChaoGang = widget.vocab.manualChaoGangWords.length;
    final totalExtra = widget.vocab.manualExtraWords.length;
    final total = totalStandard + totalExtend + totalChaoGang + totalExtra;

    final allMap = _allWordsWithCategory();
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? <MapEntry<String, String>>[]
        : allMap.entries.where((e) => e.key.toLowerCase().contains(q)).toList()
          ..sort((a, b) => a.key.compareTo(b.key));

    return SafeArea(
      child: Column(
        children: [
          EswPageHeader(title: 'ESW 词库', subtitle: '共 $total 个词条'),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              EswSpace.lg,
              0,
              EswSpace.lg,
              EswSpace.md,
            ),
            child: EswSearchField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              hintText: '搜索已添加的单词来源',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {},
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                EswSpace.lg,
                EswSpace.xs,
                EswSpace.lg,
                EswSpace.xxxl,
              ),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _importVocab,
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: const Text('导入词库'),
                      ),
                    ),
                    const SizedBox(width: EswSpace.md),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _exportVocab,
                        icon: const Icon(Icons.upload_file_rounded, size: 18),
                        label: const Text('导出词库'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: EswSpace.lg),
                if (q.isEmpty) ...[
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: EswSpace.md,
                    mainAxisSpacing: EswSpace.md,
                    childAspectRatio: 1.55,
                    children: [
                      EswStatCard(
                        label: '课标词',
                        countText: '$totalStandard',
                        color: EswColors.blue,
                        ratioText: _ratioText(totalStandard, total),
                        onTap: () => _openWordList('课标词'),
                      ),
                      EswStatCard(
                        label: '拓展词',
                        countText: '$totalExtend',
                        color: EswColors.green,
                        ratioText: _ratioText(totalExtend, total),
                        onTap: () => _openWordList('拓展词'),
                      ),
                      EswStatCard(
                        label: '超标词',
                        countText: '$totalChaoGang',
                        color: EswColors.red,
                        ratioText: _ratioText(totalChaoGang, total),
                        onTap: () => _openWordList('超标词'),
                      ),
                      EswStatCard(
                        label: '专有词',
                        countText: '$totalExtra',
                        color: EswColors.grey,
                        ratioText: _ratioText(totalExtra, total),
                        onTap: () => _openWordList('专有词'),
                      ),
                    ],
                  ),
                  const SizedBox(height: EswSpace.lg),
                  EswPrimaryButton(
                    label: _exportingHighFreq ? '导出中…' : '导出高频',
                    icon: Icons.upload_file_rounded,
                    height: 44,
                    onPressed: _exportingHighFreq
                        ? null
                        : () {
                            _exportHighFreq();
                          },
                  ),
                ] else ...[
                  EswSectionHeader(title: '搜索结果 (${filtered.length})'),
                  const SizedBox(height: EswSpace.md),
                  EswCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final e in filtered)
                          EswListTile(
                            leading: EswLetterChip(
                              letter: e.key,
                              color: _catColor(e.value),
                            ),
                            title: e.key,
                            subtitle: e.value,
                            onTap: widget.onWordTap == null
                                ? null
                                : () => widget.onWordTap!(e.key),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: EswSpace.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _catColor(e.value).withValues(
                                  alpha: 0.14,
                                ),
                                borderRadius: BorderRadius.circular(
                                  EswRadius.small,
                                ),
                              ),
                              child: Text(
                                e.value,
                                style: EswText.chip.copyWith(
                                  color: _catColor(e.value),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: EswSpace.xxl),
                EswCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      EswSettingsTile(
                        icon: Icons.description_outlined,
                        title: '使用说明',
                        onTap: () => Navigator.of(context).push(
                          CupertinoPageRoute<void>(
                            builder: (_) => const HelpPage(),
                          ),
                        ),
                      ),
                      const Divider(indent: EswSpace.lg, endIndent: EswSpace.lg),
                      EswSettingsTile(
                        icon: Icons.sync_rounded,
                        title: '同步词库',
                        subtitle: widget.syncing ? '同步中…' : null,
                        onTap: widget.syncing ? null : widget.onSyncVocab,
                        trailing: widget.syncing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : null,
                      ),
                      const Divider(indent: EswSpace.lg, endIndent: EswSpace.lg),
                      EswSettingsTile(
                        icon: Icons.system_update_alt_rounded,
                        title: '检查更新',
                        onTap: widget.onCheckUpdate,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: EswSpace.lg),
                Center(
                  child: GestureDetector(
                    onTap: () async {
                      final uri = Uri.parse('https://github.com/beenhow/ESW');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                    child: Text(
                      'V1.5.8 · github.com/beenhow/ESW',
                      style: EswText.caption.copyWith(
                        color: EswColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _ratioText(int count, int total) {
    if (total <= 0) return '占总词条比例 0%';
    final pct = (count / total * 100).toStringAsFixed(1);
    return '占总词条比例 $pct%';
  }
}

// ---------------------------------------------------------------------------
// 某类词库详情页（迁移自原 _WordListPage，逻辑不改）
// ---------------------------------------------------------------------------

class WordListPage extends StatefulWidget {
  final String category;
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final Future<void> Function(String word, VoidCallback onAdded)
      showBaseWordDialog;
  final ValueChanged<String>? onWordTap;
  final WordSyncService wordSyncService;

  const WordListPage({
    super.key,
    required this.category,
    required this.vocab,
    required this.onSaveConfig,
    required this.showBaseWordDialog,
    required this.wordSyncService,
    this.onWordTap,
  });

  @override
  State<WordListPage> createState() => _WordListPageState();
}

class _WordListPageState extends State<WordListPage> {
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
      case '课标词':
        return EswColors.blue;
      case '拓展词':
        return EswColors.green;
      case '超标词':
        return EswColors.red;
      case '专有词':
        return EswColors.grey;
      default:
        return EswColors.orange;
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
  /// 大范围删除保护：删除超过 10 个 → 确认；超过 50 个 → 先自动备份云端再确认
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
      if (!confirmed) return false;
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
          FilledButton(
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
      backgroundColor: EswColors.page,
      appBar: AppBar(
        title: Text(
          _selected.isEmpty
              ? '${widget.category}（共${_words.length}个）'
              : '${widget.category}（已选${_selected.length}个）',
        ),
        centerTitle: false,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: EswColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: editable
            ? [
                const SizedBox(width: EswSpace.xs),
                Padding(
                  padding: const EdgeInsets.only(right: EswSpace.xs),
                  child: Row(
                    children: [
                      Text(
                        '全选',
                        style: EswText.bodySmall.copyWith(
                          color: EswColors.textPrimary,
                        ),
                      ),
                      Checkbox(
                        value: _words.isNotEmpty &&
                            _selected.length == _words.length,
                        activeColor: color,
                        onChanged: _toggleAll,
                      ),
                    ],
                  ),
                ),
              ]
            : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: _words.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 36,
                          color: EswColors.textSecondary,
                        ),
                        const SizedBox(height: EswSpace.sm),
                        Text(
                          '暂无${widget.category}',
                          style: EswText.bodySmall.copyWith(
                            color: EswColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(EswSpace.md),
                    itemCount: _words.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1),
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
                                backgroundColor:
                                    color.withValues(alpha: 0.15),
                                child: Text(
                                  '${i + 1}',
                                  style: EswText.bodySmall.copyWith(
                                    color: color,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                        title: Text(
                          w,
                          style: EswText.body.copyWith(
                            color: EswColors.textPrimary,
                          ),
                        ),
                        trailing: editable
                            ? null
                            : Text(
                                '仅查看',
                                style: EswText.bodySmall.copyWith(
                                  color: EswColors.textSecondary,
                                ),
                              ),
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
              top: false,
              child: Container(
                decoration: BoxDecoration(
                  color: EswColors.card,
                  border: Border(
                    top: BorderSide(color: EswColors.border),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: EswSpace.md,
                  vertical: EswSpace.sm,
                ),
                child: Row(
                  children: [
                    for (final t in _batchTargets) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _applyBatchReclassify(t),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '转为$t',
                              style: EswText.bodySmall,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: EswSpace.sm),
                    ],
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          _applyBatchDelete();
                        },
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '删除所选单词',
                            style: EswText.bodySmall,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: EswSpace.sm),
                    Expanded(
                      child: TextButton(
                        onPressed: _doCancelSelect,
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '取消选择',
                            style: EswText.bodySmall,
                          ),
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

// ---------------------------------------------------------------------------
// 使用说明页（迁移自原 _HelpPage，仅样式走令牌）
// ---------------------------------------------------------------------------

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

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = [
      _HelpItem(
        icon: Icons.search_rounded,
        title: '真题查词',
        content: '在「真题查词」页输入英文单词后回车，即可查看课标释义、词性、真题频次、历年分布与真题例句；支持历史搜索记录快速回查。',
      ),
      _HelpItem(
        icon: Icons.analytics_outlined,
        title: '文本检测',
        content: '在「检测页」粘贴文本或导入 TXT/DOCX/PDF 文件，点击「开始分析」即可比对词库，输出课标词/拓展词/超标词/专有词四类词的覆盖统计与占比。',
      ),
      _HelpItem(
        icon: Icons.library_books_outlined,
        title: '真题/教材导入',
        content: '在「检测页」点击「导入真题」「导入教材」选择 TXT 文件，语料将存入应用文档目录，用于真题查词例句展示、高频词统计与按年份命中统计。',
      ),
      _HelpItem(
        icon: Icons.sync_rounded,
        title: '同步词库',
        content: '开启同步后，词库增删改会自动上传云端，多设备保持一致；同步进度可在词库页底部查看，首次使用建议先同步获取最新词库。',
      ),
      _HelpItem(
        icon: Icons.download_rounded,
        title: '词库导入',
        content: '在词库页点击「导入词库」选择本机备份的 JSON 词库文件，系统自动合并到当前词库；导入完成后可在搜索中立即使用。',
      ),
      _HelpItem(
        icon: Icons.upload_file_rounded,
        title: '词库导出',
        content: '在词库页点击「导出词库」，将当前词库（含四类词与个人标注）整体导出为 JSON 备份文件，便于迁移或留档。',
      ),
      _HelpItem(
        icon: Icons.insert_chart_outlined_rounded,
        title: '导出高频',
        content: '在词库页点击「导出高频」，按真题语料统计词频并导出为 Word(docx) 或 Excel(xlsx) 文件，词频统计口径与桌面版完全一致。',
      ),
    ];
    return Scaffold(
      backgroundColor: EswColors.page,
      appBar: AppBar(
        title: const Text('使用说明'),
        centerTitle: false,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: EswColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(EswSpace.lg),
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: EswSpace.md),
              child: EswCard(
                padding: EdgeInsets.zero,
                child: EswSettingsTile(
                  icon: item.icon,
                  title: item.title,
                  subtitle: item.content,
                  trailing: const SizedBox.shrink(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
