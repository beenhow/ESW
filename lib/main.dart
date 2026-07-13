import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:collection';
import 'theme/app_theme.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path/path.dart' as p;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EswApp());
}

class EswApp extends StatelessWidget {
  const EswApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESW',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppTheme.primaryBlue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei',
      ),
      home: const MainWindow(),
    );
  }
}

class MainWindow extends StatefulWidget {
  const MainWindow({super.key});

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> {
  // ============ 左侧状态 ============
  List<CorpusFile> _corpusFiles = [];

  // ============ 右侧状态 ============
  final TextEditingController _searchController = TextEditingController();

  String _activeFilter = '真题词';
  final List<String> _filters = ['真题词', '课标词', '拓展词', '超纲词', '专有词'];
  final Map<String, int> _filterCounts = {'真题词': 0, '课标词': 0, '拓展词': 0, '超纲词': 0, '专有词': 0};
  static const Map<String, Color> _filterColors = {
    '真题词': AppTheme.orange,
    '课标词': AppTheme.primaryBlue,
    '拓展词': AppTheme.green,
    '超纲词': AppTheme.red,
    '专有词': AppTheme.grey,
  };

  int _totalFrequency = 0;
  String _wordPos = '';
  String _wordDef = '';
  String? _detectedCategory;
  String _detectedWord = '';
  final List<String> _extendWords = [];  // 用户添加的拓展词列表（保持添加顺序）
  final Map<String, String> _extendBaseMap = {}; // 拓展词→基础课标词映射
  final LinkedHashSet<String> _manualChaoGangWords = LinkedHashSet<String>(); // 用户手动标记的超纲词（保持添加顺序）
  final LinkedHashSet<String> _manualExtraWords = LinkedHashSet<String>(); // 用户手动标记的专有词（保持添加顺序）
  final Map<String, String> _classificationMemory = {}; // 单词小写→分类，跨导入记忆
  final GlobalKey _importBtnKey = GlobalKey();

  // 专有词汇对话框的 setDialogState 引用，供 _pruneCategoriesAfterEdit 在原文修改后刷新对话框
  void Function(void Function())? _extraWordsDialogSetState;

  // ======== 持久化配置 ========
  String get _configPath => p.join(File(Platform.resolvedExecutable).parent.path, 'esw_config.json');
  String? _lastExamImportPath;
  String? _lastDocImportPath;
  String? _lastImportMode; // 'folder' or 'files'
  String? _lastExportPath;
  final List<String> _wordHistory = [];
  final FocusNode _searchFocus = FocusNode();
  bool _showHistory = false;
  Timer? _historyTimer;
  bool _ocrReady = false;
  String? _tesseractPath;
  String? _tessdataPath;

  void _cancelHistoryTimer() {
    _historyTimer?.cancel();
    _historyTimer = null;
  }
  final GlobalKey _searchBoxKey = GlobalKey();
  final LayerLink _searchBoxLink = LayerLink();

  final Map<int, int> _yearFrequency = {};
  final List<ResultRow> _results = [];
  Set<int> _importedYears = {};
  List<int> _sortedYears = []; // 预计算降序年份列表
  List<ResultRow> _filteredResults = []; // 预计算年份筛选结果
  int? _selectedYear;

  // ======== 导入文本分析 ========
  bool _inImportedMode = false;
  String? _importedFileName;
  String? _importedFilePath;
  List<_ImportedWord> _importedWords = [];
  String _importedActiveFilter = '真题词';
  int _importedTotalWords = 0;
  List<_ImportedWord> _cachedFilteredImportedWords = [];
  String? _cachedImportedFilter;
  List<_ImportedWord>? _cachedImportedWordsRef;
  final Map<String, int> _importedFilterCounts = {
    '真题词': 0, '课标词': 0, '拓展词': 0, '超纲词': 0, '专有词': 0,
  };

  // ======== 从导入模式跳转到查词后的返回状态 ========
  bool _cameFromImportedMode = false;
  String _savedImportedText = '';
  List<_ImportedWord> _savedImportedWords = [];
  String _savedImportedActiveFilter = '真题词';
  int _savedImportedTotalWords = 0;
  final Map<String, int> _savedImportedFilterCounts = {};

  // ======== 性能优化常量 ========
  static const int _maxContextHalf = 30;
  static const int _maxHistorySize = 20;
  static const int _autocompleteLimit = 10;
  static const int _syllabusSuggestions = 5;

  /// 单词检测预编译正则
  static final RegExp _wordTokenRegex = RegExp(r'\b[a-zA-Z]{2,}\b');
  static final RegExp _yearPrefixRegex = RegExp(r'^(\d{4})');
  static final RegExp _whitespaceRegex = RegExp(r'[\s\n\u3000]');
  static final RegExp _pureDigitsRegex = RegExp(r'^\d+$');
  static final RegExp _anyWhitespaceChar = RegExp(r'\s');
  static final RegExp _sentenceEndRegex = RegExp(r'[。！？.!?\n]');

  // ======== 防抖保存 ========
  Timer? _saveDebounce;
  void _saveConfigDebounced() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), _saveConfig);
  }

  /// 探测 Python 可执行文件路径
  static Future<String> _getPythonExe() async {
    try {
      final marvisPyDir = Directory(r'C:\Program Files\Tencent\Marvis\MarvisAgent');
      if (marvisPyDir.existsSync()) {
        final candidates = marvisPyDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) =>
                f.path.endsWith(r'\python.exe') &&
                f.path.contains(r'\runtime\python'))
            .toList();
        if (candidates.isNotEmpty) {
          candidates.sort((a, b) => b.path.compareTo(a.path));
          return candidates.first.path;
        }
      }
      final whereResult = await Process.run('where', ['python'], runInShell: true);
      if (whereResult.exitCode == 0) {
        final lines = (whereResult.stdout as String)
            .trim()
            .split('\n')
            .where((l) => !l.contains('WindowsApps'))
            .toList();
        if (lines.isNotEmpty) return lines.first.trim();
      }
    } catch (_) {}
    return 'python';
  }

  @override
  void initState() {
    super.initState();
    _initOcr();
    _loadStandardWords();
    _loadConfig();
    _autoImportLast();
  }

  Future<void> _initOcr() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      _tesseractPath = '$exeDir\\tesseract\\tesseract.exe';
      _tessdataPath = '$exeDir\\tesseract\\tessdata';
      _ocrReady = await File(_tesseractPath!).exists();
    } catch (_) {
      _ocrReady = false;
    }
  }

  /// 启动时自动导入上次使用的真题路径
  Future<void> _autoImportLast() async {
    if (_lastExamImportPath == null || _lastExamImportPath!.isEmpty) return;
    final dirObj = Directory(_lastExamImportPath!);
    if (!await dirObj.exists()) {
      _lastExamImportPath = null;
      _saveConfig();
      return;
    }
    final files = <CorpusFile>[];
    final recurse = _lastImportMode == 'folder';
    for (final entity in dirObj.listSync(recursive: recurse)) {
      if (entity is File) {
        final ext = entity.path.toLowerCase();
        if (ext.endsWith('.txt') || ext.endsWith('.doc') || ext.endsWith('.docx')) {
          files.add(CorpusFile(
            name: entity.uri.pathSegments.last,
            path: entity.path,
          ));
        }
      }
    }
    _applyCorpusFiles(files);
  }

  /// 课标词数据：{word: {category, pos, def}}，key 为原始大小写
  Map<String, Map<String, String>> _standardWords = {};
  /// 大小写不敏感索引：{lowercase → [原始大小写...]}
  Map<String, List<String>> _standardWordsLower = {};
  /// 拓展词反向索引：{extension_word → base_word}（JSON预定义+用户手动添加）
  Map<String, String> _extendReverseIndex = {};
  /// 性能索引
  Set<String> _standardWordsLowerKeySet = {}; // 小写 key 集合（用于 contains 检查）
  Map<String, List<String>> _wordsByFirstChar = {};

  // ======== 配置持久化 ========
  void _loadConfig() {
    try {
      // 兼容旧版配置：优先读 esw_config.json，不存在则自动迁移eva_config.json
      var f = File(_configPath);
      if (!f.existsSync()) {
        // 迁移1：旧版硬编码路径 → exe 同目录
        const oldHardcodedPath = r'D:\UserData\Desktop\eva\esw_config.json';
        final oldHardcoded = File(oldHardcodedPath);
        if (oldHardcoded.existsSync()) {
          oldHardcoded.copySync(_configPath);
          f = File(_configPath);
        } else {
          // 迁移2：旧版 eva_config.json → esw_config.json
          final oldConfig = File(r'D:\UserData\Desktop\eva\eva_config.json');
          if (oldConfig.existsSync()) {
            oldConfig.copySync(_configPath);
            f = File(_configPath);
          } else {
            return;
          }
        }
      }
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      // 迁移旧版配置：lastImportPath → lastExamImportPath
      _lastExamImportPath = json['lastExamImportPath'] as String? ?? json['lastImportPath'] as String?;
      _lastDocImportPath = json['lastDocImportPath'] as String? ?? json['lastImportPath'] as String?;
      _lastImportMode = json['lastImportMode'] as String?;
      _lastExportPath = json['lastExportPath'] as String?;
      final wh = json['wordHistory'];
      if (wh is List) {
        _wordHistory.addAll(wh.map((e) => e.toString()));
      }
      final ew = json['extendWords'];
      if (ew is List) {
        for (final w in ew) {
          if (!_extendWords.any((e) => e.toLowerCase() == w.toString().toLowerCase())) {
            _extendWords.add(w.toString());
          }
        }
      }
      final ebm = json['extendBaseMap'];
      if (ebm is Map) {
        ebm.forEach((k, v) {
          _extendBaseMap[k.toString()] = v.toString();
        });
      }
      // 将用户添加的拓展词也加入反向索引
      for (final entry in _extendBaseMap.entries) {
        _extendReverseIndex[entry.key.toLowerCase()] = entry.value.toLowerCase();
      }
      if (_extendWords.isNotEmpty) setState(() {});
      final mcg = json['manualChaoGangWords'];
      if (mcg is List) {
        _manualChaoGangWords.addAll(mcg.map((e) => e.toString()));
      }
      final mex = json['manualExtraWords'];
      if (mex is List) {
        _manualExtraWords.addAll(mex.map((e) => e.toString()));
      }
      final cm = json['classificationMemory'];
      if (cm is Map) {
        cm.forEach((k, v) {
          _classificationMemory[k.toString()] = v.toString();
        });
      }

      // 合并旧版 eva_config.json 中可能存在的增量数据（旧版程序可能持续写入）
      _mergeOldConfig();

      // 从全局列表回填分类记忆，确保历史积累的词也能在新导入时自动匹配
      for (final w in _extendWords) {
        _classificationMemory[w.toLowerCase()] = '拓展词';
      }
      for (final w in _manualChaoGangWords) {
        _classificationMemory[w.toLowerCase()] = '超纲词';
      }
      for (final w in _manualExtraWords) {
        _classificationMemory[w.toLowerCase()] = '专有词';
      }
    } catch (_) {}
  }

  /// 将旧版 eva_config.json 中的增量数据合并到当前状态，确保无数据丢失
  void _mergeOldConfig() {
    try {
      final oldFile = File(r'D:\UserData\Desktop\eva\eva_config.json');
      if (!oldFile.existsSync()) return;
      final old = jsonDecode(oldFile.readAsStringSync()) as Map<String, dynamic>;
      var merged = false;

      void mergeList(String key, List<dynamic> target) {
        final src = old[key];
        if (src is List) {
          for (final item in src) {
            final s = item.toString();
            if (!target.contains(s)) {
              target.add(s);
              merged = true;
            }
          }
        }
      }

      void mergeMap(String key, Map<String, dynamic> target) {
        final src = old[key];
        if (src is Map) {
          src.forEach((k, v) {
            final ks = k.toString();
            if (!target.containsKey(ks)) {
              target[ks] = v.toString();
              merged = true;
            }
          });
        }
      }

      mergeList('wordHistory', _wordHistory);
      mergeList('extendWords', _extendWords);
      mergeMap('extendBaseMap', _extendBaseMap);
      mergeList('manualChaoGangWords', _manualChaoGangWords.toList());
      mergeList('manualExtraWords', _manualExtraWords.toList());

      if (merged) {
        _saveConfig(); // 立即持久化合并后的数据
      }
    } catch (_) {}
  }

  void _saveConfig() {
    try {
      final json = {
        'lastExamImportPath': _lastExamImportPath,
        'lastDocImportPath': _lastDocImportPath,
        'lastImportMode': _lastImportMode,
        'lastExportPath': _lastExportPath,
        'wordHistory': _wordHistory,
        'extendWords': _extendWords,
        'extendBaseMap': _extendBaseMap,
        'manualChaoGangWords': _manualChaoGangWords.toList(),
        'manualExtraWords': _manualExtraWords.toList(),
        'classificationMemory': _classificationMemory,
      };
      final data = jsonEncode(json);
      File(_configPath).writeAsString(data);
    } catch (_) {}
  }

  Future<void> _loadStandardWords() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/standard_words.json');
      final raw = json.decode(jsonStr) as Map<String, dynamic>;
      _extendReverseIndex.clear();
      _standardWords = raw.map((k, v) {
        final m = v as Map<String, dynamic>;
        // 什JSON extensions 反向索引
        final exts = m['extensions'];
        if (exts is List) {
          for (final ext in exts) {
            final extLower = ext.toString().toLowerCase();
            if (extLower.isNotEmpty) {
              _extendReverseIndex[extLower] = k.toLowerCase();
            }
          }
        }
        return MapEntry(k, {
          'category': (m['category'] as String?) ?? '',
          'pos': (m['pos'] as String?) ?? '',
          'def': (m['def'] as String?) ?? '',
        });
      });
      // Build lowercase index for case-insensitive lookup
      _standardWordsLower.clear();
      for (final key in _standardWords.keys) {
        final lk = key.toLowerCase();
        _standardWordsLower.putIfAbsent(lk, () => []);
        _standardWordsLower[lk]!.add(key);
      }
      // Build performance indices
      _standardWordsLowerKeySet = _standardWordsLower.keys.toSet();
      _wordsByFirstChar.clear();
      for (final key in _standardWords.keys) {
        if (key.isEmpty) continue;
        final firstChar = key[0].toLowerCase();
        _wordsByFirstChar.putIfAbsent(firstChar, () => []);
        _wordsByFirstChar[firstChar]!.add(key);
      }
    } catch (_) {
      _standardWords = {};
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // 弹出导入方式菜单（居中于按钮正下方）
  Future<void> _showImportMenu() async {
    final RenderBox box =
        _importBtnKey.currentContext!.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero);
    final centerX = offset.dx + box.size.width / 2;

    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'folder', child: Text('导入文件夹')),
      const PopupMenuItem(value: 'files', child: Text('导入文件')),
    ];

    final mode = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          centerX - 50, offset.dy + box.size.height, centerX + 50, 0),
      items: items,
    );
    if (mode == 'folder') {
      _importFolder();
    } else if (mode == 'files') {
      _importFiles();
    }
  }

  Future<void> _importFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择真题文件夹',
      initialDirectory: _lastExamImportPath,
    );
    if (dir == null || dir.isEmpty) return;
    final dirObj = Directory(dir);
    if (!await dirObj.exists()) return;

    _lastExamImportPath = dir;
    _lastImportMode = 'folder';
    _saveConfig();

    final files = <CorpusFile>[];
    for (final entity in dirObj.listSync(recursive: true)) {
      if (entity is File) {
        final ext = entity.path.toLowerCase();
        if (ext.endsWith('.txt') || ext.endsWith('.doc') || ext.endsWith('.docx')) {
          files.add(CorpusFile(
            name: entity.uri.pathSegments.last,
            path: entity.path,
          ));
        }
      }
    }
    _applyCorpusFiles(files);
  }

  Future<void> _importFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择真题文件',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['txt', 'doc', 'docx'],
      initialDirectory: _lastExamImportPath,
    );
    if (result == null || result.files.isEmpty) return;

    final files = <CorpusFile>[];
    for (final f in result.files) {
      if (f.path != null) {
        files.add(CorpusFile(name: f.name, path: f.path!));
      }
    }
    _applyCorpusFiles(files);

    // 保存第一个文件的父目录作为导入路径
    final firstPath = result.files.first.path;
    if (firstPath != null) {
      _lastExamImportPath = File(firstPath).parent.path;
      _lastImportMode = 'files';
      _saveConfig();
    }
  }

  /// 什.docx 文件中提取纯文本
  String _readDocxContent(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentXml = archive.findFile('word/document.xml');
    if (documentXml == null) return '';

    final contentBytes = documentXml.content is List<int>
        ? Uint8List.fromList(documentXml.content as List<int>)
        : documentXml.content as Uint8List;
    final xmlStr = utf8.decode(contentBytes);
    final document = XmlDocument.parse(xmlStr);
    final paragraphs = document.findAllElements('w:p');
    final buffer = StringBuffer();
    for (final p in paragraphs) {
      final texts = p.findAllElements('w:t');
      if (texts.isEmpty) {
        buffer.writeln();
        continue;
      }
      for (final t in texts) {
        buffer.write(t.innerText);
      }
      buffer.writeln();
    }
    return buffer.toString().trim();
  }

  /// 从 PDF 文件中提取纯文本（含 OCR 回退）
  Future<String> _readPdfContent(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final document = await PdfDocument.openData(Uint8List.fromList(bytes));
    try {
      final buffer = StringBuffer();
      bool hasText = false;
      for (int i = 0; i < document.pages.length; i++) {
        final page = document.pages[i];
        final pageText = await page.loadText();
        final text = pageText.fullText;
        if (text.isNotEmpty) {
          buffer.writeln(text);
          hasText = true;
        }
      }
      if (hasText) return buffer.toString().trim();

      // 纯图片 PDF，回退到 OCR
      if (!_ocrReady) return '';

      final ocrBuffer = StringBuffer();
      for (int i = 0; i < document.pages.length; i++) {
        final pageText = await _ocrPdfPage(document.pages[i]);
        if (pageText.isNotEmpty) ocrBuffer.writeln(pageText);
      }
      return ocrBuffer.toString().trim();
    } finally {
      document.dispose();
    }
  }

  /// 对单个 PDF 页面进行 OCR 识别
  Future<String> _ocrPdfPage(PdfPage page) async {
    if (_tesseractPath == null || _tessdataPath == null) return '';
    try {
      final pageImage = await page.render(
        width: (page.width * 2).toInt(),
        height: (page.height * 2).toInt(),
      );
      if (pageImage == null) return '';

      final uiImg = await pageImage.createImage();
      pageImage.dispose();
      final pngBytes = await uiImg.toByteData(format: ui.ImageByteFormat.png);
      uiImg.dispose();
      if (pngBytes == null) return '';

      final tempDir = Directory.systemTemp;
      final imgFile = File('${tempDir.path}\\esw_ocr_${DateTime.now().millisecondsSinceEpoch}.png');
      await imgFile.writeAsBytes(pngBytes.buffer.asUint8List());

      final result = await Process.run(
        _tesseractPath!,
        [imgFile.path, 'stdout', '-l', 'chi_sim+eng'],
        environment: {'TESSDATA_PREFIX': _tessdataPath!},
        stdoutEncoding: utf8,
      );

      await imgFile.delete().catchError((_) {});

      return (result.stdout as String).trim();
    } catch (_) {
      return '';
    }
  }

  /// 导入文档内容到输入框
  Future<void> _importDocumentToInput() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择文档（支持 txt / docx / pdf）',
      type: FileType.custom,
      allowedExtensions: ['txt', 'docx', 'pdf'],
      initialDirectory: _lastDocImportPath,
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;

    final fileName = result.files.single.name;

    try {
      final ext = filePath.toLowerCase();
      String content;
      if (ext.endsWith('.docx')) {
        content = _readDocxContent(filePath);
      } else if (ext.endsWith('.pdf')) {
        content = await _readPdfContent(filePath);
      } else {
        content = File(filePath).readAsStringSync();
      }

      _searchController.text = content;
      _importedFileName = fileName;
      _importedFilePath = filePath;
      await _analyzeImportedText();

      // 记住本次导入的目录
      _lastDocImportPath = File(filePath).parent.path;
      _lastImportMode = 'files';
      _saveConfig();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 ${result.files.single.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  void _applyCorpusFiles(List<CorpusFile> files) {
    if (files.isEmpty) return;
    files.sort((a, b) => a.name.compareTo(b.name));

    final yearRegex = _yearPrefixRegex;
    final years = <int>{};
    for (final f in files) {
      final m = yearRegex.firstMatch(f.name);
      if (m != null) {
        final y = int.parse(m.group(1)!);
        if (y >= 2000 && y <= 2099) years.add(y);
      }
    }

    setState(() {
      _corpusFiles = files;
      _importedYears = years;
      _sortedYears = years.toList()..sort((a, b) => b.compareTo(a));
      _yearFrequency.clear();
      _results.clear();
      _filteredResults = [];
      _totalFrequency = 0;
      _selectedYear = null;
    });
  }

  // ---------- 单词检测----------
  /// 从文本中提取匹配位置所在的完整句子
  String _extractSentence(String text, int matchStart, int matchEnd) {
    // 向前查找句子开头
    int sentenceStart = matchStart;
    while (sentenceStart > 0) {
      if (_sentenceEndRegex.hasMatch(text[sentenceStart - 1])) {
        break;
      }
      sentenceStart--;
    }
    // 向后查找句子结尾
    int sentenceEnd = matchEnd;
    while (sentenceEnd < text.length) {
      if (_sentenceEndRegex.hasMatch(text[sentenceEnd])) {
        sentenceEnd++; // 包含结尾标点
        break;
      }
      sentenceEnd++;
    }
    return text.substring(sentenceStart, sentenceEnd).trim();
  }

  /// 检查单词在原文中是否有汉语注释（单词后紧跟中文括号注释或中文字符）
  static bool _hasChineseAnnotation(String text, int wordEnd) {
    // 从单词结束位置向后扫描最多 30 个字符
    final end = (wordEnd + 30).clamp(0, text.length);
    final snippet = text.substring(wordEnd, end);
    // 检测中文括号注释：如 (法式海鲜汤) 或（法式海鲜汤）
    if (RegExp(r'[\(（][^)）]*[\u4e00-\u9fa5]+[^)）]*[\)）]').hasMatch(snippet)) {
      return true;
    }
    // 检测紧跟的中文字符（单词后直接跟中文）
    if (RegExp(r'^\s*[\u4e00-\u9fa5]').hasMatch(snippet)) {
      return true;
    }
    return false;
  }

  Future<void> _onDetect() async {
    final raw = _searchController.text.trim();
    if (raw.isEmpty) return;

    final word = raw.toLowerCase();

    // 1) 查课标词库（优先精确匹配，再大小写不敏感匹配）
    bool isStandard = false;
    String cat = '';
    String pos = '';
    String def = '';
    String matchedKey = '';
    final swEntryExact = _standardWords[raw];
    if (swEntryExact != null) {
      isStandard = true;
      cat = swEntryExact['category']!;
      pos = swEntryExact['pos']!;
      def = swEntryExact['def']!;
      matchedKey = raw;
    } else {
      final lowerMatches = _standardWordsLower[word];
      if (lowerMatches != null && lowerMatches.isNotEmpty) {
        final swEntry = _standardWords[lowerMatches.first]!;
        isStandard = true;
        cat = swEntry['category']!;
        pos = swEntry['pos']!;
        def = swEntry['def']!;
        matchedKey = lowerMatches.first;
      }
    }

    // 2) 查拓展词
    final isExtend = _extendWords.any((e) => e.toLowerCase() == word);

    // 3) 搜索真题语料
    int totalFreq = 0;
    final results = <ResultRow>[];
    final yearFreq = <int, int>{};
    final pattern = RegExp(
      '\\b${RegExp.escape(word)}\\b',
      caseSensitive: false,
    );

    // 并行读取所有选中文件
    final selectedFiles = _corpusFiles.where((f) => f.isSelected).toList();
    final fileTexts = await Future.wait(selectedFiles.map((cf) async {
      try {
        final text = cf.path.toLowerCase().endsWith('.docx')
            ? _readDocxContent(cf.path)
            : await File(cf.path).readAsString();
        return (cf, text);
      } catch (_) {
        return null;
      }
    }));

    for (final entry in fileTexts) {
      if (entry == null) continue;
      final (cf, text) = entry;
      final matches = pattern.allMatches(text);
      for (final m in matches) {
        totalFreq++;
        // 提取年份
        final yearMatch = _yearPrefixRegex.firstMatch(cf.name);
        if (yearMatch != null) {
          final y = int.parse(yearMatch.group(1)!);
          yearFreq[y] = (yearFreq[y] ?? 0) + 1;
        }
        // 上下文：在关键词两侧各取约等量字符，并修正到词边界
        int beforeStart = (m.start - _maxContextHalf).clamp(0, text.length);
        int afterEnd = (m.end + _maxContextHalf).clamp(0, text.length);

        // 向外扩展到完整词边界
        while (beforeStart > 0 && !_whitespaceRegex.hasMatch(text[beforeStart - 1])) {
          beforeStart--;
        }
        while (afterEnd < text.length && !_whitespaceRegex.hasMatch(text[afterEnd])) {
          afterEnd++;
        }

        var before = text.substring(beforeStart, m.start);
        var after = text.substring(m.end, afterEnd);

        // 平衡两侧长度使关键词居中：从较长侧远端截断
        final diff = (before.length - after.length).abs();
        if (diff > 5) {
          if (before.length > after.length) {
            before = '\'${before.substring(diff)}\'';
          } else {
            after = '\'${after.substring(0, after.length - diff)}\'';
          }
        }

        results.add(ResultRow(
          index: results.length + 1,
          before: before,
          keyword: m.group(0)!,
          after: after,
          source: cf.name,
          filePath: cf.path,
          matchOffset: m.start,
          sentence: _extractSentence(text, m.start, m.end),
        ));
      }
    }

    // 4) 确定筛选类型 超纲词手动) > 拓展词> 合成词> 课标词> 反向索引拓展词> 手动专有词> 真题词在语料中) > 专有词不在课标词库中的专有词汇，如人名地名)
    String filter;
    if (_manualChaoGangWords.any((e) => e.toLowerCase() == word)) {
      filter = '超纲词';
    } else if (isExtend) {
      filter = '拓展词';
    } else if (isStandard) {
      filter = '课标词';
    } else if (_extendReverseIndex.containsKey(word)) {
      // 反向索引自动匹配：识别为拓展词并同步庀
      _extendWords.add(word);
      _extendBaseMap[word] = _extendReverseIndex[word]!;
      _saveConfig();
      filter = '拓展词';
    } else if (_manualExtraWords.any((e) => e.toLowerCase() == word)) {
      filter = '专有词';
    } else if (totalFreq > 0) {
      filter = '超纲词';
      _manualChaoGangWords.add(word);
    } else {
      filter = '专有词';
    }

    setState(() {
      _detectedWord = matchedKey.isNotEmpty ? matchedKey : word;
      _activeFilter = filter;
      _detectedCategory = isStandard && cat.isNotEmpty ? cat : null;
      _wordPos = pos;
      _wordDef = def;
      _totalFrequency = totalFreq;
      _yearFrequency.clear();
      _yearFrequency.addAll(yearFreq);
      _results.clear();
      _results.addAll(results);
      _selectedYear = null;
      _filteredResults = List.from(results);
      _filterCounts.updateAll((_, __) => 0);
      // 手动超纲词强制归类
      if (_manualChaoGangWords.any((e) => e.toLowerCase() == word)) {
        _filterCounts['超纲词'] = 1;
      } else {
        _filterCounts[filter] = 1;
      }
      // 真题词独立计数：只要在真题语料中出现过就计入
      if (totalFreq > 0) _filterCounts['真题词'] = 1;
    });

    // 加入历史记录
    if (word.length > 1) {
      _wordHistory.remove(word);
      _wordHistory.insert(0, word);
      if (_wordHistory.length > 20) {
        _wordHistory.removeRange(20, _wordHistory.length);
      }
      _saveConfig();
    }
  }

  /// 分析导入文本中的所有单词
  Future<void> _analyzeImportedText() async {
    final text = _searchController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _cameFromImportedMode = false;
        _inImportedMode = false;
        _importedWords.clear();
        _importedTotalWords = 0;
        _importedActiveFilter = '真题词';
        _importedFilterCounts.updateAll((_, __) => 0);
      });
      return;
    }

    // 提取单词（仅英文单词，至多字符且非纯数字）并保留原始大小写
    final wordRegex = _wordTokenRegex;
    final matches = wordRegex.allMatches(text);
    final freqMap = <String, int>{};
    final wordCaseMap = <String, String>{}; // 小写→原始大小写
    for (final m in matches) {
      final original = m.group(0)!;
      if (_pureDigitsRegex.hasMatch(original)) continue;
      final w = original.toLowerCase();
      freqMap[w] = (freqMap[w] ?? 0) + 1;
      if (!wordCaseMap.containsKey(w)) {
        wordCaseMap[w] = original;
      }
    }

    // 收集真题语料中的所有单词，用于判断「真题词」vs「超纲词」
    final corpusWordSet = <String>{};
    final selectedFiles = _corpusFiles.where((f) => f.isSelected).toList();
    final fileTexts = await Future.wait(selectedFiles.map((cf) async {
      try {
        if (cf.path.toLowerCase().endsWith('.docx')) {
          return _readDocxContent(cf.path);
        }
        final t = await File(cf.path).readAsString();
        return t;
      } catch (_) {
        return null;
      }
    }));
    for (final corpusText in fileTexts) {
      if (corpusText == null) continue;
      for (final m in wordRegex.allMatches(corpusText)) {
        final cw = m.group(0)!;
        if (!_pureDigitsRegex.hasMatch(cw)) {
          corpusWordSet.add(cw.toLowerCase());
        }
      }
    }


    final words = <_ImportedWord>[];
    for (final entry in freqMap.entries) {
      final w = entry.key; // 小写
      final original = wordCaseMap[w] ?? w; // 原始大小写
      final freq = entry.value;
      final inCorpus = corpusWordSet.contains(w);
      String cat;
      // 文档导入分析场景：命中分类记忆时直接复用历史归类
      if (_classificationMemory.containsKey(w)) {
        cat = _classificationMemory[w]!;
      } else if (_standardWordsLowerKeySet.contains(w)) {
        cat = '课标词';
      } else if (inCorpus) {
        cat = '真题词';
      } else {
        cat = '专有词';
      }
      words.add(_ImportedWord(
          word: original, category: cat, frequency: freq,
          isInCorpus: inCorpus));
    }

    // 分类统计
    final counts = <String, int>{
      '真题词': 0,
      '课标词': 0,
      '拓展词': 0,
      '超纲词': 0,
      '专有词': 0,
    };
    for (final iw in words) {
      counts[iw.category] = (counts[iw.category] ?? 0) + 1;
    }
    // 真题词= 在语料中出现但尚未归类的单词
    counts['真题词'] = words.where((iw) => iw.isInCorpus && iw.category == '真题词').length;

    setState(() {
      _cameFromImportedMode = false;
      _inImportedMode = true;
      _importedWords = words;
      _importedTotalWords = words.length;
      _importedActiveFilter = '真题词';
      _importedFilterCounts
        ..clear()
        ..addAll(counts);
    });
  }

  @override
  Widget build(BuildContext context) {
    final leftWidth = MediaQuery.of(context).size.width / 5;

    return Scaffold(
      body: Row(
        children: [
          RepaintBoundary(
            child: SizedBox(width: leftWidth, child: _buildLeftPanel()),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: RepaintBoundary(child: _buildRightPanel()),
          ),
        ],
      ),
    );
  }

  // ==================== 左侧面板 ====================
  Widget _buildLeftPanel() {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surfaceLight,
        border: Border(
          right: BorderSide(color: Color(0xFFDDE0E4), width: 1),
        ),
      ),
      child: Column(
        children: [
          _buildImportButton(),
          Expanded(child: _buildCorpusList()),
          if (_detectedWord.isNotEmpty &&
              _activeFilter != '专有词')
            _buildDetectedInfo(),
          _buildFooter(),
        ],
      ),
    );
  }

  // ---------- 检测到的单词信息（分类 + 词性+ 词义：---------
  Widget _buildDetectedInfo() {
    final isExtend = _extendWords.contains(_detectedWord);
    final isStandard = _detectedCategory != null;
    final chipColor = isExtend
        ? AppTheme.green
        : isStandard
            ? AppTheme.teal
            : AppTheme.orange; // 真题词橙
    final chipLabel = isExtend
        ? '拓展词'
        : isStandard
            ? (_detectedCategory ?? '')
            : '真题词';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('分类：',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  chipLabel,
                  style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                      fontWeight: FontWeight.w600),
                ),
              ),
              // 真题词→显示　 拓展词」按钮
              if (!isExtend && !isStandard) ...[
                const Spacer(),
                InkWell(
                  onTap: () => _showExtendWordDialog(),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.green.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: AppTheme.green.withValues(alpha: 0.3)),
                    ),
                    child: const Text('+ 拓展词',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.green,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ],
          ),
          if (isStandard) ...[
            const SizedBox(height: 8),
            // 词性
            Row(
              children: [
                const Text('词性：',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Text(_wordPos.isEmpty ? ' ' : _wordPos,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.primaryBlue,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            // 词义
            Row(
              children: [
                const Text('词义：',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Expanded(
                  child: Text(_wordDef.isEmpty ? ' ' : _wordDef,
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImportButton() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: ElevatedButton.icon(
        key: _importBtnKey,
        onPressed: _showImportMenu,
        icon: const Icon(Icons.folder_open, size: 18),
        label: const Text('真题导入', style: TextStyle(fontSize: 14)),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          backgroundColor: const Color(0xFFE3F2FD),
          foregroundColor: AppTheme.primaryBlue,
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildCorpusList() {
    if (_corpusFiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text('点击「真题导入」选择文件夹',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _corpusFiles.length,
      itemBuilder: (context, index) {
        final file = _corpusFiles[index];
        return GestureDetector(
          onSecondaryTapDown: (details) =>
              _showCorpusFileContextMenu(details.globalPosition, file),
          child: InkWell(
          onTap: () => setState(() => file.isSelected = !file.isSelected),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: file.isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined,
                    size: 15, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(file.name,
                      style: TextStyle(
                        fontSize: 12,
                        color: file.isSelected
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : Colors.grey.shade800,
                      ),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  Future<void> _showCorpusFileContextMenu(Offset position, CorpusFile file) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: 'open', child: Text('打开')),
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        const PopupMenuItem(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: Colors.red))),
      ],
    );

    if (result == null) return;

    switch (result) {
      case 'open':
        await Process.run('cmd', ['/c', 'start', '', file.path]);
        break;
      case 'edit':
        await Process.run('notepad', [file.path]);
        break;
      case 'delete':
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('确认删除'),
            content: Text('确定要永久删除 ${file.name} 吗？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('删除',
                      style: TextStyle(color: Colors.red))),
            ],
          ),
        );
        if (confirm == true) {
          final f = File(file.path);
          if (await f.exists()) {
            await f.delete();
            setState(() {
              _corpusFiles.removeWhere((cf) => cf.path == file.path);
            });
          }
        }
        break;
    }
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('真题文件数：', style: TextStyle(fontSize: 13)),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${_corpusFiles.where((f) => f.isSelected).length}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== 右侧面板 ====================
  Widget _buildRightPanel() {
    return Container(
      color: Colors.white,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            children: [
              _buildToolbar(),
              const Divider(height: 1),
              if (_cameFromImportedMode && _searchController.text.isNotEmpty)
                _buildReturnToImportedBar(),
              if (_inImportedMode)
                Expanded(child: _buildImportedTextPanel())
              else ...[
                _buildFilterChips(),
                _buildStatButtons(),
                if (_importedWords.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.spacingMd,
                        vertical: AppTheme.spacingSm),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        onPressed: _exportResultToWord,
                        icon: const Icon(Icons.file_download_outlined,
                            color: Colors.white, size: 18),
                        label: const Text('导出结果',
                            style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppTheme.spacingLg,
                              vertical: AppTheme.spacingSm),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                        ),
                      ),
                    ),
                  ),
                const Divider(height: 1),
                _buildYearDistribution(),
                const Divider(height: 1),
                _buildResultHeader(),
                const Divider(height: 1, thickness: 1),
                Expanded(child: _buildResultList()),
              ],
            ],
          ),
          if (_showHistory && _wordHistory.isNotEmpty)
            CompositedTransformFollower(
              link: _searchBoxLink,
              targetAnchor: Alignment.bottomCenter,
              followerAnchor: Alignment.topCenter,
              offset: const Offset(0, 4),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.5 - 40,
                ),
                child: _buildWordHistory(),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 从查词结果返回导入文本分析----------
  Widget _buildReturnToImportedBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceLighter,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderLight, width: 1),
        ),
      ),
      child: InkWell(
        onTap: _onReturnToImportedMode,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.arrow_back, size: 14, color: AppTheme.primaryBlue),
              SizedBox(width: 4),
              Text(
                '返回段落分析',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.primaryBlue,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onReturnToImportedMode() {
    // 重新归类：已加入拓展词手动超纲词的单词应归类为对应类别
    final oldCounts = Map<String, int>.from(_savedImportedFilterCounts);
    for (int i = 0; i < _savedImportedWords.length; i++) {
      final iw = _savedImportedWords[i];
      String? newCat;
      if (_extendWords.contains(iw.word) && iw.category != '拓展词') {
        newCat = '拓展词';
      } else if (_manualChaoGangWords.contains(iw.word) && iw.category != '超纲词') {
        newCat = '超纲词';
      }
      if (newCat != null) {
        oldCounts[iw.category] = (oldCounts[iw.category] ?? 1) - 1;
        _savedImportedWords[i] = _ImportedWord(
            word: iw.word,
            category: newCat,
            frequency: iw.frequency,
            isInCorpus: iw.isInCorpus);
        oldCounts[newCat] = (oldCounts[newCat] ?? 0) + 1;
      }
    }

    setState(() {
      _searchController.text = _savedImportedText;
      _inImportedMode = true;
      _cameFromImportedMode = false;
      _importedWords = _savedImportedWords;
      _importedActiveFilter = _savedImportedActiveFilter;
      _importedTotalWords = _savedImportedTotalWords;
      _importedFilterCounts
        ..clear()
        ..addAll(oldCounts);
      _savedImportedFilterCounts
        ..clear()
        ..addAll(oldCounts);
      // 清除单次查词结果
      _detectedWord = '';
      _results.clear();
      _yearFrequency.clear();
      _selectedYear = null;
      _filteredResults = [];
    });
  }

  /// 纯数据层：更新_importedWords / _savedImportedWords / 计数，不调用 setState
  /// 返回 true 表示实际发生了分类变更
  bool _reclassifyImportedWordData(_ImportedWord target, String newCategory) {
    bool changed = false;
    void updateList(List<_ImportedWord> list) {
      for (int i = 0; i < list.length; i++) {
        final old = list[i];
        if (old.word.toLowerCase() != target.word.toLowerCase()) continue;
        if (old.category == newCategory) continue;
        _importedFilterCounts[old.category] =
            (_importedFilterCounts[old.category] ?? 1) - 1;
        _importedFilterCounts[newCategory] =
            (_importedFilterCounts[newCategory] ?? 0) + 1;
        list[i] = _ImportedWord(
            word: old.word,
            category: newCategory,
            frequency: old.frequency,
            isInCorpus: old.isInCorpus);
        changed = true;
      }
    }
    updateList(_importedWords);
    updateList(_savedImportedWords);
    _cachedImportedFilter = null;
    return changed;
  }

  void _reclassifyImportedWord(_ImportedWord target, String newCategory) {
    setState(() {
      _reclassifyImportedWordData(target, newCategory);
    });
  }

  // ---------- 导入文本后的分析面板 ----------
  Widget _buildImportedTextPanel() {
    return Column(
      children: [
        _buildImportedFilterChips(),
        const Divider(height: 1),
        Expanded(child: _buildImportedWordList()),
      ],
    );
  }

  // ---------- 导入文本筛选标签 ----------
  Widget _buildImportedFilterChips() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppTheme.surfaceLighter,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _cameFromImportedMode = false;
                _inImportedMode = false;
                _importedWords.clear();
                _importedTotalWords = 0;
                _importedActiveFilter = '真题词';
                _importedFilterCounts.updateAll((_, __) => 0);
              });
            },
            icon: const Icon(Icons.arrow_back, size: 14),
            label: const Text('返回', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          Expanded(
            child: Center(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('筛选：',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary)),
                  ..._filters.map((f) {
                    final selected = _importedActiveFilter == f;
                    final color = _filterColors[f]!;
                    final count = _importedFilterCounts[f] ?? 0;
                    return GestureDetector(
                      onTap: () => setState(() => _importedActiveFilter = f),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: selected
                              ? color
                              : color.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? color
                                : color.withValues(alpha: 0.25),
                            width: selected ? 1.5 : 1,
                          ),
                          boxShadow: selected
                              ? [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.2),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  )
                                ]
                              : null,
                        ),
                        child: Text(
                          '$f  $count',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected ? Colors.white : color,
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _cameFromImportedMode = false;
                _inImportedMode = false;
                _importedWords.clear();
                _importedTotalWords = 0;
                _importedActiveFilter = '真题词';
                _importedFilterCounts.updateAll((_, __) => 0);
              });
            },
            icon: const Icon(Icons.clear, size: 14),
            label: const Text('清除', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.grey,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 导入文本单词列表 ----------
  Widget _buildImportedWordList() {
    // 缓存过滤结果，仅在数据或筛选变化时重新计算
    if (_cachedImportedFilter != _importedActiveFilter ||
        !identical(_cachedImportedWordsRef, _importedWords)) {
      if (_importedActiveFilter == '真题词') {
        // 真题词= 在语料中出现但尚未归类的单词（不含已标记拓展/超纲/专有词/课标词）
        _cachedFilteredImportedWords = _importedWords
            .where((iw) => iw.isInCorpus && iw.category == '真题词')
            .toList();
      } else {
        _cachedFilteredImportedWords = _importedWords
            .where((iw) => iw.category == _importedActiveFilter)
            .toList();
      }
      _cachedImportedFilter = _importedActiveFilter;
      _cachedImportedWordsRef = _importedWords;
    }
    final filtered = _cachedFilteredImportedWords;

    if (_importedWords.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined,
                size: 44, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(
              '导入文档后自动分析单词',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
            ),
          ],
        ),
      );
    }

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_none, size: 40, color: Colors.grey.shade300),
            const SizedBox(height: 8),
            Text(
              '无 ${_importedActiveFilter}类单词',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final iw = filtered[index];
        final color = _filterColors[iw.category]!;
        final isChaoGang = iw.category == '超纲词';
        final isExtraCorpus = iw.category == '专有词';
        final isUnmarkedZhenti = iw.category == '真题词'; // 未标记的真题词

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          decoration: BoxDecoration(
            color: index.isEven
                ? AppTheme.surfaceLightest
                : AppTheme.surfaceLighter,
            borderRadius: BorderRadius.circular(6),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: isExtraCorpus
                ? null
                : () async {
                    // 保存当前导入分析状态，以便后续返回
                    _savedImportedText = _searchController.text;
                    _savedImportedWords = List.from(_importedWords);
                    _savedImportedActiveFilter = _importedActiveFilter;
                    _savedImportedTotalWords = _importedTotalWords;
                    _savedImportedFilterCounts
                      ..clear()
                      ..addAll(_importedFilterCounts);

                    _searchController.text = iw.word;
                    _searchController.selection = TextSelection.collapsed(
                        offset: iw.word.length);
                    setState(() {
                      _inImportedMode = false;
                      _importedWords.clear();
                      _importedTotalWords = 0;
                      _importedActiveFilter = '真题词';
                      _importedFilterCounts.updateAll((_, __) => 0);
                    });
                    await _onDetect();
                    if (mounted) {
                      setState(() {
                        _cameFromImportedMode = true;
                      });
                    }
                  },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 分类彩色标签
                  Container(
                    width: 2,
                    height: 22,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 单词
                  SizedBox(
                    width: 130,
                    child: Text(
                      iw.word,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // ---- 专有词：标签 + 频次/筛选按钮----
                  if (isExtraCorpus) ...[
                    if (_manualExtraWords.contains(iw.word)) ...[
                      _buildCategoryTag('专有词', color),
                      const Spacer(),
                      InkWell(
                        onTap: () {
                          _manualExtraWords.remove(iw.word);
                          _reclassifyImportedWord(iw, '专有词');
                          setState(() {
                            if ((_filterCounts['专有词'] ?? 0) > 0) {
                              _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) - 1;
                            }
                          });
                          _saveConfig();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '移出',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: color,
                            ),
                          ),
                        ),
                      ),
                    ] else ...[
                      const Spacer(),
                      _buildClassifyButton(iw),
                    ],
                  ]
                  // ---- 超纲词：标签 + 频次 + 移出按钮 ----
                  else if (isChaoGang) ...[
                    _buildCategoryTag('超纲词', color),
                    const Spacer(),
                    InkWell(
                      onTap: () {
                        _manualChaoGangWords.remove(iw.word);
                        final newCat = _manualExtraWords.contains(iw.word)
                            ? '专有词'
                            : (iw.isInCorpus ? '真题词' : '专有词');
                        _reclassifyImportedWord(iw, newCat);
                        setState(() {
                          if ((_filterCounts['超纲词'] ?? 0) > 0) {
                            _filterCounts['超纲词'] = (_filterCounts['超纲词'] ?? 0) - 1;
                          }
                        });
                        _saveConfig();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '移出',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    _buildFreqColumn(iw.frequency, color),
                  ]
                  // ---- 课标词/ 拓展词：标签 + 频次 ----
                  else if (!isUnmarkedZhenti) ...[
                    _buildCategoryTag(iw.category, color),
                    const Spacer(),
                    _buildFreqColumn(iw.frequency, color),
                  ]
                  // ---- 未标记真题词：频欀+ 筛选按钮（居中：----
                  else ...[
                    _buildFreqColumn(iw.frequency, color),
                    const SizedBox(width: 6),
                    const Spacer(),
                    _buildClassifyButton(iw),
                  ],
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right,
                      size: 14, color: Color(0xFFCCCCCC)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCategoryTag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildFreqColumn(int frequency, Color color) {
    return SizedBox(
      width: 56,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text(
            '频次',
            style: TextStyle(fontSize: 9, color: Color(0xFF999999)),
          ),
          Text(
            '$frequency',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  List<String> _findBestSyllabusMatch(String word) {
    final lower = word.toLowerCase();
    final double wordLen = lower.length.toDouble();
    final candidates = <String, double>{};

    for (int pos = 0; pos < lower.length; pos++) {
      final bucket = _wordsByFirstChar[lower[pos]];
      if (bucket == null) continue;

      for (final keyLower in bucket) {
        final double keyLen = keyLower.length.toDouble();
        if (keyLen < 2) continue;

        int matchLen = 0;
        while (pos + matchLen < lower.length &&
            matchLen < keyLower.length &&
            lower[pos + matchLen] == keyLower.toLowerCase()[matchLen]) {
          matchLen++;
        }

        if (matchLen >= 3) {
          final score = (matchLen / wordLen) * 200 - (pos * 2);
          final old = candidates[keyLower];
          if (old == null || score > old) {
            candidates[keyLower] = score;
          }
        }
      }
    }
    final sorted = candidates.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(5).map((e) => e.key).toList();
  }

  // ──────────────────────────────────────────────
  // 筛选归类弹窗（独立 StatefulWidget，确保 chip 选中状态正确刷新）
  // ──────────────────────────────────────────────
  Future<void> _startClassifyBatch(_ImportedWord iw, {Set<String>? cancelled}) async {
    cancelled ??= {};
    final selectedBases = <String>[];
    final suggestions = _findBestSyllabusMatch(iw.word);

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => _ClassifyDialogContent(
        word: iw.word,
        suggestions: suggestions,
        selectedBases: selectedBases,
        standardWordsLowerKeySet: _standardWordsLowerKeySet,
        wordsByFirstChar: _wordsByFirstChar,
      ),
    );

    if (action == null) return; // 点击弹窗外→退出批量

    // 延后到下一帧，让弹窗关闭动画先跑完，避免 setState 与动画抢帧造成卡顿
    await Future.delayed(Duration.zero);

    switch (action) {
      case '拓展词':
        if (selectedBases.isEmpty) break;
        setState(() {
          final alreadyExisted = _extendWords.any((e) => e.toLowerCase() == iw.word.toLowerCase());
          _extendWords.removeWhere((e) => e.toLowerCase() == iw.word.toLowerCase());
          _extendWords.add(iw.word);
          if (!alreadyExisted) {
            _filterCounts['拓展词'] = (_filterCounts['拓展词'] ?? 0) + 1;
          }
          _extendBaseMap[iw.word] = selectedBases.first;
          _extendReverseIndex[iw.word.toLowerCase()] =
              selectedBases.first.toLowerCase();
          _reclassifyImportedWordData(iw, '拓展词');
        });
        _classificationMemory[iw.word.toLowerCase()] = '拓展词';
        _saveConfig();
        break;
      case '超纲词':
        _manualChaoGangWords.removeWhere((e) => e.toLowerCase() == iw.word.toLowerCase());
        _manualChaoGangWords.add(iw.word);
        setState(() {
          _filterCounts['超纲词'] = (_filterCounts['超纲词'] ?? 0) + 1;
          _reclassifyImportedWordData(iw, '超纲词');
        });
        _classificationMemory[iw.word.toLowerCase()] = '超纲词';
        _saveConfig();
        break;
      case '专有词':
        _manualExtraWords.removeWhere((e) => e.toLowerCase() == iw.word.toLowerCase());
        _manualExtraWords.add(iw.word);
        cancelled.add(iw.word);
        setState(() {
          _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) + 1;
          _reclassifyImportedWordData(iw, '专有词');
        });
        _classificationMemory[iw.word.toLowerCase()] = '专有词';
        _saveConfig();
        break;
    }

    // 查找下一个未标记且未被跳过的真题词
    for (final next in _importedWords) {
      if (next.isInCorpus && next.category == '真题词' && !cancelled.contains(next.word)) {
        await _startClassifyBatch(next, cancelled: cancelled);
        return;
      }
    }
  }

  Widget _buildClassifyButton(_ImportedWord iw) {
    return InkWell(
      onTap: () => _startClassifyBatch(iw),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.primaryBlue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AppTheme.primaryBlue.withValues(alpha: 0.4)),
        ),
        child: const Text(
          '筛选',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppTheme.primaryBlue,
          ),
        ),
      ),
    );
  }

  // ---------- 顶部工具栀----------
  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceLighter,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderLighter, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _importDocumentToInput,
            icon: const Icon(Icons.file_open, size: 18),
            label: const Text('文档导入', style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: CompositedTransformTarget(
              link: _searchBoxLink,
              child: Stack(
                key: _searchBoxKey,
                alignment: Alignment.center,
                children: [
                  TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    maxLines: 10,
                    minLines: 1,
                    textAlignVertical: TextAlignVertical.center,
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: '',
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(6))),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(6)),
                        borderSide: BorderSide(
                          color: AppTheme.primaryBlue,
                          width: 1.5,
                        ),
                      ),
                      isDense: false,
                      filled: true,
                      fillColor: Color(0xFFF5F5F5),
                    ),
                    onChanged: (_) {
                      final text = _searchController.text;
                      // maxLines>1 旀Enter 产生换行而非 onSubmitted，单行单词按 Enter 触发检测
                      if (text.contains('\n')) {
                        final trimmed = text.trim();
                        if (!trimmed.contains(_anyWhitespaceChar)) {
                          _searchController.text = trimmed;
                          _searchController.selection = TextSelection.collapsed(offset: trimmed.length);
                          _onDetect();
                          _cancelHistoryTimer();
                          setState(() => _showHistory = false);
                          return;
                        }
                      }
                      _cancelHistoryTimer();
                      setState(() {
                        _showHistory = false;
                      });
                      // 检测是否为多单词文本（粘贴场景），自动切换导入模式
                      final trimmed = _searchController.text.trim();
                      if (trimmed.contains(_anyWhitespaceChar) &&
                          _wordTokenRegex.allMatches(trimmed).length >= 2) {
                        _importedFileName = null;
                        _analyzeImportedText();
                      } else if (trimmed.isEmpty) {
                        setState(() {
                          _inImportedMode = false;
                          _importedWords.clear();
                        });
                      }
                    },
                    onTap: () {
                      setState(() => _showHistory = true);
                      _cancelHistoryTimer();
                      _historyTimer = Timer(const Duration(seconds: 2), () {
                        if (mounted) setState(() => _showHistory = false);
                      });
                    },
                    onSubmitted: (_) {
                      _onDetect();
                      _cancelHistoryTimer();
                      setState(() => _showHistory = false);
                    },
                  ),
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _searchController.text.isEmpty ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: const Text(
                        '输入单词或者粘贴文本后按Enter检测',
                        style: TextStyle(fontSize: 14, color: AppTheme.textDisabled),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _buildToolbarRightButton(),
        ],
      ),
    );
  }

  /// 工具栏右侧按钮：始终显示"导出结果"
  Widget _buildToolbarRightButton() {
    return OutlinedButton.icon(
      onPressed: _exportResultToWord,
      icon: const Icon(Icons.file_download_outlined, size: 18),
      label: const Text('导出结果', style: TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6)),
        side: BorderSide(color: AppTheme.primaryBlue),
        foregroundColor: AppTheme.primaryBlue,
      ),
    );
  }

/// 单词历史记录下拉
  Widget _buildWordHistory() {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Text('最近输入',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _wordHistory.clear();
                      _saveConfig();
                    });
                  },
                  child: const Text('清除',
                      style: TextStyle(fontSize: 11, color: AppTheme.primaryBlue)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _wordHistory.length,
              itemBuilder: (ctx, i) {
                final w = _wordHistory[i];
                return InkWell(
                  key: ValueKey(w),
                  onTap: () {
                    _searchController.text = w;
                    _searchController.selection = TextSelection.collapsed(
                        offset: w.length);
                    _cancelHistoryTimer();
                    setState(() => _showHistory = false);
                    _searchFocus.unfocus();
                    // 多单词文本自动进入段落分析模式，单行单词自动检测
                    final trimmed = w.trim();
                    if (trimmed.contains(_anyWhitespaceChar) &&
                        _wordTokenRegex
                                .allMatches(trimmed)
                                .length >=
                            2) {
                      _analyzeImportedText();
                    } else {
                      _onDetect();
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Text(w,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF333333))),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 词频总数 ----------
  Widget _buildStatButtons() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFrequencyTotal(),
            const SizedBox(width: 10),
            _buildExtendWordsButton(),
            const SizedBox(width: 10),
            _buildChaoGangWordsButton(),
            const SizedBox(width: 10),
            _buildExtraWordsButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildFrequencyTotal() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE3F2FD),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF90CAF9)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: '词频总数：',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textSecondary),
            ),
            TextSpan(
              text: '$_totalFrequency',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.primaryBlue,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtendWordsButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _showExtendWordsList,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE3F2FD),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF90CAF9)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
        child: Text.rich(
          TextSpan(
            children: [
              const TextSpan(
                text: '拓展词汇：',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textSecondary),
              ),
              TextSpan(
                text: '${_extendWords.length}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryBlue,
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _searchWordFromDialog(String word) {
    _searchController.text = word;
    _onDetect();
  }

  Future<void> _showExtendWordsList() async {
    if (_extendWords.isEmpty) {
      showDialog(
        barrierDismissible: true,
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('拓展词汇'),
          content: const Text('暂未添加任何拓展词。\n请先搜索标注词，再点击拓展词按钮添加。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    final reversed = _extendWords.reversed.toList();
    showDialog(
        barrierDismissible: true,
      context: context,
      builder: (ctx) {
        var dragOffset = Offset.zero;
        String extendSearch = '';
        Set<String> extendSelected = {};
        return StatefulBuilder(
          builder: (_, setDialogState) {
            final filtered = extendSearch.isEmpty
                ? reversed
                : reversed.where((w) => w.toLowerCase().contains(extendSearch.toLowerCase())).toList();
            final allSelected = filtered.isNotEmpty && filtered.every((w) => extendSelected.contains(w));
            return Transform.translate(
              offset: dragOffset,
              child: AlertDialog(
                title: GestureDetector(
                  onPanUpdate: (d) =>
                      setDialogState(() => dragOffset += d.delta),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Row(
                      children: [
                        Text('拓展词汇（共${_extendWords.length}个）',
                            style: const TextStyle(fontSize: 16)),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
                    content: SizedBox(
                      width: 540,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: TextButton.icon(
                              icon: const Icon(Icons.file_download_outlined, size: 18),
                              label: const Text('导出所有单词'),
                              onPressed: () => _exportExtendWords(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_extendWords.length > 3)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: TextField(
                                decoration: const InputDecoration(
                                  hintText: '搜索单词...',
                                  prefixIcon: Icon(Icons.search, size: 18),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.all(Radius.circular(6))),
                                ),
                                onChanged: (v) {
                                  setDialogState(() {
                                    extendSearch = v;
                                    extendSelected.clear();
                                  });
                                },
                              ),
                            ),
                          if (filtered.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                  child: Text('暂无拓展词汇',
                                      style:
                                          TextStyle(color: Colors.grey))),
                            )
                          else ...[
                            Padding(
                              padding: const EdgeInsets.only(right: 16, bottom: 2),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  const Text('全选', style: TextStyle(fontSize: 12)),
                                  Transform.scale(
                                    scale: 0.75,
                                    child: Checkbox(
                                      value: allSelected ? true : (extendSelected.isNotEmpty ? null : false),
                                      tristate: true,
                                      onChanged: (v) {
                                        setDialogState(() {
                                          if (v == true) {
                                            extendSelected.addAll(filtered);
                                          } else {
                                            extendSelected.removeAll(filtered);
                                          }
                                        });
                                      },
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Flexible(
                              child: ListView.builder(
                                padding:
                                    const EdgeInsets.only(right: 12),
                                shrinkWrap: true,
                                itemCount: filtered.length,
                                itemBuilder: (_, i) {
                                  final w = filtered[i];
                                  final base = _extendBaseMap[w] ?? '';
                                  final seq = '${i + 1}.';
                                  return Padding(
                                    padding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 2),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 32,
                                          child: Text(seq,
                                              textAlign: TextAlign.right,
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey)),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              InkWell(
                                                onTap: () {
                                                  Navigator.pop(ctx);
                                                  _searchWordFromDialog(w);
                                                },
                                                child: Text(w,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 13,
                                                        color: Color(
                                                            0xFF1565C0),
                                                        decoration:
                                                            TextDecoration
                                                                .underline)),
                                              ),
                                              if (base.isNotEmpty)
                                                Text('← $base',
                                                    style: const TextStyle(
                                                        fontSize: 11,
                                                        color:
                                                            Colors.grey)),
                                            ],
                                          ),
                                        ),
                                        _MiniIconButton(
                                          icon: Icons.edit_outlined,
                                          tooltip: '编辑',
                                          onTap: () => _editExtendWord(
                                              ctx, w, base),
                                        ),
                                        const SizedBox(width: 2),
                                        _MiniIconButton(
                                          icon: Icons.delete_outline,
                                          tooltip: '删除',
                                          onTap: () =>
                                              _removeExtendWord(ctx, w),
                                        ),
                                        const SizedBox(width: 2),
                                        Transform.scale(
                                          scale: 0.75,
                                          child: Checkbox(
                                            value: extendSelected.contains(w),
                                            onChanged: (v) {
                                              setDialogState(() {
                                                if (v == true) {
                                                  extendSelected.add(w);
                                                } else {
                                                  extendSelected.remove(w);
                                                }
                                              });
                                            },
                                            visualDensity: VisualDensity.compact,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                actions: [
                  if (extendSelected.isNotEmpty)
                    TextButton(
                      onPressed: () => _batchRemoveExtendWords(
                          ctx, extendSelected, setDialogState),
                      child: Text('批量删除(${extendSelected.length})',
                          style: const TextStyle(color: Colors.red)),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _removeExtendWord(BuildContext dialogCtx, String word) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要移除拓展词 $word 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      setState(() {
        _extendWords.remove(word);
        _extendBaseMap.remove(word);
        _extendReverseIndex.remove(word.toLowerCase());
      });
      _saveConfig();
      Navigator.pop(dialogCtx);
    }
  }


  Future<void> _batchRemoveExtendWords(
      BuildContext dialogCtx, Set<String> words,
      void Function(void Function()) setDialogState) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定要移除选中的 ${words.length} 个拓展词吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      setState(() {
        for (final w in words) {
          _extendWords.remove(w);
          _extendBaseMap.remove(w);
          _extendReverseIndex.remove(w.toLowerCase());
        }
      });
      _saveConfig();
      Navigator.pop(dialogCtx);
    }
  }

  Future<void> _batchRemoveChaoGangWords(
      BuildContext dialogCtx, Set<String> words,
      void Function(void Function()) setDialogState) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定要移除选中的 ${words.length} 个超纲词吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      setState(() {
        _manualChaoGangWords.removeAll(words);
        for (final w in words) {
          _extendReverseIndex.remove(w.toLowerCase());
        }
      });
      _saveConfig();
      Navigator.pop(dialogCtx);
    }
  }

  Future<void> _batchRemoveExtraWords(
      BuildContext dialogCtx, Set<String> words,
      void Function(void Function()) setDialogState) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定要移除选中的 ${words.length} 个专有词吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      setState(() {
        _manualExtraWords.removeAll(words);
      });
      _saveConfig();
      Navigator.pop(dialogCtx);
    }
  }

  Future<void> _exportExtendWords() async {
    _AppLog.clear();
    _AppLog.log('======= 开始导入=======');
    _AppLog.log('拓展词总数: ${_extendWords.length}');
    if (_extendWords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无拓展词汇可导入')),
      );
      return;
    }
    final extendMap = <String, List<String>>{};
    for (final w in _extendWords) {
      final base = _extendBaseMap[w] ?? '';
      if (base.isNotEmpty) {
        extendMap.putIfAbsent(base, () => []).add(w);
      }
    }
    _AppLog.log('extendMap 条目敀 ${extendMap.length}');
    _AppLog.log('extendMap keys: ${extendMap.keys.toList()}');
    final templatePath = r'D:\UserData\Desktop\3100课标词.xlsx';
    final templateFile = File(templatePath);
    if (!templateFile.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到模板文件 3100课标词.xlsx')),
      );
      return;
    }
    final savePath = await FilePicker.saveFile(
      dialogTitle: '导出拓展词汇 Excel',
      fileName: '3100课标词_拓展.xlsx',
      allowedExtensions: ['xlsx'],
      initialDirectory: _lastExportPath,
    );
    if (savePath == null) {
      _AppLog.log('用户取消了保存对话框');
      return;
    }
    _AppLog.log('用户选择保存路径: $savePath');
    await templateFile.copy(savePath);
    _AppLog.log('模板已复制到: $savePath');
    try {
      final script = '''
import openpyxl
wb = openpyxl.load_workbook(r"$savePath")
ws = wb.active
extend_map = ${jsonEncode(extendMap)}
extend_col = ws.max_column
header = ws.cell(1, extend_col).value
if header != '拓展':
    extend_col += 1
    ws.cell(1, extend_col, '拓展')
word_row = {}
for r in range(2, ws.max_row + 1):
    word = ws.cell(r, 1).value
    if word:
        word_row[word.lower().strip()] = r
for base_word, extend_words in extend_map.items():
    key = base_word.lower().strip()
    if key in word_row:
        r = word_row[key]
        existing = ws.cell(r, extend_col).value or ''
        new_vals = ', '.join(extend_words)
        if existing:
            new_vals = existing + ', ' + new_vals
        ws.cell(r, extend_col, new_vals)
wb.save(r"$savePath")
print("OK")
''';
      final pythonExe = await _getPythonExe();
      _AppLog.log('最终 pythonExe: $pythonExe');

      final tmpScriptPath = r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_19f276b029f_9b715e33016d\temp\_export.py';
      final tmpFile = File(tmpScriptPath);
      await tmpFile.writeAsString(script);
      _AppLog.log('脚本已写入 $tmpScriptPath (${script.length} chars)');
      _AppLog.log('即将执行: $pythonExe $tmpScriptPath');
      final result = await Process.run(
          pythonExe, [tmpScriptPath],
          runInShell: true);
      _AppLog.log('Python exitCode: ${result.exitCode}');
      _AppLog.log('Python stdout: ${(result.stdout as String).trim()}');
      _AppLog.log('Python stderr: ${(result.stderr as String).trim()}');
      if (result.exitCode == 0) {
        _AppLog.log('导出成功');
        _lastExportPath = Directory(savePath).parent.path;
        _saveConfig();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出到 $savePath')),
        );
      } else {
        final err = (result.stderr as String).toString().trim();
        _AppLog.log('导出失败, 准备 throw Exception');
        throw Exception(err.isNotEmpty ? err : '脚本执行失败(exitCode=${result.exitCode})');
      }
    } catch (e) {
      _AppLog.log('catch 到异帀 $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
    _AppLog.log('======= 导出流程结束 =======');
  }

  Widget _buildChaoGangWordsButton() {
    final count = _manualChaoGangWords.length;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _showChaoGangWordsList,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3E0),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFFFCC80)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: '超纲词汇：',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textSecondary),
                ),
                TextSpan(
                  text: '$count',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.orange,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 将导入的原文导出为 Word 文档，按分类颜色高亮标注单词
  Future<void> _exportResultToWord() async {
    // 仅在导入分析模式下可用
    if (!_inImportedMode || _importedWords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先导入文本并完成分析后再导出')),
      );
      return;
    }

    String? outPath;
    try {
      // 生成默认文件名：被检测文档名（去扩展名）+ 课标词检测
      String defaultName = 'ESW_分析结果.docx';
      if (_importedFileName != null && _importedFileName!.isNotEmpty) {
        final dotIdx = _importedFileName!.lastIndexOf('.');
        final baseName = dotIdx > 0 ? _importedFileName!.substring(0, dotIdx) : _importedFileName!;
        defaultName = '$baseName课标词检测.docx';
      }
      final result = await FilePicker.saveFile(
        dialogTitle: '导出结果为 Word 文档',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: ['docx'],
        initialDirectory: _lastExportPath,
      );
      if (result == null) return; // 用户取消
      outPath = result;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择保存路径失败: $e')),
      );
      return;
    }

    // 原文文本（导入模式下的原始输入）
    final originalText = _savedImportedText.isNotEmpty
        ? _savedImportedText
        : _searchController.text;

    // 构建 小写单词 -> 分类 映射
    final wordCatMap = <String, String>{};
    for (final iw in _importedWords) {
      wordCatMap[iw.word.toLowerCase()] = iw.category;
    }

    final pythonExe = await _getPythonExe();
    final tmpScriptPath = r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_19f276b029f_9b715e33016d\temp\_export_word.py';
    final isDocxImport = _importedFilePath != null &&
        _importedFilePath!.toLowerCase().endsWith('.docx');
    final script = isDocxImport ? '''
import sys, json, re, shutil
from docx import Document
from docx.shared import RGBColor
from docx.enum.text import WD_COLOR_INDEX

word_cat = ${jsonEncode(wordCatMap)}
out_path = ${jsonEncode(outPath)}
source_path = ${jsonEncode(_importedFilePath!)}

NS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'

def color_hex(cat):
    return {
        '\\u62d3\\u5c55\\u8bcd': '2E7D32',
        '\\u8d85\\u7eb2\\u8bcd': 'FF1744',
        '\\u4e13\\u6709\\u8bcd': '757575',
    }.get(cat, '')

shutil.copy2(source_path, out_path)
doc = Document(out_path)

for para in doc.paragraphs:
    full_text = para.text
    if not full_text:
        continue
    first_run = para.runs[0] if para.runs else None
    p_el = para._element
    for r in list(p_el.findall('{%s}r' % NS)):
        p_el.remove(r)
    tokens = re.findall(r"[A-Za-z]+|[^A-Za-z]+", full_text)
    for tok in tokens:
        run = para.add_run(tok)
        if first_run is not None:
            if first_run.bold:
                run.bold = True
            if first_run.italic:
                run.italic = True
            if first_run.font.size:
                run.font.size = first_run.font.size
            if first_run.font.name:
                run.font.name = first_run.font.name
        if re.fullmatch(r"[A-Za-z]+", tok):
            cat = word_cat.get(tok.lower(), '')
            hexc = color_hex(cat)
            if hexc:
                run.font.color.rgb = RGBColor.from_string(hexc)
                run.bold = True
                if cat == '\\u8d85\\u7eb2\\u8bcd':
                    run.font.highlight_color = WD_COLOR_INDEX.YELLOW
tmp_path = out_path + '.tmp'
doc.save(tmp_path)
shutil.move(tmp_path, out_path)
print("OK")
''' : '''
import sys, json, re
from docx import Document
from docx.shared import RGBColor
from docx.enum.text import WD_COLOR_INDEX
from docx.oxml.ns import qn

text = ${jsonEncode(originalText)}
word_cat = ${jsonEncode(wordCatMap)}
out_path = ${jsonEncode(outPath)}

def color_hex(cat):
    return {
        '\\u62d3\\u5c55\\u8bcd': '2E7D32',
        '\\u8d85\\u7eb2\\u8bcd': 'FF1744',
        '\\u4e13\\u6709\\u8bcd': '757575',
    }.get(cat, '')

doc = Document()
style = doc.styles['Normal']
style.font.name = 'Calibri'
style.element.rPr.rFonts.set(qn('w:eastAsia'), '\\u5b8b\\u4f53')

tokens = re.findall(r"[A-Za-z]+|[^A-Za-z]+", text)
para = doc.add_paragraph()
for tok in tokens:
    if re.fullmatch(r"[A-Za-z]+", tok):
        low = tok.lower()
        cat = word_cat.get(low, '')
        hexc = color_hex(cat)
        run = para.add_run(tok)
        if hexc:
            run.font.color.rgb = RGBColor.from_string(hexc)
            run.bold = True
            if cat == '\\u8d85\\u7eb2\\u8bcd':
                run.font.highlight_color = WD_COLOR_INDEX.YELLOW
    else:
        para.add_run(tok)
doc.save(out_path)
print("OK")
''';
    try {
      final tmpFile = File(tmpScriptPath);
      await tmpFile.writeAsString(script);
      final runResult = await Process.run(
          pythonExe, [tmpScriptPath],
          runInShell: true);
      if (runResult.exitCode == 0) {
        _lastExportPath = Directory(outPath).parent.path;
        _saveConfig();

        // 收集超纲词上下文（无汉语注释的），写入 JSON 供 Marvis 处理
        String? chaoGangJsonPath;
        final chaoGangWords = _importedWords
            .where((iw) => iw.category == '超纲词')
            .map((iw) => iw.word)
            .toSet();
        if (chaoGangWords.isNotEmpty) {
          final entries = <Map<String, String>>[];
          for (final word in chaoGangWords) {
            final pattern = RegExp(
              '\\b${RegExp.escape(word)}\\b',
              caseSensitive: false,
            );
            final matches = pattern.allMatches(originalText);
            for (final m in matches) {
              if (!_hasChineseAnnotation(originalText, m.end)) {
                entries.add({
                  'word': word,
                  'sentence': _extractSentence(originalText, m.start, m.end),
                });
              }
            }
          }
          if (entries.isNotEmpty) {
            final jsonPath = r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_19f276b029f_9b715e33016d\temp\_chaogang_replace.json';
            final payload = jsonEncode({
              'outPath': outPath,
              'entries': entries,
            });
            await File(jsonPath).writeAsString(payload);
            chaoGangJsonPath = jsonPath;

            // 运行第二个 Python 脚本，查询数据库并追加替换建议表到 Word 文档
            final suggestScriptPath = r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_19f276b029f_9b715e33016d\temp\_append_suggestions.py';
            final dbPath = r'D:\UserData\Desktop\eva\assets\esw_data.db';
            // 写入脚本
            await File(suggestScriptPath).writeAsString(r'''
# -*- coding: utf-8 -*-
import json, sys, os, sqlite3
from collections import Counter
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn

def main(json_path, db_path):
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    out_path = data["outPath"]
    entries = data["entries"]
    if not entries:
        print("NO_ENTRIES")
        return
    word_count = Counter(e["word"] for e in entries)
    unique_words = list(dict.fromkeys(e["word"] for e in entries))
    db = sqlite3.connect(db_path)
    cur = db.cursor()
    p = ",".join(["?"] * len(unique_words))
    cur.execute(f"SELECT word, replace_word, replace_note FROM chao_gang_replace WHERE word IN ({p})", unique_words)
    replace_map = {r[0]: (r[1], r[2]) for r in cur.fetchall()}
    uncovered = [w for w in unique_words if w not in replace_map]
    meaning_map = {}
    if uncovered:
        p2 = ",".join(["?"] * len(uncovered))
        cur.execute(f"SELECT word, meaning_cn FROM standard_words WHERE word IN ({p2})", uncovered)
        meaning_map = {r[0]: r[1] for r in cur.fetchall()}
    db.close()
    suggestions = {}
    for word in unique_words:
        if word in replace_map:
            rw, rn = replace_map[word]
            suggestions[word] = (rw if rw else word, rn)
        elif word in meaning_map:
            mc = meaning_map[word] or ""
            suggestions[word] = (word, "建议加注释：" + mc)
        else:
            suggestions[word] = (word, "建议加注释")
    doc = Document(out_path)
    doc.add_page_break()
    title = doc.add_paragraph()
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = title.add_run("\u8d85\u7eb2\u8bcd\u66ff\u6362\u5efa\u8bae\u8868")
    run.bold = True
    run.font.size = Pt(16)
    run.font.color.rgb = RGBColor(0x1F, 0x38, 0x64)
    note = doc.add_paragraph()
    run = note.add_run("\u8bf4\u660e\uff1a\u5efa\u8bae\u66ff\u6362\u4f18\u5148\u4ece\u8bfe\u6807\u8bcd/\u62d3\u5c55\u8bcd\u4e2d\u9009\u62e9\u3002\u65e0\u6cd5\u627e\u5230\u5408\u9002\u66ff\u6362\u7684\u8d85\u7eb2\u8bcd\uff0c\u5efa\u8bae\u5728\u539f\u6587\u4e2d\u6dfb\u52a0\u6c49\u8bed\u6ce8\u91ca\u3002")
    run.font.size = Pt(10)
    run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)
    table = doc.add_table(rows=len(unique_words) + 1, cols=4)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl = table._tbl
    tblPr = tbl.tblPr
    if tblPr is None:
        tblPr = tbl.makeelement(qn("w:tblPr"), {})
    borders = tblPr.makeelement(qn("w:tblBorders"), {})
    for bn in ["top", "left", "bottom", "right", "insideH", "insideV"]:
        border = borders.makeelement(qn("w:" + bn), {qn("w:val"): "single", qn("w:sz"): "4", qn("w:space"): "0", qn("w:color"): "000000"})
        borders.append(border)
    tblPr.append(borders)
    headers = ["\u8d85\u7eb2\u8bcd", "\u51fa\u73b0\u6b21\u6570", "\u5efa\u8bae\u66ff\u6362", "\u8bf4\u660e"]
    for i, h in enumerate(headers):
        cell = table.rows[0].cells[i]
        p_cell = cell.paragraphs[0]
        run = p_cell.add_run(h)
        run.bold = True
        run.font.size = Pt(10)
        p_cell.alignment = WD_ALIGN_PARAGRAPH.CENTER
        shading = cell._element.get_or_add_tcPr()
        shd = shading.makeelement(qn("w:shd"), {qn("w:fill"): "D9E2F3", qn("w:val"): "clear"})
        shading.append(shd)
    for idx, word in enumerate(unique_words):
        row = table.rows[idx + 1]
        sg = suggestions[word]
        vals = [word, str(word_count[word]), sg[0], sg[1]]
        for i, val in enumerate(vals):
            cell = row.cells[i]
            p_cell = cell.paragraphs[0]
            run = p_cell.add_run(val)
            run.font.size = Pt(9)
            if i == 0:
                run.bold = True
    for row in table.rows:
        row.cells[0].width = Cm(2.8)
        row.cells[1].width = Cm(1.8)
        row.cells[2].width = Cm(4.5)
        row.cells[3].width = Cm(7.5)
    tmp = out_path + ".tmp"
    doc.save(tmp)
    os.replace(tmp, out_path)
    print("OK")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
''');
            try {
              await Process.run(
                  pythonExe, [suggestScriptPath, jsonPath, dbPath],
                  runInShell: true);
            } catch (_) {
              // 建议表追加失败不影响导出主流程
            }
          }
        }

        final msg = chaoGangJsonPath != null
            ? '已导出到 $outPath（含超纲词替换建议表）'
            : '已导出到 $outPath';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
        );
      } else {
        final err = (runResult.stderr as String).toString().trim();
        throw Exception(err.isNotEmpty ? err : '脚本执行失败(exitCode=${runResult.exitCode})');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

  Future<void> _showChaoGangWordsList() async {
    if (_manualChaoGangWords.isEmpty) {
      showDialog(
        barrierDismissible: true,
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('超纲词汇'),
          content: const Text('暂未添加任何超纲词。\n请先搜索标注词，再点击超纲词按钮添加。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (ctx) {
        var dragOffset = Offset.zero;
        String chaogangSearch = '';
        Set<String> chaogangSelected = {};
        return StatefulBuilder(
          builder: (_, setDialogState) {
            final words = _manualChaoGangWords.toList().reversed.toList();
            final filtered = chaogangSearch.isEmpty
                ? words
                : words.where((w) => w.toLowerCase().contains(chaogangSearch.toLowerCase())).toList();
            final allSelected = filtered.isNotEmpty && filtered.every((w) => chaogangSelected.contains(w));
            return Transform.translate(
              offset: dragOffset,
              child: AlertDialog(
                title: GestureDetector(
                  onPanUpdate: (d) =>
                      setDialogState(() => dragOffset += d.delta),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Row(
                      children: [
                        Text('超纲词汇（共${words.length}个）',
                            style: const TextStyle(fontSize: 16)),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
                    content: SizedBox(
                      width: 540,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: TextButton.icon(
                              icon: const Icon(Icons.file_download_outlined, size: 18),
                              label: const Text('导出所有单词'),
                              onPressed: () => _exportChaoGangWords(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (words.length > 3)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: TextField(
                                decoration: const InputDecoration(
                                  hintText: '搜索单词...',
                                  prefixIcon: Icon(Icons.search, size: 18),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.all(Radius.circular(6))),
                                ),
                                onChanged: (v) {
                                  setDialogState(() {
                                    chaogangSearch = v;
                                    chaogangSelected.clear();
                                  });
                                },
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(right: 16, bottom: 2),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                const Text('全选', style: TextStyle(fontSize: 12)),
                                Transform.scale(
                                  scale: 0.75,
                                  child: Checkbox(
                                    value: allSelected ? true : (chaogangSelected.isNotEmpty ? null : false),
                                    tristate: true,
                                    onChanged: (v) {
                                      setDialogState(() {
                                        if (v == true) {
                                          chaogangSelected.addAll(filtered);
                                        } else {
                                          chaogangSelected.removeAll(filtered);
                                        }
                                      });
                                    },
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Flexible(
                            child: ListView.builder(
                              padding:
                                  const EdgeInsets.only(right: 12),
                              shrinkWrap: true,
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final w = filtered[i];
                                final seq = '${i + 1}.';
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 2),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 32,
                                        child: Text(seq,
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey)),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: InkWell(
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            _searchWordFromDialog(w);
                                          },
                                          child: Text(w,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w600,
                                                  fontSize: 13,
                                                  color: Color(
                                                      0xFFE65100),
                                                  decoration:
                                                      TextDecoration
                                                          .underline)),
                                        ),
                                      ),
                                      _MiniIconButton(
                                        icon: Icons.add_circle_outline,
                                        tooltip: '转为拓展',
                                        onTap: () =>
                                            _convertChaoGangToExtend(
                                                ctx, w, setDialogState),
                                      ),
                                      const SizedBox(width: 2),
                                      _MiniIconButton(
                                        icon: Icons.swap_horiz,
                                        tooltip: '转为专有',
                                        onTap: () =>
                                            _convertChaoGangToExtra(
                                                ctx, w, setDialogState),
                                      ),
                                      const SizedBox(width: 2),
                                      _MiniIconButton(
                                        icon: Icons.delete_outline,
                                        tooltip: '删除',
                                        onTap: () =>
                                            _removeChaoGangWord(
                                                ctx, w),
                                      ),
                                      const SizedBox(width: 2),
                                      Transform.scale(
                                        scale: 0.75,
                                        child: Checkbox(
                                          value: chaogangSelected.contains(w),
                                          onChanged: (v) {
                                            setDialogState(() {
                                              if (v == true) {
                                                chaogangSelected.add(w);
                                              } else {
                                                chaogangSelected.remove(w);
                                              }
                                            });
                                          },
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                actions: [
                  if (chaogangSelected.isNotEmpty)
                    TextButton(
                      onPressed: () => _batchRemoveChaoGangWords(
                          ctx, chaogangSelected, setDialogState),
                      child: Text('批量删除(${chaogangSelected.length})',
                          style: const TextStyle(color: Colors.red)),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _convertChaoGangToExtend(
      BuildContext dialogCtx, String word, void Function(void Function()) setDialogState) async {
    final result = await _showExtendWordDialog(extendWord: word);
    if (result == true) {
      setState(() {
        _manualChaoGangWords.remove(word);
        _extendReverseIndex.remove(word.toLowerCase());
        if ((_filterCounts['超纲词'] ?? 0) > 0) {
          _filterCounts['超纲词'] = (_filterCounts['超纲词'] ?? 0) - 1;
        }
      });
      _saveConfig();
      setDialogState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将 "$word" 转为拓展词'), duration: const Duration(seconds: 1)),
        );
      }
    }
  }

  Future<void> _convertExtraToExtend(
      BuildContext dialogCtx, String word, void Function(void Function()) setDialogState) async {
    final result = await _showExtendWordDialog(extendWord: word);
    if (result == true) {
      setState(() {
        _manualExtraWords.remove(word);
        _extendReverseIndex.remove(word.toLowerCase());
        if ((_filterCounts['专有词'] ?? 0) > 0) {
          _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) - 1;
        }
      });
      _saveConfig();
      setDialogState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将 "$word" 转为拓展词'), duration: const Duration(seconds: 1)),
        );
      }
    }
  }

  Future<void> _convertChaoGangToExtra(
      BuildContext dialogCtx, String word, void Function(void Function()) setDialogState) async {
    setState(() {
      _manualChaoGangWords.remove(word);
      _extendReverseIndex.remove(word.toLowerCase());
      if ((_filterCounts['超纲词'] ?? 0) > 0) {
        _filterCounts['超纲词'] = (_filterCounts['超纲词'] ?? 0) - 1;
      }
      if (!_manualExtraWords.any((e) => e.toLowerCase() == word.toLowerCase())) {
        _manualExtraWords.add(word);
        _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) + 1;
      }
    });
    _saveConfig();
    setDialogState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将 "$word" 转为专有词'), duration: const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _convertExtraToChaoGang(
      BuildContext dialogCtx, String word, void Function(void Function()) setDialogState) async {
    setState(() {
      _manualExtraWords.remove(word);
      _extendReverseIndex.remove(word.toLowerCase());
      if ((_filterCounts['专有词'] ?? 0) > 0) {
        _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) - 1;
      }
      if (!_manualChaoGangWords.any((e) => e.toLowerCase() == word.toLowerCase())) {
        _manualChaoGangWords.add(word);
        _filterCounts['超纲词'] = (_filterCounts['超纲词'] ?? 0) + 1;
      }
    });
    _saveConfig();
    setDialogState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将 "$word" 转为超纲词'), duration: const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _removeChaoGangWord(BuildContext dialogCtx, String word) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要移除超纲词 $word 吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      setState(() {
        _manualChaoGangWords.remove(word);
        _extendReverseIndex.remove(word.toLowerCase());
      });
      _saveConfig();
      Navigator.pop(dialogCtx);
    }
  }

  Future<void> _exportChaoGangWords() async {
    _AppLog.clear();
    _AppLog.log('======= 开始导出超纲词汇=======');
    _AppLog.log('超纲词总数: ${_manualChaoGangWords.length}');
    if (_manualChaoGangWords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无超纲词汇可导入')),
      );
      return;
    }
    final savePath = await FilePicker.saveFile(
      dialogTitle: '导出超纲词汇 Excel',
      fileName: '超纲词汇.xlsx',
      allowedExtensions: ['xlsx'],
      initialDirectory: _lastExportPath,
    );
    if (savePath == null) {
      _AppLog.log('用户取消了保存对话框');
      return;
    }
    _AppLog.log('用户选择保存路径: $savePath');

    final words = _manualChaoGangWords.toList().reversed.toList();
    try {
      final script = '''
import openpyxl
wb = openpyxl.Workbook()
ws = wb.active
ws.title = "超纲词汇"
ws.cell(1, 1, "序号")
ws.cell(1, 2, "单词")
for i, w in enumerate(${jsonEncode(words)}, 1):
    ws.cell(i + 1, 1, i)
    ws.cell(i + 1, 2, w)
wb.save(r"$savePath")
print("OK")
''';
      final pythonExe = await _getPythonExe();
      _AppLog.log('最终 pythonExe: $pythonExe');

      final tmpScriptPath = r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_19f276b029f_9b715e33016d\temp\_export_chao_gang.py';
      final tmpFile = File(tmpScriptPath);
      await tmpFile.writeAsString(script);
      _AppLog.log('脚本已写入 $tmpScriptPath (${script.length} chars)');
      _AppLog.log('即将执行: $pythonExe $tmpScriptPath');
      final result = await Process.run(
          pythonExe, [tmpScriptPath],
          runInShell: true);
      _AppLog.log('Python exitCode: ${result.exitCode}');
      _AppLog.log('Python stdout: ${(result.stdout as String).trim()}');
      _AppLog.log('Python stderr: ${(result.stderr as String).trim()}');
      if (result.exitCode == 0) {
        _AppLog.log('导出成功');
        _lastExportPath = Directory(savePath).parent.path;
        _saveConfig();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出 ${words.length} 个超纲词到：$savePath')),
        );
      } else {
        final err = (result.stderr as String).toString().trim();
        _AppLog.log('导出失败, 准备 throw Exception');
        throw Exception(err.isNotEmpty ? err : '脚本执行失败(exitCode=${result.exitCode})');
      }
    } catch (e) {
      _AppLog.log('catch 到异帀 $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
    _AppLog.log('======= 导出超纲词汇流程结束 =======');
  }

  // ---------- 专有词汇按钮 ----------
  Widget _buildExtraWordsButton() {
    final count = _manualExtraWords.length;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _showExtraWordsList,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.textDisabled),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: '专有词汇：',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textSecondary),
                ),
                TextSpan(
                  text: '$count',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showExtraWordsList() async {
    if (_manualExtraWords.isEmpty) {
      showDialog(
        barrierDismissible: true,
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('专有词汇'),
          content: const Text('暂未添加任何专有词。\n请在导入分析中点击"跳过"按钮添加。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (ctx) {
        var dragOffset = Offset.zero;
        String extraSearch = '';
        Set<String> extraSelected = {};
        return StatefulBuilder(
          builder: (_, setDialogState) {
            _extraWordsDialogSetState = setDialogState;
            final words = _manualExtraWords.toList().reversed.toList();
            final filtered = extraSearch.isEmpty
                ? words
                : words.where((w) => w.toLowerCase().contains(extraSearch.toLowerCase())).toList();
            final allSelected = filtered.isNotEmpty && filtered.every((w) => extraSelected.contains(w));
            return Transform.translate(
              offset: dragOffset,
              child: AlertDialog(
                title: GestureDetector(
                  onPanUpdate: (d) =>
                      setDialogState(() => dragOffset += d.delta),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Row(
                      children: [
                        Text('专有词汇（共${words.length}个）',
                            style: const TextStyle(fontSize: 16)),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
                    content: SizedBox(
                      width: 540,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: TextButton.icon(
                              icon: const Icon(Icons.file_download_outlined, size: 18),
                              label: const Text('导出所有单词'),
                              onPressed: () => _exportExtraWords(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (words.length > 3)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: TextField(
                                decoration: const InputDecoration(
                                  hintText: '搜索单词...',
                                  prefixIcon: Icon(Icons.search, size: 18),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.all(Radius.circular(6))),
                                ),
                                onChanged: (v) {
                                  setDialogState(() {
                                    extraSearch = v;
                                    extraSelected.clear();
                                  });
                                },
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(right: 16, bottom: 2),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                const Text('全选', style: TextStyle(fontSize: 12)),
                                Transform.scale(
                                  scale: 0.75,
                                  child: Checkbox(
                                    value: allSelected ? true : (extraSelected.isNotEmpty ? null : false),
                                    tristate: true,
                                    onChanged: (v) {
                                      setDialogState(() {
                                        if (v == true) {
                                          extraSelected.addAll(filtered);
                                        } else {
                                          extraSelected.removeAll(filtered);
                                        }
                                      });
                                    },
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Flexible(
                            child: ListView.builder(
                              padding:
                                  const EdgeInsets.only(right: 12),
                              shrinkWrap: true,
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final w = filtered[i];
                                final seq = '${i + 1}.';
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 2),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 32,
                                        child: Text(seq,
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey)),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: InkWell(
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            _searchWordFromDialog(w);
                                          },
                                          child: Text(w,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w600,
                                                  fontSize: 13,
                                                  color: Color(
                                                      0xFF757575),
                                                  decoration:
                                                      TextDecoration
                                                          .underline)),
                                        ),
                                      ),
                                      _MiniIconButton(
                                        icon: Icons.add_circle_outline,
                                        tooltip: '转为拓展',
                                        onTap: () =>
                                            _convertExtraToExtend(
                                                ctx, w, setDialogState),
                                      ),
                                      const SizedBox(width: 2),
                                      _MiniIconButton(
                                        icon: Icons.swap_horiz,
                                        tooltip: '转为超纲',
                                        onTap: () =>
                                            _convertExtraToChaoGang(
                                                ctx, w, setDialogState),
                                      ),
                                      const SizedBox(width: 2),
                                      _MiniIconButton(
                                        icon: Icons.delete_outline,
                                        tooltip: '删除',
                                        onTap: () => _removeExtraWord(
                                            ctx, w),
                                      ),
                                      const SizedBox(width: 2),
                                      Transform.scale(
                                        scale: 0.75,
                                        child: Checkbox(
                                          value: extraSelected.contains(w),
                                          onChanged: (v) {
                                            setDialogState(() {
                                              if (v == true) {
                                                extraSelected.add(w);
                                              } else {
                                                extraSelected.remove(w);
                                              }
                                            });
                                          },
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                actions: [
                  if (extraSelected.isNotEmpty)
                    TextButton(
                      onPressed: () => _batchRemoveExtraWords(
                          ctx, extraSelected, setDialogState),
                      child: Text('批量删除(${extraSelected.length})',
                          style: const TextStyle(color: Colors.red)),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      _extraWordsDialogSetState = null;
    });
  }

  Future<void> _removeExtraWord(BuildContext dialogCtx, String word) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要移除专有词 $word 吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      setState(() {
        _manualExtraWords.remove(word);
      });
      _saveConfig();
      Navigator.pop(dialogCtx);
    }
  }

  Future<void> _exportExtraWords() async {
    _AppLog.clear();
    _AppLog.log('======= 开始导出专有词汇=======');
    _AppLog.log('专有词总数: ${_manualExtraWords.length}');
    if (_manualExtraWords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无专有词汇可导入')),
      );
      return;
    }
    final savePath = await FilePicker.saveFile(
      dialogTitle: '导出专有词汇 Excel',
      fileName: '专有词汇.xlsx',
      allowedExtensions: ['xlsx'],
      initialDirectory: _lastExportPath,
    );
    if (savePath == null) {
      _AppLog.log('用户取消了保存对话框');
      return;
    }
    _AppLog.log('用户选择保存路径: $savePath');

    final words = _manualExtraWords.toList().reversed.toList();
    try {
      final script = '''
import openpyxl
wb = openpyxl.Workbook()
ws = wb.active
ws.title = "专有词汇"
ws.cell(1, 1, "序号")
ws.cell(1, 2, "单词")
for i, w in enumerate(${jsonEncode(words)}, 1):
    ws.cell(i + 1, 1, i)
    ws.cell(i + 1, 2, w)
wb.save(r"$savePath")
print("OK")
''';
      final pythonExe = await _getPythonExe();
      _AppLog.log('最终 pythonExe: $pythonExe');

      final tmpScriptPath = r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_19f276b029f_9b715e33016d\temp\_export_extra_word.py';
      final tmpFile = File(tmpScriptPath);
      await tmpFile.writeAsString(script);
      _AppLog.log('脚本已写入 $tmpScriptPath (${script.length} chars)');
      _AppLog.log('即将执行: $pythonExe $tmpScriptPath');
      final result = await Process.run(
          pythonExe, [tmpScriptPath],
          runInShell: true);
      _AppLog.log('Python exitCode: ${result.exitCode}');
      _AppLog.log('Python stdout: ${(result.stdout as String).trim()}');
      _AppLog.log('Python stderr: ${(result.stderr as String).trim()}');
      if (result.exitCode == 0) {
        _AppLog.log('导出成功');
        _lastExportPath = Directory(savePath).parent.path;
        _saveConfig();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出 ${words.length} 个专有词到：$savePath')),
        );
      } else {
        final err = (result.stderr as String).toString().trim();
        _AppLog.log('导出失败, 准备 throw Exception');
        throw Exception(err.isNotEmpty ? err : '脚本执行失败(exitCode=${result.exitCode})');
      }
    } catch (e) {
      _AppLog.log('catch 到异帀 $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
    _AppLog.log('======= 导出专有词汇流程结束 =======');
  }

  Future<void> _editExtendWord(BuildContext dialogCtx, String word, String currentBase) async {
    String selectedBase = currentBase.toLowerCase();
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('编辑拓展词 $word'),
          content: Autocomplete<String>(
            optionsBuilder: (v) {
              final q = v.text.toLowerCase();
              if (q.isEmpty) return const Iterable.empty();
              final bucket = _wordsByFirstChar[q[0]];
              if (bucket == null) return const Iterable.empty();
              final matches = bucket.where((s) => s.toLowerCase().contains(q)).toList();
              matches.sort();
              return matches;
            },
            initialValue: TextEditingValue(text: currentBase),
            fieldViewBuilder: (_, editor, focusNode, onSubmit) => TextField(
              controller: editor,
              focusNode: focusNode,
              decoration: const InputDecoration(
                labelText: '基础课标词',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
            onSelected: (s) => selectedBase = s,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(
              onPressed: () {
                if (selectedBase.isNotEmpty &&
                    _standardWordsLowerKeySet.contains(selectedBase.toLowerCase())) {
                  Navigator.pop(context, true);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请选择一个有效的课标词')),
                  );
                }
              },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
    if (result == true && selectedBase.isNotEmpty) {
      setState(() {
        _extendBaseMap[word] = selectedBase;
        _extendReverseIndex[word.toLowerCase()] = selectedBase.toLowerCase();
      });
      _saveConfig();
      Navigator.pop(dialogCtx);
    }
  }

  // ---------- 筛选标签 ----------
  Widget _buildFilterChips() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('筛选：',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            ..._filters.map((f) => _buildChip(
                  label: '$f ${_filterCounts[f] ?? 0}',
                  selected: _activeFilter == f,
                  onTap: () => setState(() => _activeFilter = f),
                  color: _filterColors[f]!,
                )),
          ],
        ),
      ),
    );
  }

  // ---------- 拓展词关联对话框 ----------
  // 返回值 true=确认添加, false=点击取消按钮, null=点击弹窗外
  Future<bool?> _showExtendWordDialog({String? extendWord}) async {
    final word = extendWord ?? _detectedWord;
    String selectedBase = '';
    String searchText = '';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            return AlertDialog(
              title: Text('将 "$word" 加入拓展词'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '请选择该词基于哪个课标词拓展：',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Autocomplete<String>(
                    optionsBuilder: (TextEditingValue value) {
                      if (value.text.isEmpty) return const Iterable.empty();
                      final lower = value.text.toLowerCase();
                      final bucket = _wordsByFirstChar[lower[0]];
                      if (bucket == null) return const Iterable.empty();
                      final matches = bucket.where((k) => k.toLowerCase().startsWith(lower)).toList();
                      matches.sort();
                      return matches.take(10);
                    },
                    fieldViewBuilder: (ctx, controller, focusNode, onSubmit) {
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: '输入课标词，自动匹配 ',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                        ),
                        onChanged: (v) {
                          searchText = v;
                        },
                        onSubmitted: (_) {
                          onSubmit();
                          if (selectedBase.isEmpty && searchText.isNotEmpty) {
                            selectedBase = searchText.toLowerCase();
                          }
                          if (selectedBase.isEmpty) return;
                          if (!_standardWordsLowerKeySet.contains(selectedBase.toLowerCase())) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('请输入有效的课标词')),
                            );
                            return;
                          }
                          Navigator.of(ctx).pop(true);
                        },
                      );
                    },
                    onSelected: (v) {
                      selectedBase = v;
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (selectedBase.isEmpty && searchText.isNotEmpty) {
                      selectedBase = searchText.toLowerCase();
                    }
                    if (selectedBase.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('请选择或输入课标词')),
                      );
                      return;
                    }
                    if (!_standardWordsLowerKeySet.contains(selectedBase.toLowerCase())) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('请输入有效的课标词')),
                      );
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text('确认'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && selectedBase.isNotEmpty) {
      setState(() {
        if (!_extendWords.contains(word)) {
          _extendWords.add(word);
          // 单词从超纲词/真题词转变为拓展词，同步更新计数
          if ((_filterCounts['超纲词'] ?? 0) > 0) {
            _filterCounts['超纲词'] = (_filterCounts['超纲词'] ?? 0) - 1;
          }
          _filterCounts['拓展词'] = (_filterCounts['拓展词'] ?? 0) + 1;
        }
        _extendBaseMap[word] = selectedBase;
        _extendReverseIndex[word.toLowerCase()] = selectedBase.toLowerCase();
        _activeFilter = '拓展词';
      });
      _saveConfig();
    }
    return result;
  }

  void _addAsChaoGangWord(String word) {
    if (_manualChaoGangWords.any((e) => e.toLowerCase() == word)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$word" 已标记为超纲词'), duration: const Duration(seconds: 1)),
      );
      return;
    }
    setState(() {
      _manualChaoGangWords.add(word);
      _filterCounts['超纲词'] = (_filterCounts['超纲词'] ?? 0) + 1;
      _activeFilter = '超纲词';
    });
    _saveConfig();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已将 "$word" 标记为超纲词'), duration: const Duration(seconds: 1)),
    );
  }

  void _addAsExtraWord(String word) {
    if (_manualExtraWords.any((e) => e.toLowerCase() == word.toLowerCase())) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$word" 已标记为专有词'), duration: const Duration(seconds: 1)),
      );
      return;
    }
    setState(() {
      _manualExtraWords.add(word);
      _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) + 1;
      _activeFilter = '专有词';
    });
    _saveConfig();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已将 "$word" 标记为专有词'), duration: const Duration(seconds: 1)),
    );
  }

  // ---------- 词频年份分布 ----------
  Widget _buildYearDistribution() {
    if (_importedYears.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: const Center(
          child: Text('请点击真题导入按钮，导入真题数据',
              style: TextStyle(fontSize: 13, color: Color(0xFF999999))),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('词频年份分布',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: _sortedYears.map((y) {
              final count = _yearFrequency[y] ?? 0;
              final label = (y % 100).toString().padLeft(2, '0');
              final isSelected = _selectedYear == y;
              // 根据词频数值宽度自适应 padding
              final countWidth = count.toString().length;
              final hPad = (countWidth <= 1) ? 12.0 : (8.0 + countWidth * 3.5);

              return Material(
                color: Colors.transparent,
                child: InkWell(
                onTap: count > 0
                    ? () => setState(() {
                          _selectedYear = isSelected ? null : y;
                          _filteredResults = _selectedYear != null
                              ? _results.where((r) => r.source.startsWith('${_selectedYear!}')).toList()
                              : List.from(_results);
                        })
                    : null,
                borderRadius: BorderRadius.circular(4),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 5),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.primaryBlue
                        : (count > 0
                            ? const Color(0xFFE3F2FD)
                            : Colors.grey.shade100),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isSelected
                          ? AppTheme.primaryBlue
                          : (count > 0
                              ? const Color(0xFF90CAF9)
                              : Colors.grey.shade300),
                      width: isSelected ? 1.5 : 1,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: AppTheme.primaryBlue.withValues(alpha: 0.25),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          style: TextStyle(
                            fontSize: 12,
                            color: isSelected
                                ? Colors.white
                                : (count > 0
                                    ? AppTheme.primaryBlue
                                    : Colors.grey.shade600),
                          )),
                      const SizedBox(height: 3),
                      Text('$count',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isSelected
                                ? Colors.white
                                : (count > 0
                                    ? AppTheme.primaryBlue
                                    : Colors.grey.shade400),
                          )),
                    ],
                  ),
                ),
              ),
            );
            }).toList(),
          ),
          if (_selectedYear != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: GestureDetector(
                onTap: () => setState(() {
                  _selectedYear = null;
                  _filteredResults = List.from(_results);
                }),
                child: Text('取消年份筛选· ${(_selectedYear! % 100).toString().padLeft(2, '0')}年',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.primaryBlue)),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 检测结果表格----------
  Widget _buildResultHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceLight,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE0E0E3), width: 1),
        ),
      ),
      child: const IntrinsicHeight(
        child: Row(
        children: [
          SizedBox(
              width: 48,
              child: Text('序号',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          VerticalDivider(width: 1, thickness: 1, color: AppTheme.borderLighter),
          Expanded(
              child: Text('所在文本',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          VerticalDivider(width: 1, thickness: 1, color: AppTheme.borderLighter),
          SizedBox(
              width: 160,
              child: Text('出处',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        ],
      ),
      ),
    );
  }

  // ---------- 检测结果列表----------
  Widget _buildResultList() {
    if (_filteredResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text(
              _selectedYear != null ? '$_selectedYear年无匹配结果' : '输入单词后可查看检测结果',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _filteredResults.length,
      itemBuilder: (context, index) {
        final row = _filteredResults[index];
        return Container(
          key: ValueKey('${row.source}_${row.matchOffset}'),
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              SizedBox(
                  width: 48,
                  child: Text('${row.index}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500))),
              const VerticalDivider(width: 1, thickness: 1, color: AppTheme.borderLighter),
              Expanded(
                child: _buildContextRow(row),
              ),
              const VerticalDivider(width: 1, thickness: 1, color: AppTheme.borderLighter),
              SizedBox(
                  width: 160,
                  child: Text(row.source,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500),
                      overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
      },
    );
  }

  // ---------- 上下文着色----------
  static const _afterColors = [
    AppTheme.red, // 红
    AppTheme.orange, // 橙
    AppTheme.green, // 绿
    AppTheme.purple, // 紫
    Color(0xFF00838F), // 青
    Color(0xFFBF360C), // 深红
    AppTheme.primaryBlue, // 蓝
  ];

  /// 前文 Span：右侧紧贴关键词，左侧溢出省略
  TextSpan _beforeSpan(String before) {
    return TextSpan(
      text: before,
      style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
    );
  }

  /// 后文 Span：逐词循环着色
  List<InlineSpan> _afterSpans(String after) {
    if (after.isEmpty) return [];
    final spans = <InlineSpan>[];
    final tokens = <String>[];
    for (final m in RegExp(r'\S+|\s+').allMatches(after)) {
      tokens.add(m.group(0)!);
    }
    var ci = 0;
    for (final tok in tokens) {
      final isSpace = tok.trimRight().isEmpty;
      spans.add(TextSpan(
        text: tok,
        style: TextStyle(
          fontSize: 12,
          color: isSpace ? const Color(0xFF333333) : _afterColors[ci++ % _afterColors.length],
        ),
      ));
    }
    return spans;
  }

  /// 打开原文 txt 并定位到关键词位罀
  void _openFileAtKeyword(ResultRow row) {
    final file = File(row.filePath);
    if (!file.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件不存在：${row.source}')),
        );
      }
      return;
    }
    final text = file.readAsStringSync();
    final keyword = row.keyword;
    final highlightController = _HighlightController(text, keyword);
    final scrollController = ScrollController();
    final totalLen = text.length;

    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (ctx) {
        // 延迟滚动到匹配位罀
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (totalLen > 0 && scrollController.hasClients) {
            final ratio = (row.matchOffset / totalLen).clamp(0.0, 1.0);
            final maxExtent = scrollController.position.maxScrollExtent;
            scrollController.jumpTo(maxExtent * ratio);
          }
        });

        return ValueListenableBuilder<TextEditingValue>(
          valueListenable: highlightController,
          builder: (_, value, __) {
            return AlertDialog(
              title: Text(
                row.source,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
              content: SizedBox(
                width: 700,
                height: 500,
                child: TextField(
                  controller: highlightController,
                  scrollController: scrollController,
                  readOnly: false,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF333333)),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                    hintText: '可直接在文本框内修改内容',
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    highlightController.dispose();
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('关闭'),
                ),
                ElevatedButton(
                  onPressed: () {
                    _saveFileText(file, highlightController.text);
                    highlightController.dispose();
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 将文本框当前全文直接写回文件
  void _saveFileText(File file, String newText) {
    // 保存前读取原文，用于对比找出被删除/修改而消失的单词
    String oldText = '';
    try {
      oldText = file.readAsStringSync();
    } catch (_) {
      oldText = '';
    }
    try {
      file.writeAsStringSync(newText);
      // 对比新旧文本，将不再出现的归类词从各集合中移除
      _pruneCategoriesAfterEdit(oldText, newText);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存修改')),
        );
      }
      _onDetect();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: \$e')),
        );
      }
    }
  }

  /// 保存文件后，对比新旧文本，将不再出现的单词从超纲词/拓展词/专有词中移除
  void _pruneCategoriesAfterEdit(String oldText, String newText) {
    if (oldText == newText) return;
    final newLower = newText.toLowerCase();
    bool changed = false;

    void pruneSet(
        dynamic set, String countKey, void Function(String w) onRemove) {
      final toRemove = <String>[];
      for (final w in List<String>.from(set)) {
        final pattern =
            RegExp(r'\b' + RegExp.escape(w) + r'\b', caseSensitive: false);
        if (!pattern.hasMatch(newLower)) {
          toRemove.add(w);
        }
      }
      if (toRemove.isNotEmpty) {
        for (final w in toRemove) {
          onRemove(w);
          _extendReverseIndex.remove(w.toLowerCase());
        }
        if ((_filterCounts[countKey] ?? 0) > 0) {
          _filterCounts[countKey] =
              (_filterCounts[countKey] ?? 0) - toRemove.length;
        }
        changed = true;
      }
    }

    pruneSet(_manualChaoGangWords, '超纲词',
        (w) => _manualChaoGangWords.remove(w));
    pruneSet(_extendWords, '拓展词', (w) => _extendWords.remove(w));
    pruneSet(_manualExtraWords, '专有词',
        (w) => _manualExtraWords.remove(w));

    if (changed) {
      _saveConfig();
      setState(() {});
      // 若专有词汇对话框处于打开状态，同步刷新其列表（原文修改后 fiends 等应自动消失）
      if (_extraWordsDialogSetState != null) {
        _extraWordsDialogSetState!(() {});
      }
    }
  }

  /// 三栏布局：前缀右对齐截断 | 关键词 | 后文(左对齐截断着色
  Widget _buildContextRow(ResultRow row) {
    return Row(
      children: [
        // 前文：右对齐，左侧溢出省略，占一半弹性空间
        Expanded(
          child: Text.rich(
            _beforeSpan(row.before),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
          ),
        ),
        const SizedBox(width: 1),
        // 关键词：蓝色可点击，点击跳转到原文定佀
        GestureDetector(
          onTap: () => _openFileAtKeyword(row),
          child: Text.rich(
            TextSpan(
              text: row.keyword,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.primaryBlue,
                decoration: TextDecoration.underline,
                decorationColor: AppTheme.primaryBlue,
              ),
            ),
            maxLines: 1,
          ),
        ),
        // 后文：左对齐，右侧溢出省略逐词着色，占一半弹性空间
        Expanded(
          child: Text.rich(
            TextSpan(children: _afterSpans(row.after)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.start,
          ),
        ),
      ],
    );
  }

  // ---------- 通用 Chip ----------
  Widget _buildChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required Color color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? color : color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? color : color.withValues(alpha: 0.35),
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.25),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : color,
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 数据模型 ====================
class CorpusFile {
  final String name;
  final String path;
  bool isSelected;

  CorpusFile({required this.name, required this.path, this.isSelected = true});
}

class ResultRow {
  final int index;
  final String before;
  final String keyword;
  final String after;
  final String source;
  final String filePath;
  final int matchOffset; // 关键词在原文中的起始位置
  final String sentence; // 关键词所在的完整句子

  ResultRow({
    required this.index,
    required this.before,
    required this.keyword,
    required this.after,
    required this.source,
    required this.filePath,
    required this.matchOffset,
    this.sentence = '',
  });
}

// ==================== 小组件 ====================

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MiniIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: Colors.grey.shade500),
        ),
      ),
    );
  }
}

// ==================== 高亮控制器（TextField readOnly + 关键词高亮） ====================

class _HighlightController extends TextEditingController {
  final String _keyword;

  _HighlightController(String text, this._keyword) : super(text: text);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final spans = <TextSpan>[];
    final regex = RegExp(
      '\\b${RegExp.escape(_keyword)}\\b',
      caseSensitive: false,
    );
    final text = this.text;
    final baseStyle = style ?? const TextStyle();
    int pos = 0;
    for (final m in regex.allMatches(text)) {
      if (m.start > pos) {
        spans.add(TextSpan(text: text.substring(pos, m.start), style: baseStyle));
      }
      spans.add(TextSpan(
        text: m.group(0)!,
        style: baseStyle.copyWith(
          fontWeight: FontWeight.bold,
          color: const Color(0xFF0D47A1),
          backgroundColor: const Color(0x66FFEB3B),
          decoration: TextDecoration.underline,
        ),
      ));
      pos = m.end;
    }
    if (pos < text.length) {
      spans.add(TextSpan(text: text.substring(pos), style: baseStyle));
    }
    return TextSpan(children: spans, style: baseStyle);
  }
}

// ==================== 筛选归类弹窗 ====================

class _ClassifyDialogContent extends StatefulWidget {
  final String word;
  final List<String> suggestions;
  final List<String> selectedBases; // 外部共享，用于回传选中的词根
  final Set<String> standardWordsLowerKeySet;
  final Map<String, List<String>> wordsByFirstChar;

  const _ClassifyDialogContent({
    required this.word,
    required this.suggestions,
    required this.selectedBases,
    required this.standardWordsLowerKeySet,
    required this.wordsByFirstChar,
  });

  @override
  State<_ClassifyDialogContent> createState() => _ClassifyDialogContentState();
}

class _ClassifyDialogContentState extends State<_ClassifyDialogContent> {
  final _chipSelections = <String>{};
  var _offset = Offset.zero;

  void _onChipTap(String s) {
    debugPrint('[ClassifyDialog] chip tapped as 拓展词: $s');
    widget.selectedBases.clear();
    widget.selectedBases.add(s);
    Navigator.pop(context, '拓展词');
  }

  void _submitTypedWord(String trimmed, BuildContext ctx) {
    if (!widget.standardWordsLowerKeySet.contains(trimmed)) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('请输入有效的课标词')),
      );
      return;
    }
    widget.selectedBases.clear();
    widget.selectedBases.add(trimmed);
    for (final c in _chipSelections) {
      if (c != trimmed) widget.selectedBases.add(c);
    }
    Navigator.pop(ctx, '拓展词');
  }

  void _submitAutoComplete(String s) {
    widget.selectedBases.clear();
    widget.selectedBases.add(s);
    for (final c in _chipSelections) {
      if (c != s) widget.selectedBases.add(c);
    }
    Navigator.pop(context, '拓展词');
  }

  void _submitButton(String action) {
    if (action == '拓展词') {
      widget.selectedBases.clear();
      widget.selectedBases.addAll(_chipSelections);
    }
    Navigator.pop(context, action);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {},
      onPointerMove: (e) {
        _offset += e.delta;
        setState(() {});
      },
      onPointerUp: (_) {},
      child: Transform.translate(
        offset: _offset,
        child: AlertDialog(
          title: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Text('将 "${widget.word}" 筛选归类'),
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 32,
                  child: widget.suggestions.isNotEmpty
                      ? Row(
                          children: List.generate(widget.suggestions.length, (i) {
                            final s = widget.suggestions[i];
                            final isSelected = _chipSelections.contains(s);
                            return Flexible(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: GestureDetector(
                                    onTap: () => _onChipTap(s),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? AppTheme.red.withValues(alpha: 0.08)
                                            : Colors.grey.withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: isSelected
                                              ? AppTheme.red
                                              : Colors.grey.withValues(alpha: 0.25),
                                          width: isSelected ? 2.0 : 1.0,
                                        ),
                                      ),
                                      child: Text(
                                        s,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isSelected
                                              ? AppTheme.red
                                              : AppTheme.textPrimary,
                                          fontWeight: isSelected
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        )
                      : null,
                ),
                const SizedBox(height: 8),
                Autocomplete<String>(
                  optionsBuilder: (v) {
                    if (v.text.isEmpty) return const Iterable.empty();
                    final lower = v.text.toLowerCase();
                    final bucket = widget.wordsByFirstChar[lower[0]];
                    if (bucket == null) return const Iterable.empty();
                    final matches = bucket.where((k) => k.startsWith(lower)).toList();
                    matches.sort();
                    return matches.take(10);
                  },
                  fieldViewBuilder: (ctx, controller, focusNode, onSubmit) {
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      onSubmitted: (value) {
                        final trimmed = value.trim().toLowerCase();
                        if (trimmed.isEmpty) return;
                        _submitTypedWord(trimmed, ctx);
                      },
                      decoration: const InputDecoration(
                        hintText: '输入课标词，按 Enter 确认添加为拓展词',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      ),
                    );
                  },
                  onSelected: _submitAutoComplete,
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton(
                      onPressed: () => _submitButton('专有词'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textHint,
                      ),
                      child: const Text('专有词'),
                    ),
                    OutlinedButton(
                      onPressed: () => _submitButton('超纲词'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.orange,
                      ),
                      child: const Text('超纲词'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 导入单词数据籀====================

class _ImportedWord {
  final String word;
  final String category;
  final int frequency;
  final bool isInCorpus; // 是否出现在真题语料中

  const _ImportedWord({
    required this.word,
    required this.category,
    required this.frequency,
    required this.isInCorpus,
  });
}

// ==================== 日志工具 ====================

class _AppLog {
  static final String _dir = r'C:\Users\Administrator\AppData\Roaming\Tencent\Marvis\User\oAN1i2RJcy_L6pl91YfZt7dWvUdo\workspace\conv_19f276b029f_9b715e33016d\temp';
  static final String _path = '$_dir\\esw_export.log';

  static void log(String msg) {
    try {
      final f = File(_path);
      final ts = DateTime.now().toIso8601String();
      final line = '[$ts] $msg\n';
      if (f.existsSync()) {
        f.writeAsStringSync(line, mode: FileMode.append);
      } else {
        Directory(_dir).createSync(recursive: true);
        f.writeAsStringSync(line);
      }
    } catch (_) {}
  }

  static void clear() {
    try {
      File(_path).writeAsStringSync('');
    } catch (_) {}
  }
}
