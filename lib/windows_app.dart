import 'package:flutter/material.dart';

import 'package:flutter/services.dart' show rootBundle;

import 'package:file_picker/file_picker.dart';

import 'dart:async';

import 'dart:collection';

import 'dart:ffi' hide Size;

import 'package:ffi/ffi.dart';

import 'theme/app_theme.dart';

import 'dart:convert';

import 'dart:io';

import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:archive/archive.dart';

import 'package:xml/xml.dart';

import 'package:pdfrx/pdfrx.dart';

import 'package:path/path.dart' as p;

import 'package:url_launcher/url_launcher.dart';

import 'package:http/http.dart' as http;

import 'dictionary_service.dart';
import 'shared/word_sync_service.dart';
import 'shared/doc_extractor.dart';
import 'shared/export_extra_table.dart';

typedef _GetDroppedFileC = Pointer<Utf8> Function();

typedef _GetDroppedFileDart = Pointer<Utf8> Function();

final DynamicLibrary _exeLib = DynamicLibrary.process();

final _GetDroppedFileDart _getDroppedFile = _exeLib

    .lookupFunction<_GetDroppedFileC, _GetDroppedFileDart>('get_dropped_file');

class WinEswApp extends StatelessWidget {

  const WinEswApp({super.key});

  @override

  Widget build(BuildContext context) {

    return MaterialApp(

      title: 'ESW',

      debugShowCheckedModeBanner: false,

      theme: ThemeData(

        colorScheme: ColorScheme.fromSeed(

          seedColor: AppTheme.primaryYellow,

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

  final List<String> _filters = ['真题词', '课标词', '拓展词', '超标词', '专有词'];

  final Map<String, int> _filterCounts = {'真题词': 0, '课标词': 0, '拓展词': 0, '超标词': 0, '专有词': 0};

  static final Map<String, Color> _filterColors = {

    '真题词': AppTheme.orange,

    '课标词': AppTheme.primaryBlue,

    '拓展词': AppTheme.green,

    '超标词': AppTheme.red,

    '专有词': AppTheme.grey,

  };

  String _wordPos = '';

  String _wordDef = '';

  String? _detectedCategory;

  String _detectedWord = '';

  final List<String> _extendWords = [];  // 用户添加的拓展词列表（保持添加顺序）

  final Map<String, String> _extendBaseMap = {}; // 拓展词→基础课标词映射

  final LinkedHashSet<String> _manualChaoGangWords = LinkedHashSet<String>(); // 用户手动标记的超标词（保持添加顺序）

  final LinkedHashSet<String> _manualExtraWords = LinkedHashSet<String>(); // 用户手动标记的专有词（保持添加顺序）

  final Map<String, String> _classificationMemory = {}; // 单词小写→分类，跨导入记忆

  // 共识引擎
  final WordSyncService _wordSyncService = WordSyncService();
  String _userId = '';

  final GlobalKey _importBtnKey = GlobalKey();

  // 专有词汇对话框的 setDialogState 引用，供 _pruneCategoriesAfterEdit 在原文修改后刷新对话框

  void Function(void Function())? _extraWordsDialogSetState;

  // 词库列表弹窗批量操作状态：3 秒防抖自动弹出批量操作弹窗

  final Set<String> _batchSelected = {};

  String _batchSourceKind = ''; // 'extend' | 'chaogang' | 'extra'

  Timer? _batchTimer;

  bool _batchSuppressAuto = false;

  bool _batchDialogOpen = false;

  // ======== 持久化配置 ========

  String get _configPath => p.join(File(Platform.resolvedExecutable).parent.path, 'esw_config.json');

  String? _lastExamImportPath;

  String? _lastDocImportPath;

  String? _lastImportMode; // 'folder' or 'files'

  String? _lastExportPath;

  final List<String> _wordHistory = [];

  final FocusNode _searchFocus = FocusNode();

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

  bool _isDragging = false;

  bool _inImportedMode = false;

  String? _importedFileName;

  String? _importedFilePath;

  /// 已筛选过的文件路径集合，打开这些文件时自动积累分类结果

  final Set<String> _processedFilePaths = {};

  List<_ImportedWord> _importedWords = [];

  String _importedActiveFilter = '真题词';

  int _importedTotalWords = 0;

  List<_ImportedWord> _cachedFilteredImportedWords = [];

  String? _cachedImportedFilter;

  List<_ImportedWord>? _cachedImportedWordsRef;

  final Map<String, int> _importedFilterCounts = {

    '真题词': 0, '课标词': 0, '拓展词': 0, '超标词': 0, '专有词': 0,

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

  /// 单词检测预编译正则

  static final RegExp _wordTokenRegex = RegExp(r'\b[a-zA-Z]{2,}\b');

  static final RegExp _yearPrefixRegex = RegExp(r'^(\d{4})');

  static final RegExp _whitespaceRegex = RegExp(r'[\s\n\u3000]');

  static final RegExp _pureDigitsRegex = RegExp(r'^\d+$');

  static final RegExp _anyWhitespaceChar = RegExp(r'\s');

  static final RegExp _sentenceEndRegex = RegExp(r'[。！？.!?\n]');

  // ======== 防抖保存 ========

  @override

  void initState() {

    super.initState();

    _initDragDrop();
    _searchFocus.addListener(_onSearchFocusChange);
    _initOcr();

    _loadStandardWords();

    _loadConfig();

    _autoImportLast();

  }

  void _onSearchFocusChange() {
    setState(() {});
  }

  void _initDragDrop() {

    Timer.periodic(const Duration(milliseconds: 300), (_) {

      final ptr = _getDroppedFile();

      if (ptr != nullptr) {

        final path = ptr.toDartString();

        _handleDroppedFile(path);

      }

    });

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
        final seenExtend = _extendWords.map((e) => e.toLowerCase()).toSet();
        for (final w in ew) {
          final word = w.toString();
          if (seenExtend.add(word.toLowerCase())) {
            _extendWords.add(word);
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

      _userId = json['userId'] as String? ?? _genUserId();

      // 合并旧版 eva_config.json 中可能存在的增量数据（旧版程序可能持续写入）

      _mergeOldConfig();

      // 从全局列表回填分类记忆，确保历史积累的词也能在新导入时自动匹配
      for (final w in _extendWords) {
        _classificationMemory[w.toLowerCase()] = '拓展词';
      }
      for (final w in _manualChaoGangWords) {
        _classificationMemory[w.toLowerCase()] = '超标词';
      }
      for (final w in _manualExtraWords) {
        _classificationMemory[w.toLowerCase()] = '专有词';
      }

      // 加载已筛选文件路径集合

      final pf = json['processedFilePaths'];

      if (pf is List) {

        _processedFilePaths.addAll(pf.map((e) => e.toString()));

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
        'userId': _userId,

        'processedFilePaths': _processedFilePaths.toList(),

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

      await imgFile.delete().catchError((_) => imgFile);

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

      allowedExtensions: ['txt', 'doc', 'docx', 'pdf'],

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

      } else if (ext.endsWith('.doc')) {

        content = extractDocText(File(filePath).readAsBytesSync());

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

  /// 拖拽文件到输入框时自动读取内容并开始检测

  Future<void> _handleDroppedFile(String filePath) async {

    final ext = filePath.toLowerCase();

    if (!ext.endsWith('.txt') && !ext.endsWith('.docx') && !ext.endsWith('.pdf') && !ext.endsWith('.doc')) {

      return;

    }

    try {

      String content;

      if (ext.endsWith('.docx')) {

        content = _readDocxContent(filePath);

      } else if (ext.endsWith('.pdf')) {

        content = await _readPdfContent(filePath);

      } else if (ext.endsWith('.doc')) {

        content = extractDocText(File(filePath).readAsBytesSync());

      } else {

        content = File(filePath).readAsStringSync();

      }

      _searchController.text = content;

      _importedFileName = File(filePath).uri.pathSegments.last;

      _importedFilePath = filePath;

      _lastDocImportPath = File(filePath).parent.path;

      _lastImportMode = 'files';

      await _analyzeImportedText();

      _saveConfig();

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

    // 4) 确定筛选类型 超标词手动) > 拓展词> 合成词> 课标词> 反向索引拓展词> 手动专有词> 真题词在语料中) > 专有词不在课标词库中的专有词汇，如人名地名)

    String filter;

    if (_manualChaoGangWords.any((e) => e.toLowerCase() == word)) {

      filter = '超标词';

    } else if (isExtend) {

      filter = '拓展词';

    } else if (isStandard) {

      filter = '课标词';

    } else if (_extendReverseIndex.containsKey(word)) {

      // 反向索引自动匹配：识别为拓展词并同步庀

      _extendWords.add(word);

      _extendBaseMap[word] = _extendReverseIndex[word]!;

      _saveConfig();
      _wordSyncService.markChanged(word);

      filter = '拓展词';

    } else if (_manualExtraWords.any((e) => e.toLowerCase() == word)) {

      filter = '专有词';

    } else if (totalFreq > 0) {

      filter = '超标词';

      _manualChaoGangWords.add(word);
      _wordSyncService.markChanged(word);

    } else {

      filter = '未筛选';

    }

    setState(() {

      _detectedWord = matchedKey.isNotEmpty ? matchedKey : word;

      _activeFilter = filter;

      _detectedCategory = isStandard && cat.isNotEmpty ? cat : null;

      _wordPos = pos;

      _wordDef = def;

      _yearFrequency.clear();

      _yearFrequency.addAll(yearFreq);

      _results.clear();

      _results.addAll(results);

      _selectedYear = null;

      _filteredResults = List.from(results);

      _filterCounts.updateAll((_, __) => 0);

      // 手动超标词强制归类

      if (_manualChaoGangWords.any((e) => e.toLowerCase() == word)) {

        _filterCounts['超标词'] = 1;

      } else if (filter != '未筛选') {

        _filterCounts[filter] = 1;

      }

      // 真题词独立计数：只要在真题语料中出现过就计入

      if (totalFreq > 0) _filterCounts['真题词'] = 1;

    });

    // 课标词库未收录时，用词典数据库补全释义

    if (_wordPos.isEmpty && _wordDef.isEmpty) {

      final lookupWord = word;

      // 先立即打一个标记，确认 fallback 分支已经进入

      setState(() {

        _wordDef = '词典查询中…';

      });

      DictionaryService.lookup(lookupWord).then((entry) {

        if (!mounted) return;

        if (entry != null && (entry['definition']?.isNotEmpty == true || entry['pos']?.isNotEmpty == true)) {

          setState(() {

            _wordPos = entry['pos'] ?? '';

            _wordDef = entry['definition'] ?? '';

          });

        } else {

          setState(() {

            _wordDef = entry == null ? '词典未收录' : '查询结果为空';

          });

        }

      });

    } else if (_wordPos.isEmpty && _wordDef.isNotEmpty) {

      // 课标词库有释义但缺词性，仅从词典补全词性

      DictionaryService.lookup(word).then((entry) {

        if (!mounted) return;

        if (entry != null && entry['pos']?.isNotEmpty == true) {

          setState(() {

            _wordPos = entry['pos'] ?? '';

          });

        }

      });

    }

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

  /// 自动将已筛选文件的分析结果积累到全局词汇列表

  void _autoAccumulateImportedResults() {

    if (_importedFilePath == null) return;

    // 未被标记为已处理时，检查是否存在分类记忆（历史兼容：v1.2.70 及之前无 processedFilePaths）

    if (!_processedFilePaths.contains(_importedFilePath!)) {

      final hasClassified = _importedWords.any(

        (iw) => _classificationMemory.containsKey(iw.word.toLowerCase()),

      );

      if (!hasClassified) return;

      _processedFilePaths.add(_importedFilePath!);

    }

    for (final iw in _importedWords) {

      final cat = _classificationMemory[iw.word.toLowerCase()];

      if (cat == null) continue;

      switch (cat) {

        case '拓展词':

          final alreadyExisted = _extendWords.any((e) => e.toLowerCase() == iw.word.toLowerCase());

          if (!alreadyExisted) {

            _extendWords.add(iw.word);

            _filterCounts['拓展词'] = (_filterCounts['拓展词'] ?? 0) + 1;

          }

          // 如果缺失 base map 映射，用标准词列表补充

          if (!_extendBaseMap.containsKey(iw.word)) {

            final suggestions = _findBestSyllabusMatch(iw.word);

            if (suggestions.isNotEmpty) {

              _extendBaseMap[iw.word] = suggestions.first;

              _extendReverseIndex[iw.word.toLowerCase()] = suggestions.first.toLowerCase();

            }

          }

          break;

        case '超标词':

          if (!_manualChaoGangWords.any((e) => e.toLowerCase() == iw.word.toLowerCase())) {

            _manualChaoGangWords.add(iw.word);

            _filterCounts['超标词'] = (_filterCounts['超标词'] ?? 0) + 1;

          }

          break;

        case '专有词':

          if (!_manualExtraWords.any((e) => e.toLowerCase() == iw.word.toLowerCase())) {

            _manualExtraWords.add(iw.word);

            _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) + 1;

          }

          break;

      }

    }

    _saveConfig();

  }

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

    // 收集真题语料中的所有单词，用于判断「真题词」vs「超标词」

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

      '超标词': 0,

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

    _autoAccumulateImportedResults();

  }

  @override

  Widget build(BuildContext context) {

    final leftWidth = MediaQuery.of(context).size.width / 5;

    return Scaffold(

      backgroundColor: const Color(0xFFFFF8E1),

      body: Column(

        children: [

          Container(

            color: const Color(0xFFFFF8E1),

            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),

            child: Row(

              children: [

                OutlinedButton(

                  onPressed: _showHelp,

                  style: OutlinedButton.styleFrom(

                    backgroundColor: const Color(0xFFFFF3E0),

                    foregroundColor: Colors.black,

                    side: const BorderSide(color: Color(0xFFFF9800)),

                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),

                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),

                  ),

                  child: const Text('使用说明', style: TextStyle(fontSize: 13)),

                ),

                const SizedBox(width: 8),

                OutlinedButton(

                  onPressed: _syncVocab,

                  style: OutlinedButton.styleFrom(

                    backgroundColor: const Color(0xFFFFF3E0),

                    foregroundColor: Colors.black,

                    side: const BorderSide(color: Color(0xFFFF9800)),

                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),

                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),

                  ),

                  child: const Text('同步词库', style: TextStyle(fontSize: 13)),

                ),

                const SizedBox(width: 8),

                OutlinedButton(

                  onPressed: _checkUpdate,

                  style: OutlinedButton.styleFrom(

                    backgroundColor: const Color(0xFFFFF3E0),

                    foregroundColor: Colors.black,

                    side: const BorderSide(color: Color(0xFFFF9800)),

                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),

                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),

                  ),

                  child: const Text('检查更新', style: TextStyle(fontSize: 13)),

                ),

              ],

            ),

          ),

          const Divider(height: 1, thickness: 1),

          Expanded(

            child: Row(

              crossAxisAlignment: CrossAxisAlignment.stretch,

              children: [

                // ========== 左侧面板 ==========

                SizedBox(

                  width: leftWidth,

                  child: Column(

                    children: [

                      Container(

                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),

                        alignment: Alignment.center,

                        child: OutlinedButton.icon(

                          key: _importBtnKey,

                          onPressed: _showImportMenu,

                          icon: const Icon(Icons.folder_open, size: 18),

                          label: const Text('真题导入', style: TextStyle(fontSize: 13)),

                          style: OutlinedButton.styleFrom(

                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),

                            backgroundColor: const Color(0xFFE8F5E9),

                            foregroundColor: Colors.black,

                            side: const BorderSide(color: Color(0xFF4CAF50)),

                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),

                          ),

                        ),

                      ),

                      const SizedBox(height: 8),

                      const Divider(height: 1, thickness: 1, color: AppTheme.borderLight),

                      Expanded(child: _buildLeftPanelContent()),

                    ],

                  ),

                ),

                // ========== 单条连续分隔线 ==========

                Container(width: 1, color: const Color(0xFFA8A8A8)),

                // ========== 右侧面板 ==========

                Expanded(

                  child: Column(

                    children: [

                      _buildToolbar(),

                      const Divider(height: 1, thickness: 1, color: AppTheme.borderLight),

                      Expanded(

                        child: RepaintBoundary(child: _buildRightPanelContent()),

                      ),

                    ],

                  ),

                ),

              ],

            ),

          ),

        ],

      ),

    );

  }

  // ==================== 左侧面板（不含工具栏，工具栏已提取到共享行） ====================

  Widget _buildLeftPanelContent() {

    return Container(

      decoration: const BoxDecoration(

        gradient: LinearGradient(

          begin: Alignment.topCenter,

          end: Alignment.bottomCenter,

          colors: [Color(0xFFFFF9C4), Color(0xFFFFF3CD)],

        ),

      ),

      child: Column(

        children: [

          Expanded(child: _buildCorpusList()),

          if (_detectedWord.isNotEmpty)

            _buildDetectedInfo(),

          _buildFooter(),

        ],

      ),

    );

  }

  // ==================== 底部状态栏（真题文件数统计） ====================

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

  // ==================== 工具栏（文档导入 + 搜索输入框） ====================

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

                      // maxLines>1 时 Enter 产生换行而非 onSubmitted，单行单词按 Enter 触发检测

                      if (text.contains('\n')) {

                        final trimmed = text.trim();

                        if (!trimmed.contains(_anyWhitespaceChar)) {

                          _searchController.text = trimmed;

                          _searchController.selection = TextSelection.collapsed(offset: trimmed.length);

                          _onDetect();

                          _cancelHistoryTimer();

                          return;

                        }

                      }

                      _cancelHistoryTimer();

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

                      _cancelHistoryTimer();

                      _historyTimer = Timer(const Duration(seconds: 2), () {

                      });

                    },

                    onSubmitted: (_) {

                      _onDetect();

                      _cancelHistoryTimer();

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

                  // 拖拽文件时的视觉提示

                  if (_isDragging)

                    Positioned.fill(

                      child: IgnorePointer(

                        child: Container(

                          decoration: BoxDecoration(

                            borderRadius: BorderRadius.circular(6),

                            border: Border.all(color: AppTheme.primaryBlue, width: 2),

                            color: AppTheme.primaryBlue.withValues(alpha: 0.05),

                          ),

                          alignment: Alignment.center,

                          child: const Text(

                            '松开以导入文档',

                            style: TextStyle(

                              color: AppTheme.primaryBlue,

                              fontWeight: FontWeight.w600,

                              fontSize: 14,

                            ),

                          ),

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

  /// 将导入的原文导出为 Word 文档，按分类颜色高亮标注单词（纯 Dart 实现，无 Python 依赖）
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
        final baseName = dotIdx > 0
            ? _importedFileName!.substring(0, dotIdx)
            : _importedFileName!;
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

    try {
      await _writeResultDocx(
        outPath,
        originalText: originalText,
        wordCatMap: wordCatMap,
        fileName: _importedFileName ?? '',
      );
      _lastExportPath = Directory(outPath).parent.path;
      _saveConfig();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出分析结果到：$outPath')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

  /// 构建拓展词按题型分组的明细（导出表格用）。
  List<ExtendSection> _buildExtendSections(String originalText) {
    final extendWords = <String>[];
    for (final iw in _importedWords) {
      if (iw.category == '拓展词') extendWords.add(iw.word);
    }
    return buildExtendSections(
      text: originalText,
      extendWords: extendWords,
      baseWordOf: (w) {
        final b = _extendReverseIndex[w.toLowerCase()];
        if (b == null) return '';
        final ms = _standardWordsLower[b];
        return (ms != null && ms.isNotEmpty) ? ms.first : b;
      },
      meaningOf: (w, base) {
        final own = _standardWords[w]?['def'] ?? '';
        if (own.isNotEmpty) return own;
        if (base.isNotEmpty) {
          final bm = _standardWords[base]?['def'] ?? '';
          if (bm.isNotEmpty) return bm;
        }
        return '';
      },
    );
  }

  /// 生成 DOCX 结果文档：标题 + 统计信息 + 标注说明 + 带标注全文（按分类着色）。
  /// DOCX 本质是 ZIP 包，这里用 archive 包手写最小可用 OOXML 文档。
  Future<void> _writeResultDocx(
    String path, {
    required String originalText,
    required Map<String, String> wordCatMap,
    required String fileName,
  }) async {
    final bodyParts = <String>[];

    bodyParts.add(_docxParagraph('ESW 课标词检测导出', bold: true));
    bodyParts.add(_docxParagraph('文件名: $fileName'));

    final cc = _importedFilterCounts;
    final totalRaw = _importedWords.fold<int>(
        0, (sum, w) => sum + w.frequency);
    bodyParts.add(_docxParagraph(
        '全套题词数: $totalRaw | 去重总词数: ${_importedWords.length} '
        '| 课标词: ${cc['课标词'] ?? 0} | 拓展词: ${cc['拓展词'] ?? 0} '
        '| 超标词: ${cc['超标词'] ?? 0} | 专有词: ${cc['专有词'] ?? 0} '
        '| 真题词: ${cc['真题词'] ?? 0} | 其他: ${cc['其他'] ?? 0}'));
    bodyParts.add(_docxParagraph('【标注说明】', bold: true));
    bodyParts.add(_docxParagraph(
        '课标词：黑色（无标记）；拓展词：绿色；超标词：红色；专有词：灰色'));
    bodyParts.add(_docxParagraph('带标注全文', bold: true));
    bodyParts.add(_docxAnnotatedParagraph(originalText, wordCatMap));
    bodyParts.add(_docxParagraph('拓展词明细（按题型）', bold: true));
    bodyParts.add(buildExtendTableXml(_buildExtendSections(originalText)));

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
    archive.addFile(ArchiveFile.string('[Content_Types].xml', contentTypes));
    archive.addFile(ArchiveFile.string('_rels/.rels', rels));
    archive.addFile(ArchiveFile.string('word/document.xml', documentXml));

    final encoder = ZipEncoder();
    final bytes = encoder.encode(archive);
    if (bytes == null) throw Exception('DOCX 生成失败');
    await File(path).writeAsBytes(bytes);
  }

  /// 生成单个 DOCX 段落 XML。
  String _docxParagraph(String text, {bool bold = false}) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final runs = '<w:r><w:rPr>${bold ? '<w:b/>' : ''}</w:rPr>'
        '<w:t xml:space="preserve">$escaped</w:t></w:r>';
    return '<w:p>$runs</w:p>';
  }

  /// 生成带标注全文的 DOCX 段落：按分类用不同颜色 run 着色。
  /// 按行拆分，每行生成一个独立 <w:p>，保留原文段落结构（避免 Word 中段落被合并成一段）。
  String _docxAnnotatedParagraph(
      String text, Map<String, String> catByLower) {
    // 分类 -> 十六进制颜色（无 # 前缀）
    String colorOf(String cat) {
      switch (cat) {
        case '拓展词':
          return '2E7D32';
        case '超标词':
          return 'C62828';
        case '专有词':
          return '616161';
        default:
          return '000000';
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
        if (cat == null || cat == '课标词' || cat == '真题词' || cat == '其他') {
          runs.add(_docxRun(word, '000000'));
        } else {
          runs.add(_docxRun(word, colorOf(cat),
              highlight: cat == '超标词' ? 'yellow' : null));
        }
        lastEnd = m.end;
      }
      final tail = line.substring(lastEnd);
      if (tail.isNotEmpty) runs.add(_docxRun(tail, '000000'));
      return '<w:p>${runs.join('')}</w:p>';
    }

    final lines = text.split('\n');
    return lines.map(oneLine).join('\n');
  }

  /// 生成单个 DOCX run（带颜色）。
  String _docxRun(String text, String color, {String? highlight}) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final hl = highlight != null ? '<w:highlight w:val="$highlight"/>' : '';
    return '<w:r><w:rPr><w:color w:val="$color"/>$hl</w:rPr>'
        '<w:t xml:space="preserve">$escaped</w:t></w:r>';
  }

  // ==================== 右侧面板内容（筛选 / 年份分布 / 结果区） ====================

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
    // 重新归类：已加入拓展词手动超标词的单词应归类为对应类别
    final oldCounts = Map<String, int>.from(_savedImportedFilterCounts);
    for (int i = 0; i < _savedImportedWords.length; i++) {
      final iw = _savedImportedWords[i];
      String? newCat;
      if (_extendWords.contains(iw.word) && iw.category != '拓展词') {
        newCat = '拓展词';
      } else if (_manualChaoGangWords.contains(iw.word) && iw.category != '超标词') {
        newCat = '超标词';
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
        // 真题词= 在语料中出现但尚未归类的单词（不含已标记拓展/超标/专有词/课标词）
        _cachedFilteredImportedWords = _importedWords
            .where((iw) => iw.isInCorpus && iw.category == '真题词')
            .toList();
      } else {
        _cachedFilteredImportedWords = _importedWords
            .where((iw) => iw.category == _importedActiveFilter)
            .toList();
      }
      // 专有词优先显示未筛选分类的单词，已标记专有词排在末尾
      if (_importedActiveFilter == '专有词') {
        _cachedFilteredImportedWords.sort((a, b) {
          final aManual = _manualExtraWords.any((e) => e.toLowerCase() == a.word.toLowerCase());
          final bManual = _manualExtraWords.any((e) => e.toLowerCase() == b.word.toLowerCase());
          if (aManual && !bManual) return 1;
          if (!aManual && bManual) return -1;
          return 0;
        });
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
        final isChaoGang = iw.category == '超标词';
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
                  // ---- 超标词：标签 + 频次 + 移出按钮 ----
                  else if (isChaoGang) ...[
                    _buildCategoryTag('超标词', color),
                    const Spacer(),
                    InkWell(
                      onTap: () {
                        _manualChaoGangWords.remove(iw.word);
                        final newCat = _manualExtraWords.contains(iw.word)
                            ? '专有词'
                            : (iw.isInCorpus ? '真题词' : '专有词');
                        _reclassifyImportedWord(iw, newCat);
                        setState(() {
                          if ((_filterCounts['超标词'] ?? 0) > 0) {
                            _filterCounts['超标词'] = (_filterCounts['超标词'] ?? 0) - 1;
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
      case '超标词':
        _manualChaoGangWords.removeWhere((e) => e.toLowerCase() == iw.word.toLowerCase());
        _manualChaoGangWords.add(iw.word);
        setState(() {
          _filterCounts['超标词'] = (_filterCounts['超标词'] ?? 0) + 1;
          _reclassifyImportedWordData(iw, '超标词');
        });
        _classificationMemory[iw.word.toLowerCase()] = '超标词';
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

    // 专有词筛选模式：自动进入下一个专有词
    if (_importedActiveFilter == '专有词') {
      for (final next in _importedWords) {
        if (next.category == '专有词' && !cancelled.contains(next.word)) {
          await _startClassifyBatch(next, cancelled: cancelled);
          return;
        }
      }
    }

    // 查找下一个未标记且未被跳过的真题词
    for (final next in _importedWords) {
      if (next.isInCorpus && next.category == '真题词' && !cancelled.contains(next.word)) {
        await _startClassifyBatch(next, cancelled: cancelled);
        return;
      }
    }

    // 批量筛选走完——标记当前文件为已处理，下次打开自动积累
    if (_importedFilePath != null) {
      _processedFilePaths.add(_importedFilePath!);
      _saveConfig();
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

  Widget _buildRightPanelContent() {

    if (_inImportedMode) {
      return _buildImportedTextPanel();
    }
    return Column(

      children: [

        if (_cameFromImportedMode && _searchController.text.isNotEmpty)
          _buildReturnToImportedBar(),

        _buildWordBankEntries(),

        const Divider(height: 1),

        _buildFilterChips(),

        const Divider(height: 1),

        _buildYearDistribution(),

        const Divider(height: 1),

        _buildResultHeader(),

        const Divider(height: 1, thickness: 1),

        Expanded(child: _buildResultList()),

      ],

    );

  }

  // ==================== 课标词智能匹配（按首字母桶加速） ====================

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

  // ---------- 检测到的单词信息（分类 + 词性+ 词义：---------

  Widget _buildDetectedInfo() {

    final isExtend = _extendWords.any((e) => e.toLowerCase() == _detectedWord.toLowerCase());

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

            : _activeFilter;

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

          if (isStandard || _wordPos.isNotEmpty || _wordDef.isNotEmpty) ...[

            const SizedBox(height: 8),

            // 词性

            Row(

              children: [

                const Text('词性：',

                    style:

                        TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),

                Text(_wordPos.isEmpty ? '?' : _wordPos,

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

                  child: Text(_wordDef.isEmpty ? '?' : _wordDef,

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

              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),

              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),

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

                          hintText: '输入课标词，自动匹配?',

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

          // 单词从超标词/真题词转变为拓展词，同步更新计数

          if ((_filterCounts['超标词'] ?? 0) > 0) {

            _filterCounts['超标词'] = (_filterCounts['超标词'] ?? 0) - 1;

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

  /// 保存文件后，对比新旧文本，将不再出现的单词从超标词/拓展词/专有词中移除

  void _pruneCategoriesAfterEdit(String oldText, String newText) {

    if (oldText == newText) return;

    // ?? 全局词汇列表（超标词/拓展词/专有词）不在此处修剪

    //    它们是跨文档累积的结果，仅当用户在对话框中手动移除时才删除。

    //    此处只做导入文档的 filterCounts 同步（会话级计数可重置）

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

  void _showHelp() {

    Navigator.of(context).push(

      MaterialPageRoute(builder: (_) => const _HelpPage()),

    );

  }

  // ==================== 词库列表弹窗（复选 + 全选 + 3秒防抖批量操作） ====================

  Future<void> _showWordListDialog({

    required String title,

    required String emptyHint,

    required List<String> Function() getWords,

    required List<Widget> Function(String w,

        void Function(void Function()) setDialogState, BuildContext ctx)

        trailingBuilder,

  }) async {

    if (getWords().isEmpty) {

      showDialog(

        barrierDismissible: true,

        context: context,

        builder: (_) => AlertDialog(

          title: Text(title),

          content: Text(emptyHint),

          actions: [

            TextButton(

                onPressed: () => Navigator.pop(context),

                child: const Text('确定')),

          ],

        ),

      );

      return;

    }

    _batchTimer?.cancel();

    _batchSelected.clear();

    _batchSuppressAuto = false;

    _batchDialogOpen = false;

    await showDialog(

      barrierDismissible: true,

      context: context,

      builder: (listCtx) {

        String search = '';

        var dragOffset = Offset.zero;

        return StatefulBuilder(

          builder: (_, setDialogState) {

            // 批量操作改为页面底部按钮，不再使用 3 秒自动弹出弹窗

            final targets = switch (_batchSourceKind) {

              'extend' => const ['超标词', '专有词'],

              'chaogang' => const ['拓展词', '专有词'],

              'extra' => const ['拓展词', '超标词'],

              _ => const <String>[],

            };

            void doBatchReclassify(String target) {

              _applyBatchReclassify(target);

              _batchSelected.clear();

              _batchSuppressAuto = false;

              setState(() {});

              if (listCtx.mounted) Navigator.pop(listCtx);

            }

            Future<void> doBatchDelete() async {

              final ok = await _applyBatchDelete();

              if (!ok) return; // 用户取消：保留选择状态，无副作用

              _batchSelected.clear();

              _batchSuppressAuto = false;

              setState(() {});

              if (listCtx.mounted) Navigator.pop(listCtx);

            }

            void doCancelSelect() {

              setDialogState(() => _batchSelected.clear());

              _batchSuppressAuto = false;

            }

            final words = getWords().reversed.toList();

            final filtered = search.isEmpty

                ? words

                : words

                    .where((w) =>

                        w.toLowerCase().contains(search.toLowerCase()))

                    .toList();

            final allSelected = filtered.isNotEmpty &&

                filtered.every((w) => _batchSelected.contains(w));

            return Transform.translate(

              offset: dragOffset,

              child: AlertDialog(

                title: GestureDetector(

                  onPanUpdate: (d) =>

                      setDialogState(() => dragOffset += d.delta),

                  child: MouseRegion(

                    cursor: SystemMouseCursors.move,

                    child: Row(

                      mainAxisAlignment: MainAxisAlignment.center,

                      children: [

                        Text(_batchSelected.isEmpty
                            ? '$title（共${getWords().length}个）'
                            : '$title（已选${_batchSelected.length}个）',

                            style: const TextStyle(fontSize: 16)),

                      ],

                    ),

                  ),

                ),

                content: SizedBox(

                  width: 540,

                  child: Column(

                    mainAxisSize: MainAxisSize.min,

                    children: [

                      if (words.length > 3) ...[

                        Padding(

                          padding: const EdgeInsets.only(bottom: 8),

                          child: TextField(

                            decoration: const InputDecoration(

                              hintText: '搜索单词...',

                              prefixIcon: Icon(Icons.search, size: 18),

                              isDense: true,

                              contentPadding: EdgeInsets.symmetric(

                                  horizontal: 12, vertical: 8),

                              border: OutlineInputBorder(

                                  borderRadius: BorderRadius.all(

                                      Radius.circular(6))),

                            ),

                            onChanged: (v) {

                              setDialogState(() {

                                search = v;

                                _batchSelected.clear();

                              });

                            },

                          ),

                        ),

                      ],

                      if (filtered.isEmpty) ...[

                        const Padding(

                          padding: EdgeInsets.symmetric(vertical: 24),

                          child: Center(

                            child: Text('暂无匹配单词',

                                style: TextStyle(color: Colors.grey)),

                          ),

                        ),

                      ],

                      if (!filtered.isEmpty) ...[

                        Padding(

                          padding:

                              const EdgeInsets.only(right: 16, bottom: 2),

                          child: Row(

                            mainAxisAlignment: MainAxisAlignment.end,

                            children: [

                              const Text('全选',

                                  style: TextStyle(fontSize: 12)),

                              Transform.scale(

                                scale: 0.75,

                                child: Checkbox(

                                  value: allSelected

                                      ? true

                                      : (_batchSelected.isNotEmpty

                                          ? null

                                          : false),

                                  tristate: true,

                                  onChanged: (v) {

                                    setDialogState(() {

                                      if (v == true) {

                                        _batchSelected.addAll(filtered);

                                      } else {

                                        _batchSelected.removeAll(filtered);

                                      }

                                    });

                                    _batchSuppressAuto = false;

                                  },

                                  visualDensity: VisualDensity.compact,

                                ),

                              ),

                            ],

                          ),

                        ),

                        Flexible(

                          child: ListView.builder(

                            padding: const EdgeInsets.only(right: 12),

                            shrinkWrap: true,

                            itemCount: filtered.length,

                            itemBuilder: (_, i) {

                              final w = filtered[i];

                              return Padding(

                                padding: const EdgeInsets.symmetric(

                                    horizontal: 4, vertical: 2),

                                child: Row(

                                  children: [

                                    SizedBox(

                                      width: 32,

                                      child: Text('${i + 1}.',

                                          textAlign: TextAlign.right,

                                          style: const TextStyle(

                                              fontSize: 12,

                                              color: Colors.grey)),

                                    ),

                                    const SizedBox(width: 8),

                                    Expanded(

                                      child: InkWell(

                                        onTap: () {

                                          Navigator.pop(listCtx);

                                          _searchController.text = w;

                                          _onDetect();

                                        },

                                        child: Text(w,

                                            style: const TextStyle(

                                                fontWeight:

                                                    FontWeight.w600,

                                                fontSize: 13,

                                                color: Color(0xFF1565C0),

                                                decoration: TextDecoration

                                                    .underline)),

                                      ),

                                    ),

                                    ...trailingBuilder(

                                        w, setDialogState, listCtx),

                                    const SizedBox(width: 2),

                                    Transform.scale(

                                      scale: 0.75,

                                      child: Checkbox(

                                        value: _batchSelected.contains(w),

                                        onChanged: (v) {

                                          setDialogState(() {

                                            if (v == true) {

                                              _batchSelected.add(w);

                                            } else {

                                              _batchSelected.remove(w);

                                            }

                                          });

                                          _batchSuppressAuto = false;

                                        },

                                        visualDensity:

                                            VisualDensity.compact,

                                      ),

                                    ),

                                  ],

                                ),

                              );

                            },

                          ),

                        ),

                      ],

                      if (_batchSelected.isNotEmpty) ...[

                        const Padding(

                          padding: EdgeInsets.only(top: 12),

                          child: Divider(height: 1),

                        ),

                        const SizedBox(height: 10),

                        Row(

                          children: [

                            for (final t in targets) ...[

                              Expanded(

                                child: OutlinedButton(

                                  onPressed: () => doBatchReclassify(t),

                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text('转为$t'),
                                  ),

                                ),

                              ),

                              const SizedBox(width: 8),

                            ],

                            Expanded(

                              child: OutlinedButton(

                                onPressed: doBatchDelete,

                                child: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('删除所选单词'),
                                ),

                              ),

                            ),

                            const SizedBox(width: 8),

                            Expanded(

                              child: TextButton(

                                onPressed: doCancelSelect,

                                child: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('取消选择'),
                                ),

                              ),

                            ),

                          ],

                        ),

                      ],

                    ],

                  ),

                  ),

                // 批量操作按钮已移至页面底部，多选后直接点击执行

              ),

            );

          },

        );

      },

    );

    _batchTimer?.cancel();

    _batchSelected.clear();

    _batchSuppressAuto = false;

  }

  Future<void> _showExtendWordsDialog() async {

    _batchSourceKind = 'extend';

    await _showWordListDialog(

      title: '拓展词汇',

      emptyHint: '暂未添加任何拓展词。\n请先搜索标注词，再点击拓展词按钮添加。',

      getWords: () => List<String>.from(_extendWords),

      trailingBuilder: (w, setDialogState, ctx) {

        // 仅保留勾选框与 3 秒后自动弹出的批量操作，不再显示行内转换/编辑/删除按钮

        return [];

      },

    );

  }

  Future<void> _showChaoGangWordsDialog() async {

    _batchSourceKind = 'chaogang';

    await _showWordListDialog(

      title: '超标词汇',

      emptyHint: '暂未添加任何超标词。\n请先搜索标注词，再点击超标词按钮添加。',

      getWords: () => _manualChaoGangWords.toList(),

      trailingBuilder: (w, setDialogState, ctx) {

        // 仅保留勾选框与 3 秒后自动弹出的批量操作，不再显示行内转换/删除按钮

        return [];

      },

    );

  }

  Future<void> _showExtraWordsDialog() async {

    _batchSourceKind = 'extra';

    await _showWordListDialog(

      title: '专有词汇',

      emptyHint: '暂未添加任何专有词。\n请在导入分析中点击"跳过"按钮添加。',

      getWords: () => _manualExtraWords.toList(),

      trailingBuilder: (w, setDialogState, ctx) {

        // 仅保留勾选框与 3 秒后自动弹出的批量操作，不再显示行内转换/删除按钮

        return [];

      },

    );

  }

  // ==================== 批量转类 / 批量删除 ====================

  void _applyBatchReclassify(String target) {

    final words = _batchSelected.toList();

    for (final w in words) {

      _applyCategoryChange(w, target);

      _wordSyncService.markChanged(w);

      if (target != '拓展词') {

        _extendBaseMap.remove(w);

        _extendReverseIndex.remove(w.toLowerCase());

      }

    }

    _saveConfig();

  }

  Future<bool> _applyBatchDelete() async {

    final words = _batchSelected.toList();

    if (words.isEmpty) return false;

    // 大范围删除保护：与同步弹窗规则一致——
    // 删除超过 10 个 → 确认；超过 50 个 → 先自动备份云端再确认；取消无副作用
    if (words.length > 10) {
      final total = _extendWords.length +
          _manualChaoGangWords.length +
          _manualExtraWords.length;
      final backedUp = words.length > 50
          ? await _wordSyncService.backupRemoteState()
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

      final lower = w.toLowerCase();

      _extendWords.removeWhere((e) => e.toLowerCase() == lower);

      _manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);

      _manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);

      _extendBaseMap.remove(w);

      _extendReverseIndex.remove(lower);

      _wordSyncService.markDeleted(w);

    }

    _saveConfig();

    return true;

  }

  // ==================== 词库列表入口按钮 ====================

  Widget _buildWordBankEntries() {

    return Padding(

      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),

      child: Row(

        children: [

          _buildWordBankEntry(

            label: '拓展词汇',

            count: _extendWords.length,

            color: AppTheme.primaryBlue,

            bg: const Color(0xFFE3F2FD),

            border: const Color(0xFF90CAF9),

            onTap: _showExtendWordsDialog,

          ),

          const SizedBox(width: 8),

          _buildWordBankEntry(

            label: '超标词汇',

            count: _manualChaoGangWords.length,

            color: AppTheme.orange,

            bg: const Color(0xFFFFF3E0),

            border: const Color(0xFFFFCC80),

            onTap: _showChaoGangWordsDialog,

          ),

          const SizedBox(width: 8),

          _buildWordBankEntry(

            label: '专有词汇',

            count: _manualExtraWords.length,

            color: AppTheme.grey,

            bg: const Color(0xFFF5F5F5),

            border: AppTheme.textDisabled,

            onTap: _showExtraWordsDialog,

          ),

        ],

      ),

    );

  }

  Widget _buildWordBankEntry({

    required String label,

    required int count,

    required Color color,

    required Color bg,

    required Color border,

    required VoidCallback onTap,

  }) {

    return Expanded(

      child: Material(

        color: Colors.transparent,

        child: InkWell(

          onTap: onTap,

          borderRadius: BorderRadius.circular(6),

          child: Container(

            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

            decoration: BoxDecoration(

              color: bg,

              borderRadius: BorderRadius.circular(6),

              border: Border.all(color: border),

            ),

            child: Row(

              mainAxisAlignment: MainAxisAlignment.center,

              children: [

                Text(label,

                    style: const TextStyle(

                        fontSize: 13,

                        fontWeight: FontWeight.w500,

                        color: AppTheme.textSecondary)),

                const SizedBox(width: 6),

                Text('$count',

                    style: TextStyle(

                        fontSize: 14,

                        fontWeight: FontWeight.bold,

                        color: color)),

              ],

            ),

          ),

        ),

      ),

    );

  }

  String _genUserId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = (now * 1103515245 + 12345) & 0x7fffffff;
    return 'win_${now.toRadixString(36)}_${rand.toRadixString(36)}';
  }

  /// 时间戳同步：逐词比对，谁新谁赢。
  /// 云端有变动时弹窗让用户选择同意/拒绝，无网络时静默。
  Future<void> _syncVocab() async {
    try {
      final localWords = <String, Map<String, String>>{};
      for (final w in _extendWords) {
        localWords[w.toLowerCase()] = {'original_case': w, 'category': '拓展词'};
      }
      for (final w in _manualChaoGangWords) {
        localWords[w.toLowerCase()] = {'original_case': w, 'category': '超标词'};
      }
      for (final w in _manualExtraWords) {
        localWords[w.toLowerCase()] = {'original_case': w, 'category': '专有词'};
      }

      final result = await _wordSyncService.sync(
        localWords: localWords,
        localExtendBaseMap: _extendBaseMap,
        source: 'win',
      );

      final remoteChanges = result['remote_changes'] as List<dynamic>;

      if (remoteChanges.isNotEmpty && mounted) {
        final decisions = await _showSyncConflictDialog(remoteChanges);
        if (decisions != null) {
          final reasonMap = <String, String>{
            for (final ch in remoteChanges)
              (ch['word'] as String): (ch['reason'] as String? ?? ''),
          };
          // 大范围删除保护：统计本次操作将传播删除到云端的词
          // （拒绝云端新增 remote_only → 写墓碑传播删除；上传本地且本地删过 remote_only → 强制同步删除）
          final willDelete = <String>{};
          for (final d in decisions) {
            final word = d['word'] as String;
            final action = d['action'] as String;
            if (action == 'upload_local' && reasonMap[word] == 'remote_only') {
              willDelete.add(word);
            } else if (action == 'reject' && reasonMap[word] == 'remote_only') {
              willDelete.add(word);
            }
          }
          final remoteCount = result['remote_count'] as int? ?? 0;
          final delCount = willDelete.length;
          if (delCount > 10) {
            // 删除云端单词超过 10 个 → 提示用户确认；
            // 超过 50 个 → 自动在云端备份全部词库后再执行用户操作
            final backedUp = delCount > 50
                ? await _wordSyncService.backupRemoteState()
                : false;
            final confirmed = await _confirmLargeDelete(
              context,
              delCount,
              remoteCount,
              backedUp,
            );
            if (!confirmed) {
              // 用户取消：不执行任何删除，无副作用
              return;
            }
          }
          for (final d in decisions) {
            final word = d['word'] as String;
            final action = d['action'] as String; // 'accept' / 'reject' / 'upload_local'
            if (action == 'accept') {
              if (reasonMap[word] == 'remote_deleted') {
                // 接受云端删除 → 本地也删除该词，并记录删除墓碑防止再上传
                _applyCategoryChange(word, '');
                _wordSyncService.markDeleted(word);
              } else {
                final cat = d['category'] as String;
                _applyCategoryChange(word, cat);
                _wordSyncService.markChanged(word);
              }
            } else if (action == 'upload_local') {
              // 上传本地：以本地为准。云端新增、本地删过（remote_only）→ 传播删除到云端；
              // 云端删除/分类更新而本地保留（remote_deleted/remote_newer）→ 以本地为准恢复，刷新时间戳
              if (reasonMap[word] == 'remote_only') {
                _wordSyncService.markDeleted(word);
              } else {
                _wordSyncService.markChanged(word);
              }
            } else {
              // 拒绝：云端新增词（remote_only）→ 记墓碑传播删除；分类更新/云端删除（remote_newer/remote_deleted）→ 保留本地，本地时间戳最新
              if (reasonMap[word] == 'remote_only') {
                _wordSyncService.markDeleted(word);
              } else {
                _wordSyncService.markChanged(word);
              }
            }
          }
          // 决策已落地（接收/拒绝/上传本地）：立即再同步一次把结果推送云端。
          // 此前 markChanged/markDeleted 只更新本地时间戳/墓碑、不会立即推送，
          // 若不再次同步，云端将一直停留在旧状态，导致对端反复弹窗、本端"确认后未生效"。
          final pushLocalWords = <String, Map<String, String>>{};
          for (final w in _extendWords) {
            pushLocalWords[w.toLowerCase()] = {'original_case': w, 'category': '拓展词'};
          }
          for (final w in _manualChaoGangWords) {
            pushLocalWords[w.toLowerCase()] = {'original_case': w, 'category': '超标词'};
          }
          for (final w in _manualExtraWords) {
            pushLocalWords[w.toLowerCase()] = {'original_case': w, 'category': '专有词'};
          }
          await _wordSyncService.sync(
            localWords: pushLocalWords,
            localExtendBaseMap: _extendBaseMap,
            source: 'win',
          );
        }
      }

      final ebm = result['extendBaseMap'] as Map<String, dynamic>?;
      if (ebm != null) {
        for (final entry in ebm.entries) {
          if (!_extendBaseMap.containsKey(entry.key)) {
            _extendBaseMap[entry.key] = entry.value.toString();
          }
        }
        _extendReverseIndex.clear();
        for (final entry in _extendBaseMap.entries) {
          _extendReverseIndex[entry.key.toLowerCase()] = entry.value.toLowerCase();
        }
      }

      final cm = <String, String>{};
      for (final w in _extendWords) { cm[w.toLowerCase()] = '拓展词'; }
      for (final w in _manualChaoGangWords) { cm[w.toLowerCase()] = '超标词'; }
      for (final w in _manualExtraWords) { cm[w.toLowerCase()] = '专有词'; }
      _classificationMemory..clear()..addAll(cm);

      _saveConfig();
      if (mounted) {
        setState(() {});
        final msg = remoteChanges.isEmpty ? '同步完成 (已是最新)' : '同步完成 (已处理${remoteChanges.length}条云端变更)';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {}
  }

  void _applyCategoryChange(String word, String category) {
    final lower = word.toLowerCase();
    _extendWords.removeWhere((e) => e.toLowerCase() == lower);
    _manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
    _manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
    switch (category) {
      case '拓展词':
        if (!_extendWords.any((e) => e.toLowerCase() == lower)) _extendWords.add(word);
        break;
      case '超标词':
        _manualChaoGangWords.add(word);
        break;
      case '专有词':
        _manualExtraWords.add(word);
        break;
    }
    _classificationMemory[lower] = category;
  }

  /// 删除确认弹窗：删除云端单词超过 10 个时提示用户确认，
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
            ? '已自动在云端备份全部词库（word_sync_state_backup_*.json）。'
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

  /// 返回每个单词的用户决策列表（null 表示用户取消整个操作）。
  /// 每条决策: {word, action: 'accept'|'reject', category}
  Future<List<Map<String, String>>?> _showSyncConflictDialog(List<dynamic> changes) async {
    final decisions = <String, String>{};
    // 默认不预选任何词：用户点哪个按钮就立即执行哪个（接受云端/拒绝云端）
    final processed = <String>{};

    return await showDialog<List<Map<String, String>>?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (builderCtx, setDialogState) {
            final categories = ['拓展词', '超标词', '专有词'];

            // 依据未处理词的回退动作构建最终决策列表
            List<Map<String, String>> buildResult(String fallbackAction) {
              final result = <Map<String, String>>[];
              for (final ch in changes) {
                final c = ch as Map<String, dynamic>;
                final w = c['word'] as String;
                final d = decisions[w] ?? fallbackAction;
                result.add({
                  'word': w,
                  'action': d,
                  'category': d == 'accept' ? (c['new_category'] as String? ?? '') : '',
                });
              }
              return result;
            }

            return AlertDialog(
              title: const Center(child: Text('云端词库有更新（逐词确认）')),
              content: SizedBox(
                width: 600,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '共 ${changes.length} 条云端变更，可逐词接收或拒绝：',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
                    ),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 400),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: changes.length,
                          itemBuilder: (_, i) {
                            final ch = changes[i] as Map<String, dynamic>;
                            final word = ch['word'] as String;
                            final oldCat = (ch['old_category'] as String?) ?? '无';
                            final newCat = (ch['new_category'] as String?) ?? '';
                            final isRemoteDeleted = (ch['reason'] as String?) == 'remote_deleted';
                            final decision = decisions[word];
                            final isDone = processed.contains(word);

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            word,
                                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                                          ),
                                        ),
                                        Text(isRemoteDeleted ? '云端已删除' : '$oldCat → $newCat',
                                          style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        // 逐词接收/拒绝：点击一个立即执行一个
                                        if (!isDone)
                                          Tooltip(
                                            message: '应用这条云端更新',
                                            child: FilledButton(
                                              style: FilledButton.styleFrom(
                                                backgroundColor: Colors.green.shade600,
                                                foregroundColor: Colors.white,
                                                visualDensity: VisualDensity.compact,
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                                minimumSize: const Size(0, 32),
                                              ),
                                              onPressed: () {
                                                setDialogState(() {
                                                  decisions[word] = 'accept';
                                                  processed.add(word);
                                                });
                                              },
                                              child: const Text('接收更新', style: TextStyle(fontSize: 13)),
                                            ),
                                          )
                                        else if (decision == 'accept')
                                          const Text('✓ 已接收', style: TextStyle(fontSize: 13, color: Colors.green)),
                                        if (!isDone) ...[
                                          const SizedBox(width: 8),
                                          Tooltip(
                                            message: '拒绝这条云端更新，保留本地',
                                            child: FilledButton(
                                              style: FilledButton.styleFrom(
                                                backgroundColor: Colors.red.shade400,
                                                foregroundColor: Colors.white,
                                                visualDensity: VisualDensity.compact,
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                                minimumSize: const Size(0, 32),
                                              ),
                                              onPressed: () {
                                                setDialogState(() {
                                                  decisions[word] = 'reject';
                                                  processed.add(word);
                                                });
                                              },
                                              child: const Text('拒绝更新', style: TextStyle(fontSize: 13)),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Tooltip(
                                            message: '以本地为准，将本地删除同步到云端',
                                            child: FilledButton(
                                              style: FilledButton.styleFrom(
                                                backgroundColor: Colors.orange.shade700,
                                                foregroundColor: Colors.white,
                                                visualDensity: VisualDensity.compact,
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                                minimumSize: const Size(0, 32),
                                              ),
                                              onPressed: () {
                                                setDialogState(() {
                                                  decisions[word] = 'upload_local';
                                                  processed.add(word);
                                                });
                                              },
                                              child: const Text('上传本地', style: TextStyle(fontSize: 13)),
                                            ),
                                          ),
                                        ] else if (decision == 'reject')
                                          const Text('✗ 已拒绝', style: TextStyle(fontSize: 13, color: Colors.red))
                                        else if (decision == 'upload_local')
                                          const Text('✗ 已上传删除', style: TextStyle(fontSize: 13, color: Colors.orange)),
                                        const Spacer(),
                                        if (isDone && decision == 'accept' && !isRemoteDeleted) ...[
                                          const Text('分类: ', style: TextStyle(fontSize: 12)),
                                          const SizedBox(width: 4),
                                          Container(
                                            constraints: const BoxConstraints(maxWidth: 110),
                                            child: DropdownButton<String>(
                                              value: newCat.isNotEmpty && categories.contains(newCat) ? newCat : categories.first,
                                              isDense: true,
                                              underline: const SizedBox(),
                                              style: const TextStyle(fontSize: 13, color: Colors.black87),
                                              items: categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                                              onChanged: (selected) {
                                                if (selected != null) {
                                                  setDialogState(() {
                                                    ch['new_category'] = selected;
                                                  });
                                                }
                                              },
                                            ),
                                          ),
                                        ],
                                        if (isDone && decision == 'accept' && isRemoteDeleted) ...[
                                          const Text('确认后本地删除', style: TextStyle(fontSize: 12, color: Colors.red)),
                                        ],
                                      ],
                                    ),
                                  ],
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
              actionsAlignment: MainAxisAlignment.spaceBetween,
              actions: [
                // 全部接收（应用云端更新）
                Tooltip(
                  message: '全部应用云端更新，不删除本地词',
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.green.shade800),
                    onPressed: () => Navigator.pop(ctx, buildResult('accept')),
                    child: const Text('接收更新'),
                  ),
                ),
                // 全部拒绝（保留本地）
                Tooltip(
                  message: '全部拒绝云端更新，保留本地',
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                    onPressed: () => Navigator.pop(ctx, buildResult('reject')),
                    child: const Text('拒绝更新'),
                  ),
                ),
                // 全部上传本地（以本地删除为准同步到云端并关闭）
                Tooltip(
                  message: '全部以本地为准，将本地删除同步到云端',
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.orange.shade800),
                    onPressed: () => Navigator.pop(ctx, buildResult('upload_local')),
                    child: const Text('上传本地'),
                  ),
                ),
                // 右：取消（保留已单独逐词处理的决策）
                Tooltip(
                  message: '取消本次操作，不做任何改动',
                  child: TextButton(
                    onPressed: () {
                      if (processed.isEmpty) {
                        Navigator.pop(ctx, null);
                        return;
                      }
                      final result = <Map<String, String>>[];
                      for (final w in processed) {
                        final d = decisions[w] ?? 'accept';
                        final c = changes
                            .firstWhere((ch) => (ch as Map<String, dynamic>)['word'] == w,
                              orElse: () => <String, dynamic>{}) as Map<String, dynamic>;
                      result.add({
                        'word': w,
                        'action': d,
                        'category': d == 'accept' ? (c['new_category'] as String? ?? '') : '',
                      });
                    }
                    Navigator.pop(ctx, result);
                  },
                  child: const Text('取消'),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _checkUpdate() async {

    const currentVersion = '1.4.9';

    try {

      final response = await http.get(

        Uri.parse('https://api.github.com/repos/beenhow/ESW/releases/latest'),

        headers: {'Accept': 'application/vnd.github.v3+json'},

      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {

        _showUpdateResult('无法获取更新信息（网络异常）');

        return;

      }

      final data = jsonDecode(response.body);

      final tagName = data['tag_name'] as String?;

      if (tagName == null) {

        _showUpdateResult('无法获取更新信息');

        return;

      }

      final latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;

      if (_compareVersions(latestVersion, currentVersion) > 0) {

        if (mounted) {

          showDialog(

            context: context,

            builder: (ctx) => AlertDialog(

              title: const Text('发现新版本'),

              content: Column(

                mainAxisSize: MainAxisSize.min,

                children: [

                  Text('当前版本：$currentVersion\n最新版本：$latestVersion\n\n请选择下载入口：'),

                  const SizedBox(height: 12),

                  Row(

                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,

                    children: [

                      InkWell(

                        onTap: () async {

                          Navigator.pop(ctx);

                          try {

                            await launchUrl(Uri.parse('https://github.com/beenhow/ESW/releases'), mode: LaunchMode.externalApplication);

                          } catch (e) {
                            // 打开外部浏览器失败时静默处理
                          }

                        },

                        child: const Column(

                          children: [

                            Icon(Icons.code, size: 36, color: Colors.black),

                            SizedBox(height: 4),

                            Text('GitHub', style: TextStyle(fontSize: 12)),

                          ],

                        ),

                      ),

                      InkWell(

                        onTap: () async {

                          Navigator.pop(ctx);

                          try {

                            await launchUrl(Uri.parse('https://wwbcj.lanzouu.com/b02qeywze'), mode: LaunchMode.externalApplication);

                          } catch (e) {
                            // 打开外部浏览器失败时静默处理
                          }

                        },

                        child: const Column(

                          children: [

                            Icon(Icons.cloud_download, size: 36, color: Colors.blue),

                            SizedBox(height: 4),

                            Text('蓝奏云\n(密码 52pj)', style: TextStyle(fontSize: 12), textAlign: TextAlign.center),

                          ],

                        ),

                      ),

                    ],

                  ),

                ],

              ),

              actions: [

                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),

              ],

            ),

          );

        }

      } else {

        _showUpdateResult('暂无更新（当前 $currentVersion 已是最新）');

      }

    } catch (_) {

      _showUpdateResult('检查更新失败，请稍后重试');

    }

  }

  int _compareVersions(String a, String b) {

    final aParts = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    final bParts = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    final len = aParts.length > bParts.length ? aParts.length : bParts.length;

    for (int i = 0; i < len; i++) {

      final av = i < aParts.length ? aParts[i] : 0;

      final bv = i < bParts.length ? bParts[i] : 0;

      if (av != bv) return av.compareTo(bv);

    }

    return 0;

  }

  void _showUpdateResult(String message) {

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(

      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),

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

                      onPressed: () => _submitButton('超标词'),

                      style: OutlinedButton.styleFrom(

                        foregroundColor: AppTheme.orange,

                      ),

                      child: const Text('超标词'),

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

// ==================== 使用说明页 ====================

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

        icon: Icons.upload_file,

        title: '真题导入',

        content: '点击「真题导入」按钮或直接将 TXT/DOCX/PDF 文件拖入窗口。导入后自动按年份分词统计词频，支持多文件叠加分析。',

      ),

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
