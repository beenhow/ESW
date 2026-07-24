import 'package:flutter/material.dart';
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
import 'package:url_launcher/url_launcher.dart';
import 'theme/app_theme.dart';
import 'shared/vocab_service.dart';
import 'porter_stemmer.dart';
import 'translation_service.dart';

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

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _pasteCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _initApp() async {
    await _vocab.loadStandardWords();
    await _loadPreloadVocab();
    await _extractCorpus();
    await _loadConfig();
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
      }
    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    try {
      final configPath = await _getConfigPath();
      await File(configPath).writeAsString(jsonEncode(_vocab.toJson()));
    } catch (_) {}
  }

  Future<void> _loadPreloadVocab() async {
    try {
      final data = await rootBundle.loadString('assets/preload_vocab.json');
      final json = jsonDecode(data) as Map<String, dynamic>;
      // 浣跨敤 mergeFromJson 杩藉姞棰勫姞杞借瘝锛岄伩鍏嶈鐩栫敤鎴峰凡绉疮鐨勫垎绫昏瘝锛?
      // 涓嶅湪姝ゅ璋冪敤 _saveConfig()锛岄槻姝㈣鐩栫鐩樹笂宸叉湁鐨勭敤鎴烽厤缃€?
      _vocab.mergeFromJson(json);
    } catch (_) {}
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
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildSearchTab(),
          _buildImportTab(),
          _buildVocabTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
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
                    color: AppTheme.surfaceLighter,
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
                    maxLines: 8,
                    minLines: 4,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: '粘贴文本到这里',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: AppTheme.surfaceLighter,
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
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
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
                      return Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        child: ListTile(
                          leading: const Icon(Icons.history, size: 20, color: AppTheme.textSecondary),
                          title: Text(h.fileName, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                          subtitle: Text(
                            '${_formatTime(h.time)} · ${h.totalWords}词${summary.isNotEmpty ? ' · $summary' : ''}',
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
          try {
            content = utf8.decode(file.bytes!, allowMalformed: true)
                .replaceAll(_controlCharRegex, ' ')
                .replaceAll(_whitespaceRegex, ' ')
                .trim();
            if (content.isEmpty) throw Exception('提取为空');
          } catch (_) {
            throw Exception('暂不支持旧版 .doc，请转换为 .docx 或 .txt');
          }
        } else if (file.path != null) {
          final raw = await File(file.path!).readAsBytes();
          content = utf8.decode(raw, allowMalformed: true)
              .replaceAll(_controlCharRegex, ' ')
              .replaceAll(_whitespaceRegex, ' ')
              .trim();
          if (content.isEmpty) throw Exception('暂不支持旧版 .doc，请转换为 .docx 或 .txt');
        } else {
          throw Exception('无法读取文件内容');
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
          SnackBar(content: Text("鏂囦欢璇诲彇澶辫触: $e")),
        );
      }
      return;
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
        ));
      });
    }
  }

  // ====== Tab 3: 查词 ======
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  final TextEditingController _pasteCtrl = TextEditingController();
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
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16),
                        decoration: InputDecoration(
                          hintText: '输入英文单词',
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
                          fillColor: Colors.white,
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

  void _lookupWord(String word) {
    if (word.isEmpty) return;
    final info = _vocab.lookup(word);
    String cat;
    if (_vocab.isExtend(word)) {
      cat = '拓展词';
    } else if (_vocab.isChaoGang(word)) {
      cat = '超纲词';
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

    // 异步查询真题词频，用于决定是否显示「从未出现」提示
    _corpusDirPath().then((p) => _vocab.getWordFrequency(word, p)).then((data) {
      if (mounted && _searchResult == word) {
        setState(() {
          _hasFreq = data != null && (data['total'] as int) > 0;
        });
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

    // 非课标词释义：ML Kit 中文翻译
    if (_wordInfo == null) {
      TranslationService.getChineseMeaning(word).then((zh) {
        if (zh != null && zh.isNotEmpty && mounted) {
          setState(() {
            _wordInfo = {'zh_def': zh, 'def': '', 'pos': '', 'category': _vocab.isExtend(word) ? '拓展词' : '翻译'};
          });
        }
      });
    }
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
    } else if (_vocab.extendWords.contains(_searchResult)) {
      categoryLabel = '拓展词';
      labelColor = AppTheme.green;
    } else if (_vocab.manualChaoGangWords.contains(_searchResult)) {
      categoryLabel = '超纲词';
      labelColor = AppTheme.red;
    } else if (_vocab.manualExtraWords.contains(_searchResult)) {
      categoryLabel = '专有词';
      labelColor = AppTheme.grey;
    }

    return Card(
      elevation: 0,
      color: AppTheme.surfaceLighter,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 鍒嗙被鏍囩灞呬腑
            if (categoryLabel != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: labelColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    categoryLabel,
                    style: TextStyle(color: labelColor, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
              ),
            if (categoryLabel != null) const SizedBox(height: 8),
            // 2. 鍗曡瘝灞呬腑
            Center(
              child: Text(
                _searchResult,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            // 3. 閲婁箟灞呬腑
            // 3. 释义区：中文优先，英文辅助（最多3行）
            if (_wordInfo != null && ((_wordInfo!['def'] ?? '').isNotEmpty || (_wordInfo!['zh_def'] ?? '').isNotEmpty)) ...[
              if (_wordFormDesc != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 2),
                  child: Text(
                    _wordFormDesc!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
                  ),
                ),
              // 中文释义（优先，较大字体）
              if ((_wordInfo!['zh_def'] ?? _wordInfo!['def'] ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Center(
                    child: Text(
                      (_wordInfo!['zh_def'] ?? _wordInfo!['def'] ?? ''),
                      style: const TextStyle(color: Colors.black87, fontSize: 15),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
            // 4. 涓変釜娣诲姞鎸夐挳灞呬腑
            if (canMark)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _markButton('+ 拓展词', AppTheme.green, () => _handleReclassify('拓展词')),
                    const SizedBox(width: 12),
                    _markButton('+ 超纲词', AppTheme.red, () => _handleReclassify('超纲词')),
                    const SizedBox(width: 12),
                    _markButton('+ 专有词', AppTheme.grey, () => _handleReclassify('专有词')),
                  ],
                ),
              ),
            const Divider(height: 24),
            if (canMark && !_hasFreq)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: const Center(
                  child: Text(
                    '本单词从未在高考真题中出现过',
                    style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            if (_wordInfo != null && (_wordInfo!['pos'] ?? '').isNotEmpty)
              Center(
                child: Text(
                  '璇嶆€э細${_wordInfo!['pos'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            const Divider(height: 24),
            _buildWordFrequency(),
          ],
        ),
      ),
    );
  }

  /// 绱у噾鏍囪鎸夐挳锛氭樉绀虹缉鍐欐枃瀛楋紝甯﹀垎绫婚鑹插簳绾癸紱鑻ュ綋鍓嶅凡鏄绫诲埆鍒欏彉鐏颁笉鍙偣鍑汇€?
  Widget _markButton(String label, Color color, VoidCallback onPressed) {
    final isCurrent = _wordCategory == label;
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

  /// 判断单词当前的手动分类（拓展词/超纲词/专有词），无则返回 null。
  String? _currentManualCategory(String lower) {
    if (_vocab.extendWords.any((e) => e.toLowerCase() == lower)) return '拓展词';
    if (_vocab.manualChaoGangWords.any((e) => e.toLowerCase() == lower)) return '超纲词';
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
        _saveConfig();
        if (mounted) setState(() => _wordCategory = '拓展词');
      });
    } else {
      _vocab.reclassifyWord(_searchResult, targetCategory);
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
        if (!snap.hasData || snap.data == null) return const SizedBox.shrink();
        final data = snap.data!;
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
                // 鍦ㄥ綋鍓嶈瘝棰戠粨鏋滀腑鏌ユ壘鍖归厤璇ュ叧閿瘝鐨勭湡棰樻潯鐩苟璺宠浆
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
      case '超纲词': return AppTheme.red;
      case '专有词': return AppTheme.grey;
      default: return AppTheme.orange;
    }
  }
}

/// 鐪熼鍘熸枃鏌ョ湅鍣細鎵撳紑鎸囧畾鐪熼 txt 鏂囦欢锛屾粴鍔ㄥ苟楂樹寒鍏抽敭璇嶆墍鍦ㄤ綅缃€?
class _ExamPaperViewer extends StatefulWidget {
  final String filePath;
  final String keyword;
  final int offset;

  const _ExamPaperViewer({
    required this.filePath,
    required this.keyword,
    required this.offset,
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
          // 浼扮畻婊氬姩浣嶇疆锛氭寜瀛楃鏁扮矖鐣ユ槧灏勫埌婊氬姩鍋忕Щ
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

  List<TextSpan> _buildSpans() {
    if (_highlightStart < 0 || _highlightEnd <= _highlightStart) {
      return [TextSpan(text: _content)];
    }
    return [
      TextSpan(text: _content.substring(0, _highlightStart)),
      TextSpan(
        text: _content.substring(_highlightStart, _highlightEnd),
        style: const TextStyle(
          backgroundColor: Color(0x66FFEB3B),
          fontWeight: FontWeight.bold,
          color: Colors.red,
        ),
      ),
      TextSpan(text: _content.substring(_highlightEnd)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.filePath.split(RegExp(r'[\\/]')).last;
    return Scaffold(
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
                child: SelectableText.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 15, height: 1.6, color: Colors.black87),
                    children: _buildSpans(),
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

  _DetectHistory({
    required this.fileName,
    required this.time,
    required this.totalWords,
    required this.categoryCounts,
    required this.text,
  });
}

/// 鍘嗗彶璁板綍纾佽创
class _HistoryTile extends StatelessWidget {
  final String word;
  final VoidCallback onTap;

  const _HistoryTile({required this.word, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
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

/// 鏂囨湰鍒嗘瀽缁撴灉椤甸潰
class _AnalysisPage extends StatefulWidget {
  final String text;
  final String fileName;
  final VocabService vocab;
  final VoidCallback onSaveConfig;
  final ValueChanged<String>? onWordTap;

  const _AnalysisPage({required this.text, required this.fileName, required this.vocab, required this.onSaveConfig, this.onWordTap});

  @override
  State<_AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<_AnalysisPage> {
  late List<_AnalyzedWord> _words;
  late Map<String, int> _categoryCounts;
  String _filter = '全部';
  bool _batchMode = false;
  final Set<String> _selectedOthers = {};

  final Map<String, int?> _realFreq = {};
  bool _freqLoading = false;

  static final RegExp _wordRegex = RegExp(r'\b[a-zA-Z]{2,}\b');
  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  @override
  void initState() {
    super.initState();
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
        cat = '超纲词';
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

    // 寮傛鑾峰彇真题词频锛堜笉闃诲鍒嗘瀽涓绘祦绋嬶級
    _loadRealFreq();
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

  List<_AnalyzedWord> get _filtered => _filter == '全部'
      ? _words
      : _words.where((w) => w.category == _filter).toList();
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
      appBar: AppBar(
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
                  _FilterChip(label: '全部', count: _words.length, selected: _filter == '全部', onTap: () => setState(() => _filter = '全部')),
                  ...['课标词', '拓展词', '超纲词', '专有词', '其他'].map((cat) => _FilterChip(
                    label: cat, count: _categoryCounts[cat] ?? 0,
                    selected: _filter == cat,
                    onTap: () => setState(() => _filter = cat),
                  )),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (_filter == '其他' && (_categoryCounts['其他'] ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    _batchMode = !_batchMode;
                    if (!_batchMode) _selectedOthers.clear();
                  }),
                  icon: Icon(_batchMode ? Icons.close : Icons.checklist, size: 18),
                  label: Text(_batchMode ? '退出批量归类' : '批量归类'),
                ),
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
                                  switch (cat) {
                                    case '拓展词': await _showBaseWordDialog(aw.word); break;
                                    case '超纲词': widget.vocab.addChaoGangWord(aw.word); break;
                                    case '专有词': widget.vocab.addExtraWord(aw.word); break;
                                  }
                                  widget.onSaveConfig();
                                  _analyze();
                                  if (mounted) setState(() {});
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(value: '拓展词', child: Text('设为拓展词')),
                                  const PopupMenuItem(value: '超纲词', child: Text('设为超纲词')),
                                  const PopupMenuItem(value: '专有词', child: Text('设为专有词')),
                                ],
                              )
                            : null,
                      );
                    },
                  ),
          ),
          // 批量归类操作条
          if (_batchMode && _selectedOthers.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text('已选 ${_selectedOthers.length} 个', style: const TextStyle(fontSize: 13, color: Colors.black87)),
                  ),
                  Expanded(child: TextButton(onPressed: _batchExtendDialog, child: const Text('拓展词', style: TextStyle(fontSize: 13)))),
                  Expanded(child: TextButton(onPressed: _batchSetChaoGang, child: const Text('超纲词', style: TextStyle(fontSize: 13)))),
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

    // 鍙傝€冪數鑴戠増閫愬瓧姣嶅尮閰嶉€昏緫
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


  /// 鐢熸垚甯︽爣娉ㄧ殑鍏ㄦ枃锛氭寜浠庡乏鍒板彸鎵弿鍘熸枃锛屽凡璇嗗埆鍗曡瘝鐢ㄥ搴旀爣璁板寘瑁广€?
  /// 课标词嶆棤鏍囪锛屾嫇灞曡瘝鐢{}锛岃秴绾茶瘝鐢<>锛屼笓鏈夎瘝鐢()銆?
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
      } else if (cat == '超纲词') {
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

      if (choice == 'txt') {
        final path = '${exportDir.path}/analysis_$stamp.txt';
        final buffer = StringBuffer();
        buffer.writeln('ESW 文本检测导出');
        buffer.writeln('分析时间: ${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}');
        buffer.writeln('文件名: ${widget.fileName}');
        final cc = _categoryCounts;
        buffer.writeln('总词数： ${_words.length} | 课标词： ${cc['课标词'] ?? 0} | 拓展词： ${cc['拓展词'] ?? 0} | 超纲词： ${cc['超纲词'] ?? 0} | 专有词： ${cc['专有词'] ?? 0} | 其他: ${cc['其他'] ?? 0}');
        buffer.writeln('');
        buffer.writeln('=' * 64);
        buffer.writeln('【标注说明】');
        buffer.writeln('[课标词]：单词本身（无标记）');
        buffer.writeln('{拓展词}：用花括号标记');
        buffer.writeln('<超纲词>：用尖括号标记');
        buffer.writeln('(专有词)：用圆括号标记');
        buffer.writeln('=' * 64);
        buffer.writeln('');
        buffer.writeln(_buildAnnotatedText());
        buffer.writeln('');
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
  Future<void> _exportDocx(String path) async {
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('ESW 文本检测导出', heading: 1));
    bodyParts.add(_docxParagraph('文件名: ${widget.fileName}'));
    final cc = _categoryCounts;
    bodyParts.add(_docxParagraph('总词数: ${_words.length} | 课标词: ${cc['课标词'] ?? 0} | 拓展词: ${cc['拓展词'] ?? 0} | 超纲词: ${cc['超纲词'] ?? 0} | 专有词: ${cc['专有词'] ?? 0} | 其他: ${cc['其他'] ?? 0}'));
    bodyParts.add(_docxParagraph('【标注说明】', heading: 2));
    bodyParts.add(_docxParagraph('课标词：黑色（无标记）；拓展词：绿色；超纲词：红色；专有词：灰色'));
    bodyParts.add(_docxParagraph('带标注全文', heading: 2));
    bodyParts.add(_docxAnnotatedParagraph());

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
        case '超纲词': return 'C62828';
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
        runs.add(_docxRun(word, colorOf(cat)));
      }
      lastEnd = m.end;
    }
    final tail = text.substring(lastEnd);
    if (tail.isNotEmpty) runs.add(_docxRun(tail, '000000'));
    return '<w:p>${runs.join('')}</w:p>';
  }

  /// 鐢熸垚鍗曚釜 DOCX run锛堝甫棰滆壊锛夈€?
  String _docxRun(String text, String color) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    return '<w:r><w:rPr><w:color w:val="$color"/></w:rPr><w:t xml:space="preserve">$escaped</w:t></w:r>';
  }

  Color _chipColor(String cat) {
    switch (cat) {
      case '课标词': return AppTheme.primaryBlue;
      case '拓展词': return AppTheme.green;
      case '超纲词': return AppTheme.red;
      case '专有词': return AppTheme.grey;
      default: return AppTheme.orange;
    }
  }

  void _openSourcePopup(String keyword) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SourcePopupViewer(
        text: widget.text,
        keyword: keyword,
        words: _words,
        chipColor: _chipColor,
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

  const _SourcePopupViewer({
    required this.text,
    required this.keyword,
    required this.words,
    required this.chipColor,
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

  @override
  void initState() {
    super.initState();
    _lowerKey = widget.keyword.toLowerCase();
    _lines = widget.text.split('\n');

    _catByLower = <String, String>{};
    for (final w in widget.words) {
      _catByLower.putIfAbsent(w.word.toLowerCase(), () => w.category);
    }

    int target = -1;
    for (int i = 0; i < _lines.length; i++) {
      for (final m in _wordRegex.allMatches(_lines[i].toLowerCase())) {
        if (m.group(0) == _lowerKey) {
          target = i;
          break;
        }
      }
      if (target != -1) break;
    }
    _targetLine = target;

    if (_targetLine != -1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _positionToTarget());
    }
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
      return SelectableText(line, style: const TextStyle(fontSize: _fontSize, color: Colors.black87));
    }

    return SelectableText.rich(
      TextSpan(
        style: const TextStyle(fontSize: _fontSize, color: Colors.black87),
        children: spans,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('"${widget.keyword}" 在原文中的位置'),
        titleTextStyle: const TextStyle(fontSize: 16, color: Colors.white),
        backgroundColor: AppTheme.primaryBlue,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        controller: _scrollCtrl,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(_lines.length, (i) => Padding(
            key: i == _targetLine ? (_targetKey ??= GlobalKey()) : null,
            padding: const EdgeInsets.only(bottom: 2),
            child: _buildLine(i, _lines[i]),
          )),
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

class _ScoredWord {
  final String word;
  final int score;
  final int pos;
  final int lcp;
  _ScoredWord(this.word, this.score, [this.pos = 0, this.lcp = 0]);
}
  /// 计算两字符串的最长公共前缀长度
  int _lcpLength(String a, String b) {
    final len = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < len; i++) {
      if (a[i] != b[i]) return i;
    }
    return len;
  }

const _knownPrefixes = {
    'anti', 'un', 're', 'dis', 'pre', 'mis', 'over', 'under', 'out', 'up',
    'down', 'in', 'im', 'il', 'ir', 'non', 'ex', 'de', 'en', 'em', 'sub',
    'inter', 'trans', 'super', 'semi', 'mid', 'co', 'counter', 'extra',
    'hyper', 'micro', 'mini', 'multi', 'post', 'pro', 'auto', 'bio', 'geo',
    'tele', 'mono', 'poly', 'uni', 'bi', 'tri', 'self', 'fore', 'with',
    'per', 'a', 'ab', 'ad', 'be', 'com', 'con', 'ob', 'se',
  };

const _knownSuffixes = {
    'ing', 'ed', 's', 'es', 'er', 'est', 'ly', 'tion', 'sion', 'ment',
    'ness', 'ful', 'less', 'able', 'ible', 'al', 'ive', 'ous', 'ize', 'ise',
    'en', 'ship', 'hood', 'ist', 'ism', 'ity', 'ify', 'ate', 'age', 'ance',
    'ence', 'ant', 'ent', 'ic', 'ish', 'ty', 'ure', 'ward', 'wise', 'y',
    'or', 'ee', 'ian',
  };

  /// 候选词匹配：对目标词的每个起始位置，计算与课标词的最长公共前缀。
  /// 词缀感知：known prefix 使词干候选大幅提权；known suffix 使根词候选加分。
  List<String> _getBaseWordCandidates(String word, List<String> allStandardWords) {
    final lower = word.toLowerCase();
    final scored = <_ScoredWord>[];
    final seen = <String>{};

    for (int pos = 0; pos < lower.length; pos++) {
      final suffix = lower.substring(pos);
      for (final sw in allStandardWords) {
        final swLower = sw.toLowerCase();
        if (seen.contains(sw)) continue;

        final lcp = _lcpLength(suffix, swLower);
        if (lcp < 3) continue;

        if (pos == 0) {
          // 完全匹配
          if (swLower == lower) {
            scored.add(_ScoredWord(sw, 10000, pos, lcp));
            seen.add(sw);
            continue;
          }
          // 课标词比目标词长太多 → 不可能派生自它
          if (swLower.length > lower.length && lcp < lower.length * 0.7) {
            continue;
          }

          if (lcp < 4) {
            // lcp=3 → 覆盖率门槛 40%
            if (lcp.toDouble() / lower.length < 0.4) continue;
          } else {
            // lcp≥4 → 若仅为部分匹配（非完整覆盖标准词），需覆盖率≥45%
            if (lcp < swLower.length && lcp.toDouble() / lower.length < 0.45) continue;
          }

          int score = lcp * 200;
          // 剩余部分像后缀（pacing → pac + ing → pace）
          final remainder = lower.substring(lcp);
          if (_knownSuffixes.contains(remainder)) {
            score += 300;
          }
          // 课标词几乎被 LCP 完全覆盖 → 更像词根
          if (swLower.length - lcp <= 2) {
            score += 200;
          }
          scored.add(_ScoredWord(sw, score, pos, lcp));
        } else {
          final skipped = lower.substring(0, pos);

          if (lcp < 4) {
            // lcp=3 在非首位 → 前段必须是 known prefix 且覆盖率≥50%
            if (!_knownPrefixes.contains(skipped)) continue;
            final maxLen = lower.length > swLower.length ? lower.length : swLower.length;
            if (lcp.toDouble() / maxLen < 0.5) continue;
            scored.add(_ScoredWord(sw, 5000 + lcp * 200, pos, lcp));
          } else {
            final maxLen = lower.length > swLower.length ? lower.length : swLower.length;

            // 完整子串匹配（整个标准词出现在目标词中）→ 复合词拆分，放宽覆盖率
            if (lcp == swLower.length) {
              int score = 3000 + lcp * 200;
              if (_knownPrefixes.contains(skipped)) {
                score += 5000;
              }
              scored.add(_ScoredWord(sw, score, pos, lcp));
              seen.add(sw);
              continue;
            }

            // 跳过的部分过短且不是已知前缀 → 不合理的匹配（如 sprinkler → princess，跳过 "s"）
            if (pos < 2 && !_knownPrefixes.contains(skipped)) continue;

            if (lcp.toDouble() / maxLen < 0.4) continue;
            int score = lcp * 100 - pos * 5;
            if (_knownPrefixes.contains(skipped)) {
              score += 5000;
            }
            scored.add(_ScoredWord(sw, score, pos, lcp));
          }
        }
        seen.add(sw);
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    // 词干匹配提权：Porter Stemmer 识别词干相同的候选词
    final inputStem = porterStem(word);
    for (int i = 0; i < scored.length; i++) {
      final sw = scored[i];
      final candStem = porterStem(sw.word);
      if (inputStem == candStem) {
        // 词干完全一致（如 running→run 匹配标准词 run）
        scored[i] = _ScoredWord(sw.word, sw.score + 7000, sw.pos, sw.lcp);
      } else if (inputStem.length >= 4 && candStem.length >= 4) {
        final stemLcp = _lcpLength(inputStem, candStem);
        if (stemLcp >= 4) {
          // 词干部分重合（如 happiness→happi 与 happen→happen 有公共前缀）
          scored[i] = _ScoredWord(sw.word, sw.score + stemLcp * 200, sw.pos, sw.lcp);
        }
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    // 主导候选词抑制：若首位候选词覆盖率≥75%，过滤同位置弱匹配
    if (scored.isNotEmpty) {
      final top = scored.first;
      if (top.pos == 0 && top.lcp > 0) {
        final coverage = top.lcp.toDouble() / lower.length;
        if (coverage >= 0.75) {
          scored.removeWhere((s) =>
              s.pos == 0 && s.lcp < top.lcp && s.lcp.toDouble() / lower.length < 0.5);
        }
      }
    }

    return scored.map((s) => s.word).take(30).toList();
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
      // 闇€寰€涓婁袱绾у埌 /storage/emulated/0锛屽啀杩涘叆绯荤粺 Download 鐩綍
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
        icon: Icons.search,
        title: '词频查询',
        content: '输入英文单词，自动显示释义、课标分类、历年真题词频和例句。输入后 1 秒自动搜索，长按例句关键词可复制、全选或跳转到真题原文。',
      ),
      _HelpItem(
        icon: Icons.assignment,
        title: '真题检测',
        content: '导入 txt 或 docx 格式的英语真题文档，自动提取其中的单词并按词频排序。点击单词可查看真题原文标注，关键词自动高亮定位。',
      ),
      _HelpItem(
        icon: Icons.library_books,
        title: '词库积累',
        content: '按学段分类展示课标词库（初中课标词、高中课标词、必修课标词、选修课标词等），支持搜索筛选。电脑版与手机版词库可导出导入互通。',
      ),
      _HelpItem(
        icon: Icons.backup,
        title: '数据备份',
        content: '在设置页面可将词库数据导出为备份文件，也可从备份文件导入恢复。方便在更换设备或重装 App 后快速恢复数据。',
      ),
      _HelpItem(
        icon: Icons.wifi,
        title: '联网释义',
        content: '部分功能需要联网。查词时优先使用内置词库，未收录的单词会自动联网获取释义，无网络时使用离线翻译。',
      ),
    ];

    return Scaffold(
      appBar: AppBar(
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
                        Text(item.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
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

  const _VocabTabPage({required this.vocab, required this.onSaveConfig, required this.showBaseWordDialog, this.onWordTap});

  @override
  State<_VocabTabPage> createState() => _VocabTabPageState();
}

class _VocabTabPageState extends State<_VocabTabPage> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
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
      map[w] = '超纲词';
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
      case '超纲词': return AppTheme.red;
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
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: '搜索已积累的词库单词...',
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
                      fillColor: AppTheme.surfaceLight,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  // 瀵煎叆瀵煎嚭鎸夐挳
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
                          label: '超纲词', count: totalChaoGang, color: AppTheme.red,
                          onTap: () => _openWordList('超纲词'),
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
                          color: AppTheme.surfaceLighter,
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
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _HelpPage()),
                    ),
                    child: const Text('使用说明'),
                  ),
                  const Text('V 1.3.0', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 4),
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

  const _WordListPage({
    required this.category,
    required this.vocab,
    required this.onSaveConfig,
    required this.showBaseWordDialog,
    this.onWordTap,
  });

  @override
  State<_WordListPage> createState() => _WordListPageState();
}

class _WordListPageState extends State<_WordListPage> {
  late List<String> _words;

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
      case '超纲词':
        _words = List.from(widget.vocab.manualChaoGangWords);
        break;
      case '专有词':
        _words = List.from(widget.vocab.manualExtraWords);
        break;
      default:
        _words = [];
    }
    // 鍊掑簭锛氭渶鏂版坊鍔犵殑鍦ㄦ渶鍓嶉潰
    _words = _words.reversed.toList();
  }

  Color _colorFor(String cat) {
    switch (cat) {
      case '课标词': return AppTheme.primaryBlue;
      case '拓展词': return AppTheme.green;
      case '超纲词': return AppTheme.red;
      case '专有词': return AppTheme.grey;
      default: return AppTheme.orange;
    }
  }

  Future<void> _convertTo(String word, String target) async {
    final vocab = widget.vocab;
    // 鍏堜粠鍘熺被鍒Щ闄?
    switch (widget.category) {
      case '拓展词':
        vocab.extendWords.removeWhere((e) => e.toLowerCase() == word.toLowerCase());
        vocab.extendBaseMap.remove(word);
        vocab.extendReverseIndex.remove(word.toLowerCase());
        break;
      case '超纲词':
        vocab.manualChaoGangWords.removeWhere((e) => e.toLowerCase() == word.toLowerCase());
        break;
      case '专有词':
        vocab.manualExtraWords.removeWhere((e) => e.toLowerCase() == word.toLowerCase());
        break;
    }
    // 鍔犲叆鐩爣绫诲埆
    if (target == '拓展词') {
      await widget.showBaseWordDialog(word, () {});
    } else if (target == '超纲词') {
      vocab.addChaoGangWord(word);
    } else if (target == '专有词') {
      vocab.addExtraWord(word);
    }
    widget.onSaveConfig();
    setState(_load);
  }

  Future<void> _editBase(String word) async {
    await widget.showBaseWordDialog(word, () {});
    widget.onSaveConfig();
    setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(widget.category);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.category}（${_words.length}个）', style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _words.isEmpty
          ? Center(child: Text('鏆傛棤${widget.category}', style: TextStyle(color: Colors.grey.shade500)))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _words.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final w = _words[i];
                return ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
                  ),
                  title: Text(w, style: const TextStyle(fontWeight: FontWeight.w500)),
                  trailing: _buildActions(w),
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
    );
  }

  Widget _buildActions(String word) {
    final buttons = <Widget>[];
    switch (widget.category) {
      case '拓展词':
        buttons.add(_opBtn(Icons.edit, AppTheme.green, '修改关联', () => _editBase(word)));
        buttons.add(_opBtn(Icons.flag, AppTheme.red, '转超纲', () => _confirmConvert(word, '超纲词')));
        buttons.add(_opBtn(Icons.star, AppTheme.grey, '转专有', () => _confirmConvert(word, '专有词')));
        break;
      case '超纲词':
        buttons.add(_opBtn(Icons.add, AppTheme.green, '转拓展', () => _confirmConvert(word, '拓展词')));
        buttons.add(_opBtn(Icons.star, AppTheme.grey, '转专有', () => _confirmConvert(word, '专有词')));
        break;
      case '专有词':
        buttons.add(_opBtn(Icons.add, AppTheme.green, '转拓展', () => _confirmConvert(word, '拓展词')));
        buttons.add(_opBtn(Icons.flag, AppTheme.red, '转超纲', () => _confirmConvert(word, '超纲词')));
        break;
      case '课标词':
      default:
        // 课标词嶄粎鏌ョ湅
        break;
    }
    if (buttons.isEmpty) {
      return const Text('仅查看', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }

  Widget _opBtn(IconData icon, Color color, String tooltip, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, size: 18, color: color),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }

  Future<void> _confirmConvert(String word, String target) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认转换'),
        content: Text('将"$word" 从 ${widget.category} 转为 $target？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('确认')),
        ],
      ),
    );
    if (ok == true) {
      await _convertTo(word, target);
    }
  }
}

/// 寮傛鎵弿鎵€鏈?corpus 璇枡鏂囦欢锛岀粺璁＄粰瀹氬崟璇嶇殑鍑虹幇娆℃暟銆?
/// 鍙亶鍘嗘枃浠朵竴娆★紝浣跨敤鑱斿悎姝ｅ垯涓€娆℃€у尮閰嶆墍鏈夊崟璇嶏紝閬垮厤閫愪釜鍗曡瘝閲嶅鎵弿銆?
/// 浣跨敤 readAsString锛堝紓姝ワ級+ 姣?10 涓枃浠惰鍑轰簨浠跺惊鐜紝閬垮厤闃诲 UI 绾跨▼銆?
/// 鍔犺浇 corpus 鍏ㄩ噺璇嶉绱㈠紩銆?
/// 棣栨璋冪敤鏃舵壂鎻?corpus 鐩綍涓嬫墍鏈'.txt锛屾寜鍗曡瘝锛堥暱搴?=3锛夌粺璁″嚭鐜版鏁板苟鍐欏叆
/// corpus_index.json锛涘悗缁皟鐢ㄧ洿鎺ヨ鍐呭瓨 Map锛屾绉掔骇鍝嶅簲锛屽交搴曡В鍐抽€愭枃浠舵壂鎻忚浆鍦堥棶棰樸€?
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
