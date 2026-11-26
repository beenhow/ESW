import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show rootBundle, Clipboard, ClipboardData;
import 'dart:isolate';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'dart:async';
import 'dart:collection';
import 'dart:ffi' hide Size;
import 'package:ffi/ffi.dart';
import 'package:window_manager/window_manager.dart';
import 'theme/app_theme.dart';
import 'theme/glass_theme.dart';
import 'theme/dialog_kit.dart' show EswDialog, EswDialogShell, EswDialogActions, EswDialogTextAction, EswDialogPrimaryAction, EswDialogGhostAction, EswOptionTile, EswOptionRow, EswDialogWidth, EswDialogHint;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;
import 'package:archive/archive.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdf/pdf.dart' as pwpdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'dictionary_service.dart';
import 'esw_perf_probe.dart';
import 'export_summary.dart';
import 'high_freq_export.dart';
import 'shared/word_sync_service.dart';
import 'shared/win_window_repaint.dart';
import 'shared/webdav_client.dart';
import 'shared/doc_extractor.dart';
import 'shared/export_extra_table.dart';
import 'shared/base_word_candidates.dart';
import 'shared/inplace_docx_annotator.dart';
import 'shared/export_word_style.dart';
import 'word_filter_rules.dart';
import 'shared/export_annotate_markup.dart';
import 'shared/text_normalize.dart';
import 'shared/builtin_corpus.dart';
import 'shared/imported_corpus.dart';
import 'windows/imported_word_row.dart';
import 'windows/year_filter_bar.dart';

typedef _GetDroppedFileC = Pointer<Utf8> Function();
typedef _GetDroppedFileDart = Pointer<Utf8> Function();
final DynamicLibrary _exeLib = DynamicLibrary.process();
final _GetDroppedFileDart _getDroppedFile = _exeLib
    .lookupFunction<_GetDroppedFileC, _GetDroppedFileDart>('get_dropped_file');

/// 自动化截图自查用的根绘制边界 key（仅在 ESW_SHOT_CAPTURE 环境下使用，生产环境无副作用）。
final GlobalKey kEswShotBoundaryKey = GlobalKey();

class WinEswApp extends StatelessWidget {
  const WinEswApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESW',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppTheme.primaryBlue,
          brightness: Brightness.light,
          surface: AppTheme.surfaceLightest,
        ),
        scaffoldBackgroundColor: AppTheme.surfaceLightest,
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei',
        // 第三关 ⑤：玻璃面板禁用 InkWell 水波纹（全局 NoSplash）
        splashFactory: NoSplash.splashFactory,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: GlassTheme.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
            ),
            minimumSize: const Size(64, 38),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: GlassTheme.fBody,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: GlassTheme.ink2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
            ),
            minimumSize: const Size(64, 38),
            side: const BorderSide(color: GlassTheme.line),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: GlassTheme.fBody,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: GlassTheme.ink2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: GlassTheme.fBody,
            ),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: GlassTheme.panel, // 第三关 ②：卡片同样是玻璃白 .58，禁裸用不透明白
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            side: const BorderSide(color: AppTheme.borderLighter),
          ),
        ),
        // 弹窗视觉统一（基准：参考图「导出检测结果」弹窗，V9 收紧）：
        // 圆角 12、紧凑内边距、标题 14.5 加粗、正文 11.5 次级灰、按钮区右下收口
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xB8FFFFFF), // 加厚玻璃 rgba(255,255,255,0.72)
          barrierColor: const Color(0x4718181B), // 第三关 ③：遮罩 rgba(24,24,27,0.28)
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EswDialog.rPanel),
          ),
          shadowColor: const Color(0x4018181B), // 0 24px 60px rgba(24,24,27,0.25)
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 64,
            vertical: 48,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(
            EswDialog.padH,
            EswDialog.gapSection,
            EswDialog.padH,
            EswDialog.padB,
          ),
          titleTextStyle: EswDialog.titleStyle,
          contentTextStyle: EswDialog.subtitleStyle,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: GlassTheme.panelSolid, // rgba(255,255,255,0.72) 输入框可读性（规范 2.4/6.1）
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingMd,
            vertical: AppTheme.spacingSm,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            borderSide: const BorderSide(color: AppTheme.borderLight),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            borderSide: const BorderSide(color: AppTheme.borderLight),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            borderSide: BorderSide(
              color: GlassTheme.accent,
              width: 1.5,
            ),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: AppTheme.borderLight,
          thickness: 1,
          space: 1,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xD118181B), // 深色玻璃胶囊 rgba(24,24,27,0.82)（规范 3.1 Toast）
          contentTextStyle: const TextStyle(
            fontSize: GlassTheme.fBody,
            color: Colors.white,
            height: 1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0x1FFFFFFF)), // rgba(255,255,255,0.12)
          ),
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: kGap16, vertical: kGap12),
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: AppTheme.textPrimary.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xB8FFFFFF), // rgba(255,255,255,0.72) 右键/下拉菜单玻璃（规范 2.9）
          elevation: 24,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: GlassTheme.line),
          ),
          textStyle: const TextStyle(
            fontSize: GlassTheme.fBody,
            color: GlassTheme.ink,
            height: 1,
          ),
        ),
      ),
      // 任务②：随窗口尺寸统一刷新自适应缩放。
      // 布局尺寸由 GlassTheme.dp() / 各 h* 读取 uiScale；文字在此按同一系数收缩，
      // 保证各板块 / 提示文字 / 按钮在小窗口下等比变小，而不是被裁切或溢出。
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        GlassTheme.updateUiScale(mq.size);
        final factor =
            (GlassTheme.uiScale * mq.textScaler.scale(1.0)).clamp(0.7, 1.4);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(factor)),
          child: RepaintBoundary(
            key: kEswShotBoundaryKey,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const MainWindow(),
    );
  }
}

/// 结构守卫测试开关（规范 §3.3）：仅由 test/ 下的 widget 测试置为 true。
/// 为 true 时跳过拖放轮询、窗口状态查询、启动同步提示等依赖平台能力的副作用，
/// 使主界面可在 widget 测试环境中真实渲染（9 个 region key 均可被 findsOneWidget 命中）。
/// 生产环境恒为 false，不改变任何功能行为。
bool kEswStructureGuardTestMode = false;

/// 最近查询历史测试种子：仅由 test/ 下的 widget 测试临时赋值。
/// 用于在不依赖磁盘配置的情况下渲染「最近查询」展开态，验证小窗口不溢出。
/// 生产环境恒为 null，不改变任何功能行为。
List<String>? kEswTestWordHistory;

/// 应用用户数据目录（Windows 为 `%LOCALAPPDATA%\ESW`）：
/// 配置、调试日志、运行时产物统一落在这里，不写安装目录（安装目录可能只读）。
/// 供 main.dart 记录崩溃日志等启动早期信息使用。
String get eswUserDataDir => _MainWindowState._userDataDir;

class MainWindow extends StatefulWidget {
  const MainWindow({super.key});
  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow>
    with WindowListener, WidgetsBindingObserver {
  // ============ 自绘标题栏状态 ============
  bool _isMaximized = false;
  double _windowBtnScale = 1.0; // 窗口三键按压反馈
  // ============ 左侧状态 ============
  List<CorpusFile> _corpusFiles = [];
  // 内置真题（随包发布，首启释放）与用户自选语料分开持有：
  // _corpusFiles 始终是「内置 + 用户」的合并视图，下游扫描/统计/导出一律读它，
  // 因此内置接入不需要改动任何检测与导出逻辑。
  List<CorpusFile> _builtinFiles = [];
  List<CorpusFile> _userCorpusFiles = [];
  Set<String> _builtinIds = {};
  bool _builtinHidden = false; // 隐藏内置真题（不参与统计，可一键恢复）
  bool _builtinCollapsed = false; // 仅折叠内置分组（仍参与统计）
  bool _highFreqExporting = false;
  // 教材导入文件列表（txt/doc/docx，可勾选，参与语料统计）
  List<CorpusFile> _textbookFiles = [];
  // 第三关 ⑥：左栏每组的"高亮行"（选中态全栏唯一，初始为第 1 行）。
  // 仅用于视觉高亮，与 CorpusFile.isSelected（勾选参与统计的功能语义）解耦。
  String? _activeCorpusPath;
  String? _activeTextbookPath;

  /// 左栏当前列表：false = 真题（默认），true = 教材。两态互斥、各占满左栏。
  bool _leftPanelIsTextbook = false;

  /// 取某组的高亮行路径：优先记住的行；[fallbackFirst] 为 true 时失效回退第 1 行。
  /// 第三关 ⑥：全栏唯一高亮——仅"真题导入"组默认高亮第 1 行；其余组默认无高亮
  /// （透明底、hover 变灰），点击后才产生高亮，避免左栏同时出现两处选中态。
  String? _activePathOf(
    List<CorpusFile> files,
    String? remembered, {
    bool fallbackFirst = false,
    String? firstPathOverride,
  }) {
    if (files.isEmpty) return null;
    if (remembered != null && files.any((f) => f.path == remembered)) {
      return remembered;
    }
    if (!fallbackFirst) return null;
    // 左栏分组展示后，"第一行"以展示序列为准（内置分组可能排在用户分组之前）
    return firstPathOverride ?? files.first.path;
  }
  // ============ 右侧状态 ============
  final TextEditingController _searchController = TextEditingController();
  String _activeFilter = '真题词';

  final List<String> _filters = ['真题词', '课标词', '拓展词', '超标词', '专有词', '未筛选'];
  final Map<String, int> _filterCounts = {
    '真题词': 0,
    '课标词': 0,
    '拓展词': 0,
    '超标词': 0,
    '专有词': 0,
    '未筛选': 0,
  };
  static final Map<String, Color> _filterColors = {
    '真题词': AppTheme.orange,
    '课标词': AppTheme.primaryBlue,
    '拓展词': AppTheme.green,
    '超标词': AppTheme.red,
    '专有词': AppTheme.grey,
    '未筛选': AppTheme.purple,
  };
  String _wordPos = '';
  String _wordDef = '';
  String? _detectedCategory;
  String _detectedWord = '';
  final List<String> _extendWords = []; // 用户添加的拓展词列表（保持添加顺序）

  /// 拓展词小写索引：查询/渲染高频路径（_onDetect、_buildWordDefBanner）避免
  /// 对列表线性扫描 + 逐词 toLowerCase，改为 O(1) contains。
  final Set<String> _extendWordsLower = {};
  final Map<String, String> _extendBaseMap = {}; // 拓展词→基础课标词映射
  final LinkedHashSet<String> _manualChaoGangWords =
      LinkedHashSet<String>(); // 用户手动标记的超标词（保持添加顺序）
  final LinkedHashSet<String> _manualExtraWords =
      LinkedHashSet<String>(); // 用户手动标记的专有词（保持添加顺序）
  final Map<String, String> _classificationMemory = {}; // 单词小写→分类，跨导入记忆
  // 共识引擎
  final WordSyncService _wordSyncService = WordSyncService();
  String _userId = '';
  final GlobalKey _importBtnKey = GlobalKey();
  final GlobalKey _textbookBtnKey = GlobalKey();

  /// 左栏标题行锚点：切换标签后「＋」按钮的 GlobalKey 可能尚未挂载，
  /// 导入菜单以标题行为兜底锚点，避免空指针。
  final GlobalKey _leftHeaderKey = GlobalKey();

  // 词库列表弹窗批量操作状态：3 秒防抖自动弹出批量操作弹窗
  final Set<String> _batchSelected = {};
  String _batchSourceKind = ''; // 'extend' | 'chaogang' | 'extra'
  Timer? _batchTimer;


  // ======== 持久化配置 ========
  /// 用户可写数据目录（%LOCALAPPDATA%\ESW）：配置、日志一律落在这里，
  /// 保证软件被安装到 Program Files 等只读目录、或被其他 Windows 账号运行时
  /// 依然可写；进程内只解析/创建一次。
  static String? _userDataDirCache;

  static String get _userDataDir {
    final cached = _userDataDirCache;
    if (cached != null) return cached;
    String? dir;
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Platform.environment['APPDATA'];
    if (base != null && base.isNotEmpty) {
      final candidate = p.join(base, 'ESW');
      try {
        Directory(candidate).createSync(recursive: true);
        // 可写性验证：目录可能存在但当前账号无写权限（组策略/多账号机器），
        // 那样写配置会静默失败；这里用一次性探针文件确认可写后再采用。
        final probe = File(p.join(candidate, '.write_probe'));
        probe.writeAsStringSync('ok');
        probe.deleteSync();
        dir = candidate;
      } catch (_) {}
    }
    // 兜底：用户目录不可用时退回 exe 同目录（1.5.7 及以前的行为），
    // 保证功能可用而不是直接丢配置。
    dir ??= File(Platform.resolvedExecutable).parent.path;
    _userDataDirCache = dir;
    return dir;
  }

  /// 旧版（1.5.7 及以前）把配置写在 exe 同目录，仅用于首次启动时迁移读取。
  String get _legacyConfigPath =>
      p.join(File(Platform.resolvedExecutable).parent.path, 'esw_config.json');

  /// 更早版本（程序名 eva）的配置：同样在 exe 同目录，只是文件名为
  /// eva_config.json。跨机器上按「exe 同目录」推导，不再硬编码开发机绝对路径。
  String _legacyEvaConfigPath() {
    try {
      return p.join(
          File(Platform.resolvedExecutable).parent.path, 'eva_config.json');
    } catch (_) {
      return '';
    }
  }

  String get _configPath => p.join(_userDataDir, 'esw_config.json');
  String? _lastExamImportPath;
  String? _lastDocImportPath;
  String? _lastTextbookImportPath;
  String? _lastImportMode; // 'folder' or 'files'
  String? _lastExportPath;
  final List<String> _wordHistory = [];
  final FocusNode _searchFocus = FocusNode();
  Timer? _historyTimer;
  // 查询代际序号：每次发起新查询（输入检测/历史点击）自增，旧查询的异步结果
  // （语料扫描 Future.wait、词典 lookup 回调）据此判定过期并丢弃，杜绝快速连续
  // 点击时"后发先至"的旧结果覆盖新结果——即"点A出B"根因。
  int _querySeq = 0;
  // 历史下拉当前 hover 的词条索引（整行高亮，直观提示整块可点击）。
  // 用 ValueNotifier 驱动高亮：hover 变化只重建条目内部的 Container，
  // 绝不触发包含 GestureDetector 的子树重建，避免 recognizer 被替换导致
  // 鼠标按下-抬起之间的点击手势被取消（点击历史词条无响应的根因防御）。
  final ValueNotifier<int?> _hoverHistoryIndex = ValueNotifier<int?>(null);
  // 第三关 ⑤：历史条目按压态（ValueNotifier 驱动，避免 setState 重建条目子树）
  final ValueNotifier<int?> _pressedHistoryIndex = ValueNotifier<int?>(null);
  // 历史词条 Listener 手动点击检测：记录按下位置，抬起时位移小于阈值视为点击。
  // 完全绕开手势竞技场（GestureDetector 在桌面端被 Scrollable/焦点重建吞掉 onTap 的根因防御）。
  Offset? _historyDownPos;
  bool _ocrReady = false;
  String? _tesseractPath;
  String? _tessdataPath;
  /// 缺失资源降级提示：本次文档读取是否因「缺少 tesseract OCR 组件」而拿不到
  /// 任何文字（图片型 PDF）。由 _readFileTextCached 重置、_readPdfContent 置位，
  /// 导入流程据此弹出明确提示，而不是静默导入一段空白。
  bool _lastPdfOcrUnavailable = false;
  void _cancelHistoryTimer() {
    _historyTimer?.cancel();
    _historyTimer = null;
  }

  /// 调试日志：内存缓冲 + 定时批量落盘（写入用户目录 %LOCALAPPDATA%\ESW）。
  /// 原实现每次调用同步写盘，高频路径（每次查词/历史点击 3~6 次同步 IO）
  /// 会阻塞 UI 线程造成可见卡顿，改为攒批后最多每 2 秒 flush 一次。
  /// 落盘位置从「exe 同目录」改到用户目录：安装目录可能只读（Program Files）
  /// 或由其他账号运行，写 exe 目录会静默失败并丢失日志。
  final List<String> _debugLogBuffer = [];
  Timer? _debugLogFlushTimer;

  void _debugLog(String msg) {
    if (kEswStructureGuardTestMode) return; // 测试模式不写日志、不留 pending Timer
    try {
      _debugLogBuffer.add('${DateTime.now().toIso8601String()} $msg');
      _debugLogFlushTimer ??= Timer(const Duration(seconds: 2), () {
        _flushDebugLog();
      });
    } catch (_) {}
  }

  void _flushDebugLog() {
    _debugLogFlushTimer?.cancel();
    _debugLogFlushTimer = null;
    if (_debugLogBuffer.isEmpty) return;
    final lines = List.of(_debugLogBuffer);
    _debugLogBuffer.clear();
    try {
      final f = File(p.join(_userDataDir, 'debug_log.txt'));
      // 异步追加：日志落盘不占用 UI 线程（失败静默，日志本身不影响功能）。
      unawaited(
        f.writeAsString('${lines.join('\n')}\n', mode: FileMode.append)
            .then((_) {}, onError: (_) {}),
      );
    } catch (_) {}
  }

  final Map<int, int> _yearFrequency = {};
  final List<ResultRow> _results = [];
  // 教材文件中的位置结果（检测时并行搜索选中教材文件生成，点击联动右侧原文面板）
  final List<ResultRow> _textbookResults = [];
  List<int> _sortedYears = []; // 预计算降序年份列表（由 _rebuildCorpusList 统一维护）
  List<ResultRow> _filteredResults = []; // 预计算年份筛选结果
  int? _selectedYear;
  String? _selectedTextbook; // 教材筛选：当前选中的教材文件路径
  List<ResultRow> _filteredTextbookResults = []; // 教材筛选结果
  // ======== 导入文本分析 ========
  final bool _isDragging = false;
  bool _inImportedMode = false;
  String? _importedFileName;
  String? _importedFilePath;
  // ======== 右侧原文面板（常驻） ========
  bool _rightPanelVisible = false;
  String _rightPanelTitle = '';
  String _rightPanelKeyword = '';
  _HighlightController? _rightHighlightController;
  final GlobalKey _rightReaderKey = GlobalKey(); // 右侧原文 TextField（精确文本定位用）
  final ScrollController _rightScrollController = ScrollController();
  ResultRow? _rightPanelRow; // 教材定位行（供弹窗编辑兜底）
  int _rightPanelOccurrence = 0; // 当前关键词的第几次出现（窗口缩放后重新定位用）
  // ======== 左侧真题内联阅读器 ========
  // 真题原文不再占用右侧面板：点击文件行尾按钮在行下方内联展开本套真题，
  // 从检测结果点击单词时自动展开该词所在年份并定位到该词。
  final Set<String> _corpusReaderOpen = <String>{}; // 展开中的真题路径
  final Map<String, String> _corpusReaderTexts = {}; // 路径 → 已解析全文
  final Map<String, _HighlightController> _corpusReaderControllers = {};
  final Map<String, ScrollController> _corpusReaderScrolls = {};
  final Map<String, GlobalKey> _corpusReaderKeys = {}; // 用于精确计算关键词行位置
  final Map<String, int> _corpusReaderAnchors = {}; // 路径 → 当前定位到的字符位置
  final ScrollController _corpusListScrollController = ScrollController();
  Timer? _readerReanchorTimer; // 窗口缩放后重新定位的防抖计时器
  /// 结果行定位时只显示这一套真题（其它年份折叠隐藏），null 表示正常全量列表
  String? _corpusFocusPath;
  // ======== 教材内联阅读器（与真题一致：行下展开、关键词定位） ========
  final Set<String> _textbookReaderOpen = <String>{}; // 展开中的教材路径
  final ScrollController _textbookListScrollController = ScrollController();
  String? _textbookFocusPath; // 结果定位时只显示这本教材

  /// 已筛选过的文件路径集合，打开这些文件时自动积累分类结果
  final Set<String> _processedFilePaths = {};
  List<_ImportedWord> _importedWords = [];
  String _importedActiveFilter = '真题词';
  int _importedTotalWords = 0;
  List<_ImportedWord> _cachedFilteredImportedWords = [];
  String? _cachedImportedFilter;
  List<_ImportedWord>? _cachedImportedWordsRef;
  final Map<String, int> _importedFilterCounts = {
    '真题词': 0,
    '课标词': 0,
    '拓展词': 0,
    '超标词': 0,
    '专有词': 0,
    '未筛选': 0,
  };
  // ======== 从导入模式跳转到查词后的返回状态 ========
  bool _cameFromImportedMode = false;
  String _savedImportedText = '';
  List<_ImportedWord> _savedImportedWords = [];
  String _savedImportedActiveFilter = '真题词';
  int _savedImportedTotalWords = 0;
  final Map<String, int> _savedImportedFilterCounts = {};
  // ======== 文件文本缓存（LRU，避免重复解析 docx/pdf/txt） ========
  /// 语料/导入文件纯文本缓存：key=绝对路径，value=解析结果+文件签名
  final Map<String, _CachedFileText> _fileTextCache = {};

  /// LRU 顺序（尾部为最近使用）
  final List<String> _fileTextCacheOrder = [];

  // ======== 常驻扫描 worker isolate ========
  Isolate? _scanWorker;
  SendPort? _scanWorkerPort;
  ReceivePort? _scanResultPort;
  /// 已同步到 worker 的文件版本（path -> modified.ms）
  final Map<String, int> _workerTextVersions = {};
  final Map<int, Completer<_ScanOut>> _scanPending = {};
  int _scanReqSeq = 0;
  /// worker 初始化失败后置位：后续查询直接走同步回退，不再反复尝试 spawn
  bool _scanWorkerFailed = false;

  /// 缓存总字节上限，超限后淘汰最久未使用的条目（控制内存占用）
  static const int _fileTextCacheMaxBytes = 80 * 1024 * 1024;

  /// 缓存条目上限
  static const int _fileTextCacheMaxEntries = 160;

  /// 命中返回文本，未命中返回 null（缓存的是纯文本，比每次解析出的 XML/压缩中间结构省内存）
  String? _readCachedFileText(String path) {
    final cached = _fileTextCache[path];
    if (cached != null) {
      try {
        final stat = FileStat.statSync(path);
        if (stat.modified.millisecondsSinceEpoch == cached.modified &&
            stat.size == cached.size) {
          _touchCache(path);
          return cached.text;
        }
      } catch (_) {}
      // 文件已变化，丢弃旧缓存
      _fileTextCache.remove(path);
      _fileTextCacheOrder.remove(path);
    }
    return null;
  }

  void _cacheFileText(String path, String text) {
    if (path.isEmpty) return;
    try {
      final stat = FileStat.statSync(path);
      _fileTextCache[path] = _CachedFileText(
        text: text,
        modified: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
      );
    } catch (_) {
      _fileTextCache[path] = _CachedFileText(text: text, modified: 0, size: 0);
    }
    _touchCache(path);
    // 容量控制：总字节或条目超限时，淘汰最久未使用的条目
    var total = _fileTextCache.values.fold<int>(0, (s, c) => s + c.text.length);
    while ((total > _fileTextCacheMaxBytes ||
            _fileTextCacheOrder.length > _fileTextCacheMaxEntries) &&
        _fileTextCacheOrder.isNotEmpty) {
      final oldest = _fileTextCacheOrder.removeAt(0);
      final removed = _fileTextCache.remove(oldest);
      if (removed != null) total -= removed.text.length;
    }
  }

  void _touchCache(String path) {
    _fileTextCacheOrder.remove(path);
    _fileTextCacheOrder.add(path);
  }

  /// 读取任意文件纯文本并走缓存（docx/pdf/doc/txt 统一异步入口）
  Future<String> _readFileTextCached(String filePath) async {
    // 缺失资源降级标记：本次读取是否因缺少 OCR 组件而读不出文字（供调用方提示）
    _lastPdfOcrUnavailable = false;
    final hit = _readCachedFileText(filePath);
    if (hit != null) return hit;
    final ext = filePath.toLowerCase();
    String content;
    if (ext.endsWith('.docx')) {
      try {
        content = _readDocxContent(filePath);
      } catch (_) {
        // 部分教材文件实为纯文本但后缀为 .docx，解析失败时回退按纯文本读取
        content = _decodeTxtBytes(File(filePath).readAsBytesSync());
      }
    } else if (ext.endsWith('.pdf')) {
      content = await _readPdfContent(filePath);
    } else if (ext.endsWith('.doc')) {
      content = extractDocText(File(filePath).readAsBytesSync());
    } else {
      content = _decodeTxtBytes(File(filePath).readAsBytesSync());
    }
    // 三条入口（真题语料 / 导入文档 / 粘贴文本）统一规范化：
    // 制表符当分隔、软换行当断行、选项标记断行，避免 itB / toC 这类粘连 token
    content = normalizeText(content);
    _cacheFileText(filePath, content);
    return content;
  }

  /// txt 文本解码：统一走 shared/doc_extractor 的 decodeTextBytes
  /// （UTF-16 BOM / UTF-8 BOM / UTF-8 严格 / GBK 回退）。
  String _decodeTxtBytes(List<int> bytes) => decodeTextBytes(bytes);

  // ======== 性能优化常量 ========
  static const int _maxContextHalf = 30;

  /// 单词检测预编译正则
  static final RegExp _yearPrefixRegex = RegExp(r'^(\d{4})');
  static final RegExp _whitespaceRegex = RegExp(r'[\s\n\u3000]');
  static final RegExp _anyWhitespaceChar = RegExp(r'\s');
  static final RegExp _sentenceEndRegex = RegExp(r'[。！？.!?\n]');
  // ======== 防抖保存 ========
  @override
  void initState() {
    super.initState();
    final testHistory = kEswTestWordHistory;
    if (testHistory != null) _wordHistory.addAll(testHistory);
    EswPerf.boot('app.initState');
    // 探针专用：仅在 ESW_PERF_PROBE 下注册打点定时器，生产/测试环境不注册
    // 任何回调与定时器（避免留下 pending Timer 影响结构守卫测试）。
    if (EswPerf.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        EswPerf.boot('first.frame');
        // 首帧之后的 0.5s / 1.5s / 3s 各打一点，用于对齐外部脚本观测到的
        // 「窗口出现后仍在消耗 CPU」区间，判断残余启动工作发生在哪一段。
        for (final s in <int>[500, 1500, 3000]) {
          Future<void>.delayed(Duration(milliseconds: s), () {
            EswPerf.boot('after.firstFrame(${s}ms)');
          });
        }
      });
    }
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    _initWindowState();
    _initDragDrop();
    _searchFocus.addListener(_onSearchFocusChange);
    _initOcr();
    _loadStandardWords();
    // 配置加载（异步）完成后只释放内置真题；不再自动载入上次导入的真题目录。
    // 历史路径仍保存在配置里，仅用于文件选择器的初始目录（initialDirectory）。
    unawaited(_loadConfig().then((_) async {
      await _initBuiltinCorpus();
    }));
    if (Platform.environment['ESW_SHOT_CAPTURE'] == null && !EswPerf.enabled) {
      _maybePromptSync();
    }
    _maybeOpenShotDialog();
    _maybeCaptureShot();
    _maybeCaptureFrames();
    _maybeAutoDrive();
    _runPerfProbe();
    _scheduleWordBankWarmUp();
  }

  /// 截图自查钩子：环境变量 ESW_SHOT_CAPTURE 指定 PNG 输出路径时，
  /// 启动延迟后截取整个窗口画面（含已弹出的对话框）写入该路径。
  /// 未设置时零影响，不改变任何业务逻辑。
  Future<void> _maybeCaptureShot() async {
    final out = Platform.environment['ESW_SHOT_CAPTURE'];
    if (out == null || out.isEmpty) return;
    final log = File('${File(out).parent.path}${Platform.pathSeparator}shot_debug.txt');
    void w(String m) {
      try {
        log.writeAsStringSync('$m\n', mode: FileMode.append);
      } catch (_) {}
    }

    w('hook start');
    await Future<void>.delayed(const Duration(seconds: 9));
    w('after delay mounted=$mounted');
    if (!mounted) return;
    try {
      final ctx = kEswShotBoundaryKey.currentContext;
      w('ctx=${ctx != null}');
      final obj = ctx?.findRenderObject();
      w('obj type=${obj.runtimeType}');
      if (obj is! RenderRepaintBoundary) {
        w('not a repaint boundary');
        return;
      }
      final img = await obj.toImage(pixelRatio: 1.0);
      w('img=${img.width}x${img.height}');
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      w('bytes=${data?.lengthInBytes}');
      if (data == null) return;
      File(out).writeAsBytesSync(data.buffer.asUint8List());
      w('written ok');
    } catch (e, st) {
      w('ERR $e');
      w('$st');
    }
  }

  /// 逐帧取图钩子（仅自动化取证使用；未设置 ESW_FRAMES_DIR 时零影响）。
  ///
  /// 环境变量：
  ///   ESW_FRAMES_DIR          PNG 输出目录（必填，缺失即整体跳过）
  ///   ESW_FRAMES_START_MS     开始抓帧时刻（自 initState 起算，默认 6000）
  ///   ESW_FRAMES_COUNT        抓帧数量（默认 240）
  ///   ESW_FRAMES_INTERVAL_MS  帧间隔（默认 0，即每个渲染帧抓一次）
  ///
  /// 输出：f0000.png ... + frames_log.txt（每帧墙钟微秒 + 尺寸），
  /// 供外部脚本与动作日志（ESW_ACTION_LOG）对齐时间轴。
  Future<void> _maybeCaptureFrames() async {
    final dir = Platform.environment['ESW_FRAMES_DIR'];
    if (dir == null || dir.isEmpty) return;
    final startMs =
        int.tryParse(Platform.environment['ESW_FRAMES_START_MS'] ?? '') ?? 6000;
    final count =
        int.tryParse(Platform.environment['ESW_FRAMES_COUNT'] ?? '') ?? 240;
    final intervalMs =
        int.tryParse(Platform.environment['ESW_FRAMES_INTERVAL_MS'] ?? '') ?? 0;
    final outDir = Directory(dir);
    try {
      outDir.createSync(recursive: true);
    } catch (_) {}
    final log = File('${outDir.path}${Platform.pathSeparator}frames_log.txt');
    void w(String m) {
      try {
        log.writeAsStringSync('$m\n', mode: FileMode.append);
      } catch (_) {}
    }

    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < startMs) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    w('capture.start ${DateTime.now().microsecondsSinceEpoch}');
    for (var i = 0; i < count; i++) {
      if (!mounted) return;
      final ctx = kEswShotBoundaryKey.currentContext;
      final obj = ctx?.findRenderObject();
      if (obj is! RenderRepaintBoundary) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        continue;
      }
      final t = DateTime.now().microsecondsSinceEpoch;
      try {
        final img = await obj.toImage(pixelRatio: 1.0);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        if (data != null) {
          File(
            '${outDir.path}${Platform.pathSeparator}'
            'f${i.toString().padLeft(4, '0')}.png',
          ).writeAsBytesSync(data.buffer.asUint8List());
        }
        w('frame $i t=$t elapsed=${sw.elapsedMilliseconds} '
            'size=${img.width}x${img.height}');
        img.dispose();
      } catch (e) {
        w('frame $i t=$t ERR $e');
      }
      if (intervalMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: intervalMs));
      } else {
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    w('capture.end ${DateTime.now().microsecondsSinceEpoch}');
  }

  /// 自动动作钩子（仅自动化取证使用；未设置 ESW_AUTO_ACTION 时零影响）。
  ///
  /// 环境变量：
  ///   ESW_AUTO_ACTION    filter | query | export | maximize | resize | history
  ///   ESW_AUTO_ACTION_MS 动作开始时刻（自 initState 起算，默认 6500）
  ///   ESW_AUTO_RESIZE   query/history 动作前是否缩到最小窗口（1=是）
  ///   ESW_AUTO_DOC      export 动作前先导入检测的文档绝对路径
  ///   ESW_AUTO_QUERY    query 动作要检测的单词（默认 science）
  ///   ESW_AUTO_EXPAND   query 动作检测完成后是否展开首套真题原文（1=是）
  ///   ESW_AUTO_CLICK_RESULT query 动作检测完成后是否点击第一条结果行（1=是）
  ///   ESW_AUTO_CLICK_TEXTBOOK query 动作检测完成后是否点击第一条教材结果（1=是）
  ///   ESW_AUTO_TEXTBOOK query 动作使用的教材语料文件路径（验证教材结果联动）
  ///   ESW_AUTO_IMPORTED_CONTEXT 配合 ESW_AUTO_DOC：模拟「从导入文档点词进入查词」
  ///   ESW_AUTO_FRESH_QUERY 模拟「搜索框独立查词」，应退出导入文档语境
  ///   ESW_ACTION_LOG    动作时间轴日志路径（与 frames_log.txt 对齐）
  Future<void> _maybeAutoDrive() async {
    final action = Platform.environment['ESW_AUTO_ACTION'];
    if (action == null || action.isEmpty) return;
    final startMs =
        int.tryParse(Platform.environment['ESW_AUTO_ACTION_MS'] ?? '') ?? 6500;
    final logPath = Platform.environment['ESW_ACTION_LOG'];
    void w(String m) {
      if (logPath == null || logPath.isEmpty) return;
      try {
        File(logPath).writeAsStringSync('$m\n', mode: FileMode.append);
      } catch (_) {}
    }

    await Future<void>.delayed(Duration(milliseconds: startMs));
    if (!mounted) return;
    w('action.begin $action ${DateTime.now().microsecondsSinceEpoch}');
    if (action == 'filter') {
      const seq = ['课标词', '拓展词', '超标词', '专有词', '未筛选', '真题词'];
      for (final f in seq) {
        if (!mounted) return;
        w('filter.$f ${DateTime.now().microsecondsSinceEpoch}');
        setState(() => _activeFilter = f);
        await Future<void>.delayed(const Duration(milliseconds: 220));
      }
    } else if (action == 'query') {
      final q = Platform.environment['ESW_AUTO_QUERY'] ?? 'science';
      // 可选：把指定文档当作「用户导入的被检测文本」，用于验证右侧联动
      final doc = Platform.environment['ESW_AUTO_DOC'];
      if (doc != null && doc.isNotEmpty && File(doc).existsSync()) {
        try {
          _savedImportedText = await _readFileTextCached(doc);
          _importedFileName = p.basename(doc);
          // 模拟「从导入文档点词进入查词」：允许右侧回退展示该文档
          if (Platform.environment['ESW_AUTO_IMPORTED_CONTEXT'] == '1') {
            _cameFromImportedMode = true;
          }
        } catch (_) {}
      }
      // 模拟「搜索框独立查词」：应退出导入文档语境
      if (Platform.environment['ESW_AUTO_FRESH_QUERY'] == '1') {
        _beginIndependentQuery();
      }
      // 可选：把指定文件/目录当作「教材语料」，用于验证教材结果联动
      final tb = Platform.environment['ESW_AUTO_TEXTBOOK'];
      if (tb != null && tb.isNotEmpty) {
        final paths = <String>[];
        final tbDir = Directory(tb);
        if (tbDir.existsSync()) {
          for (final e in tbDir.listSync()) {
            if (e is! File) continue;
            final low = e.path.toLowerCase();
            if (low.endsWith('.txt') ||
                low.endsWith('.doc') ||
                low.endsWith('.docx') ||
                low.endsWith('.pdf')) {
              paths.add(e.path);
            }
          }
        } else if (File(tb).existsSync()) {
          paths.add(tb);
        }
        if (paths.isNotEmpty) {
          _textbookFiles = [
            for (final path in paths)
              CorpusFile(name: p.basename(path), path: path)..isSelected = true,
          ];
        }
      }
      setState(() => _searchController.text = q);
      w('detect.begin tb=${_textbookFiles.length} '
          '${DateTime.now().microsecondsSinceEpoch}');
      await _onDetect();
      w('detect.done results=${_results.length} '
          'textbook=${_filteredTextbookResults.length} '
          '${DateTime.now().microsecondsSinceEpoch}');
      if (Platform.environment['ESW_AUTO_EXPAND'] == '1' &&
          _corpusFiles.isNotEmpty) {
        await _openCorpusReader(_corpusFiles.first);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      if (Platform.environment['ESW_AUTO_CLICK_RESULT'] == '1' &&
          _filteredResults.isNotEmpty) {
        // 先展开另一套真题，验证点击结果行后其它年份自动折叠
        if (_corpusFiles.length > 3) {
          await _openCorpusReader(_corpusFiles[3]);
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        w('click.result ${DateTime.now().microsecondsSinceEpoch}');
        await _showResultInRightReader(_filteredResults.first);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      // 教材结果点击冒烟：验证左栏内联展开、右侧仍为被检测文本
      if (Platform.environment['ESW_AUTO_CLICK_TEXTBOOK'] == '1' &&
          _filteredTextbookResults.isNotEmpty) {
        w('click.textbook ${_filteredTextbookResults.first.source}');
        await _showResultInRightReader(_filteredTextbookResults.first);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        w('after.textbook right=$_rightPanelVisible kw=$_rightPanelKeyword '
            'focus=$_textbookFocusPath open=${_textbookReaderOpen.length}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      if (Platform.environment['ESW_AUTO_RESIZE'] == '1') {
        w('resize.min ${DateTime.now().microsecondsSinceEpoch}');
        await windowManager.setSize(const Size(900, 600));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      // 导出冒烟：查词模式下直接走一次导出（ESW_AUTO_OUT 指定输出路径）
      if (Platform.environment['ESW_AUTO_EXPORT'] == '1') {
        w('export.begin ${DateTime.now().microsecondsSinceEpoch}');
        await _exportResultToWord();
        w('export.end ${DateTime.now().microsecondsSinceEpoch}');
      }
    } else if (action == 'history') {
      // 截图/取证用：展开「最近查询」（搜索框聚焦且输入为空），
      // 用于验证小窗口下历史列表展开态无溢出。
      if (Platform.environment['ESW_AUTO_RESIZE'] == '1') {
        await windowManager.setSize(const Size(900, 600));
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      _searchController.clear();
      _searchFocus.requestFocus();
      if (mounted) setState(() {});
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    } else if (action == 'winning') {
      final doc = Platform.environment['ESW_AUTO_DOC'];
      if (doc != null && File(doc).existsSync()) {
        try {
          _savedImportedText = await _readFileTextCached(doc);
          _importedFileName = p.basename(doc);
          // 模拟「导入文档后进入查词」：输入框保存被检测文本，便于 _openImportedWord 留存
          _searchController.text = _savedImportedText;
        } catch (_) {}
      }
      final word = Platform.environment['ESW_AUTO_QUERY'] ?? 'winning';
      w('word.begin=$word len=${_savedImportedText.length} '
          'idx=${_savedImportedText.toLowerCase().indexOf(word.toLowerCase())}');
      await _openImportedWord(_ImportedWord(
        word: word,
        category: '拓展词',
        frequency: 1,
        isInCorpus: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      w('detect.done results=${_filteredResults.length} '
          'right=$_rightPanelVisible');
      if (_filteredResults.isNotEmpty) {
        final row = _filteredResults.firstWhere(
          (r) => r.keyword.toLowerCase() == word.toLowerCase(),
          orElse: () => _filteredResults.first,
        );
        w('click.row ${row.source} kw=${row.keyword} off=${row.matchOffset}');
        await _showResultInRightReader(row);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        w('after.click right=$_rightPanelVisible kw=$_rightPanelKeyword '
            'focus=$_corpusFocusPath items=${_corpusDisplayItems().length} '
            'open=${_corpusReaderOpen.length} collapsed=$_builtinCollapsed '
            'pixels=${_rightScrollController.hasClients ? _rightScrollController.offset.toStringAsFixed(1) : -1}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      if (Platform.environment['ESW_AUTO_RESIZE'] == '1') {
        await windowManager.setSize(const Size(900, 600));
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
    } else if (action == 'maximize') {
      for (var i = 0; i < 2; i++) {
        w('maximize ${DateTime.now().microsecondsSinceEpoch}');
        await windowManager.maximize();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        w('unmaximize ${DateTime.now().microsecondsSinceEpoch}');
        await windowManager.unmaximize();
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    } else if (action == 'resize') {
      for (var i = 0; i < 2; i++) {
        w('resize.small ${DateTime.now().microsecondsSinceEpoch}');
        await windowManager.setSize(const Size(920, 620));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        w('resize.large ${DateTime.now().microsecondsSinceEpoch}');
        await windowManager.setSize(const Size(1200, 680));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } else if (action == 'export') {
      final doc = Platform.environment['ESW_AUTO_DOC'];
      if (doc != null && doc.isNotEmpty) {
        try {
          final content = await _readFileTextCached(doc);
          if (!mounted) return;
          _searchController.text = content;
          _importedFileName = File(doc).uri.pathSegments.last;
          _importedFilePath = doc;
          _resetWordQueryState();
          w('detect.begin ${DateTime.now().microsecondsSinceEpoch}');
          await _analyzeImportedText();
          w('detect.done words=${_importedWords.length} '
              '${DateTime.now().microsecondsSinceEpoch}');
        } catch (e) {
          w('detect.ERR $e');
        }
      }
      w('export.begin ${DateTime.now().microsecondsSinceEpoch}');
      w('export.state imported=$_inImportedMode '
          'words=${_importedWords.length} counts=$_importedFilterCounts');
      await _exportResultToWord();
      w('export.end ${DateTime.now().microsecondsSinceEpoch}');
    }
    w('action.end ${DateTime.now().microsecondsSinceEpoch}');
  }

  /// 读取窗口当前最大化状态，用于自绘标题栏最大化图标。
  Future<void> _initWindowState() async {
    if (kEswStructureGuardTestMode) return;
    if (!mounted) return;
    final maxed = await windowManager.isMaximized();
    if (mounted && maxed != _isMaximized) {
      setState(() => _isMaximized = maxed);
    }
  }

  /// 标题栏最大化/还原切换。
  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  /// 窗口尺寸变化后文本会重新换行，等布局稳定再按关键词重新定位左右原文，
  /// 避免放大/缩小窗口后高亮词跑出可视区。
  @override
  void onWindowResize() {
    _scheduleReaderReanchor();
  }

  /// Windows 上窗口停止缩放后还会单独发一次 onWindowResized，一并作为重定位信号。
  @override
  void onWindowResized() {
    _scheduleReaderReanchor();
  }

  /// 窗口尺寸变化（含系统 DPI/可用区域变化）统一在布局更新后重定位原文。
  @override
  void didChangeMetrics() {
    _scheduleReaderReanchor();
  }

  void _scheduleReaderReanchor() {
    // 结构守卫测试下不注册定时器，避免留下 pending Timer
    if (kEswStructureGuardTestMode) return;
    _readerReanchorTimer?.cancel();
    _readerReanchorTimer = Timer(
      const Duration(milliseconds: 240),
      () {
        if (mounted) _reanchorReaders();
      },
    );
  }

  /// 标题栏窗口控制按钮（最小化/最大化/关闭）。
  Widget _buildWindowButton(
    IconData icon,
    VoidCallback onTap, {
    bool isClose = false,
  }) {
    return Listener(
      onPointerDown: (_) => setState(() => _windowBtnScale = 0.96), // 第三关 ⑤：按压 .96
      onPointerUp: (_) => setState(() => _windowBtnScale = 1.0),
      onPointerCancel: (_) => setState(() => _windowBtnScale = 1.0),
      child: AnimatedScale(
        scale: _windowBtnScale,
        duration: const Duration(milliseconds: 80), // 第三关 ⑤：80ms
        curve: Curves.easeOut,
        child: SizedBox(
          width: 32,
          height: 26,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: InkWell(
              onTap: onTap,
              hoverColor: const Color(0x0D242427), // hover 底色 rgba(24,24,27,0.05)
              borderRadius: BorderRadius.circular(6),
              child: Icon(
                icon,
                size: 16,
                color: GlassTheme.ink3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 当前是否已导入过真题/教材语料（供"导入提示"判断）。
  bool get _hasCorpusImported =>
      _corpusFiles.isNotEmpty || _textbookFiles.isNotEmpty;

  /// 若全部真题文件来自同一父目录，返回该目录作为语料目录；否则 null。
  String? _deriveCorpusDir() {
    if (_corpusFiles.isEmpty) return null;
    final dirs = _corpusFiles
        .map((f) => File(f.path).parent.path)
        .toSet();
    if (dirs.length != 1) return null;
    return dirs.first;
  }

  /// 弹窗引导用户导入真题或教材（词库同步完成/导出高频前调用）。
  /// 返回 true 表示已具备语料，false 表示用户未导入/取消。
  /// 未导入时明确提示"无法完成真题单词检测"。
  Future<bool> _promptCorpusImport() async {
    if (_hasCorpusImported) return true;
    if (!mounted) return false;
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => _glassDialog(
        EswDialogShell(
          title: '需要真题/教材语料',
          subtitle: '真题单词检测需要真题或教材语料支撑。请先导入真题或教材；若不导入，将无法完成真题单词检测。',
          icon: Icons.folder_open,
          body: const SizedBox.shrink(),
          actions: EswDialogActions(
            children: [
              EswDialogGhostAction(label: '导入教材', onPressed: () => Navigator.pop(dctx, 'textbook')),
              EswDialogPrimaryAction(label: '导入真题', onPressed: () => Navigator.pop(dctx, 'exam')),
              EswDialogTextAction(label: '暂不', onPressed: () => Navigator.pop(dctx, 'later')),
            ],
          ),
        )
      ),
    );
    if (choice == null || choice == 'later') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法完成真题单词检测：未导入真题/教材语料')),
        );
      }
      return false;
    }
    if (choice == 'exam') {
      await _showImportMenu();
    } else {
      await _showTextbookImportMenu();
    }
    if (_hasCorpusImported) return true;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法完成真题单词检测：请先导入真题或教材语料')),
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

  /// 启动同步词库提示：首帧后弹窗提醒"词库可能不是最新"，用户可选择
  /// "去同步"（直接触发 _syncVocab）或"暂不"。
  Future<void> _maybePromptSync() async {
    if (kEswStructureGuardTestMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final goSync = await showDialog<bool>(
        context: context,
        builder: (dctx) => _glassDialog(
          EswDialogShell(
            title: '同步词库',
            subtitle: '词库可能不是最新，请前往词库页同步。',
            icon: Icons.sync,
            body: const SizedBox.shrink(),
            actions: EswDialogActions(
              children: [
                EswDialogTextAction(
                  label: '暂不',
                  onPressed: () => Navigator.pop(dctx, false),
                ),
                EswDialogPrimaryAction(
                  label: '去同步',
                  onPressed: () => Navigator.pop(dctx, true),
                ),
              ],
            ),
          ),
        ),
      );
      if (goSync == true && mounted) {
        await _syncVocab();
      }
    });
  }

  /// 性能自测探针脚本（仅当设置环境变量 ESW_PERF_PROBE 时执行）。
  ///
  /// 采集项：① 拓展词弹窗候选词生成耗时（含全量展开）；② 词库列表搜索
  /// 过滤耗时（全量重建）；③ 词库列表弹窗打开首帧与逐字输入帧耗时；
  /// ④ 配置写盘耗时；⑤ 主界面鼠标横扫（hover）期间帧耗时。
  /// 结果同时打印 stdout 并写入 ESW_PERF_LOG 指向的文件，便于前后对比。
  Future<void> _runPerfProbe() async {
    if (!EswPerf.enabled || kEswStructureGuardTestMode) return;
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    EswPerf.log('== ESW 性能探针 ==  '
        'standard=${_standardWords.length}  extend=${_extendWords.length}  '
        'chaoGang=${_manualChaoGangWords.length}  extra=${_manualExtraWords.length}');
    EswPerf.log('启动预热 开关='
        '${Platform.environment['ESW_NO_WARMUP'] == '1' ? '关闭(ESW_NO_WARMUP=1)' : '开启'}  '
        '已调度=$_wordBankWarmUpScheduled  已执行=$_wordBankWarmedUp');
    await EswPerf.flush();

    // ① 拓展词弹窗「课标词原词」候选生成（输入热路径）
    //    同机同轮直接对比：优化前实现快照（Legacy，每次 toLowerCase + 未缓存词干）
    //    vs 优化后实现（小写词表/词干预计算 + 候选结果记忆）
    for (final t in <String>['', 'a', 'ab', 'abili', 'undergo']) {
      EswPerf.bench('candidatesLegacy("$t")', 10,
          () => _extendDialogCandidatesLegacy(t, 'ability').length);
      EswPerf.bench('candidates("$t")', 10,
          () => _extendDialogCandidates(t, 'ability').length);
    }
    // 冷路径（记忆未命中，即真实逐字输入首帧）单次成本对照
    EswPerf.bench('candidatesColdLegacy("abili")', 10,
        () => _extendDialogCandidatesLegacy('abili', 'ability').length);
    EswPerf.bench('candidatesCold("abili")', 10, () {
      _extendCandMemoKey = null;
      _extendCandMemoValue = null;
      return _extendDialogCandidates('abili', 'ability').length;
    });
    await EswPerf.flush();

    // ② 词库列表（拓展词汇 7756 词）搜索过滤：每次输入全量重建
    for (final s in <String>['', 'a', 'st']) {
      EswPerf.bench('bankFilterLegacy("$s")', 10,
          () => _bankSearchListLegacy(_extendWords, s).length);
      EswPerf.bench('bankFilter("$s")', 10,
          () => _bankSearchList(_extendWords, s).length);
    }
    // 冷路径（记忆未命中）：等价于逐字输入时的真实单次过滤成本
    EswPerf.bench('bankFilterColdLegacy("star")', 10,
        () => _bankSearchListLegacy(_extendWords, 'star').length);
    EswPerf.bench('bankFilterCold("star")', 10, () {
      _bankMemoValue = null;
      _bankMemoSource = null;
      return _bankSearchList(_extendWords, 'star').length;
    });
    // ③ 配置写盘（jsonEncode 614KB + 落盘）：首次为全量编码，后续命中片段缓存
    await EswPerf.flush();
    EswPerf.bench('saveConfig', 3, () {
      _saveConfig();
      return 1;
    });
    await EswPerf.flush();

    // ④-0 【诊断】把「首次打开词库弹窗」的一次性开销做归因切分：
    //     先测「空路由弹窗」（仅遮罩 + 空内容）、再测「仅玻璃外壳弹窗」，
    //     最后才测真实词库弹窗 —— 用于判定开销挂在路由机制 / 玻璃壳 / 列表内容。
    EswPerf.logEachFrame = true;
    EswPerf.mark('bare#1');
    final bare1 = await EswPerf.openLatency('probeBareDialog#1',
        () async => unawaited(_probeOpenBareDialog()));
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await Future<void>.delayed(const Duration(milliseconds: 260));
    final bare2 = await EswPerf.openLatency('probeBareDialog#2',
        () async => unawaited(_probeOpenBareDialog()));
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await Future<void>.delayed(const Duration(milliseconds: 260));
    final shell1 = await EswPerf.openLatency('probeShellDialog#1',
        () async => unawaited(_probeOpenShellDialog()));
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await Future<void>.delayed(const Duration(milliseconds: 260));
    EswPerf.log('归因(首帧墙钟) bare#1=${bare1.toStringAsFixed(1)}ms  '
        'bare#2=${bare2.toStringAsFixed(1)}ms  '
        'shell#1=${shell1.toStringAsFixed(1)}ms');
    await EswPerf.flush();
    EswPerf.logEachFrame = false;

    // ④ 打开词库列表弹窗（#1 首次：含着色器编译/字形缓存/首帧一次性开销）
    //    除帧耗时统计外，另测「发起打开 → 首帧开始构建」的墙钟耗时（可信指标），
    //    并逐帧打印 build/raster 明细，用于定位停顿落在 UI 构建还是光栅阶段。
    //    注：引擎 FrameTiming 为批量延迟投递，「批次投递」数值不代表用户可见耗时。
    EswPerf.logEachFrame = true;
    var open1 = -1.0;
    EswPerf.mark('bank#1');
    await EswPerf.recordFrames('bankDialogOpen#1(cold)', () async {
      open1 = await EswPerf.openLatency(
        'bankDialogOpen#1(首次打开)',
        () async => unawaited(_showExtendWordsDialog()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    EswPerf.logEachFrame = false;
    // ⑤ 弹窗内逐字输入（真实代码路径：setDialogState → 过滤 + 列表重建）
    //    先热身一轮（首轮含一次性开销：着色器编译、字形缓存、首帧模糊层），
    //    再计量一轮，得到的才是「逐字输入」本身的帧耗时。
    final driver = EswPerf.bankSearchDriver;
    EswPerf.log('bankSearchDriver=${driver != null}');
    if (driver != null) {
      await EswPerf.recordFrames('bankDialogTypingWarmup', () async {
        for (final t in <String>['s', 'st', 'sta']) {
          driver(t);
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      });
      await EswPerf.recordFrames('bankDialogTyping', () async {
        for (final t in <String>[
          'star', 'start', 'starte', 'started', 'starter', 'starters',
        ]) {
          driver(t);
          await Future<void>.delayed(const Duration(milliseconds: 90));
        }
      });
    }
    await EswPerf.flush();
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // ⑥ 再次打开同一词库弹窗（热态）：验证首次停顿是否属于一次性开销
    EswPerf.logEachFrame = true;
    var open2 = -1.0;
    await EswPerf.recordFrames('bankDialogOpen#2(warm)', () async {
      open2 = await EswPerf.openLatency(
        'bankDialogOpen#2(第二次打开)',
        () async => unawaited(_showExtendWordsDialog()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    EswPerf.logEachFrame = false;
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // ⑦ 主界面鼠标横扫：触发 hover 高亮 / 渐变 / 玻璃模糊层重绘
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    await EswPerf.recordFrames('mainHoverSweep', () => EswPerf.hoverSweep(size));
    EswPerf.log('== 首开对比(首帧墙钟) ==  启动预热='
        '${Platform.environment['ESW_NO_WARMUP'] == '1' ? '关闭' : '开启'}  '
        '首次打开=${open1 < 0 ? "未测" : "${open1.toStringAsFixed(1)}ms"}  '
        '第二次打开=${open2 < 0 ? "未测" : "${open2.toStringAsFixed(1)}ms"}');
    EswPerf.log('== ESW 性能探针结束 ==');
    await EswPerf.flush();
  }

  // ==================== 启动预热：词库弹窗首开一次性开销 ====================
  // 取证结论（引擎时间线 + 屏幕截图双重取证）：
  //   旧探针把「首开」记为 ~1003~1041ms 属**指标伪影**——引擎 FrameTiming 是
  //   批量延迟投递的，等「前 2 帧上报」得到的 1s 只是投递延迟。真实数据：
  //   · 首开首帧墙钟 ≈15ms（空路由弹窗 ≈11ms，即真实弹窗仅多 ~4ms）；
  //   · 首开动画跨度 ≈146~162ms / 16~17 帧，与二次打开（≈144ms）一致；
  //   · 首开首帧 build≈8.7ms / raster≈2.8ms，无一次性光栅尖峰；
  //   · 截图实测：发起打开后 ~60ms 内遮罩+弹窗已上屏。
  //   即进程内首开**不存在 1s 一次性停顿**，无需渲染管线预热。
  // 做法：仅保留零成本的数据侧预热（词表快照 + 全量过滤，实测 0ms）；
  //   渲染侧「不可见同构图层」预热默认关闭（实测对首开无收益，而其自身首帧
  //   raster≈428ms，反而存在启动后 ~300ms 交互期的卡顿风险），
  //   需要 A/B 复现时设 `ESW_WARMUP_RENDER=1` 开启。
  // 开关：`ESW_NO_WARMUP=1` 整体关闭数据预热（仅性能 A/B 用，不影响业务）。

  /// 首帧后延迟多久开始预热（毫秒）：保证启动流程与主界面首屏绝对优先。
  static const int wordBankWarmUpDelayMs = 300;

  /// 预热是否已调度（避免重复注册首帧回调）。
  bool _wordBankWarmUpScheduled = false;

  /// 预热是否已执行（进程内只做一次）。
  bool _wordBankWarmedUp = false;

  /// 调度启动预热：注册在首帧渲染完成之后，再延迟 [wordBankWarmUpDelayMs]
  /// 执行。测试模式下不注册（避免留下 pending Timer / 额外帧）。
  void _scheduleWordBankWarmUp() {
    if (_wordBankWarmUpScheduled || kEswStructureGuardTestMode) return;
    if (Platform.environment['ESW_NO_WARMUP'] == '1') {
      EswPerf.log('warmup(bankDialog) 已由 ESW_NO_WARMUP=1 关闭');
      return;
    }
    _wordBankWarmUpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future<void>.delayed(const Duration(milliseconds: wordBankWarmUpDelayMs), () {
        if (!mounted) return;
        unawaited(_warmUpWordBankDialog());
      });
    });
  }

  /// 执行预热：
  /// ① 数据侧 —— 按词库弹窗打开时的同一代码路径做一次词表快照 + 全量过滤；
  /// ② 渲染侧 —— 在根 Overlay 插入不可见的同构图层，真实绘制两帧后移除。
  Future<void> _warmUpWordBankDialog() async {
    if (_wordBankWarmedUp || !mounted) return;
    _wordBankWarmedUp = true;
    final sw = Stopwatch()..start();
    try {
      // ① 数据快照预热：与 _showWordListDialog 打开时同一路径（整表拷贝 +
      //    全量过滤），使首次打开的过滤命中已就绪的缓存。
      final snapshot = List<String>.from(_extendWords);
      EswPerf.sink += _bankSearchList(snapshot, '').length;
      EswPerf.sink += snapshot.length;
      final dataMs = sw.elapsedMilliseconds;
      // ② 渲染管线预热（默认关闭）：实测对首开无收益——首开首帧 raster 仅
      //    2.8ms，无一次性光栅尖峰；而本图层自身首帧 raster≈428ms。保留代码
      //    供 A/B 复现，`ESW_WARMUP_RENDER=1` 开启。
      if (Platform.environment['ESW_WARMUP_RENDER'] == '1') {
        final overlay = Overlay.of(context, rootOverlay: true);
        final entry = OverlayEntry(builder: (_) => _buildWordBankWarmUpLayer());
        await EswPerf.recordFrames('warmup(bankDialog) layer', () async {
          overlay.insert(entry);
          // 绘制两帧后移除：第一帧完成布局+绘制+光栅（预热发生在此帧），
          // 第二帧确认合成稳定；随后立即移除，不给用户留下任何残留图层。
          await _waitFrames(2);
          entry.remove();
        });
      } else {
        EswPerf.log('warmup(bankDialog) 渲染图层预热默认关闭（实测无收益）'
            '，A/B 复现请设 ESW_WARMUP_RENDER=1');
      }
      EswPerf.log('warmup(bankDialog)  数据=${dataMs}ms  '
          '图层+总计=${sw.elapsedMilliseconds}ms');
    } catch (e) {
      // 预热失败必须对用户完全透明：只记日志，不抛出、不影响任何功能
      EswPerf.log('warmup(bankDialog) 失败已忽略: $e');
    }
  }

  /// 等待 [count] 帧绘制结束（预热图层需真实完成布局/绘制/光栅后再移除）。
  Future<void> _waitFrames(int count) async {
    for (var i = 0; i < count; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// 词库弹窗的「不可见同构预热图层」：弹窗外壳、玻璃模糊、投影、圆角裁剪、
  /// 搜索框、词条行、底部按钮全部复用弹窗真实组件，仅整体降到 0.4% 不透明度
  /// 并忽略指针事件 —— 肉眼不可分辨、不接收任何交互、不进入语义树。
  Widget _buildWordBankWarmUpLayer() {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Opacity(
          opacity: 0.004,
          child: _glassDialog(
            EswDialogShell(
              width: 560,
              icon: Icons.menu_book_outlined,
              titleWidget: Text(
                '拓展词汇（共${_extendWords.length}个）',
                style: EswDialog.titleStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _SyncDialogCloseButton(onPressed: () {}),
              // 与词库列表弹窗一致：列表自带滚动体，禁用外层整体滚动
              scrollable: false,
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: kGap8),
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: '搜索单词...',
                        prefixIcon: Icon(Icons.search, size: 18),
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(6)),
                        ),
                      ),
                    ),
                  ),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 440),
                      child: ListView.builder(
                        padding: const EdgeInsets.only(right: kGap12),
                        shrinkWrap: true,
                        itemCount: _wordBankWarmUpRows,
                        itemBuilder: (_, i) => _buildWordBankWarmUpRow(i),
                      ),
                    ),
                  ),
                ],
              ),
              actions: EswDialogActions(
                children: [
                  EswDialogGhostAction(label: '超标词', onPressed: () {}),
                  EswDialogGhostAction(label: '专有词', onPressed: () {}),
                  EswDialogPrimaryAction(label: '删除', onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 预热列表行数：与真实弹窗首屏可视行数同量级（足够触发列表行、下划线
  /// 文本、复选框的首次光栅，又不额外增加可见工作量的开销）。
  static const int _wordBankWarmUpRows = 14;

  Widget _buildWordBankWarmUpRow(int i) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              '${i + 1}.',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12.5, color: GlassTheme.ink2),
            ),
          ),
          const SizedBox(width: kGap8),
          GlassPressable(
            radius: GlassTheme.rMd,
            hoverColor: const Color(0x0A18181B),
            pressColor: const Color(0x294462F2),
            enabled: true,
            child: InkWell(
              onTap: () {},
              child: Text(
                'warmup$i',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                  color: GlassTheme.accentInk,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
          const SizedBox(width: kGap8),
          const Checkbox(
            value: false,
            onChanged: null,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// 截图自查钩子：仅当环境变量 ESW_SHOT_DIALOG 指定弹窗名时，启动 5 秒后
  /// 打开对应弹窗，供自动化截图对照视觉（未设置时零影响，不改变任何业务逻辑）。
  Future<void> _maybeOpenShotDialog() async {
    final which = Platform.environment['ESW_SHOT_DIALOG'];
    if (which == null || which.isEmpty) return;
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    switch (which) {
      case 'export':
        // 「导出高频」格式选择弹窗
        await _exportHighFreq();
        break;
      case 'sync':
        await _maybePromptSync();
        break;
      case 'help':
        _showHelp();
        break;
      case 'corpus':
        await _promptCorpusImport();
        break;
      case 'wordlist':
        await _showExtendWordsDialog();
        break;
      case 'extend':
        await _showExtendWordDialog(extendWord: 'ability');
        break;
      case 'editword':
        // 「修改单词」弹窗（原文面板选中词 → 修改）。若无原文内容，先铺一段
        // 示例文本，使弹窗与真实触发路径完全一致（仅截图自查用）。
        if (_rightHighlightController == null) {
          setState(() {
            _rightPanelVisible = true;
            _rightPanelTitle = '示例原文';
            _rightPanelKeyword = '';
            _rightPanelRow = null;
            _rightHighlightController = _HighlightController(
              'The abandoned house was quiet at dawn.',
              '',
            );
          });
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!mounted) return;
        }
        await _editRightPanelWord('abandoned', 4, 13);
        break;
      case 'extendRoot':
        // 拓展词关联弹窗（带自定义标题：修改 xxx 的课标词根）
        await _showExtendWordDialog(
          extendWord: 'timer',
          dialogTitle: '修改 "timer" 的课标词根',
        );
        break;
      case 'update':
        _showUpdateResult('检查更新失败，请稍后重试');
        break;
      case 'largeDel':
        await _confirmLargeDelete(context, 12, 120, true);
        break;
      case 'classify':
        await _startClassifyBatch(
          const _ImportedWord(
            word: 'ability',
            category: '拓展词',
            frequency: 3,
            isInCorpus: true,
          ),
        );
        break;
      case 'conflict':
        await _showSyncConflictDialog(<dynamic>[
          <String, dynamic>{
            'word': 'ability',
            'old_category': '拓展词',
            'new_category': '超标词',
            'reason': 'category_changed',
          },
          <String, dynamic>{
            'word': 'timer',
            'old_category': '超标词',
            'new_category': '拓展词',
            'reason': 'category_changed',
          },
        ]);
        break;
      case 'extraList':
        // 词库列表弹窗（专有词汇，未选状态）
        await _showExtraWordsDialog();
        break;
      case 'extraListSel':
        // 词库列表弹窗（专有词汇，已选状态：预置全部词条勾选）
        await _showExtraWordsDialog(
          initialSelected: List<String>.from(_manualExtraWords),
        );
        break;
      case 'extendList':
        // 词库列表弹窗（拓展词汇，未选状态：行内编辑按钮可见）
        await _showExtendWordsDialog();
        break;
      case 'extendListSel':
        // 词库列表弹窗（拓展词汇，已选 1 个）
        await _showExtendWordsDialog(
          initialSelected: _extendWords.isEmpty
              ? const <String>[]
              : <String>[_extendWords.first],
        );
        break;
      case 'extendListSelMany':
        // 词库列表弹窗（拓展词汇，已选多个）
        await _showExtendWordsDialog(
          initialSelected: _extendWords.take(3).toList(),
        );
        break;
    }
  }

  void _onSearchFocusChange() {
    // 聚焦瞬间：若输入框文本仍是最近一次已查询的单词，则清空输入框，
    // 退出当前单词、进入新查询状态（使历史下拉按"聚焦+输入为空"条件显示）。
    // 仅在"聚焦且文本等于上次查询词"时清空一次；手动编辑中失焦再聚焦不会误伤。
    if (_searchFocus.hasFocus) {
      final raw = _searchController.text.trim();
      if (_detectedWord.isNotEmpty &&
          raw.isNotEmpty &&
          raw.toLowerCase() == _detectedWord.toLowerCase()) {
        _searchController.clear();
        _searchController.selection = const TextSelection.collapsed(offset: 0);
      }
    }
    if (mounted) setState(() {});
  }

  void _initDragDrop() {
    // 结构守卫测试模式：跳过 FFI 拖放轮询，避免测试环境残留 pending Timer。
    if (kEswStructureGuardTestMode) return;
    // 1000ms 轮询一次拖放：原 300ms 在无拖拽时也持续调用原生指针查询，
    // 24 小时空转约 28.8 万次平台调用，是常态 CPU 开销来源之一；
    // 降频后拖放检测延迟最大 1 秒，交互无感。
    Timer.periodic(const Duration(milliseconds: 1000), (_) {
      final ptr = _getDroppedFile();
      if (ptr != nullptr) {
        final path = ptr.toDartString();
        _handleDroppedFile(path);
      }
    });
  }

  Future<void> _initOcr() async {
    final sw = Stopwatch()..start();
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      _tesseractPath = '$exeDir\\tesseract\\tesseract.exe';
      _tessdataPath = '$exeDir\\tesseract\\tessdata';
      _ocrReady = await File(_tesseractPath!).exists();
    } catch (_) {
      _ocrReady = false;
    }
    EswPerf.bootDt('initOcr(ocrReady=$_ocrReady)', sw);
  }

  /// 课标词数据：{word: {category, pos, def}}，key 为原始大小写
  Map<String, Map<String, String>> _standardWords = {};

  /// 大小写不敏感索引：{lowercase → [原始大小写...]}
  final Map<String, List<String>> _standardWordsLower = {};

  /// 拓展词反向索引：{extension_word → base_word}（JSON预定义+用户手动添加）
  final Map<String, String> _extendReverseIndex = {};

  /// 性能索引
  Set<String> _standardWordsLowerKeySet = {}; // 小写 key 集合（用于 contains 检查）
  final Map<String, List<String>> _wordsByFirstChar = {};
  // ======== 配置持久化 ========
  Future<void> _loadConfig() async {
    final sw = Stopwatch()..start();
    try {
      // 配置读取策略（跨机器可运行性）：
      // ① 首选用户目录 %LOCALAPPDATA%\ESW\esw_config.json（始终可写）；
      // ② 首次运行（用户目录还没有配置）时按顺序迁移旧位置：exe 同目录
      //    esw_config.json → 更早的 eva_config.json（老用户目录同名文件）；
      // ③ 全部不存在则按默认值启动。
      // 注意：不再引用开发机硬编码绝对路径（D:\UserData\Desktop\eva\...）——
      // 在别人电脑上该路径必然不存在，且探测网络/不存在盘符的路径会拖慢首启。
      // 全部 IO 改为异步：原同步读写（实测 ~45ms，含 jsonDecode）会在首帧前
      // 阻塞 UI 线程，异步化后首帧不再等待磁盘。
      var f = File(_configPath);
      if (!await f.exists()) {
        final legacyCandidates = <String>[
          _legacyConfigPath,
          _legacyEvaConfigPath(),
        ];
        for (final cand in legacyCandidates) {
          if (cand.isEmpty) continue;
          final cf = File(cand);
          if (await cf.exists()) {
            try {
              await cf.copy(_configPath);
            } catch (_) {}
            if (await f.exists()) break;
          }
        }
      }
      if (!await f.exists()) {
        EswPerf.bootDt('loadConfig(无配置文件)', sw);
        return;
      }
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      // 迁移旧版配置：lastImportPath → lastExamImportPath
      _lastExamImportPath =
          json['lastExamImportPath'] as String? ??
          json['lastImportPath'] as String?;
      _lastDocImportPath =
          json['lastDocImportPath'] as String? ??
          json['lastImportPath'] as String?;
      _lastTextbookImportPath = json['lastTextbookImportPath'] as String?;
      // 记忆的教材导入目录已不存在时重置，避免文件选择器定位到无效路径
      if (_lastTextbookImportPath != null &&
          !await Directory(_lastTextbookImportPath!).exists()) {
        _lastTextbookImportPath = null;
      }
      _lastImportMode = json['lastImportMode'] as String?;
      // 内置真题分组的显示偏好（隐藏 / 折叠）
      _builtinHidden = json['builtinHidden'] as bool? ?? false;
      _builtinCollapsed = json['builtinCollapsed'] as bool? ?? false;
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
        _extendReverseIndex[entry.key.toLowerCase()] = entry.value
            .toLowerCase();
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
      // 配置与旧版合并完成后重建拓展词小写索引（新增/合并的词一并纳入）
      _extendWordsLower
        ..clear()
        ..addAll(_extendWords.map((e) => e.toLowerCase()));
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
      // 恢复用户主动导入的真题文件：只认本应用内导入并记录到配置的路径，
      // 不读取任何外部固定目录；路径失效的条目静默跳过。
      // 同名内置项由 _initBuiltinCorpus 的既有合并规则归并（内置优先）。
      final icp = json['importedCorpusPaths'];
      if (icp is List && icp.isNotEmpty) {
        final validPaths = await ImportedCorpusRestore.existingPaths(
          icp.map((e) => e.toString()),
        );
        if (validPaths.isNotEmpty) {
          _userCorpusFiles = [
            for (final path in validPaths)
              CorpusFile(
                name: File(path).uri.pathSegments.last,
                path: path,
              ),
          ];
          _rebuildCorpusList();
        }
      }
      // 恢复用户主动导入的教材文件列表（路径失效的自动跳过，不崩溃）
      final itp = json['importedTextbookPaths'];
      if (itp is List && itp.isNotEmpty) {
        final validPaths = await ImportedCorpusRestore.existingPaths(
          itp.map((e) => e.toString()),
        );
        if (validPaths.isNotEmpty) {
          _textbookFiles = [
            for (final path in validPaths)
              CorpusFile(
                name: File(path).uri.pathSegments.last,
                path: path,
              ),
          ];
          // 教材默认全部勾选，便于直接参与"同时检测真题和教材"
          for (final f in _textbookFiles) {
            f.isSelected = true;
          }
          // 同步恢复导入目录记忆，便于下次打开文件选择器定位
          _lastTextbookImportPath = File(validPaths.first).parent.path;
        }
      }
      await _mergeOldConfig();
    } catch (_) {}
    // 配置已在首帧之后异步就绪：补一次重建，让历史词 / 扩展词等
    // 依配置恢复的界面元素及时反映出来。
    if (mounted) setState(() {});
    EswPerf.bootDt('loadConfig', sw);
  }

  /// 将旧版 eva_config.json 中的增量数据合并到当前状态，确保无数据丢失。
  /// 仅当该旧文件存在时才读取（一次异步 stat），不存在时零开销。
  /// 跨机器可运行性：路径由 exe 同目录推导（原为开发机硬编码绝对路径）。
  Future<void> _mergeOldConfig() async {
    try {
      final oldPath = _legacyEvaConfigPath();
      if (oldPath.isEmpty) return;
      final oldFile = File(oldPath);
      if (!await oldFile.exists()) return;
      final old =
          jsonDecode(await oldFile.readAsString()) as Map<String, dynamic>;
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

  Timer? _saveConfigTimer;

  /// 高频路径的配置持久化防抖：连续操作（如逐词查询写入历史）在 800ms
  /// 窗口内合并为一次写盘，避免每次查询都 jsonEncode + 同步写盘阻塞 UI 线程。
  void _saveConfigDebounced() {
    _saveConfigTimer?.cancel();
    _saveConfigTimer = Timer(const Duration(milliseconds: 800), () {
      _saveConfigTimer = null;
      _saveConfig();
    });
  }

  // 任务④（运行速度）：配置写盘是高频主线程路径（每次标注/导入/改类都会调用，
  // 一次性全量 jsonEncode 约 20ms，直接体现为卡顿）。这里改为「按字段浅比较 +
  // JSON 片段缓存」：内容未变的字段复用上次编码好的片段，只对真正变化的字段
  // 重新编码。浅比较是逐元素比对（不是哈希近似），因此生成结果与
  // 原实现的全量 jsonEncode 逐字节一致；稳态下省掉几乎全部编码开销。
  final Map<String, Object?> _cfgFragSnap = <String, Object?>{};
  final Map<String, String> _cfgFragJson = <String, String>{};

  /// 配置写盘链：把每次保存串起来（最后一次覆盖前面），保证不会并发交错写。
  Future<void>? _configWrite;

  bool _cfgSameValue(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || b[k] != a[k]) return false;
      }
      return true;
    }
    return a == b;
  }

  String _cfgFrag(String key, Object? value) {
    final cached = _cfgFragJson[key];
    if (cached != null && _cfgSameValue(_cfgFragSnap[key], value)) {
      return cached;
    }
    final encoded = jsonEncode(value);
    _cfgFragSnap[key] = value is List
        ? List<Object?>.from(value)
        : (value is Map ? Map<Object?, Object?>.from(value) : value);
    _cfgFragJson[key] = encoded;
    return encoded;
  }

  void _saveConfig() {
    try {
      final buf = StringBuffer('{');
      var first = true;
      void put(String key, Object? value) {
        if (!first) buf.write(',');
        first = false;
        buf.write('"');
        buf.write(key);
        buf.write('":');
        buf.write(_cfgFrag(key, value));
      }

      put('lastExamImportPath', _lastExamImportPath);
      put('lastDocImportPath', _lastDocImportPath);
      put('lastTextbookImportPath', _lastTextbookImportPath);
      put('lastImportMode', _lastImportMode);
      put('builtinHidden', _builtinHidden);
      put('builtinCollapsed', _builtinCollapsed);
      put('lastExportPath', _lastExportPath);
      put('wordHistory', _wordHistory);
      // 仅记录用户在本应用内主动导入的语料文件（内置 119 套由内置链路释放，不写这里）
      put('importedCorpusPaths', _userCorpusFiles.map((f) => f.path).toList());
      put('importedTextbookPaths', _textbookFiles.map((f) => f.path).toList());
      put('extendWords', _extendWords);
      put('extendBaseMap', _extendBaseMap);
      put('manualChaoGangWords', _manualChaoGangWords.toList());
      put('manualExtraWords', _manualExtraWords.toList());
      put('classificationMemory', _classificationMemory);
      put('userId', _userId);
      put('processedFilePaths', _processedFilePaths.toList());
      buf.write('}');
      // 串行化写盘：避免多次保存并发写同一文件导致内容交错（写入顺序 = 调用
      // 顺序，最后一次写覆盖前面），同时吞掉 IO 异常避免未捕获异步报错。
      final text = buf.toString();
      _configWrite = (_configWrite ?? Future<void>.value()).then((_) async {
        try {
          await File(_configPath).writeAsString(text);
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<void> _loadStandardWords() async {
    final swAll = Stopwatch()..start();
    try {
      // 用 rootBundle.load 取字节再自行 utf8 解码：与 loadString 语义等价
      // （loadString 内部就是 load + utf8.decode），拆开是为了把「IO 等待」
      // 与「解码 CPU」分别归因到启动阶段打点上。
      final data = await rootBundle.load('assets/standard_words.json');
      EswPerf.bootDt('loadStandardWords.assetLoad', swAll);
      final swDec = Stopwatch()..start();
      final jsonStr = utf8.decode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      EswPerf.bootDt('loadStandardWords.utf8Decode', swDec);
      final sw = Stopwatch()..start();
      final raw = json.decode(jsonStr) as Map<String, dynamic>;
      EswPerf.bootDt('loadStandardWords.decode(${raw.length} 词条)', sw);
      final swIdx = Stopwatch()..start();
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
      EswPerf.bootDt(
        'loadStandardWords.index(拓展词 ${_extendReverseIndex.length})',
        swIdx,
      );
      EswPerf.bootDt('loadStandardWords.total', swAll);
    } catch (_) {
      _standardWords = {};
    }
  }

  @override
  void dispose() {
    // 退出前落盘防抖中的配置与内存调试日志，避免丢失最后一次状态
    if (_saveConfigTimer != null) {
      _saveConfigTimer?.cancel();
      _saveConfig();
      _saveConfigTimer = null;
    }
    _flushDebugLog();
    _searchController.dispose();
    _searchFocus.dispose();
    _rightHighlightController?.dispose();
    _rightScrollController.dispose();
    _corpusListScrollController.dispose();
    _textbookListScrollController.dispose();
    _readerReanchorTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final c in _corpusReaderControllers.values) {
      c.dispose();
    }
    for (final s in _corpusReaderScrolls.values) {
      s.dispose();
    }
    // 关闭常驻扫描 worker isolate，释放后台线程与内存
    _scanResultPort?.close();
    _scanWorker?.kill(priority: Isolate.immediate);
    super.dispose();
  }

  // 弹出导入方式菜单（居中于按钮正下方）
  Future<void> _showImportMenu() async {
    if (_leftPanelIsTextbook) {
      setState(() => _leftPanelIsTextbook = false);
    }
    final ctx = _importBtnKey.currentContext ?? _leftHeaderKey.currentContext;
    final RenderBox box = ctx!.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero);
    final centerX = offset.dx + box.size.width / 2;
    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'folder', child: Text('导入文件夹')),
      const PopupMenuItem(value: 'files', child: Text('导入文件')),
    ];
    final mode = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        centerX - 50,
        offset.dy + box.size.height,
        centerX + 50,
        0,
      ),
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
        if (ext.endsWith('.txt') ||
            ext.endsWith('.doc') ||
            ext.endsWith('.docx') ||
            ext.endsWith('.pdf')) {
          files.add(
            CorpusFile(name: entity.uri.pathSegments.last, path: entity.path),
          );
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
      allowedExtensions: ['txt', 'doc', 'docx', 'pdf'],
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

  // ==================== 教材导入（txt/doc/docx，可多选，可勾选） ====================
  Future<void> _showTextbookImportMenu() async {
    if (!_leftPanelIsTextbook) {
      setState(() => _leftPanelIsTextbook = true);
    }
    final ctx =
        _textbookBtnKey.currentContext ?? _leftHeaderKey.currentContext;
    final RenderBox box = ctx!.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero);
    final centerX = offset.dx + box.size.width / 2;
    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'files', child: Text('导入文件')),
      const PopupMenuItem(value: 'folder', child: Text('导入文件夹')),
    ];
    final mode = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        centerX - 60,
        offset.dy + box.size.height,
        centerX + 60,
        0,
      ),
      items: items,
    );
    if (mode == 'folder') {
      _importTextbookFolder();
    } else if (mode == 'files') {
      _importTextbookFiles();
    }
  }

  Future<void> _importTextbookFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择教材文件',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['txt', 'doc', 'docx', 'pdf'],
      initialDirectory: _lastTextbookImportPath,
    );
    if (result == null || result.files.isEmpty) return;
    final files = <CorpusFile>[];
    for (final f in result.files) {
      if (f.path != null) {
        files.add(CorpusFile(name: f.name, path: f.path!));
      }
    }
    _lastTextbookImportPath = File(files.first.path).parent.path;
    _saveConfig();
    _applyTextbookFiles(files);
  }

  Future<void> _importTextbookFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择教材文件夹',
      initialDirectory: _lastTextbookImportPath,
    );
    if (dir == null || dir.isEmpty) return;
    final dirObj = Directory(dir);
    if (!await dirObj.exists()) return;
    final files = <CorpusFile>[];
    for (final entity in dirObj.listSync(recursive: true)) {
      if (entity is File) {
        final ext = entity.path.toLowerCase();
        if (ext.endsWith('.txt') ||
            ext.endsWith('.doc') ||
            ext.endsWith('.docx') ||
            ext.endsWith('.pdf')) {
          files.add(
            CorpusFile(name: entity.uri.pathSegments.last, path: entity.path),
          );
        }
      }
    }
    _lastTextbookImportPath = dir;
    _saveConfig();
    _applyTextbookFiles(files);
  }

  void _applyTextbookFiles(List<CorpusFile> files) {
    if (files.isEmpty) return;
    files.sort((a, b) => a.name.compareTo(b.name));
    // 退出单词查询模式：若输入框仍为上次查询词则一并清空
    final queryText = _searchController.text.trim();
    if (_detectedWord.isNotEmpty &&
        queryText.toLowerCase() == _detectedWord.toLowerCase()) {
      _searchController.clear();
    }
    setState(() {
      _textbookFiles = files;
      // 导入教材后左栏自动切到教材栏（单栏形态，真题列表整块不占位）
      _leftPanelIsTextbook = true;
      // 教材文件默认全部勾选，便于直接参与"同时检测真题和教材"
      for (final f in _textbookFiles) {
        f.isSelected = true;
      }
      // 导入教材后自动退出单词查询模式，切换/进入文档检测模式
      _detectedWord = '';
      _activeFilter = '真题词';
      _detectedCategory = null;
      _wordPos = '';
      _wordDef = '';
      _yearFrequency.clear();
      _results.clear();
      _textbookResults.clear();
      _filteredResults = [];
      _filteredTextbookResults = [];
      _selectedYear = null;
      _selectedTextbook = null;
    });
    // 持久化已导入教材路径列表，重启后自动恢复
    _saveConfig();
  }

  /// 什.docx 文件中提取纯文本（保留制表符/软换行分隔，与构建脚本共用实现）
  String _readDocxContent(String filePath) {
    return extractDocxText(File(filePath).readAsBytesSync());
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
      // 纯图片 PDF，回退到 OCR；缺少 OCR 组件时明确标记（调用方据此提示用户），
      // 而不是静默返回空串让界面看起来「什么都没检测到」。
      if (!_ocrReady) {
        _lastPdfOcrUnavailable = true;
        return '';
      }
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
      final imgFile = File(
        '${tempDir.path}\\esw_ocr_${DateTime.now().millisecondsSinceEpoch}.png',
      );
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

  /// 缺失资源降级提示（跨机器可运行性）：发布包若缺少 tesseract OCR 组件，
  /// 图片型 PDF 会一个字都读不出来。这里明确告知原因与解法，避免用户误以为
  /// 「文档没内容」或程序坏了。非图片型文档、OCR 正常时什么都不做。
  void _showMissingOcrHintIfNeeded() {
    if (!_lastPdfOcrUnavailable) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '未找到 OCR 组件（tesseract\\tesseract.exe），该 PDF 为扫描图片版，'
          '无法提取文字。请使用完整发布包（含 tesseract 文件夹），'
          '或改用 txt / docx 文档。',
        ),
        duration: Duration(seconds: 8),
      ),
    );
  }

  /// 导入文档内容到输入框
  Future<void> _importDocumentToInput() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择文档（建议优先 txt / docx，可保留原排版标注；doc / pdf 转换后格式可能变化）',
      type: FileType.custom,
      allowedExtensions: ['txt', 'doc', 'docx', 'pdf'],
      initialDirectory: _lastDocImportPath,
    );
    if (result == null || result.files.isEmpty) return;
    final filePath = result.files.single.path;
    if (filePath == null) return;
    final fileName = result.files.single.name;
    // 导入文档前：若未同步筛选词库（extendBaseMap 为空），提醒先同步词库，确保拓展词能映射到课标词
    if (_extendBaseMap.isEmpty) {
      if (!mounted) return;
      final goSync = await showDialog<bool>(
        context: context,
        builder: (ctx) => _glassDialog(
          EswDialogShell(
            title: '词库未同步',
            subtitle: '当前未检测到已同步的筛选词库，导入文档后拓展词将无法映射到课标词，导出结果可能不完整。建议先「同步词库」再导入检测。',
            icon: Icons.cloud_off,
            body: const SizedBox.shrink(),
            actions: EswDialogActions(
              children: [
                EswDialogTextAction(label: '仍然导入', onPressed: () => Navigator.of(ctx).pop(false)),
                EswDialogPrimaryAction(label: '去同步', onPressed: () => Navigator.of(ctx).pop(true)),
              ],
            ),
          )
        ),
      );
      if (goSync == true) {
        await _syncVocab();
        return;
      }
    }
    try {
      final content = await _readFileTextCached(filePath);
      if (mounted) _showMissingOcrHintIfNeeded();
      _searchController.text = content;
      _importedFileName = fileName;
      _importedFilePath = filePath;
      // 导入文档后自动退出单词查询模式，确保导出数据源为文档检测结果
      _resetWordQueryState();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  /// 拖拽文件到输入框时自动读取内容并开始检测
  Future<void> _handleDroppedFile(String filePath) async {
    final ext = filePath.toLowerCase();
    if (!ext.endsWith('.txt') &&
        !ext.endsWith('.docx') &&
        !ext.endsWith('.pdf') &&
        !ext.endsWith('.doc')) {
      return;
    }
    try {
      final content = await _readFileTextCached(filePath);
      if (mounted) _showMissingOcrHintIfNeeded();
      _searchController.text = content;
      _importedFileName = File(filePath).uri.pathSegments.last;
      _importedFilePath = filePath;
      _lastDocImportPath = File(filePath).parent.path;
      _lastImportMode = 'files';
      // 导入文档后自动退出单词查询模式，确保导出数据源为文档检测结果
      _resetWordQueryState();
      await _analyzeImportedText();
      _saveConfig();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  /// 退出单词查询模式：重置查询状态与查询结果数据源，切换到文档检测模式。
  /// 在导入文档（真题/教材/文档到输入框）成功后调用，确保导出数据源为文档检测结果。
  void _resetWordQueryState() {
    setState(() {
      _detectedWord = '';
      _activeFilter = '真题词';
      _detectedCategory = null;
      _wordPos = '';
      _wordDef = '';
      _results.clear();
      _textbookResults.clear();
      _filteredResults = [];
      _filteredTextbookResults = [];
      _selectedYear = null;
      _selectedTextbook = null;
    });
  }

  /// 首启释放内置真题到用户目录，并登记为内置分组。
  /// 任何一步失败都静默降级（左栏只是没有内置分组），不影响手动导入。
  Future<void> _initBuiltinCorpus() async {
    // 结构守卫测试只验证骨架，跳过释放（避免测试写用户目录 2MB 语料）
    if (kEswStructureGuardTestMode) return;
    try {
      final index = await BuiltinCorpus.loadIndex();
      if (index == null) return;
      final paths = await BuiltinCorpus.ensureExtracted(
        baseDir: p.join(_userDataDir, 'corpus'),
        version: index.version,
        papers: index.papers,
      );
      if (paths == null) return;
      final files = <CorpusFile>[];
      for (final paper in index.papers) {
        final path = paths[paper.id];
        if (path == null) continue;
        files.add(
          CorpusFile(name: '${paper.id}.txt', path: path, isBuiltin: true),
        );
      }
      if (files.isEmpty) return;
      _builtinIds = files.map((f) => f.name).toSet();
      if (!mounted) {
        _builtinFiles = files;
        _rebuildCorpusList();
        return;
      }
      setState(() {
        _builtinFiles = files;
        // 内置已覆盖同名文件：用户分组里剔除，避免同一套真题被计两次词频
        _userCorpusFiles = _userCorpusFiles
            .where((f) => !_builtinIds.contains(f.name))
            .toList();
        _rebuildCorpusList();
      });
    } catch (_) {}
  }

  /// 合并「内置 + 用户」语料为下游唯一的 _corpusFiles 视图，并重算年份索引。
  /// 调用方需在 setState 内调用（构造期初始化除外）。
  void _rebuildCorpusList() {
    final merged = <CorpusFile>[
      if (!_builtinHidden) ..._builtinFiles,
      ..._userCorpusFiles,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final yearRegex = _yearPrefixRegex;
    final years = <int>{};
    for (final f in merged) {
      final m = yearRegex.firstMatch(f.name);
      if (m != null) {
        final y = int.parse(m.group(1)!);
        if (y >= 2000 && y <= 2099) years.add(y);
      }
    }
    _corpusFiles = merged;
    _sortedYears = years.toList()..sort((a, b) => b.compareTo(a));
  }

  void _applyCorpusFiles(List<CorpusFile> files) {
    if (files.isEmpty) return;
    files.sort((a, b) => a.name.compareTo(b.name));
    // 内置已收录的同名真题不重复计入（用户导入同源文件夹时归并到内置分组）；
    // 内置被隐藏时仍保留用户副本，保证用户导入的语料可用。
    final userFiles = _builtinHidden
        ? files
        : files.where((f) => !_builtinIds.contains(f.name)).toList();
    // 退出单词查询模式：若输入框仍为上次查询词则一并清空
    final queryText = _searchController.text.trim();
    if (_detectedWord.isNotEmpty &&
        queryText.toLowerCase() == _detectedWord.toLowerCase()) {
      _searchController.clear();
    }
    setState(() {
      _userCorpusFiles = userFiles;
      // 导入真题后左栏切回真题栏
      _leftPanelIsTextbook = false;
      _rebuildCorpusList();
      // 导入真题后自动退出单词查询模式，切换/进入文档检测模式
      _detectedWord = '';
      _activeFilter = '真题词';
      _detectedCategory = null;
      _wordPos = '';
      _wordDef = '';
      _yearFrequency.clear();
      _results.clear();
      _textbookResults.clear();
      _filteredResults = [];
      _filteredTextbookResults = [];
      _selectedYear = null;
      _selectedTextbook = null;
    });
    // 持久化用户主动导入的真题路径列表，重启后自动恢复
    _saveConfig();
  }

  // ---------- 单词检测----------
  /// 点击最近查询历史条目：回填输入框并立即发起检测，再收起下拉与焦点。
  /// 顺序关键：必须基于"被点击的历史词"显式传参发起检测（对齐安卓 _lookupWord(w)
  /// 传参模式），不依赖输入框文本时序——unfocus 触发的重建/监听不影响已发起的
  /// 异步查询，保证必然按被点击的词重新查询并刷新全部结果区。
  void _onHistoryWordTap(String w) {
    _debugLog('[HistoryTap] enter w=$w focus=${_searchFocus.hasFocus} '
        'text="${_searchController.text}"');
    _cancelHistoryTimer();
    _hoverHistoryIndex.value = null;
    _searchController.text = w;
    _searchController.selection = TextSelection.collapsed(
      offset: w.length,
    );
    // 显式传参发起检测：查询词来源 = 被点击的历史词（overrideWord）
    _beginIndependentQuery();
    _onDetect(w);
    _searchFocus.unfocus();
    // 强制重建一次，确保下拉（text 非空 + 失焦）立即关闭
    if (mounted) setState(() {});
    _debugLog('[HistoryTap] done w=$w');
  }

  Future<void> _onDetect([String? overrideWord]) async {
    // ======== 常驻扫描 worker isolate：管理后台扫描 isolate ========
    void onScanWorkerMessage(dynamic msg) {
      final m = msg as Map;
      if (m['type'] == 'scanResult') {
        final reqId = m['reqId'] as int;
        final c = _scanPending.remove(reqId);
        if (c == null) return;
        c.complete((
          rows: (m['rows'] as List).map((r) {
            final rm = r as Map;
            return (
              before: rm['before'] as String,
              keyword: rm['keyword'] as String,
              after: rm['after'] as String,
              source: rm['source'] as String,
              filePath: rm['filePath'] as String,
              matchOffset: rm['matchOffset'] as int,
              sentence: rm['sentence'] as String,
            );
          }).toList(),
          yearFreq: (m['yearFreq'] as Map)
              .map((k, v) => MapEntry(int.parse('$k'), v as int)),
          totalFreq: m['totalFreq'] as int,
        ));
      } else if (m['type'] == 'scanError') {
        final reqId = m['reqId'] as int;
        final c = _scanPending.remove(reqId);
        if (c != null) {
          c.completeError(StateError('scan worker error: ${m['error']}'));
        }
      }
    }

    Future<void> ensureScanWorker() async {
      if (_scanWorkerFailed) throw StateError('scan worker disabled');
      if (_scanWorkerPort != null) return;
      final receivePort = ReceivePort();
      _scanResultPort = receivePort;
      _scanWorker = await Isolate.spawn(_scanWorkerMain, receivePort.sendPort);
      _scanWorkerPort = await receivePort.first
          .timeout(const Duration(seconds: 3));
      receivePort.listen(onScanWorkerMessage);
    }

    /// 在常驻 worker 上执行扫描：文本驻留 worker，重复查词零拷贝零重转。
    /// [texts] 为可选增量同步源：仅当文件版本与 worker 不一致时才重发文本。
    /// worker 不可用（spawn 失败/超时/异常）时自动回退同步扫描，保证结果必出。
    Future<_ScanOut> scanOnWorker(
      String keyword,
      List<_ScanTarget> targets,
      bool includeYears, {
      Map<String, ({String text, int version})>? texts,
    }) async {
      _ScanOut fallbackSync() {
        final textsMap = <String, String>{};
        final lowerMap = <String, String>{};
        texts?.forEach((path, tv) {
          textsMap[path] = tv.text;
          lowerMap[path] = tv.text.toLowerCase();
        });
        return _scanCorpusWorker(
            keyword, targets, includeYears, textsMap, lowerMap);
      }

      try {
        await ensureScanWorker().timeout(const Duration(seconds: 4));
        final toSend = <Map<String, Object>>[];
        if (texts != null) {
          texts.forEach((path, tv) {
            if (_workerTextVersions[path] != tv.version) {
              toSend.add({
                'path': path,
                'text': tv.text,
                'version': tv.version,
              });
            }
          });
        }
        if (toSend.isNotEmpty) {
          _scanWorkerPort!.send({'type': 'updateTexts', 'entries': toSend});
          for (final e in toSend) {
            _workerTextVersions[e['path'] as String] = e['version'] as int;
          }
        }
        final reqId = _scanReqSeq++;
        final completer = Completer<_ScanOut>();
        _scanPending[reqId] = completer;
        _scanWorkerPort!.send({
          'type': 'scan',
          'reqId': reqId,
          'keyword': keyword,
          'targets': [
            for (final t in targets)
              {'path': t.path, 'name': t.name},
          ],
          'includeYears': includeYears,
        });
        return await completer.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            _scanPending.remove(reqId);
            _debugLog('[ScanWorker] scan timeout fallback sync req=$reqId');
            return fallbackSync();
          },
        );
      } catch (e) {
        _scanWorkerFailed = true;
        _debugLog('[ScanWorker] fallback sync: $e');
        return fallbackSync();
      }
    }
    // 捕获本次查询代际：后续任何 await 恢复后若代际已过期，说明用户已发起更新
    // 查询（如快速点击另一条历史），必须丢弃本查询结果，避免旧结果覆盖新结果。
    final seq = ++_querySeq;
    final raw = (overrideWord ?? _searchController.text).trim();
    _debugLog('[Detect] enter seq=$seq raw="$raw" override=$overrideWord '
        'mounted=$mounted');
    if (raw.isEmpty) {
      _debugLog('[Detect] empty-raw return');
      return;
    }
    final word = raw.toLowerCase();
    // 立即反馈：同步清空上一单词的释义/结果区并标记"查询中…"，避免异步扫描期间
    // 旧结果残留，造成"点击没反应 / 显示的还是上一个单词释义"的错觉。
    // 扫描完成后的主 setState 会覆盖以下临时状态，不会与最终结果冲突。
    if (seq == _querySeq && mounted) {
      setState(() {
        _detectedWord = word;
        _activeFilter = '查询中…';
        _detectedCategory = null;
        _wordPos = '';
        _wordDef = '查询中…';
        _yearFrequency.clear();
        _results.clear();
        _textbookResults.clear();
        _filteredResults = [];
        _filteredTextbookResults = [];
        _selectedYear = null;
        _selectedTextbook = null;
      });
      _debugLog('[Detect] sync-querying setState seq=$seq');
    }
    // 1) 查课标词库（大小写敏感；大写写法可命中同名小写词条，反之不行）
    bool isStandard = false;
    String cat = '';
    String pos = '';
    String def = '';
    final standardKey = findWordEntryKey(_standardWords, raw);
    if (standardKey != null) {
      final swEntry = _standardWords[standardKey]!;
      isStandard = true;
      cat = swEntry['category']!;
      pos = swEntry['pos']!;
      def = swEntry['def']!;
    } else if (isWordEntryHit(_standardWords, raw)) {
      // 连字符复合词：各部分均为课标词，整体按课标词处理（无单条级别/释义）
      isStandard = true;
    }
    // 2) 查拓展词（大小写敏感；大写写法可命中同名小写词条）
    final isExtend = matchWordEntryKey(_extendWords.toSet(), raw) != null;
    // 3) 搜索真题语料
    int totalFreq = 0;
    final results = <ResultRow>[];
    final yearFreq = <int, int>{};
    // 并行读取所有选中文件（走缓存，重复查词不再重复解析 docx/pdf）
    final selectedFiles = _corpusFiles.where((f) => f.isSelected).toList();
    final fileTexts = await Future.wait(
      selectedFiles.map((cf) async {
        try {
          final text = await _readFileTextCached(cf.path);
          return (cf, text);
        } catch (_) {
          return null;
        }
      }),
    );
    // 期间用户发起了新查询，本次结果已过期，立即放弃，避免覆盖新查询结果
    if (seq != _querySeq || !mounted) {
      _debugLog('[Detect] stale-return-after-corpus seq=$seq cur=$_querySeq '
          'mounted=$mounted');
      return;
    }
    // 扫描移入常驻后台 worker：文本驻留 worker，重复查词零拷贝零重转
    final scanTargets = [
      for (final e in fileTexts)
        if (e != null) (path: e.$1.path, name: e.$1.name),
    ];
    if (scanTargets.isNotEmpty) {
      final textsToSync = <String, ({String text, int version})>{};
      for (final e in fileTexts) {
        if (e == null) continue;
        final cached = _fileTextCache[e.$1.path];
        textsToSync[e.$1.path] =
            (text: e.$2, version: cached?.modified ?? 0);
      }
      final scanOut = await scanOnWorker(word, scanTargets, true,
          texts: textsToSync);
      // 后台扫描期间用户可能已发起新查询，本次结果作废
      if (seq != _querySeq || !mounted) {
        _debugLog('[Detect] stale-return-after-scan seq=$seq cur=$_querySeq '
            'mounted=$mounted');
        return;
      }
      for (final r in scanOut.rows) {
        results.add(ResultRow(
          index: results.length + 1,
          before: r.before,
          keyword: r.keyword,
          after: r.after,
          source: r.source,
          filePath: r.filePath,
          matchOffset: r.matchOffset,
          sentence: r.sentence,
        ));
      }
      yearFreq.addAll(scanOut.yearFreq);
      totalFreq = scanOut.totalFreq;
    }
    // 3.5) 搜索选中教材文件，生成教材位置结果（点击联动右侧原文面板）
    final textbookResults = <ResultRow>[];
    final textbookFiles = _textbookFiles.where((f) => f.isSelected).toList();
    if (textbookFiles.isNotEmpty) {
      final textbookTexts = await Future.wait(
        textbookFiles.map((cf) async {
          try {
            final text = await _readFileTextCached(cf.path);
            return (cf, text);
          } catch (_) {
            return null;
          }
        }),
      );
      // 教材扫描期间新查询已发起，本次结果作废
      if (seq != _querySeq || !mounted) return;
      // 教材扫描同样移入常驻 worker，避免大文本同步扫描阻塞 UI
      final tbTargets = [
        for (final e in textbookTexts)
          if (e != null) (path: e.$1.path, name: e.$1.name),
      ];
      if (tbTargets.isNotEmpty) {
        final tbTextsToSync = <String, ({String text, int version})>{};
        for (final e in textbookTexts) {
          if (e == null) continue;
          final cached = _fileTextCache[e.$1.path];
          tbTextsToSync[e.$1.path] =
              (text: e.$2, version: cached?.modified ?? 0);
        }
        final tbOut = await scanOnWorker(word, tbTargets, false,
            texts: tbTextsToSync);
        // 后台扫描期间新查询已发起，本次结果作废
        if (seq != _querySeq || !mounted) return;
        for (final r in tbOut.rows) {
          textbookResults.add(ResultRow(
            index: textbookResults.length + 1,
            before: r.before,
            keyword: r.keyword,
            after: r.after,
            source: r.source,
            filePath: r.filePath,
            matchOffset: r.matchOffset,
            sentence: r.sentence,
          ));
        }
      }
    }
    // 4) 确定词库归属（互斥口径）：超标词手动) > 拓展词> 合成词> 课标词>
    //    反向索引拓展词> 手动专有词。真题词不参与互斥归类：
    //    它是叠加口径 —— 只要该词在真题语料中出现过（totalFreq > 0）就计入
    //    真题词列，可与课标/拓展/超标/专有任意一类重合；四个词库都不收录的词
    //    一律归「未筛选」（无论语料是否出现过），语料出现过的这类词同时出现在
    //    真题词列与未筛选列，由用户在未筛选列手动归类。
    String filter;
    if (apostropheBaseInStandard(raw, isStandard)) {
      // 缩略/所有格按基形判定：基形在课标就归课标词（I've / He's）
      filter = '课标词';
    } else if (isProperNounHit(properNounKeySet(_manualExtraWords), raw)) {
      // 首字母大写 / 全大写写法优先命中专有词；小写写法留给用户确认
      filter = '专有词';
    } else if (_manualChaoGangWords.any((e) => e.toLowerCase() == word)) {
      filter = '超标词';
    } else if (isExtend) {
      filter = '拓展词';
    } else if (isStandard) {
      filter = '课标词';
    } else if (_extendReverseIndex.containsKey(word)) {
      // 反向索引自动匹配：识别为拓展词并同步庀
      _extendWords.add(word);
      _extendWordsLower.add(word);
      _extendBaseMap[word] = _extendReverseIndex[word]!;
      _saveConfig();
      _wordSyncService.markChanged(word);
      filter = '拓展词';
    } else {
      // 四个词库均未收录：一律未筛选（语料出现过的词另由真题词叠加列展示）
      filter = '未筛选';
    }
    // 结果计算完毕后再校验一次代际：此期间用户可能已发起新查询，需让位于新结果
    if (seq != _querySeq || !mounted) {
      _debugLog('[Detect] stale-return-final seq=$seq cur=$_querySeq '
          'mounted=$mounted');
      return;
    }
    _debugLog('[Detect] final-setState seq=$seq raw="$raw" filter=$filter '
        'freq=$totalFreq');
    setState(() {
      // 展示完整词元（haven't 不再回写成基形 have）
      _detectedWord = word;
      _activeFilter = filter;
      _detectedCategory = isStandard && cat.isNotEmpty ? cat : null;
      _wordPos = pos;
      _wordDef = def;
      _yearFrequency.clear();
      _yearFrequency.addAll(yearFreq);
      _results.clear();
      _results.addAll(results);
      _textbookResults.clear();
      _textbookResults.addAll(textbookResults);
      _selectedYear = null;
      _selectedTextbook = null;
      _filteredTextbookResults = List.from(textbookResults);
      _filteredResults = List.from(results);
      _filterCounts.updateAll((_, __) => 0);
      // 查词时右侧默认空白：不自动打开上次导入/上次阅读的文本，
      // 只有用户点击结果行或主动选择时才由 _showResultInRightReader 加载。
      if (!_inImportedMode) {
        _rightPanelVisible = false;
        _rightPanelTitle = '';
        _rightPanelKeyword = '';
        _rightPanelRow = null;
        _rightHighlightController?.dispose();
        _rightHighlightController = null;
        // 新查询恢复完整真题 / 教材列表（退出聚焦态）
        _corpusFocusPath = null;
        _textbookFocusPath = null;
      }
      // 词库归属（互斥）：filter 必为 课标/拓展/超标/专有/未筛选 之一；
      // 四库均不收录的词归未筛选，语料出现过的另计入真题词（叠加口径）
      _filterCounts[filter] = 1;
      // 真题词为叠加口径：只要在真题语料中出现过就计入（可与词库类别重合）
      if (totalFreq > 0) _filterCounts['真题词'] = 1;
    });
    // 课标词库未收录时，用词典数据库补全释义
    if (_wordPos.isEmpty && _wordDef.isEmpty) {
      final lookupWord = word;
      // 先立即打一个标记，确认 fallback 分支已经进入
      if (seq == _querySeq && mounted) {
        setState(() {
          _wordDef = '词典查询中…';
        });
      }
      DictionaryService.lookup(lookupWord).then((entry) {
        // 代际过期：期间用户已发起新查询，丢弃本次回调，避免旧释义覆盖新结果
        if (!mounted || seq != _querySeq) return;
        if (entry != null &&
            (entry['definition']?.isNotEmpty == true ||
                entry['pos']?.isNotEmpty == true)) {
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
        // 代际过期：丢弃本次回调
        if (!mounted || seq != _querySeq) return;
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
      // 高频路径走防抖：连续查词合并写盘，不阻塞 UI
      _saveConfigDebounced();
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
    // 任务④（运行速度）：先一次性建立小写索引，避免在遍历全部导入词时
    // 反复做 O(m) 线性扫描 + 逐元素 toLowerCase（原实现整体是 O(n×m)，
    // 导入上千词、手动归类词较多时会明显拖慢导入后的自动归类阶段）。
    final chaoGangLower =
        _manualChaoGangWords.map((e) => e.toLowerCase()).toSet();
    final extraLower = _manualExtraWords.map((e) => e.toLowerCase()).toSet();
    for (final iw in _importedWords) {
      final lower = iw.word.toLowerCase();
      final cat = _classificationMemory[lower];
      if (cat == null) continue;
      switch (cat) {
        case '拓展词':
          // Set.add 返回是否新增：命中即已存在，省掉一次重复的 contains 查找
          if (_extendWordsLower.add(lower)) {
            _extendWords.add(iw.word);
            _filterCounts['拓展词'] = (_filterCounts['拓展词'] ?? 0) + 1;
          }
          // 不自动补映射：拓展词↔课标词关联完全来自用户筛选词库（esw_config.json 的 extendBaseMap），
          // 未同步词库时由检测流程提示用户先同步，避免错误识别
          break;
        case '超标词':
          if (chaoGangLower.add(lower)) {
            _manualChaoGangWords.add(iw.word);
            _filterCounts['超标词'] = (_filterCounts['超标词'] ?? 0) + 1;
          }
          break;
        case '专有词':
          if (extraLower.add(lower)) {
            _manualExtraWords.add(iw.word);
            _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) + 1;
          }
          break;
      }
    }
    _saveConfig();
  }

  /// 统计导入词各筛选标签的词数。
  ///
  /// 口径（第四关重构）：
  /// - 真题词为**叠加口径**：只要 isInCorpus 即计入，因此真题词数可以与
  ///   课标/拓展/超标/专有/未筛选重合，各列之和允许大于去重总词数；
  /// - 其余五类为**互斥口径**：四个词库都不收录的词（category == '未筛选'）
  ///   计入未筛选列，其中语料出现过的同时计入真题词列。
  Map<String, int> _computeImportedCounts(List<_ImportedWord> words) =>
      buildFilterCounts(
        words.map(
          (w) => WordFilterState(category: w.category, isInCorpus: w.isInCorpus),
        ),
      );

  Future<void> _analyzeImportedText() async {
    // 粘贴/输入文本同样走统一规范化（幂等，文件入口已规范化过）
    final text = normalizeText(_searchController.text.trim());
    if (text.isEmpty) {
      setState(() {
        _cameFromImportedMode = false;
        _inImportedMode = false;
        _importedWords.clear();
        _importedTotalWords = 0;
        _importedActiveFilter = '真题词';
        // 同步清空上一份导入模式的"返回现场"保存态，避免残留旧文本
        _savedImportedText = '';
        _savedImportedWords = [];
        _importedFilterCounts.updateAll((_, __) => 0);
      });
      return;
    }
    // 提取单词（仅英文单词，至少 2 字符且非纯数字）并保留原始大小写。
    // 统一走 shared/text_normalize 的 extractWordTokens：连字/变音/全角折叠 +
    // 选项字母粘连剥离，与 Android 端和语料统计口径一致。
    final freqMap = <String, int>{};
    final wordCaseMap = <String, String>{}; // 小写→原始大小写
    for (final original in extractWordTokens(text)) {
      final w = original.toLowerCase();
      freqMap[w] = (freqMap[w] ?? 0) + 1;
      if (!wordCaseMap.containsKey(w)) {
        wordCaseMap[w] = original;
      }
    }
    // 收集真题 + 教材语料中的所有单词；其中真题语料另统计真题词频（totalFreq）
    // 注意：真题词判定只看「真题语料」（_corpusFiles），教材语料不参与真题词判定，
    // 否则会出现「真题词但真题频次为 0」的矛盾口径。
    final corpusFreqMap = <String, int>{};
    final selectedFiles = <CorpusFile>[
      ..._corpusFiles.where((f) => f.isSelected),
      ..._textbookFiles.where((f) => f.isSelected),
    ];
    final corpusFilePaths = _corpusFiles
        .where((f) => f.isSelected)
        .map((f) => f.path)
        .toSet();
    final fileTexts = await Future.wait(
      selectedFiles.map((cf) async {
        try {
          return await _readFileTextCached(cf.path);
        } catch (_) {
          return null;
        }
      }),
    );
    for (var i = 0; i < fileTexts.length; i++) {
      final corpusText = fileTexts[i];
      if (corpusText == null) continue;
      final isCorpusText = corpusFilePaths.contains(selectedFiles[i].path);
      for (final cw in extractWordTokens(corpusText)) {
        final lw = cw.toLowerCase();
        if (isCorpusText) {
          corpusFreqMap[lw] = (corpusFreqMap[lw] ?? 0) + 1;
        }
      }
    }
    // 词库索引：未筛选判定需要「四个词库全不收录」。
    // 手动词表与课标词库同口径：精确匹配优先，大写写法可回退到同名小写词条。
    final extendKeySet = _extendWords.toSet();
    final chaoGangKeySet = _manualChaoGangWords.toSet();
    final extraKeySet = properNounKeySet(_manualExtraWords);
    final words = <_ImportedWord>[];
    for (final entry in freqMap.entries) {
      final w = entry.key; // 小写
      final original = wordCaseMap[w] ?? w; // 原始大小写
      final freq = entry.value;
      // 词形保留完整（couldn't / China's），查表按「完整词形 → 基形」回退，
      // 否则所有格与缩略形式会整段丢失词库分类。
      final keys = wordLookupKeys(original);
      String? remembered;
      for (final key in keys) {
        final mem = _classificationMemory[key];
        if (mem != null) {
          remembered = mem;
          break;
        }
      }
      // 真题词＝在真题语料中出现过（叠加口径，可与课标/拓展/超标/专有重合）
      final inCorpus = corpusFreqMap.containsKey(w);
      final standardHit = isWordEntryHit(_standardWords, original);
      // 词库归属（互斥口径）：历史归类 > 大写写法的专有词 > 超标 > 拓展 > 课标；
      // 小写写法不自动归专有词，四库都不收录时进未筛选（语料出现过的同时进
      // 真题词叠加列，并在未筛选列等待用户手动归类）
      final cat = resolveFilterCategory(
        inCorpus: inCorpus,
        inStandard: standardHit,
        inExtend: matchWordEntryKey(extendKeySet, original) != null,
        inChaoGang: matchWordEntryKey(chaoGangKeySet, original) != null,
        inProper: false,
        preferProper: isProperNounHit(extraKeySet, original) &&
            !apostropheBaseInStandard(original, standardHit),
        apostropheBaseStandard: apostropheBaseInStandard(original, standardHit),
        remembered: remembered,
      );
      words.add(
        _ImportedWord(
          word: original,
          category: cat,
          frequency: freq,
          isInCorpus: inCorpus,
          totalFreq: corpusFreqMap[w] ?? 0,
        ),
      );
    }
    // 分类统计（真题词为叠加口径，其余五类互斥）
    final counts = _computeImportedCounts(words);
    setState(() {
      _cameFromImportedMode = false;
      _inImportedMode = true;
      _importedWords = words;
      _importedTotalWords = words.length;
      _importedActiveFilter = '真题词';
      // 导入新文档/新文本：清空上一份导入模式的"返回现场"保存态，
      // 防止导出结果错源为上一份文件内容（导出原文取 _searchController.text）。
      _savedImportedText = '';
      _savedImportedWords = [];
      _importedFilterCounts
        ..clear()
        ..addAll(counts);
    });
    // 检测完成即把被检测文本展示在右侧面板（不再展示真题原文）
    _showDetectedTextInRightReader();
    _autoAccumulateImportedResults();
  }

  @override
  Widget build(BuildContext context) {
    // 任务②：依赖 MediaQuery 尺寸，窗口缩放时本 Widget 自动重建；
    // 重建前先刷新全局缩放系数，保证本帧内所有 dp()/hXxx/fXxx 取值都是新尺寸下的值。
    GlassTheme.updateUiScale(MediaQuery.sizeOf(context));
    // 规范 2.3：左侧语料栏固定为 248（基准窗口），随窗口等比缩放（任务②）
    final leftWidth = GlassTheme.dp(248.0);
    return RepaintBoundary(
      // 任务④（运行速度）：主界面整体独立成层 —— 有弹窗悬浮时底层内容不参与重绘
      child: Scaffold(
      backgroundColor: GlassTheme.bg,
      body: GlowBackground(
        child: Column(
          children: [
            // ① 标题栏 h42（region-titlebar）
            // 顶栏条带修复：GlowBand 给标题栏套独立 RepaintBoundary，并把「整窗柔光
            // 在 y=0 这一段」直接画进标题栏自身。标题栏底为透明，一旦只重绘条带
            // （导出掉帧后的局部重绘 / 系统对话框开合触发的刷新），原先会露出
            // Scaffold 纯色底形成横向色带；现在条带自带同源柔光，任何一帧都一致。
            GlowBand(
              offsetY: 0,
              child: ClipRect(child: FrostFilter(enabled: false, filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: Container(
              key: const ValueKey('region-titlebar'),
              height: GlassTheme.hTitleBar,
              padding: const EdgeInsets.symmetric(horizontal: GlassTheme.s16),
              // 第三轮清单第 13 项：标题栏不再画底边线 —— 标题栏与工具栏紧贴，
              // 两者之间只保留工具栏顶部的 1px 分隔线（line），避免 2px 双线读成"浅缝"。
              // 第三关 ②：与工具栏一致的真玻璃结构 —— ClipRect → FrostFilter(blur20)
              // → Container(白 .58)。必须夹在 ClipRect 内，否则 blur 取景越出渲染表面，
              // 会把整层（Logo/程序名/版本胶囊/窗口三键）糊掉。
              child: Stack(fit: StackFit.passthrough, children: [Container(
                // 视觉修正①：标题栏去掉白底（原 GlassTheme.panel = 白 .58）——
                // 用户反馈标题栏整行下方的白色背景条与窗口柔光背景不搭，
                // 改为透明让 GlowBackground 柔光直接透出，与窗口整体背景一致。
                // 仅改背景填充，区域高度/结构/顺序不变。
                color: Colors.transparent,
                child: Row(
                  children: [
                      // 左侧名称区：整段可拖拽移动窗口；自绘标题栏下名称只保留此处一份
                      Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) {
                          if (e.buttons == 1 && !_isMaximized) {
                            windowManager.startDragging();
                          }
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const GlassLogo(),
                            const SizedBox(width: kGap8),
                            const Text(
                              '真题课标词',
                              style: TextStyle(
                                fontSize: GlassTheme.fBody,
                                fontWeight: FontWeight.w600,
                                color: GlassTheme.ink,
                              ),
                            ),
                            const SizedBox(width: kGap8),
                            GlassVersionBadge(version: 'v1.6.3'),
                          ],
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(width: kGap8),
                      // 窗口控制按钮（自绘标题栏替代系统按钮）
                      _buildWindowButton(
                        Icons.remove_rounded,
                        () => windowManager.minimize(),
                      ),
                      _buildWindowButton(
                        _isMaximized
                            ? Icons.filter_none_rounded
                            : Icons.crop_square_rounded,
                        _toggleMaximize,
                      ),
                      _buildWindowButton(
                        Icons.close_rounded,
                        () => windowManager.close(),
                        isClose: true,
                      ),
                    ],
                  ),
              ), Positioned(top: 0, left: 0, right: 0, child: IgnorePointer(child: Container(height: 1, color: GlassTheme.lineHi)))]),
            )))),
            // ========== 工具栏：独立 44px 一行（骨架 ② / region-toolbar） ==========
            // 顶栏条带修复：工具栏同样自带「整窗柔光在 y=标题栏高度 这一段」的
            // 确定性底层 + 独立 RepaintBoundary，避免与标题栏之间出现色带断层。
            GlowBand(
              offsetY: GlassTheme.hTitleBar,
              child: Container(
              key: const ValueKey('region-toolbar'),
              height: GlassTheme.hToolbar,
              padding: const EdgeInsets.symmetric(horizontal: kGap12),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: GlassTheme.line),
                  bottom: BorderSide(color: GlassTheme.line),
                ),
              ),
              // 关键修复：BackdropFilter 必须夹在 ClipRect 内，否则 blur 取景会向上外溢，
              // 把上方标题栏（Logo/程序名/版本胶囊/窗口三键）整层糊掉 → 表现为"标题栏内容消失"。
              child: ClipRect(
                child: FrostFilter(
                  enabled: false,
                  filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Stack(fit: StackFit.passthrough, children: [Container(
                  // 视觉修正①：工具栏与标题栏同步去掉白底，让窗口柔光背景透出，
                  // 消除"标题栏整行下方白色背景条"；上下 1px line 分隔线与高度均保留。
                  color: Colors.transparent,
                  child: Row(
                    children: [
                      // 左组按钮：窗口变窄时横向滚动，避免挤压/溢出（最小 900×600 安全）
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              // 恢复文字按钮：图标按钮挤在一起显粘连，改回「图标 + 文字」并留足间距
                              GlassToolButton(
                                label: '使用说明',
                                icon: Icons.help_outline_rounded,
                                onPressed: _showHelp,
                              ),
                              const SizedBox(width: kGap12),
                              GlassToolButton(
                                label: '同步词库',
                                icon: Icons.sync_rounded,
                                onPressed: _syncVocab,
                              ),
                              const SizedBox(width: kGap12),
                              GlassToolButton(
                                label: '导出高频',
                                icon: Icons.file_download_outlined,
                                onPressed: _exportHighFreq,
                              ),
                              const SizedBox(width: kGap12),
                              // 三个词库入口（原主面板三块卡片改为工具栏按钮）
                              GlassToolButton(
                                label: '拓展词库',
                                icon: Icons.menu_book_rounded,
                                onPressed: _showExtendWordsDialog,
                              ),
                              const SizedBox(width: kGap12),
                              GlassToolButton(
                                label: '超标词库',
                                icon: Icons.trending_up_rounded,
                                onPressed: _showChaoGangWordsDialog,
                              ),
                              const SizedBox(width: kGap12),
                              GlassToolButton(
                                label: '专有词库',
                                icon: Icons.bookmark_added_outlined,
                                onPressed: _showExtraWordsDialog,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: kGap12),
                      // 状态徽标：无边框淡底圆角矩形（非按钮，规范 2.2）
                      Container(
                        height: GlassTheme.hToolBtn,
                        padding: const EdgeInsets.symmetric(horizontal: kGap10),
                        decoration: BoxDecoration(
                          color: const Color(0x0818181B),
                          borderRadius: BorderRadius.circular(GlassTheme.rMd),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: GlassTheme.green,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: kGap7),
                            Text(
                              _standardWordsLowerKeySet.isNotEmpty
                                  ? '词库已同步 - ${_standardWordsLowerKeySet.length} 条'
                                  : '词库已同步',
                              style: const TextStyle(
                                fontSize: GlassTheme.fSmall,
                                color: GlassTheme.ink3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: kGap12),
                      GlassToolButton(
                        label: '检查更新',
                        icon: Icons.system_update_alt_rounded,
                        onPressed: _checkUpdate,
                      ),
                    ],
                  ),
                // 第三轮清单第 13 项：去掉工具栏顶部 1px 内高光（lineHi）——
                // 它与工具栏 top 分隔线上下相邻，会在两行之间形成"能看到底色的浅缝"。
                )]),
              ),
                ),
            )),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ========== 左侧窄栏（真题 / 教材 二选一）③ region-side w248 ==========
                  SizedBox(
                    key: const ValueKey('region-side'),
                    width: leftWidth,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                          kGap12, kGap16, kGap12, kGap16),
                      child: RepaintBoundary(
                        child: GlassPanel(
                          radius: GlassTheme.rXl,
                          sigma: 0, // 任务④：背靠平滑柔光背景，模糊不可见但每帧代价高
                          child: Column(
                            children: [
                              // 单栏形态：标题行本身就是「真题 / 教材」切换入口，
                              // 两种状态互斥，各自占满整个左栏高度。
                              _buildLeftTabHeader(),
                              Container(height: 1, color: GlassTheme.line),
                              Expanded(
                                child: RepaintBoundary(
                                  child: _leftPanelIsTextbook
                                      ? _buildTextbookList()
                                      : _buildCorpusList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ========== 单条连续分隔线（左右留白，避免贴边）==========
                  // 左右各 14 与示意图一致（示意图 左卡右沿254 -> 分隔线268 -> 内容290）
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: kGap12),
                    child: Container(width: 1, color: GlassTheme.line),
                  ),
                  // ========== 中间检测主区 ==========
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: RepaintBoundary(
                            child: _buildRightContent(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // ========== 最右侧原文面板 ==========
                  if (_rightPanelVisible)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: kGap12),
                      child: Container(width: 1, color: GlassTheme.line),
                    ),
                  if (_rightPanelVisible)
                    SizedBox(
                      width: MediaQuery.of(context).size.width / 3.4,
                      child: _buildRightReaderPanel(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
  }


  // ==================== 教材文件列表（可勾选，参与语料统计） ====================
  /// 教材列表：与真题列表一致，点击行尾按钮在行下内联展开教材原文；
  /// 命中教材结果时进入聚焦态（只显示该教材）并定位到关键词。
  Widget _buildTextbookList() {
    if (_textbookFiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 32,
              color: GlassTheme.ink3,
            ),
            const SizedBox(height: kGap6),
            Text(
              '点击「教材导入」选择教材文件',
              style: TextStyle(fontSize: 12, color: GlassTheme.ink3),
            ),
          ],
        ),
      );
    }
    final items = _textbookDisplayItems();
    final heights = items.map(_textbookItemHeight).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final double avail = constraints.maxHeight;
        final double natural =
            kGap8 * 2 + heights.fold<double>(0, (s, h) => s + h);
        double viewH = natural <= avail ? natural : avail;
        double? focusReaderH;
        if (_textbookFocusPath != null) {
          viewH = avail;
          final double hintH = GlassTheme.dp(24);
          final double rowH = GlassTheme.dp(32);
          final double rest = avail - kGap8 * 2 - hintH - rowH - kGap6;
          focusReaderH =
              rest < GlassTheme.dp(120) ? GlassTheme.dp(120) : rest;
        }
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: viewH,
            child: ListView.builder(
              controller: _textbookListScrollController,
              // 对齐示意图：卡内列表内容左内缩 16 = 列表 padding 8 + 行 padding 8
              padding: const EdgeInsets.symmetric(
                horizontal: kGap8,
                vertical: kGap8,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                switch (item.kind) {
                  case 'focusHint':
                    return _buildTextbookFocusHint();
                  case 'reader':
                    return _buildCorpusReader(
                      item.file!,
                      itemHeight: focusReaderH,
                    );
                  default:
                    return _buildTextbookFileRow(item.file!);
                }
              },
            ),
          ),
        );
      },
    );
  }

  List<({String kind, CorpusFile? file})> _textbookDisplayItems() {
    final focus = _textbookFocusPath;
    final files = focus == null
        ? _textbookFiles
        : _textbookFiles.where((f) => f.path == focus).toList();
    if (files.isEmpty) return const <({String kind, CorpusFile? file})>[];
    return <({String kind, CorpusFile? file})>[
      if (focus != null) (kind: 'focusHint', file: null),
      for (final f in files) ...[
        (kind: 'file', file: f),
        if (_textbookReaderOpen.contains(f.path)) (kind: 'reader', file: f),
      ],
    ];
  }

  double _textbookItemHeight(({String kind, CorpusFile? file}) item) {
    switch (item.kind) {
      case 'focusHint':
        return GlassTheme.dp(24);
      case 'reader':
        return GlassTheme.dp(_kCorpusReaderH) + kGap6;
      default:
        return GlassTheme.dp(32);
    }
  }

  /// 教材聚焦态提示条：只显示当前教材，可一键恢复完整列表。
  Widget _buildTextbookFocusHint() {
    var name = '';
    for (final f in _textbookFiles) {
      if (f.path == _textbookFocusPath) {
        name = f.name;
        break;
      }
    }
    return SizedBox(
      height: GlassTheme.dp(24),
      child: Row(
        children: [
          const Icon(
            Icons.filter_alt_outlined,
            size: 13,
            color: GlassTheme.accentInk,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '仅显示 $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: GlassTheme.ink2),
            ),
          ),
          const SizedBox(width: kGap8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _textbookFocusPath = null),
              child: const Text(
                '显示全部',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: GlassTheme.accentInk,
                  decoration: TextDecoration.underline,
                  decorationColor: GlassTheme.accentInk,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextbookFileRow(CorpusFile file) {
    // 第三关 ⑥：高亮行全栏唯一——教材导入组默认无高亮（透明底、hover 变灰），
    // 点击后才产生高亮；勾选语义 isSelected 保持原功能
    final selected =
        file.path == _activePathOf(_textbookFiles, _activeTextbookPath);
    final expanded = _textbookReaderOpen.contains(file.path);
    final ext = _fileTypeLabel(file.name);
    return GlassPressable(
      radius: GlassTheme.rMd,
      hoverColor: const Color(0x0A18181B),
      pressColor: const Color(0x294462F2),
      enabled: true,
      child: InkWell(
        onTap: () {
          setState(() {
            file.isSelected = !file.isSelected;
            // 原功能：多选参与统计（只改视觉，不动交互）
            _activeTextbookPath = file.path; // 第三关 ⑥：高亮行唯一
          });
        },
        borderRadius: BorderRadius.circular(GlassTheme.rMd),
        child: Container(
          height: 32,
          padding: const EdgeInsets.only(right: kGap8),
          // 第三轮清单第 2 项：选中态 = 淡蓝底 rgba(68,98,242,.12) + 左侧 2.5px 蓝竖条
          //（竖条上下各内缩 6，圆角 2）+ 深蓝字，行高仍 32、不整行填主色
          decoration: BoxDecoration(
            color: selected ? const Color(0x1F4462F2) : null,
            borderRadius: BorderRadius.circular(GlassTheme.rMd),
          ),
          child: Row(
            children: [
              // 左侧 2.5px 蓝色竖条（骨架 FileItem: Positioned(left:0, top:6, bottom:6, width:2.5)）
              SizedBox(
                width: kGap8,
                child: selected
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 2.5,
                          height: 20,
                          decoration: BoxDecoration(
                            color: GlassTheme.accent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      )
                    : null,
              ),
              GlassFileTypeTag(label: ext, selected: selected),
              const SizedBox(width: kGap8),
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: GlassTheme.fBody,
                    color: selected
                        ? GlassTheme.accentInk
                        : const Color(0xFF52525B),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: kGap4),
              // 行尾展开按钮：行下内联展示教材原文
              Tooltip(
                message: expanded ? '收起教材原文' : '查看教材原文',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GlassPressable(
                    radius: 6,
                    hoverColor: GlassTheme.accentSoft,
                    pressColor: const Color(0x294462F2),
                    enabled: true,
                    child: InkWell(
                      onTap: () => _toggleTextbookReader(file),
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: Icon(
                          expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color:
                              selected ? GlassTheme.accentInk : GlassTheme.ink3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showTextbookImportMenu,
                child: GlassPressable(
                  radius: 6,
                  hoverColor: GlassTheme.accentSoft,
                  pressColor: const Color(0x294462F2),
                  enabled: true,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: const Color(0x1218181B),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      size: 14,
                      color: GlassTheme.ink2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleTextbookReader(CorpusFile file) async {
    if (_textbookFocusPath != null) {
      setState(() => _textbookFocusPath = null);
    }
    if (_textbookReaderOpen.contains(file.path)) {
      _closeTextbookReader(file.path);
      return;
    }
    await _openTextbookReader(file);
  }

  void _closeTextbookReader(String path) {
    setState(() => _textbookReaderOpen.remove(path));
    _corpusReaderControllers.remove(path)?.dispose();
    _corpusReaderScrolls.remove(path)?.dispose();
    _corpusReaderKeys.remove(path);
    _corpusReaderAnchors.remove(path);
    _corpusReaderTexts.remove(path);
  }

  /// 展开教材并（可选）定位到关键词；[focusOnly] 时教材栏只显示这一本。
  Future<void> _openTextbookReader(
    CorpusFile file, {
    String keyword = '',
    int? matchOffset,
    bool collapseOthers = false,
    bool focusOnly = false,
  }) async {
    final path = file.path;
    if (collapseOthers) {
      for (final p in _textbookReaderOpen.where((p) => p != path).toList()) {
        _corpusReaderControllers.remove(p)?.dispose();
        _corpusReaderScrolls.remove(p)?.dispose();
        _corpusReaderKeys.remove(p);
        _corpusReaderAnchors.remove(p);
        _corpusReaderTexts.remove(p);
      }
    }
    setState(() {
      _leftPanelIsTextbook = true;
      _activeTextbookPath = path;
      _textbookFocusPath = focusOnly ? path : null;
      if (collapseOthers) {
        _textbookReaderOpen
          ..clear()
          ..add(path);
      } else {
        _textbookReaderOpen.add(path);
      }
      _corpusReaderControllers.remove(path)?.dispose();
      _corpusReaderControllers[path] =
          _HighlightController(_corpusReaderTexts[path] ?? '', keyword);
      _corpusReaderScrolls.putIfAbsent(path, () => ScrollController());
    });
    if (!_corpusReaderTexts.containsKey(path)) {
      String text = '';
      try {
        text = await _readFileTextCached(path);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _corpusReaderTexts[path] = text;
        _corpusReaderControllers.remove(path)?.dispose();
        _corpusReaderControllers[path] = _HighlightController(text, keyword);
      });
    }
    _scrollTextbookListToFile(path);
    final loaded = _corpusReaderTexts[path] ?? '';
    int? anchor = matchOffset;
    if (anchor == null && keyword.isNotEmpty) {
      // 与共用分词同口径（撇号等价、整词匹配）；找不到时 keywordMatchOffset 返回 -1
      final i = keywordMatchOffset(loaded, keyword);
      if (i >= 0) anchor = i;
    }
    if (anchor != null) _corpusReaderAnchors[path] = anchor;
    _jumpCorpusReaderToKeyword(path, loaded, keyword, anchor);
  }

  /// 把教材列表滚动到指定教材行并居中。
  void _scrollTextbookListToFile(String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_textbookListScrollController.hasClients) return;
      final items = _textbookDisplayItems();
      double off = kGap8;
      double targetH = GlassTheme.dp(32);
      for (final it in items) {
        if (it.kind == 'file' && it.file?.path == path) {
          targetH = _textbookItemHeight(it);
          break;
        }
        off += _textbookItemHeight(it);
      }
      final pos = _textbookListScrollController.position;
      final center = off - (pos.viewportDimension - targetH) / 2;
      _textbookListScrollController.jumpTo(
        center.clamp(0.0, pos.maxScrollExtent),
      );
    });
  }

  String _fileTypeLabel(String name) {
    final idx = name.lastIndexOf('.');
    if (idx < 0 || idx == name.length - 1) return '';
    return name.substring(idx + 1);
  }

  // ==================== 工具栏（文档导入 + 搜索输入框） ====================
  // ④-1 搜索行：高 40，属右栏内容区（骨架要求：不属于工具栏）
  // [historyMaxHeight] 由内容区按剩余高度预算下发，保证历史列表展开时
  // 下方筛选/词频/结果表仍保有最低可用高度（小窗口不溢出）。
  Widget _buildSearchRow({required double historyMaxHeight}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ④-1 搜索行 h40：文档导入（固定宽）→ 搜索框（Expanded）→ 导出结果（主按钮）
        SizedBox(
          key: const ValueKey('region-srow'),
          height: GlassTheme.hSearchRow,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(width: kGap20),
              Tooltip(
                message:
                    '建议优先 txt / docx，可保留原排版标注；doc / pdf 转换后格式可能变化',
                child: GlassGhostButton(
                  label: '文档导入',
                  icon: Icons.arrow_upward_rounded,
                  onPressed: _importDocumentToInput,
                  height: GlassTheme.hSearchBtn,
                ),
              ),
              const SizedBox(width: GlassTheme.s8),
              Expanded(
                child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      // 对齐示意图：搜索输入框四角内缩 5~6 -> r6（与卡片 r8 区分，示意图中输入框更"方"）
                      borderRadius: BorderRadius.circular(GlassTheme.rSm),
                      // 聚焦态只靠 1.5px 强调色描边（focusedBorder）表达，
                      // 不再叠加向外扩散的蓝色光晕。
                    ),
                    child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 40),
                    child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    maxLines: 10,
                    minLines: 1,
                    textAlignVertical: TextAlignVertical.center,
                    style: const TextStyle(fontSize: GlassTheme.fInput, height: 1.4285714286),
                    decoration: InputDecoration(
                      hintText: '',
                      // 右侧预留 Enter 徽标位（规范 2.4：快捷键徽标置于输入框内部右侧）
                      contentPadding: const EdgeInsets.only(
                        // 第三轮清单第 5 项：左侧留出 16px 放大镜位（12 图标左距 + 16 图标宽 + 8 间距）
                        left: 36,
                        right: 78,
                        top: 12,
                        bottom: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(GlassTheme.rSm),
                        ),
                        borderSide: const BorderSide(color: GlassTheme.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(GlassTheme.rSm),
                        ),
                        borderSide: const BorderSide(color: GlassTheme.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(GlassTheme.rSm),
                        ),
                        borderSide: const BorderSide(
                          color: GlassTheme.accent,
                          width: 1.5,
                        ),
                      ),
                      isDense: false,
                      filled: true,
                      fillColor: GlassTheme.panelSolid, // rgba(255,255,255,0.72) 比玻璃更实（规范 2.4）
                    ),
                    onChanged: (_) {
                      final text = _searchController.text;
                      // maxLines>1 时 Enter 产生换行而非 onSubmitted，单行单词按 Enter 触发检测
                      if (text.contains('\n')) {
                        final trimmed = text.trim();
                        if (!trimmed.contains(_anyWhitespaceChar)) {
                          _searchController.text = trimmed;
                          _searchController.selection = TextSelection.collapsed(
                            offset: trimmed.length,
                          );
                          _beginIndependentQuery();
                          _onDetect();
                          _cancelHistoryTimer();
                          return;
                        }
                      }
                      _cancelHistoryTimer();
                      // 检测是否为多单词文本（粘贴场景），自动切换导入模式
                      final trimmed = _searchController.text.trim();
                      if (trimmed.contains(_anyWhitespaceChar) &&
                          extractWordTokens(trimmed).length >= 2) {
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
                      _historyTimer = Timer(const Duration(seconds: 2), () {});
                      // 点击输入框：若文本仍是上次查询词，则清空进入新查询状态。
                      // 查询后输入框通常仍持有焦点（true→true 不触发 focus listener），
                      // 必须在 onTap 中兜底处理，使历史下拉按"聚焦+输入为空"显示。
                      final tapRaw = _searchController.text.trim();
                      if (_detectedWord.isNotEmpty &&
                          tapRaw.isNotEmpty &&
                          tapRaw.toLowerCase() ==
                              _detectedWord.toLowerCase()) {
                        _searchController.clear();
                        _searchController.selection =
                            const TextSelection.collapsed(offset: 0);
                        if (mounted) setState(() {});
                      }
                    },
                    onSubmitted: (_) {
                      _beginIndependentQuery();
                      _onDetect();
                      _cancelHistoryTimer();
                    },
                    ),
                  ),
                ),
                  // 第三轮清单第 5 项：左侧 16px 放大镜（距左 12）→ 占位文字左对齐（图标后 8px）
                  Positioned(
                    left: 12,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Icon(
                          Icons.search_rounded,
                          size: 16,
                          color: GlassTheme.ink3,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 36,
                    right: 78,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _searchController.text.isEmpty &&
                                !_searchFocus.hasFocus
                            ? 1.0
                            : 0.0,
                        duration: const Duration(milliseconds: 150),
                        child: const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '输入单词或粘贴文本进行检测',
                            style: TextStyle(
                              fontSize: 14,
                              color: GlassTheme.ink3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Enter 快捷键徽标（输入框内部右侧，规范 2.4）
                  Positioned(
                    right: 10,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x8CFFFFFF), // rgba(255,255,255,.55)
                            borderRadius: BorderRadius.circular(GlassTheme.rSm),
                          ),
                          child: const Text(
                            'Enter ↵',
                            style: TextStyle(
                              fontSize: 10,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: GlassTheme.ink3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 拖拽文件时的视觉提示
                  if (_isDragging)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(GlassTheme.rLg),
                            border: Border.all(
                              color: GlassTheme.accent,
                              width: 2,
                            ),
                            color: GlassTheme.accentSoft,
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            '松开以导入文档',
                            style: TextStyle(
                              color: GlassTheme.accentInk,
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
              const SizedBox(width: kGap8),
              _buildToolbarRightButton(),
              const SizedBox(width: kGap20),
            ],
          ),
        ),
          // 最近查询历史：内嵌推压式，展开时把下方内容推下去，不遮挡释义与词库。
          // 高度按预算上限展开；空间不足时列表内部滚动，绝不低于下方内容所需高度。
          if (_searchFocus.hasFocus &&
              _searchController.text.isEmpty &&
              _wordHistory.isNotEmpty &&
              historyMaxHeight >= GlassTheme.dp(72))
            _buildHistoryList(maxHeight: historyMaxHeight),
        if (_searchController.text.isNotEmpty && _detectedWord.isNotEmpty)
          _buildWordDefBanner(),
      ],
    );
  }

  // ========== 右栏内容区（④ region-content）：上16 左右20 下16，块间距 12 ==========
  // 骨架 ④：④-1 搜索行(40) → ④-2 筛选行(自适应) →
  //          ④-3 词频面板(按可用高度分配) → ④-4 结果表(flex:1)。
  /// 内容区纵向栅格：所有区块之间统一 12，避免逐块手写不同间距
  static const double _kSectionGap = kGap12;

  Widget _buildRightContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 最近查询展开态的高度预算：搜索行区域内（上方 16 + 搜索行 + 历史列表上边距 8）
        // 之外，至少要给下方「筛选行 + 词频面板 + 结果表」留下可用的最低高度，
        // 否则 900×600 及更小窗口展开历史列表时下方区块会溢出。
        // 预算不足 dp(72) 时历史列表整体收起（仅在极小压力尺寸出现）。
        final reserved = kGap16 + GlassTheme.hSearchRow + kGap8;
        final lowerMin = kGap12 /* 内容区上内边距 */
            + kGap16 /* 内容区下内边距 */
            + GlassTheme.hFilterRow * 2 /* 筛选行最多两行 */
            + _kSectionGap * 2 /* 两处区块间距 */
            + GlassTheme.dp(96) /* 词频面板下限 */
            + GlassTheme.dp(160) /* 结果表表头 + 至少一行 */
            ;
        final historyMaxHeight = (constraints.maxHeight - reserved - lowerMin)
            .clamp(0.0, GlassTheme.dp(240));

        return Column(
          key: const ValueKey('region-content'),
          children: [
            // 视觉修正②：搜索行距工具栏分隔线补 16 上边距（规范 §4.10⑤：
            // 「上边线 = 搜索行距工具栏分隔线 = 16」）。原为 0 → 搜索行顶着工具栏过挤。
            const SizedBox(height: kGap16),
            _buildSearchRow(historyMaxHeight: historyMaxHeight),
            Expanded(
              child: _inImportedMode
                  ? _buildImportedTextPanel()
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        // 自适应分配：年份面板常态保持设计高度，窗口变矮时按可用
                        // 高度线性收缩；剩余高度全部留给结果表。筛选行改为内容
                        // 自适应高度（可换行），不再以固定高度裁切/压住下方区块。
                        final yearHeight = (constraints.maxHeight * 0.34)
                            .clamp(GlassTheme.dp(96), GlassTheme.hWordPanel)
                            .toDouble();
                        return Padding(
                          // 内容区栅格统一：左右 20、下 16，内部所有区块之间统一 _kSectionGap(12)
                          padding: const EdgeInsets.fromLTRB(
                              kGap20, _kSectionGap, kGap20, kGap16),
                          child: Column(
                            children: [
                              if (_cameFromImportedMode &&
                                  _searchController.text.isNotEmpty) ...[
                                _buildReturnToImportedBar(),
                                const SizedBox(height: _kSectionGap),
                              ],
                              _buildFilterChips(),
                              const SizedBox(height: _kSectionGap),
                              SizedBox(
                                height: yearHeight,
                                child: _buildYearDistribution(),
                              ),
                              const SizedBox(height: _kSectionGap),
                              Expanded(
                                child: GlassPanel(
                                  key: const ValueKey('region-table'),
                                  sigma: 0, // 任务④：结果表为常驻大面板，模糊不可见 → 关闭

                                  // 对齐示意图：结果面板表头带与面板顶沿齐平（示意图 y462 面板顶=表头带顶）
                                  padding: EdgeInsets.zero,
                                  radius: GlassTheme.rXl,
                                  child: Column(
                                    children: [
                                      _buildResultHeader(),
                                      Expanded(
                                        child: RepaintBoundary(
                                          child: _buildResultList(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 最近查询历史列表（内嵌推压式）：置于输入框与释义区之间，展开时推压下方内容。
  /// [maxHeight] 由内容区预算下发，列表内部可滚动，不挤占下方区块的最低高度。
  Widget _buildHistoryList({required double maxHeight}) {
    return Container(
      // 与搜索框、释义长条、统计面板共用同一条 kGap20 内边距基准（横向对齐一致）
      margin: const EdgeInsets.only(left: kGap20, right: kGap20, top: kGap8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FrostFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xB8FFFFFF), // rgba(255,255,255,0.72) 下拉浮层玻璃（规范 2.9）
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x73C4C6CE)), // rgba(196,198,206,0.45)
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14242427), // rgba(24,24,27,0.08)
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '最近查询',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: GlassTheme.ink,
                      ),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        _wordHistory.clear();
                        _saveConfig();
                      });
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GlassPressable(radius: 6, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: const Text(
                        '清除历史',
                        style: TextStyle(
                          fontSize: 11,
                          color: GlassTheme.accentInk,
                        ),
                      ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: GlassTheme.line),
            for (var i = 0; i < _wordHistory.length && i < 10; i++)
              Builder(
                // 固定 key：hover setState 重建时复用同一 Element，避免条目被
                // 重建替换导致手势竞技场中断（防御连续点击/快速移动场景）。
                key: ValueKey('history_item_$i'),
                builder: (ctx) {
                  final w = _wordHistory[i];
                // 关键：用 Listener 手动点击检测，完全绕开手势竞技场。
                // GestureDetector 的 TapGestureRecognizer 在桌面端可能被
                // Scrollable 拖拽竞技场 / 焦点重建 / 其它 recognizer 竞争吞掉
                //（此前多轮修复均无效、日志证实 onTap 从未触发）。
                // Listener 是原始指针事件监听，不参与竞技场，只要指针到达
                // 词条热区，按下+抬起且位移 < 10px 即视为点击，必然触发查询。
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    // buttons==1 为鼠标左键（kPrimaryButton），避免右键/中键误触发
                    if (e.buttons == 1) {
                      _debugLog('[HistoryItem] down w=$w pos=${e.position}');
                      _historyDownPos = e.position;
                      _pressedHistoryIndex.value = i; // 第三关 ⑤：按压态（仅驱动视觉）
                    }
                  },
                  onPointerCancel: (_) => _pressedHistoryIndex.value = null,
                  onPointerUp: (e) {
                    final down = _historyDownPos;
                    if (down != null) {
                      _historyDownPos = null;
                      _pressedHistoryIndex.value = null;
                      final dist = (e.position - down).distance;
                      _debugLog(
                          '[HistoryItem] up w=$w dist=${dist.toStringAsFixed(1)}');
                      if (dist < 10) {
                        _onHistoryWordTap(w);
                      }
                    }
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    // 关键：hover 只更新 ValueNotifier，由 ValueListenableBuilder
                    // 局部重建 Container 高亮；绝不 setState 重建本子树，避免
                    // GestureDetector 的 recognizer 被替换、点击手势被取消。
                    onEnter: (_) => _hoverHistoryIndex.value = i,
                    onExit: (_) => _hoverHistoryIndex.value = null,
                    child: ValueListenableBuilder<int?>(
                      valueListenable: _hoverHistoryIndex,
                      builder: (_, hoverIdx, __) {
                        final hovered = hoverIdx == i;
                        return ValueListenableBuilder<int?>(
                          valueListenable: _pressedHistoryIndex,
                          builder: (_, pressedIdx, child) {
                            final pressed = pressedIdx == i;
                            // 第三关 ⑤：按压 .96 / 80ms + 底色加深 rgba(68,98,242,.16)；
                            // 仍只走 ValueNotifier，保持“绝不 setState 重建本子树”的既有约束。
                            return AnimatedScale(
                              scale: pressed ? 0.96 : 1.0,
                              duration: const Duration(milliseconds: 80),
                              child: Container(
                                // 显式撑满整行宽度：热区 = 整行，不依赖文字长度，
                                // 点词条空白处、文字边缘、右侧任意位置均可触发查询。
                                width: double.infinity,
                                color: pressed
                                    ? const Color(0x294462F2)
                                    : (hovered ? GlassTheme.accentSoft : null),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppTheme.spacingLg,
                                  vertical: 10,
                                ),
                                child: Text(
                                  w,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: hovered
                                        ? GlassTheme.accentInk
                                        : GlassTheme.ink,
                                    fontWeight: hovered
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                );
              }),
          ],
        ),
        ),
      ),
      ),
    ),
  );
  }

  /// 检测单词信息居中长条（分类 + 词性 + 释义，显示在搜索框正下方）
  Widget _buildWordDefBanner() {
    // 走小写索引 O(1) 判命中（_detectedWord 可能保留原文大小写，统一转小写查询）
    final isExtend =
        matchWordEntryKey(_extendWords.toSet(), _detectedWord) != null;
    final isStandard = _detectedCategory != null;
    final chipColor = isExtend
        ? AppTheme.green
        : isStandard
            ? GlassTheme.accent
            : AppTheme.orange; // 真题词橙
    final chipLabel = isExtend
        ? '拓展词'
        : isStandard
            ? (_detectedCategory ?? '')
            : _activeFilter;
    return Padding(
      // 左右边界对齐下方词汇统计面板：右栏内容区各块共用同一条 20px 内边距基准
      // （词频/筛选/统计卡均在 region-content 的 kGap20 Padding 内），
      // 释义长条位于搜索行（region-srow）内、不在该 Padding 内，
      // 故在此显式补同一份 kGap20，保证横向起点/终点与统计面板完全一致。
      padding: const EdgeInsets.only(left: kGap20, right: kGap20, top: kGap8),
      key: const ValueKey('region-defbanner'),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: kGap16, vertical: kGap10),
        decoration: BoxDecoration(
          color: GlassTheme.panel,
          borderRadius: BorderRadius.circular(GlassTheme.rLg),
          border: Border.all(
            color: GlassTheme.accent.withValues(alpha: 0.25),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 窄窗口（如最小 900×600 且右侧原文面板打开）时释义改为第二行居中，
            // 避免释义被挤成单字换行。
            final bool compact = constraints.maxWidth < 560;
            final List<Widget> head = [
              // 分类 + 词性：单行横向排列
              const Text(
                '分类：',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: kGap8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: chipColor,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  chipLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!isExtend && !isStandard) ...[
                const SizedBox(width: kGap10),
                GlassPressable(radius: GlassTheme.rMd, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: InkWell(
                  onTap: () => _showExtendWordDialog(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.green.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(GlassTheme.rMd),
                      border: Border.all(
                        color: AppTheme.green.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Text(
                      '+ 拓展词',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )),
              ],
              if (isStandard || _wordPos.isNotEmpty) ...[
                const SizedBox(width: kGap16),
                // 词性
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: '词性：',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      TextSpan(
                        text: _wordPos.isEmpty ? '?' : _wordPos,
                        style: const TextStyle(
                          fontSize: 13,
                          color: GlassTheme.accentInk,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ];
            const defStyle = TextStyle(
              fontSize: 14,
              color: GlassTheme.accentInk,
              fontWeight: FontWeight.w600,
            );
            if (compact) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 4,
                    children: head,
                  ),
                  if (_wordDef.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      _wordDef,
                      textAlign: TextAlign.center,
                      style: defStyle,
                    ),
                  ],
                ],
              );
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ...head,
                if (_wordDef.isNotEmpty) ...[
                  const SizedBox(width: kGap16),
                  Container(
                    width: 1,
                    height: 20,
                    color: GlassTheme.accent.withValues(alpha: 0.15),
                  ),
                  const SizedBox(width: kGap16),
                  Flexible(
                    child: Text(
                      _wordDef,
                      textAlign: TextAlign.center,
                      style: defStyle,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// 工具栏右侧按钮：始终显示"导出结果"
  Widget _buildToolbarRightButton() {
    return GlassGradientButton(
      label: '导出结果',
      icon: Icons.arrow_downward,
      onPressed: _exportResultToWord,
      height: GlassTheme.hSearchBtn,
    );
  }

  /// 导出检测结果前的「单词标注方案」选择弹窗（返回 null 表示用户取消）。
  ///
  /// 沿用「选择导出格式」同一套玻璃弹窗骨架与紧凑选项块，不新增并行入口：
  /// - 方案一：按单词类型标不同颜色（既有导出）；
  /// - 方案二：按单词类型用字体与格式区分（Times New Roman / 下划线 /
  ///   波浪下划线 / 加粗），一眼可分辨类型。
  Future<ExportAnnotateScheme?> _promptAnnotateScheme() {
    return showDialog<ExportAnnotateScheme>(
      context: context,
      builder: (dctx) {
        var picked = ExportAnnotateScheme.color;
        return _glassDialog(
          StatefulBuilder(
            builder: (ctx, setDialogState) => EswDialogShell(
              title: '选择单词标注方案',
              subtitle: '导出时按所选方案标注原文中的单词：',
              icon: Icons.text_fields,
              minContent: 340,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EswOptionRow(
                    children: [
                      EswOptionTile(
                        label: '方案一',
                        desc: '不同颜色',
                        selected: picked == ExportAnnotateScheme.color,
                        onTap: () => setDialogState(
                          () => picked = ExportAnnotateScheme.color,
                        ),
                      ),
                      EswOptionTile(
                        label: '方案二',
                        desc: '字体与格式',
                        selected: picked == ExportAnnotateScheme.typography,
                        onTap: () => setDialogState(
                          () => picked = ExportAnnotateScheme.typography,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: kGap8),
                  EswDialogHint(
                    picked == ExportAnnotateScheme.color
                        ? '方案一：按类型着色——初中课标词黑色、必修课标词深蓝、'
                            '选修课标词浅蓝、拓展词深绿、超标词红色、专有词紫色，'
                            '不加粗。'
                        : '方案二（黑白打印）：课标词默认不标注；拓展词 加粗；'
                            '超标词 单线下划线；专有词 30% 灰底纹；'
                            '全文西文统一 Times New Roman。',
                    icon: Icons.info_outline,
                  ),
                ],
              ),
              actions: EswDialogActions(
                children: [
                  EswDialogTextAction(
                    label: '取消',
                    onPressed: () => Navigator.pop(dctx),
                  ),
                  EswDialogPrimaryAction(
                    label: '下一步',
                    onPressed: () => Navigator.pop(dctx, picked),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 导出格式选择（docx / pdf）。返回 null 表示用户取消。
  ///
  /// 先定格式再打保存对话框：保存框里只保留所选类型，建议文件名后缀与格式
  /// 始终一致，避免原生对话框切换类型时文件名后缀不跟随的问题。
  Future<String?> _promptExportFormat() {
    return showDialog<String>(
      context: context,
      builder: (dctx) {
        var picked = 'docx';
        return _glassDialog(
          StatefulBuilder(
            builder: (ctx, setDialogState) => EswDialogShell(
              title: '选择导出格式',
              subtitle: 'Word 可保留原文档排版；PDF 适合直接打印或分享。',
              icon: Icons.save_alt_rounded,
              minContent: 340,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EswOptionRow(
                    children: [
                      EswOptionTile(
                        label: 'Word 文档',
                        desc: '*.docx',
                        selected: picked == 'docx',
                        onTap: () => setDialogState(() => picked = 'docx'),
                      ),
                      EswOptionTile(
                        label: 'PDF 文档',
                        desc: '*.pdf',
                        selected: picked == 'pdf',
                        onTap: () => setDialogState(() => picked = 'pdf'),
                      ),
                    ],
                  ),
                  const SizedBox(height: kGap8),
                  const EswDialogHint(
                    '选择后进入保存对话框，文件名后缀会与所选格式保持一致。',
                    icon: Icons.info_outline,
                  ),
                ],
              ),
              actions: EswDialogActions(
                children: [
                  EswDialogTextAction(
                    label: '取消',
                    onPressed: () => Navigator.pop(dctx),
                  ),
                  EswDialogPrimaryAction(
                    label: '下一步',
                    onPressed: () => Navigator.pop(dctx, picked),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 导出前提示：存在未筛选词时，用户可先去筛选列归类，也可直接继续导出。
  ///
  /// 返回 true 表示用户选择「继续导出」。
  Future<bool> _promptUnfilteredBeforeExport(int count) async {
    if (!mounted) return false;
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => _glassDialog(
        EswDialogShell(
          title: '还有未筛选的词',
          subtitle: '当前检测结果中仍有 $count 个未筛选的词。未筛选词不参与导出标注，'
              '你可以先去筛选列把它们归类到课标词 / 拓展词 / 超标词 / 专有词，'
              '也可以直接继续导出。',
          icon: Icons.filter_alt_off,
          body: const SizedBox.shrink(),
          actions: EswDialogActions(
            children: [
              EswDialogTextAction(
                label: '取消',
                onPressed: () => Navigator.pop(dctx),
              ),
              EswDialogTextAction(
                label: '去筛选',
                onPressed: () => Navigator.pop(dctx, 'filter'),
              ),
              EswDialogPrimaryAction(
                label: '继续导出',
                onPressed: () => Navigator.pop(dctx, 'continue'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == 'filter' && mounted) {
      setState(() => _importedActiveFilter = '未筛选');
    }
    return choice == 'continue';
  }

  /// 将导入的原文导出为 docx / pdf，按所选方案标注单词（纯 Dart 实现，无 Python 依赖）
  Future<void> _exportResultToWord() async {
    // 文档检测模式优先：已导入文档并完成检测时，导出文档检测结果
    if (_inImportedMode && _importedWords.isNotEmpty) {
      // 进入下方文档检测结果导出流程
    } else if (_detectedWord.isNotEmpty &&
        (_results.isNotEmpty || _textbookResults.isNotEmpty)) {
      // 查词模式（未导入文档检测）：导出当前单词例句汇总
      await _exportWordSentenceDocx();
      return;
    } else {
      // 未检测：提示先检测
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先导入文本并完成检测后再导出')));
      return;
    }
    // 导出前提示：仍有未筛选词时询问用户，选择继续则照常导出（未筛选词不标注）。
    final unfilteredCount = _importedFilterCounts['未筛选'] ?? 0;
    if (unfilteredCount > 0) {
      // 自动化取证（ESW_AUTO_OUT）下不弹窗，直接终止导出
      final autoOut = Platform.environment['ESW_AUTO_OUT'];
      if (autoOut != null && autoOut.isNotEmpty) return;
      final proceed = await _promptUnfilteredBeforeExport(unfilteredCount);
      if (!proceed || !mounted) return;
    }
    // 单词标注方案：导出前弹窗让用户二选一（方案一配色 / 方案二字体格式）。
    // 复用「选择导出格式」同一套弹窗骨架与选项块（EswDialogShell + EswOptionRow），
    // 不另设并行入口；用户取消则不导出。
    final autoScheme = Platform.environment['ESW_AUTO_ANNOTATE'];
    final autoOut = Platform.environment['ESW_AUTO_OUT'];
    ExportAnnotateScheme? scheme;
    if (autoScheme == 'color') {
      scheme = ExportAnnotateScheme.color;
    } else if (autoScheme == 'typography') {
      scheme = ExportAnnotateScheme.typography;
    } else if (autoOut != null && autoOut.isNotEmpty) {
      // 自动化取证（ESW_AUTO_OUT 已指定输出路径）沿用既有方案一，不弹窗阻塞。
      scheme = ExportAnnotateScheme.color;
    } else {
      scheme = await _promptAnnotateScheme();
    }
    if (scheme == null || !mounted) return;
    // 先选格式再保存：保存对话框只列所选类型，建议文件名后缀与格式一致，
    // 从根上避免「选了 PDF 但文件名仍是 .docx」的问题。
    // 自动化取证钩子：ESW_AUTO_OUT 指定输出路径时跳过两个选择弹窗。
    final autoOutPath = Platform.environment['ESW_AUTO_OUT'];
    String chosenExt;
    if (autoOutPath != null && autoOutPath.isNotEmpty) {
      chosenExt =
          p.extension(autoOutPath).toLowerCase() == '.pdf' ? 'pdf' : 'docx';
    } else {
      final picked = await _promptExportFormat();
      if (picked == null || !mounted) return;
      chosenExt = picked;
    }
    String? outPath;
    if (autoOutPath != null && autoOutPath.isNotEmpty) {
      outPath = autoOutPath;
    } else {
      try {
        String baseName = 'ESW_分析结果';
        if (_importedFileName != null && _importedFileName!.isNotEmpty) {
          final dotIdx = _importedFileName!.lastIndexOf('.');
          baseName = dotIdx > 0
              ? _importedFileName!.substring(0, dotIdx)
              : _importedFileName!;
        }
        final fs.FileSaveLocation? result = await fs.getSaveLocation(
          suggestedName: '$baseName课标词检测.$chosenExt',
          acceptedTypeGroups: [
            if (chosenExt == 'pdf')
              const fs.XTypeGroup(
                label: 'PDF 文档 (*.pdf)',
                extensions: ['pdf'],
              )
            else
              const fs.XTypeGroup(
                label: 'Word 文档 (*.docx)',
                extensions: ['docx'],
              ),
          ],
          initialDirectory: _lastExportPath,
        );
        // 原生保存对话框关闭后立刻整窗重绘，避免顶栏残留对话框投影形成条带
        WinWindowRepaint.burst();
        if (result == null) return; // 用户取消保存
        outPath = result.path;
        // 后缀强制与所选格式一致（用户可能在保存框里手动改过名字/后缀）
        final curExt = p.extension(outPath).toLowerCase();
        final wantExt = '.$chosenExt';
        if (curExt != wantExt) {
          outPath = curExt.isEmpty
              ? '$outPath$wantExt'
              : '${outPath.substring(0, outPath.length - curExt.length)}$wantExt';
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择保存路径失败: $e')));
        WinWindowRepaint.burst();
        return;
      }
    }
    // 原文文本：文档检测模式下输入框即为当前导入文档全文，直接取输入框；
    // 仅当从文档检测进入单词查词模式（_inImportedMode=false 且已保存返回现场）时
    // 回退到保存的导入文本，避免导入新文档后导出内容错源为上一份文件。
    final originalText = (_inImportedMode || _savedImportedText.isEmpty)
        ? _searchController.text
        : _savedImportedText;
    // ===== 导出等待提示 =====
    // 文档检测结果导出需统计真题词频、构建拓展/超标词表并逐段排版写盘，
    // 长文档实测耗时十余秒且全程占用主线程，此前无任何界面反馈，用户会误判为卡死。
    // 此处立即弹出不可取消的进度窗（阶段文案 + 已用时秒数），结束后统一关闭。
    final exportProgress = await _beginExportProgress(
      '正在准备导出数据…',
      delayMs: 0,
    );
    final setExportStage = exportProgress.setStage;

    try {
      // 构建 小写单词 -> 导出标注分类 映射（双端口径唯一真源）
      //
      // - 课标词按课标级别细分为「初中课标词 / 必修课标词 / 选修课标词」：
      //   与汇总统计（[_standardCategoryCounts]）、标注说明（七类图例）逐类对齐，
      //   统计分三类则正文也必须分三类着色，否则图例宣称的颜色在正文里查无对应；
      // - 「未筛选」在真题语料出现过 → 「真题词」（叠加维度，不参与配色），
      //   否则 → 「未筛选」（土红色），与筛选列的类别定义完全一致；
      // - 手动归入拓展 / 超标 / 专有的词仍按实际类别着色。
      final wordCatMap = <String, String>{};
      for (final iw in _importedWords) {
        final lower = iw.word.toLowerCase();
        var level = '';
        if (iw.category == '课标词') {
          final key = findWordEntryKey(_standardWords, iw.word);
          if (key != null) level = _standardWords[key]?['category'] ?? '';
        }
        wordCatMap[lower] = exportAnnotateCategoryOfDetected(
          category: iw.category,
          standardLevel: level,
          isInCorpus: iw.isInCorpus,
        );
      }
      // 换机首次导出：本地可能尚未部署词典库（无 ecdict.db），
      // 先确保部署到位，否则本次导出的释义列为空。已部署时仅做存在性/版本判断。
      await setExportStage('正在准备词典库…');
      await DictionaryService.ensureDeployedDbPath();
      await setExportStage('正在统计真题词频并生成词表…');
      // 构建新格式导出表格数据：拓展词明细（真题词频 < 400）+ 超标词表
      final exportData = await _buildExportTableData(originalText);
      final ext = p.extension(outPath).toLowerCase();
      final formatLabel = switch (ext) {
        '.pdf' => 'PDF 文档',
        _ => 'Word(docx) 文档',
      };
      await setExportStage('正在生成$formatLabel并写入文件…');
      if (ext == '.pdf') {
        await _writeResultPdf(
          outPath,
          originalText: originalText,
          wordCatMap: wordCatMap,
          fileName: _importedFileName ?? '',
          exportData: exportData,
          scheme: scheme,
        );
      } else {
        // .docx 导出：若源文件是 docx，走“原地标注”保留原排版格式；
        // 否则（pdf 或粘贴文本）退回重新生成模式
        final srcPath = _importedFilePath;
        final srcExt =
            srcPath != null ? p.extension(srcPath).toLowerCase() : '';
        if (srcPath != null &&
            srcExt == '.docx' &&
            File(srcPath).existsSync()) {
          await _writeResultDocxInplace(
            outPath,
            srcPath: srcPath,
            wordCatMap: wordCatMap,
            fileName: _importedFileName ?? '',
            exportData: exportData,
            scheme: scheme,
          );
        } else {
          // .pdf / 粘贴文本等非 docx 源：统一重新生成 Word 标注文档（.docx）。
          // 不再弹出"无法原位保留原排版"提示——生成新 docx 即为预期导出行为，
          // 原排版保留仅对 .docx 源文件生效（走上方 _writeResultDocxInplace）。
          await _writeResultDocx(
            outPath,
            originalText: originalText,
            wordCatMap: wordCatMap,
            fileName: _importedFileName ?? '',
            exportData: exportData,
            scheme: scheme,
          );
        }
      }
      WinWindowRepaint.burst();
      _lastExportPath = Directory(outPath).parent.path;
      _saveConfig();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出分析结果到：$outPath')));
    } catch (e, st) {
      _debugLog('[Export] fail: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    } finally {
      // 无论成功、失败还是中途返回，均需关闭等待提示并停掉计时器，
      // 否则进度窗会残留在界面上遮挡操作。
      exportProgress.close();
    }
  }

  /// 弹出导出等待提示（全窗口毛玻璃遮罩 + 阶段文案 + 已用时秒数）。
  ///
  /// [delayMs] 为弹窗延迟出现时间：耗时短的导出（<0.5s）不弹窗，避免闪一下；
  /// 已确认的长任务（文档检测导出）传 0 立即弹出。
  /// 返回的控制器必须在导出结束时调用 `close()`，否则弹窗残留。
  Future<_ExportProgress> _beginExportProgress(
    String initialStage, {
    int delayMs = 500,
    String? hint,
  }) async {
    final progress = _ExportProgress(
      ValueNotifier<String>(initialStage),
      ValueNotifier<double>(0),
    );
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    if (!mounted || progress.isClosed) return progress;
    progress.startTicking();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) {
        progress.attachDialog(dctx);
        return _glassDialog(
          EswDialogShell(
            minContent: 300,
            body: _ExportProgressBody(progress: progress, hint: hint),
          ),
        );
      },
    );
    // 等入场动画与首帧绘制完成再进入耗时流程，确保提示完整可见
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return progress;
  }

  /// 查词模式：导出当前单词在真题与教材中的例句汇总 Word 文档（.docx）。
  /// 真题例句按年份倒序分组、教材例句按教材名分组，真题在前、教材在后；
  /// 保存位置逻辑与其他导出一致（file_selector + _lastExportPath）。
  Future<void> _exportWordSentenceDocx() async {
    final word = _detectedWord;
    String? outPath;
    try {
      final fs.FileSaveLocation? result = await fs.getSaveLocation(
        suggestedName: '${word}_例句汇总.docx',
        acceptedTypeGroups: const [
          fs.XTypeGroup(label: 'Word 文档 (*.docx)', extensions: ['docx']),
        ],
        initialDirectory: _lastExportPath,
      );
      WinWindowRepaint.burst();
      if (result == null) return; // 用户取消
      outPath = result.path;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('选择保存路径失败: $e')));
      return;
    }
    // 等待提示：例句汇总需遍历真题/教材语料并排版 Word，语料多时同样耗时，
    // 延迟 0.5s 未完成才弹窗，快速导出不闪屏。
    final progress = await _beginExportProgress(
      '正在汇总真题与教材例句…',
      hint: '语料越多耗时越长，请耐心等待',
    );
    try {
      await progress.setStage('正在生成 Word 文档并写入文件…');
      await _writeWordSentenceDocx(outPath, word);
      WinWindowRepaint.burst();
      _lastExportPath = Directory(outPath).parent.path;
      _saveConfig();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出 $word 例句汇总到：$outPath')));
    } catch (e, st) {
      _debugLog('[Export] fail: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    } finally {
      progress.close();
    }
  }

  /// 构建导出用新格式表格数据：拓展词明细（仅真题词频 < 400）+ 超标词表。
  /// 原文例句取自导入原文，高考例句取自选中真题语料，教材例句取自选中教材文件（无则留空）。
  Future<_ExportTableData> _buildExportTableData(String originalText) async {
    // 耗时归因（仅 ESW_PERF_PROBE 下输出，生产零开销）
    final swExport = Stopwatch()..start();
    void plog(String tag) => EswPerf.logFile(
        '[export] $tag dt=${swExport.elapsedMilliseconds}ms');
    // 出帧呼吸器：只要连续占用 UI 线程超过 8ms 就让出一次事件循环。
    // Dart 的 await 命中同步缓存时只是微任务，不会把控制权交还事件循环，
    // Flutter 因此无法出帧 —— 表现就是导出期间整窗不重绘、顶栏条带/割裂。
    // Future.delayed(Duration.zero) 是真正的 Timer 轮转，可让引擎出帧。
    final swBreathe = Stopwatch()..start();
    Future<void> breathe({bool force = false}) async {
      if (!force && swBreathe.elapsedMilliseconds < 8) return;
      swBreathe.reset();
      await Future<void>.delayed(Duration.zero);
    }
    // 教材合并文本（教材例句来源）
    final tbSb = StringBuffer();
    for (final cf in _textbookFiles.where((f) => f.isSelected)) {
      try {
        tbSb.writeln(await _readFileTextCached(cf.path));
      } catch (_) {}
    }
    final textbookText = tbSb.toString();

    // 拓展词明细：仅保留真题词频 < 400 的单词（保留原文大小写、全局去重）
    final lowFreqExtend = <String>[];
    final seenLow = <String>{};
    for (final iw in _importedWords) {
      if (iw.category != '拓展词') continue;
      if (iw.totalFreq >= 400) continue;
      final lw = iw.word.toLowerCase();
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
          resolveBaseWord(glued != null ? glued.group(1)! : w, _baseWordOf)
              .toLowerCase();
      if (base == 'be' || base == 'ok') return true;
      return isSimpleInflection(w, _isStandardWord);
    });
    // 按题型分组（原文按题型标题行归属区间，组内同句多词合并成一行）
    List<ExtendSection> sections = buildExtendSections(
      text: originalText,
      extendWords: lowFreqExtend,
      baseWordOf: _baseWordOf,
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
                baseWord: _baseWordOf(w),
              ),
          ],
        ),
      ];
    }
    plog('extendSections rows=${sections.fold<int>(0, (a, s) => a + s.rows.length)}');
    // 教材例句源建一次句子索引，供所有拓展词行复用
    final textbookIndex = buildSentenceIndex(textbookText);
    // 教材"完整句"索引：同样只建一次。原实现对每个拓展词都重新整篇归一化+切句，
    // 复杂度是「词数 × 教材全文长度」，直接卡死主线程（导出的主要耗时来源）。
    final textbookFullIndex = buildFullSentenceIndex(textbookText);
    plog('textbook chars=${textbookText.length} '
        'sentences=${textbookFullIndex.length}');

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
    final fileWordRe = wordTokenRegExp;
    var corpusIdx = 0;
    for (final cf in _corpusFiles.where((f) => f.isSelected)) {
      corpusIdx++;
      final swFile = Stopwatch()..start();
      final String fileText;
      try {
        fileText = await _readFileTextCached(cf.path);
      } catch (_) {
        continue;
      }
      final readMs = swFile.elapsedMilliseconds;
      final year = _yearPrefixRegex.firstMatch(cf.name)?.group(1) ?? '';
      // 整文件预检：拆词后只保留出现在目标词集合里的词，避免无谓建索引/切句
      final hitQueries = <String>{};
      for (final m in fileWordRe.allMatches(fileText)) {
        final raw = m.group(0)!;
        final glued = gluedLetterRe.firstMatch(raw);
        final q = (glued != null ? glued.group(1)! : raw).toLowerCase();
        if (extendQueryWords.contains(q)) hitQueries.add(q);
      }
      if (hitQueries.isEmpty) {
        if (readMs > 120) plog('corpus#$corpusIdx read=${readMs}ms noHit');
        continue;
      }
      await breathe(force: true);
      final swIdx = Stopwatch()..start();
      final idx = buildSentenceIndex(fileText);
      final idxMs = swIdx.elapsedMilliseconds;
      final swCand = Stopwatch()..start();
      // 一次扫描收集所有命中词的整句候选，替代逐词全量扫描（大幅提速）
      final candsByWord = collectSentenceCandidates(idx, hitQueries);
      final candMs = swCand.elapsedMilliseconds;
      if (readMs + idxMs + candMs > 120) {
        plog('corpus#$corpusIdx ${cf.name} chars=${fileText.length} '
            'read=${readMs}ms idx=${idxMs}ms cand=${candMs}ms '
            'words=${hitQueries.length}');
      }
      for (final q in hitQueries) {
        await breathe();
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
    plog('gaokao corpusFiles=${_corpusFiles.where((f) => f.isSelected).length} '
        'words=${extendQueryWords.length}');
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
      final def = await _posDefOf(lw);
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
    String resolveUsageFromIndex(SentenceIndex idx, String word) {
      final ws = word.split(' ').where((w) => w.isNotEmpty).toList();
      if (ws.isEmpty) return '';
      // 完整句优先：走一次性建好的索引，语义与 pickFullSentenceFromText 等价
      final sentence = pickFullSentenceFromIndex(
        textbookFullIndex,
        ws,
        fallbackToFirst: true,
      );
      if (sentence.isNotEmpty) return sentence;
      return pickPhraseFromIndex(idx, ws);
    }

    final extendSections = <_ExportExtendSection>[];
    // ignore: unused_local_variable
    var yieldedRows = 0;
    for (final sec in sections) {
      final items = <_ExportExtendItem>[];
      for (final r in sec.rows) {
        // 关键：按时间阈值显式让出事件循环（见 breathe 说明），保证持续出帧。
        yieldedRows++;
        await breathe();
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
          textbookExample: resolveUsageFromIndex(textbookIndex, r.word),
        ));
      }
      extendSections.add(_ExportExtendSection(name: sec.name, items: items));
    }

    plog('extendDetail sections=${extendSections.length} '
        'items=${extendSections.fold<int>(0, (a, s) => a + s.items.length)}');
    // 超标词表：按题型分组（复用 buildExtendSections，课标原词回调对超标词返回空串），
    // 每词输出 单词 / 词性.释义 / 原文例句（例句取所在题型区间的较短句）
    final overLimitWords = <String>[];
    final seenOver = <String>{};
    for (final iw in _importedWords) {
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
    // ignore: unused_local_variable
    var yieldedOver = 0;
    for (final sec in overSections) {
      final items = <_ExportOverLimitItem>[];
      for (final r in sec.rows) {
        yieldedOver++;
        await breathe();
        final def = await _posDefOf(r.word);
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
    plog('overLimit sections=${overLimitSections.length} '
        'items=${overLimitSections.fold<int>(0, (a, s) => a + s.items.length)}');
    plog('done');
    return _ExportTableData(
      extend: extendSections,
      overLimit: overLimitSections,
    );
  }

  /// 判断单词是否为课标词（精确优先，大写写法可回退到同名小写词条）。
  bool _isStandardWord(String word) =>
      findWordEntryKey(_standardWords, word) != null;

  /// 拓展词 → 课标原词：优先用户关联映射（extendBaseMap），其次反向索引，最后课标词库本身。
  String _baseWordOf(String word) {
    final linked = _extendBaseMap[word.toLowerCase()] ?? _extendBaseMap[word];
    if (linked != null && linked.isNotEmpty) return linked;
    final b = _extendReverseIndex[word.toLowerCase()];
    if (b == null) {
      final ms2 = _standardWordsLower[word.toLowerCase()];
      return (ms2 != null && ms2.isNotEmpty) ? ms2.first : '';
    }
    final ms = _standardWordsLower[b];
    return (ms != null && ms.isNotEmpty) ? ms.first : b;
  }

  /// 获取单词"词性.释义"组合文本（参照查词页 _buildWordDefBanner 数据来源）：
  /// 课标词库 def 与词典 definition 均自带词性前缀（如 "n. 洞穴, 岩穴, 洞室"），
  /// 因此直接返回释义字段即可；取不到时留空。
  Future<String> _posDefOf(String word) async {
    final lowerList = _standardWordsLower[word.toLowerCase()];
    if (lowerList != null && lowerList.isNotEmpty) {
      final sw = _standardWords[lowerList.first];
      final def = sw?['def'] ?? '';
      if (def.isNotEmpty) return def;
    }
    final entry = await DictionaryService.lookup(word);
    return entry?['definition'] ?? '';
  }

  /// 生成新格式拓展词明细纯文本（按题型分组 + 每词五行，不用表格）。
  /// 组内按 1. 2. 3. 编号；课标原词/原文例句/高考例句取不到留空，教材例句无则写"无"。
  String _buildExtendDetailPlain(List<_ExportExtendSection> sections) {
    if (sections.isEmpty) return '本套题无真题词频低于 400 次的拓展词';
    final sb = StringBuffer();
    var first = true;
    for (final sec in sections) {
      if (sec.items.isEmpty) continue; // 无词的题型区块不输出
      if (!first) sb.writeln();
      first = false;
      sb.writeln(sec.name);
      for (var i = 0; i < sec.items.length; i++) {
        final it = sec.items[i];
        final no = i + 1;
        sb.writeln('$no. ${it.word}');
        sb.writeln('课标原词：${it.baseWord}');
        sb.writeln('原文用法：${it.originalExample}');
        if (it.gaokaoExamples.isEmpty) {
          sb.writeln('高考用法：');
        } else {
          final words = it.word.split(' ');
          for (final g in it.gaokaoExamples) {
            final prefix = words.length > 1 ? '高考用法·${g.word}：' : '高考用法：';
            sb.writeln(
                '$prefix${g.example}${g.year.isNotEmpty ? '（${g.year}）' : ''}');
          }
        }
        sb.writeln('教材用法：${it.textbookExample.isEmpty ? '无' : it.textbookExample}');
      }
    }
    return sb.toString();
  }

  /// 生成超标词纯文本（按题型分组 + 每词三行，无标签前缀，不用表格）。
  /// 题型标题行为纯题型名；组内每词：第一行编号+单词，第二行词性.释义（无则留空），
  /// 第三行原文例句（无则留空）。
  String _buildOverLimitPlain(List<_ExportOverLimitSection> sections) {
    if (sections.isEmpty) return '本套题未检测到超标词';
    final sb = StringBuffer();
    var first = true;
    for (final sec in sections) {
      if (sec.items.isEmpty) continue; // 无词的题型区块不输出
      if (!first) sb.writeln();
      first = false;
      sb.writeln(sec.name);
      for (var i = 0; i < sec.items.length; i++) {
        final it = sec.items[i];
        final no = i + 1;
        sb.writeln('$no. ${it.word}');
        sb.writeln(it.posDef);
        sb.writeln(it.originalExample);
      }
    }
    return sb.toString();
  }

  // ==================== 导出汇总（附件设计图基准）====================
  // 条目名称、顺序、配色与"结果为 0 的类别不显示"规则统一在 lib/export_summary.dart
  // 中实现（纯函数，附带单测），本类只负责提供统计数据。

  /// 统计"课标词"按课标级别（初中/必修/选修）的拆分数量。
  Map<String, int> _standardCategoryCounts() {
    final counts = <String, int>{'初中': 0, '必修': 0, '选修': 0};
    for (final w in _importedWords) {
      if (w.category != '课标词') continue;
      String cat = '';
      final key = findWordEntryKey(_standardWords, w.word);
      if (key != null) cat = _standardWords[key]?['category'] ?? '';
      if (counts.containsKey(cat)) counts[cat] = counts[cat]! + 1;
    }
    return counts;
  }

  /// 导出汇总条目列表（顺序、命名、配色以附件设计图为准；0 值类别不显示）。
  List<ExportSummaryItem> _buildExportSummaryItems() => buildExportSummaryItems(
        totalRawCount:
            _importedWords.fold<int>(0, (sum, w) => sum + w.frequency),
        dedupCount: _importedWords.length,
        filterCounts: _importedFilterCounts,
        standardCategoryCounts: _standardCategoryCounts(),
      );

  /// 生成 DOCX 汇总段：条目按设计图着色，段间以竖线分隔，不设高亮底色。
  String _docxSummaryParagraph() {
    final items = _buildExportSummaryItems();
    final runs = <String>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) runs.add(_docxRun(' | ', ExportSummaryItem.black));
      runs.add(_docxRun('${items[i].label}: ${items[i].value}',
          items[i].colorHex, bold: items[i].bold));
    }
    return '<w:p>${runs.join('')}</w:p>';
  }

  /// 生成 DOCX 结果文档：标题 + 统计信息 + 标注说明 + 带标注全文（按分类着色）。
  /// DOCX 本质是 ZIP 包，这里用 archive 包手写最小可用 OOXML 文档。
  Future<void> _writeResultDocx(
    String path, {
    required String originalText,
    required Map<String, String> wordCatMap,
    required String fileName,
    required _ExportTableData exportData,
    required ExportAnnotateScheme scheme,
  }) async {
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('ESW 课标词检测导出', bold: true));
    bodyParts.add(_docxParagraph('文件名: $fileName'));
    // 标注说明只保留一份：方案一用彩色统计行；方案二用带样式的图例行。
    bodyParts.add(_docxParagraph('【标注说明】', bold: true));
    if (scheme == ExportAnnotateScheme.color) {
      bodyParts.add(_docxSummaryParagraph());
    } else {
      bodyParts.add(_docxAnnotateLegendParagraph(scheme));
    }
    bodyParts.add(_docxParagraph('带标注全文', bold: true));
    bodyParts.add(_docxAnnotatedParagraph(originalText, wordCatMap, scheme));
    bodyParts.addAll(_buildDocxDetailParagraphs(exportData));
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
    // 注意：必须用 ArchiveFile(name, 字节长度, 字节) 构造，保证 zip 中记录
    // 的 uncompressed size 是 UTF-8 字节数。用 ArchiveFile.string 会按字符数
    // 记大小，中文内容会导致大小不符，部分阅读器按错误大小截断 document.xml
    // 而出现乱码/内容异常。
    archive.addFile(
      ArchiveFile(
        '[Content_Types].xml',
        utf8.encode(contentTypes).length,
        utf8.encode(contentTypes),
      ),
    );
    archive.addFile(
      ArchiveFile('_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)),
    );
    archive.addFile(
      ArchiveFile(
        'word/document.xml',
        utf8.encode(documentXml).length,
        utf8.encode(documentXml),
      ),
    );
    final encoder = ZipEncoder();
    final bytes = encoder.encode(archive);
    if (bytes == null) throw Exception('DOCX 生成失败');
    await File(path).writeAsBytes(bytes);
  }

  /// 构建 DOCX 文末明细段落：拓展词明细 + 超标词表（原地标注与重新生成模式共用）。
  List<String> _buildDocxDetailParagraphs(_ExportTableData exportData) {
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('【拓展词明细】', bold: true));
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
    bodyParts.add(_docxParagraph('【超标词】', bold: true));
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

  /// 构建 DOCX 正文前汇总段（原地标注用）：标题 + 文件名 + 标注说明。
  ///
  /// 标注说明只保留一份：方案一用彩色统计行；方案二用带样式的图例行。
  List<String> _buildDocxPreambleParagraphs({
    required String fileName,
    required _ExportTableData exportData,
    required ExportAnnotateScheme scheme,
  }) {
    return [
      _docxParagraph('ESW 课标词检测导出', bold: true),
      _docxParagraph('文件名: $fileName'),
      _docxParagraph('【标注说明】', bold: true),
      if (scheme == ExportAnnotateScheme.color)
        _docxSummaryParagraph()
      else
        _docxAnnotateLegendParagraph(scheme),
    ];
  }

  /// 生成 DOCX 标注说明段（方案二）：逐项呈现全部统计条目——
  /// 总数类（全套词词数 / 去重总词数 / 真题词 / 其他）以「名称: 数值」中性黑输出，
  /// 七类词以「名称（n 词）」并按方案二样式（加粗 / 单线 / 灰底纹）呈现。
  /// 不遗漏项目，也不与方案一的彩色统计行同时出现。
  String _docxAnnotateLegendParagraph(ExportAnnotateScheme scheme) {
    final items = _buildExportSummaryItems();
    final runs = <String>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (i > 0) runs.add(_docxRun(' | ', ExportSummaryItem.black));
      if (!ExportCategory.all.contains(item.label)) {
        // 总数类 / 真题词 / 其他：中性黑、不加样式
        runs.add(_docxRun('${item.label}: ${item.value}', ExportSummaryItem.black));
        continue;
      }
      final text = '${item.label}（${item.value} 词）';
      if (scheme == ExportAnnotateScheme.typography) {
        final style = exportScheme2StyleOf(item.label);
        runs.add(docxRunXml(
          text,
          ExportSummaryItem.black,
          fontName: kExportTypographyFont,
          bold: style?.bold ?? false,
          underline: style?.underline,
          shadeFill: style?.shadeFill,
        ));
      } else {
        runs.add(_docxRun(text, item.colorHex));
      }
    }
    return '<w:p>${runs.join('')}</w:p>';
  }

  /// 构建 DOCX 文末明细节段落（原地标注追加用）：分页 + 拓展词明细 + 超标词。
  List<String> _buildDocxAppendixParagraphs({
    required _ExportTableData exportData,
  }) {
    return [
      '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
      ..._buildDocxDetailParagraphs(exportData),
    ];
  }

  /// 原地标注导出：源文件为 .docx 时，只改写 word/document.xml（目标词拆 run +
  /// 追加高亮/颜色/加粗），其余部件原样保留，从而完整保留原文档排版格式；
  /// 正文前插入汇总段（标题 + 统计 + 标注说明），文末追加分页明细节。
  Future<void> _writeResultDocxInplace(
    String path, {
    required String srcPath,
    required Map<String, String> wordCatMap,
    required String fileName,
    required _ExportTableData exportData,
    required ExportAnnotateScheme scheme,
  }) async {
    final srcBytes = await File(srcPath).readAsBytes();
    final preamble = _buildDocxPreambleParagraphs(
      fileName: fileName,
      exportData: exportData,
      scheme: scheme,
    );
    final appendix = _buildDocxAppendixParagraphs(
      exportData: exportData,
    );
    final swWrite = Stopwatch()..start();
    // 大文档的 OOXML 标注+zip 重打包是纯 CPU 同步活儿（数百 ms 起），
    // 放在 UI 线程会整窗停帧、顶栏出现条带/割裂，故大于阈值时改到独立 isolate。
    List<int> bytes;
    if (srcBytes.length >= 120000) {
      bytes = await Isolate.run(() => annotateDocxBytes(
            srcBytes: srcBytes,
            catByLower: wordCatMap,
            preambleParagraphsXml: preamble,
            appendixParagraphsXml: appendix,
            scheme: scheme,
            colorBold: false,
            annotateUnfiltered: false,
          ));
    } else {
      bytes = annotateDocxBytes(
        srcBytes: srcBytes,
        catByLower: wordCatMap,
        preambleParagraphsXml: preamble,
        appendixParagraphsXml: appendix,
        scheme: scheme,
        colorBold: false,
        annotateUnfiltered: false,
      );
    }
    EswPerf.logFile('[export] annotateDocx ms=${swWrite.elapsedMilliseconds} '
        'src=${srcBytes.length}B out=${bytes.length}B');
    await File(path).writeAsBytes(bytes);
  }

  /// 生成单词例句汇总 DOCX：真题例句按年份倒序分组、教材例句按教材名分组，
  /// 真题在前、教材在后；复用 _writeResultDocx 的手写 OOXML 封装机制。
  Future<void> _writeWordSentenceDocx(String path, String word) async {
    final bodyParts = <String>[];
    bodyParts.add(_docxParagraph('$word 例句汇总', bold: true));
    bodyParts.add(_docxParagraph('高考用法按年份倒序、教材用法按教材分组。'));

    // 词性判断缓存（名/形整句过长降级为词组，与拓展词明细口径一致）
    final nounAdjCache = <String, bool>{};
    Future<bool> isNounAdjOf(String w) async {
      final lw = w.toLowerCase();
      final cached = nounAdjCache[lw];
      if (cached != null) return cached;
      final def = await _posDefOf(lw);
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

    final wordIsNounAdj = await isNounAdjOf(word);
    // 单条例句应用用法提取逻辑：动/副整句优先；名/形且整句过长（>12 词）
    // 降级为 3-5 词词组；降级取不到时保留原句，例句汇总不丢数据。
    String usageOf(String sentence) {
      final s = sentence.trim();
      if (s.isEmpty) return '';
      final resolved = resolveUsageText(s, s, word, wordIsNounAdj);
      return resolved.isNotEmpty ? resolved : s;
    }
    // 真题例句：按年份倒序分组（年份从文件名前缀提取），每组标题带年份；
    // 无法识别年份的按文件名分组放在最后，避免遗漏数据。
    final yearGroups = <int, List<String>>{};
    final noYearRows = <({String name, String sentence})>[];
    for (final r in _results) {
      final yearMatch = _yearPrefixRegex.firstMatch(r.source);
      if (yearMatch != null) {
        final y = int.parse(yearMatch.group(1)!);
        yearGroups.putIfAbsent(y, () => []).add(r.sentence);
      } else {
        noYearRows.add((name: r.source, sentence: r.sentence));
      }
    }
    if (yearGroups.isNotEmpty || noYearRows.isNotEmpty) {
      bodyParts.add(_docxParagraph('高考用法', bold: true));
      final yearsDesc = yearGroups.keys.toList()..sort((a, b) => b.compareTo(a));
      for (final y in yearsDesc) {
        bodyParts.add(_docxParagraph('$y年', bold: true));
        for (final s in yearGroups[y]!) {
          bodyParts.add(_docxParagraphWithBoldWords(usageOf(s), [word]));
        }
      }
      for (final nr in noYearRows) {
        bodyParts.add(_docxParagraph(nr.name, bold: true));
        bodyParts.add(_docxParagraphWithBoldWords(usageOf(nr.sentence), [word]));
      }
    }
    // 教材例句：按教材名分组（保持教材顺序），每组标题带教材名
    if (_textbookResults.isNotEmpty) {
      bodyParts.add(_docxParagraph('教材用法', bold: true));
      final tbGroups = <String, List<String>>{};
      for (final r in _textbookResults) {
        final name = _textbookNameByPath(r.filePath);
        tbGroups.putIfAbsent(name, () => []).add(r.sentence);
      }
      for (final entry in tbGroups.entries) {
        bodyParts.add(_docxParagraph(entry.key, bold: true));
        for (final s in entry.value) {
          bodyParts.add(_docxParagraphWithBoldWords(usageOf(s), [word]));
        }
      }
    }
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
    archive.addFile(
      ArchiveFile(
        '[Content_Types].xml',
        utf8.encode(contentTypes).length,
        utf8.encode(contentTypes),
      ),
    );
    archive.addFile(
      ArchiveFile('_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)),
    );
    archive.addFile(
      ArchiveFile(
        'word/document.xml',
        utf8.encode(documentXml).length,
        utf8.encode(documentXml),
      ),
    );
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
    final runs =
        '<w:r><w:rPr>${bold ? '<w:b/>' : ''}</w:rPr>'
        '<w:t xml:space="preserve">$escaped</w:t></w:r>';
    return '<w:p>$runs</w:p>';
  }

  /// 生成带标注全文的 DOCX 段落：按当前方案标注（配色 / 字体格式），**不加底纹**。
  ///
  /// 实现单点落地于 shared/export_annotate_markup.dart：DOCX 侧不再有任何
  /// w:shd / w:highlight 注入（底纹只有 PDF 导出使用）。
  String _docxAnnotatedParagraph(
    String text,
    Map<String, String> catByLower,
    ExportAnnotateScheme scheme,
  ) =>
      docxAnnotatedParagraphXml(text, catByLower,
          scheme: scheme, colorBold: false, annotateUnfiltered: false);

  /// 生成单个 DOCX run（仅字色 + 可选加粗；无底纹/高亮参数，Word 导出不带底纹）。
  String _docxRun(String text, String color, {bool bold = false}) =>
      docxRunXml(text, color, bold: bold);

  /// 生成 DOCX 段落：按英文单词边界拆分，[words] 中的单词（大小写不敏感）
  /// 用加粗黑色 run 输出，其余文本用普通黑色 run。
  String _docxParagraphWithBoldWords(String text, List<String> words) =>
      docxParagraphWithBoldWordsXml(text, words);



  /// 用 WPS / Word 的 COM 接口把「已标注 docx」转成 PDF（对齐 Android 的 docx→PDF 流程）。
  ///
  /// 未安装可自动化办公套件、被安全策略拦截或转换超时则返回 false，
  /// 由调用方回退到文本重排 PDF。
  Future<bool> _convertDocxToPdf(String docxPath, String pdfPath) async {
    const script = r'''
$ErrorActionPreference = "Stop"
$app = $null
foreach ($prog in @("KWPS.Application", "Word.Application")) {
  try { $app = New-Object -ComObject $prog; break } catch { }
}
if (-not $app) { exit 2 }
try {
  try { $app.Visible = $false } catch { }
  try { $app.DisplayAlerts = 0 } catch { }
  $doc = $app.Documents.Open($args[0], $false, $true)
  $doc.ExportAsFixedFormat($args[1], 17)
  $doc.Close(0)
} finally {
  try { $app.Quit() } catch { }
}
''';
    Directory? tmpDir;
    Process? proc;
    try {
      tmpDir = await Directory.systemTemp.createTemp('esw_pdf_conv_');
      final scriptPath = '${tmpDir.path}\\convert.ps1';
      await File(scriptPath).writeAsString(script, flush: true);
      proc = await Process.start(
        'powershell',
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          scriptPath,
          docxPath,
          pdfPath,
        ],
      );
      final code = await proc.exitCode.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          proc?.kill();
          return -1;
        },
      );
      if (code != 0) return false;
      final out = File(pdfPath);
      return await out.exists() && await out.length() > 0;
    } catch (_) {
      return false;
    } finally {
      try {
        await tmpDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _writeResultPdf(
    String path, {
    required String originalText,
    required Map<String, String> wordCatMap,
    required String fileName,
    required _ExportTableData exportData,
    required ExportAnnotateScheme scheme,
  }) async {
    final typographyMode = scheme == ExportAnnotateScheme.typography;
    // 与 DOCX 导出共用同一套标注逻辑（对齐 Android）：源文件是 docx 时，
    // 先生成「已标注 docx」，再交给 WPS / Word 转 PDF，
    // 从而完整保留原文档的段落、字体、表格与图片排版。
    final srcDocx = _importedFilePath;
    if (srcDocx != null &&
        srcDocx.toLowerCase().endsWith('.docx') &&
        File(srcDocx).existsSync()) {
      Directory? tmpDir;
      try {
        tmpDir = await Directory.systemTemp.createTemp('esw_pdf_src_');
        final tmpDocx = '${tmpDir.path}\\annotated.docx';
        await _writeResultDocxInplace(
          tmpDocx,
          srcPath: srcDocx,
          wordCatMap: wordCatMap,
          fileName: fileName,
          exportData: exportData,
          scheme: scheme,
        );
        final ok = await _convertDocxToPdf(tmpDocx, path);
        if (ok) return;
      } catch (_) {
        // 原生转换异常 → 回退到文本重排 PDF，保证导出仍可用
      } finally {
        try {
          await tmpDir?.delete(recursive: true);
        } catch (_) {}
      }
    }
    // 使用系统中文字体（优先黑体），缺失或加载失败时按候选回退，
    // 避免不同系统缺少字体导致导出报错。
    // 跨机器可运行性：字体目录由 %WINDIR% 推导（Windows 装在非 C 盘时同样有效），
    // 仅在环境变量缺失时才退回默认 C:\Windows\Fonts。
    final winDir = Platform.environment['WINDIR'] ??
        Platform.environment['SystemRoot'] ??
        r'C:\Windows';
    final fontDir = '$winDir\\Fonts';
    final fontCandidates = <String>[
      '$fontDir\\simhei.ttf',
      '$fontDir\\Deng.ttf',
      '$fontDir\\simfang.ttf',
      '$fontDir\\simkai.ttf',
      '$fontDir\\msyh.ttc',
      '$fontDir\\simsun.ttc',
    ];
    pw.Font? font;
    for (final fp in fontCandidates) {
      try {
        if (!File(fp).existsSync()) continue;
        final bytes = File(fp).readAsBytesSync();
        font = pw.Font.ttf(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        );
        break;
      } catch (_) {
        // 单个字体加载失败（如 ttc 集合不受支持）时继续尝试下一个候选
      }
    }
    if (font == null) {
      throw Exception('未找到可用的中文字体（已尝试: ${fontCandidates.join(', ')}）');
    }

    // 方案二：全文单词统一 Times New Roman；拓展词用 Times New Roman Bold。
    // 系统缺少字体时回退中文字体，加粗 / 线型 / 灰底纹语义不受影响。
    pw.Font? loadLatinFont(String name) {
      final fp = '$fontDir\\$name';
      try {
        if (!File(fp).existsSync()) return null;
        final bytes = File(fp).readAsBytesSync();
        return pw.Font.ttf(
          ByteData.view(
            bytes.buffer,
            bytes.offsetInBytes,
            bytes.lengthInBytes,
          ),
        );
      } catch (_) {
        return null;
      }
    }

    final wordFont = typographyMode ? loadLatinFont('times.ttf') : null;
    final boldFont = typographyMode ? loadLatinFont('timesbd.ttf') : null;

    // 单行标注生成 RichText：方案一为规范字色 + 极淡同色底纹（不加粗，
    // 底纹仅 PDF 使用）；方案二为 TNR + 加粗 / 单线 / 灰底纹。
    // 实现单点落地于 shared/export_annotate_markup.dart。
    pw.Widget oneLine(String line) => pdfAnnotatedLine(
          line,
          wordCatMap,
          font!,
          scheme: scheme,
          colorBold: false,
          annotateUnfiltered: false,
          // 方案一只靠字色区分：PDF 也不加底纹，避免与原文底色混淆。
          annotateShade: false,
          wordFont: wordFont,
          boldFont: boldFont,
        );

    /// 汇总行：条目按设计图着色（选修蓝 / 超标红 / 专有洋红 / 未筛选灰，其余黑）。
    pw.RichText summaryWidget() {
      final items = _buildExportSummaryItems();
      final spans = <pw.TextSpan>[];
      pwpdf.PdfColor pdfHex(String hex) {
        try {
          return pwpdf.PdfColor.fromHex(hex);
        } catch (e) {
          _debugLog('[PdfColor] bad hex="$hex" ($e)');
          return pwpdf.PdfColor.fromInt(0xFF000000);
        }
      }

      for (var i = 0; i < items.length; i++) {
        if (i > 0) {
          spans.add(pw.TextSpan(
            text: ' | ',
            style: pw.TextStyle(
              font: font,
              fontSize: 10,
              color: pdfHex('#${ExportSummaryItem.black}'),
            ),
          ));
        }
        spans.add(pw.TextSpan(
          text: '${items[i].label}: ${items[i].value}',
          style: pw.TextStyle(
            font: font,
            fontSize: 10,
            color: pdfHex('#${items[i].colorHex}'),
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

    /// 标注说明：逐项呈现全部统计条目——总数类（全套词词数 / 去重总词数 /
    /// 真题词 / 其他）以「名称: 数值」中性黑输出，七类词以「名称（n 词）」
    /// 并按所选方案的样式呈现（方案一配色；方案二加粗 / 单线 / 灰底纹）。
    pw.Widget legendWidget() {
      final items = _buildExportSummaryItems();
      final black = pwpdf.PdfColor.fromInt(0xFF000000);
      final spans = <pw.TextSpan>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (i > 0) {
          spans.add(pw.TextSpan(
            text: ' | ',
            style: pw.TextStyle(font: font, fontSize: 10),
          ));
        }
        final isCategory = ExportCategory.all.contains(item.label);
        if (!isCategory) {
          spans.add(pw.TextSpan(
            text: '${item.label}: ${item.value}',
            style: pw.TextStyle(font: font, fontSize: 10, color: black),
          ));
          continue;
        }
        if (typographyMode) {
          final style = exportScheme2StyleOf(item.label);
          spans.add(pw.TextSpan(
            text: '${item.label}（${item.value} 词）',
            style: pw.TextStyle(
              font: wordFont ?? font,
              fontSize: 10,
              color: black,
              decoration: style?.underline == null
                  ? null
                  : pw.TextDecoration.underline,
              decorationStyle: pw.TextDecorationStyle.solid,
              decorationColor: black,
              background: style?.shadeFill == null
                  ? null
                  : pw.BoxDecoration(
                      color: pwpdf.PdfColor.fromHex(style!.shadeFill!),
                    ),
            ),
          ));
          continue;
        }
        spans.add(pw.TextSpan(
          text: '${item.label}（${item.value} 词）',
          style: pw.TextStyle(
            font: font,
            fontSize: 10,
            color: pwpdf.PdfColor.fromHex('#${item.colorHex}'),
            fontWeight: pw.FontWeight.normal,
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

    /// 纯文本明细逐行输出，保证长表也能跨页。
    Iterable<pw.Widget> plainLines(String text, {double fontSize = 10}) sync* {
      for (final line in text.split('\n')) {
        yield pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 1),
          child: pw.Text(
            line,
            style: pw.TextStyle(font: font, fontSize: fontSize),
          ),
        );
      }
    }

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: pwpdf.PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (context) {
          final widgets = <pw.Widget>[
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(
                'ESW 课标词检测导出',
                style: pw.TextStyle(font: font, fontSize: 16, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.Text('文件名: $fileName', style: pw.TextStyle(font: font, fontSize: 10)),
            // 标注说明只保留一份：方案一用彩色统计行；方案二用带样式的图例行。
            pw.Text('【标注说明】', style: pw.TextStyle(font: font, fontSize: 11, fontWeight: pw.FontWeight.bold)),
            if (scheme == ExportAnnotateScheme.color)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 4, bottom: 8),
                child: summaryWidget(),
              )
            else
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 4, bottom: 6),
                child: legendWidget(),
              ),
            pw.Text('【带标注全文】', style: pw.TextStyle(font: font, fontSize: 11, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 2),
            // 逐行输出：MultiPage 只能在顶层 widget 之间分页，
            // 若整篇正文包在一个 Column 里，长文档会报 “Widget won't fit into the page”。
            ...originalText.split('\n').map(
                  (line) => pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 1),
                    child: oneLine(line),
                  ),
                ),
            pw.SizedBox(height: 8),
            pw.Text('【拓展词明细】', style: pw.TextStyle(font: font, fontSize: 11, fontWeight: pw.FontWeight.bold)),
            ...plainLines(_buildExtendDetailPlain(exportData.extend), fontSize: 9),
            pw.SizedBox(height: 12),
            pw.Text('【超标词】', style: pw.TextStyle(font: font, fontSize: 11, fontWeight: pw.FontWeight.bold)),
            ...plainLines(_buildOverLimitPlain(exportData.overLimit)),
          ];
          return widgets;
        },
      ),
    );
    final outBytes = await doc.save();
    await File(path).writeAsBytes(outBytes);
  }

  // ==================== 右侧面板内容（筛选 / 年份分布 / 结果区） ====================
  Widget _buildReturnToImportedBar() {
    return Container(
      width: double.infinity,
      height: GlassTheme.dp(40),
      decoration: BoxDecoration(
        color: GlassTheme.accentSoft,
        borderRadius: BorderRadius.circular(GlassTheme.rMd),
        border: Border.all(color: const Color(0x334462F2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _onReturnToImportedMode,
          borderRadius: BorderRadius.circular(GlassTheme.rMd),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: GlassTheme.dp(kGap12)),
            child: Row(
              children: [
                Icon(
                  Icons.keyboard_return_rounded,
                  size: GlassTheme.dp(18),
                  color: GlassTheme.accentInk,
                ),
                SizedBox(width: GlassTheme.dp(kGap8)),
                Text(
                  '返回段落分析',
                  style: TextStyle(
                    fontSize: GlassTheme.fBody,
                    color: GlassTheme.accentInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '回到原文段落',
                  style: TextStyle(
                    fontSize: GlassTheme.fSmall,
                    color: GlassTheme.ink3,
                  ),
                ),
                SizedBox(width: GlassTheme.dp(kGap4)),
                Icon(
                  Icons.chevron_right_rounded,
                  size: GlassTheme.dp(16),
                  color: GlassTheme.ink3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onReturnToImportedMode() {
    // 重新归类：已加入拓展词手动超标词的单词应归类为对应类别
    final oldCounts = Map<String, int>.from(_savedImportedFilterCounts);
    // 任务④（运行速度）：预建索引。手动词表与课标词库同口径：
    // 精确匹配优先，大写写法可回退到同名小写词条。
    final extendKeys = _extendWords.toSet();
    final chaoGangKeys = _manualChaoGangWords.toSet();
    final extraKeys = properNounKeySet(_manualExtraWords);
    for (int i = 0; i < _savedImportedWords.length; i++) {
      final iw = _savedImportedWords[i];
      String? newCat;
      if (apostropheBaseInStandard(
              iw.word, isWordEntryHit(_standardWords, iw.word)) &&
          iw.category != '课标词') {
        newCat = '课标词';
      } else if (isProperNounHit(extraKeys, iw.word) &&
          iw.category != '专有词') {
        newCat = '专有词';
      } else if (matchWordEntryKey(extendKeys, iw.word) != null &&
          iw.category != '拓展词') {
        newCat = '拓展词';
      } else if (matchWordEntryKey(chaoGangKeys, iw.word) != null &&
          iw.category != '超标词') {
        newCat = '超标词';
      }
      if (newCat != null) {
        oldCounts[iw.category] = (oldCounts[iw.category] ?? 1) - 1;
        _savedImportedWords[i] = _ImportedWord(
          word: iw.word,
          category: newCat,
          frequency: iw.frequency,
          isInCorpus: iw.isInCorpus,
          totalFreq: iw.totalFreq,
        );
        oldCounts[newCat] = (oldCounts[newCat] ?? 0) + 1;
      }
    }
    setState(() {
      _searchController.text = _savedImportedText;
      _inImportedMode = true;
      _cameFromImportedMode = false;
      _corpusFocusPath = null;
      _textbookFocusPath = null;
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
    // 返回导入分析：右侧面板同步展示被检测文本
    _showDetectedTextInRightReader();
  }

  /// 纯数据层：更新_importedWords / _savedImportedWords / 计数，不调用 setState
  /// 返回 true 表示实际发生了分类变更
  ///
  /// 计数不再做「旧类 -1 / 新类 +1」的增量更新：真题词是叠加口径，增量会破坏
  /// 真题词计数（例如从真题词列归入拓展词时，真题词数不应减少）。改为整表重算。
  bool _reclassifyImportedWordData(_ImportedWord target, String newCategory) {
    bool changed = false;
    void updateList(List<_ImportedWord> list) {
      for (int i = 0; i < list.length; i++) {
        final old = list[i];
        if (old.word.toLowerCase() != target.word.toLowerCase()) continue;
        if (old.category == newCategory) continue;
        list[i] = _ImportedWord(
          word: old.word,
          category: newCategory,
          frequency: old.frequency,
          isInCorpus: old.isInCorpus,
          totalFreq: old.totalFreq,
        );
        changed = true;
      }
    }

    updateList(_importedWords);
    updateList(_savedImportedWords);
    if (changed) {
      _importedFilterCounts
        ..clear()
        ..addAll(_computeImportedCounts(_importedWords));
    }
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
        Container(height: 1, color: GlassTheme.line),
        Expanded(child: RepaintBoundary(child: _buildImportedWordList())),
      ],
    );
  }

  // ---------- 导入文本筛选标签 ----------
  Widget _buildImportedFilterChips() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kGap12, vertical: kGap6),
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
              foregroundColor: GlassTheme.accentInk,
              padding: const EdgeInsets.symmetric(horizontal: kGap8, vertical: kGap4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          Expanded(
            child: Center(
              child: Wrap(
                spacing: kGap6,
                runSpacing: kGap4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    '筛选：',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: GlassTheme.ink2,
                    ),
                  ),
                  ..._filters.map((f) {
                    final selected = _importedActiveFilter == f;
                    final color = _filterColors[f]!;
                    final count = _importedFilterCounts[f] ?? 0;
                    return GestureDetector(
                      onTap: () => setState(() => _importedActiveFilter = f),
            child: GlassPressable(radius: 20, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
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
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          '$f  $count',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: selected ? Colors.white : color,
                          ),
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
              padding: const EdgeInsets.symmetric(horizontal: kGap8, vertical: kGap4),
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
        // 真题词＝在真题语料中出现过的词（叠加口径）：课标/拓展/超标/专有词只要
        // 在语料出现过同样出现在本列，因此不再做 category 限制（见规则层注释）
        _cachedFilteredImportedWords = _importedWords
            .where((iw) => matchesFilterColumn(
                  filter: kFilterZhenti,
                  category: iw.category,
                  isInCorpus: iw.isInCorpus,
                ))
            .toList();
      } else if (_importedActiveFilter == '未筛选') {
        // 未筛选＝四个词库都不收录的词（语料出现过的也在此列，同时出现在真题词列），
        // 本列提供手动归类入口
        _cachedFilteredImportedWords = _importedWords
            .where((iw) => matchesFilterColumn(
                  filter: kFilterUnfiltered,
                  category: iw.category,
                  isInCorpus: iw.isInCorpus,
                ))
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
            Icon(Icons.article_outlined, size: 44, color: GlassTheme.ink3),
            const SizedBox(height: kGap12),
            Text(
              '导入文档后自动分析单词',
              style: TextStyle(fontSize: 14, color: GlassTheme.ink3),
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
            Icon(Icons.filter_none, size: 40, color: GlassTheme.ink3),
            const SizedBox(height: kGap8),
            Text(
              '无 $_importedActiveFilter类单词',
              style: TextStyle(fontSize: 13, color: GlassTheme.ink3),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: kGap4),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final iw = filtered[index];
        return ImportedWordRow(
          word: iw.word,
          category: iw.category,
          frequency: iw.frequency,
          activeFilter: _importedActiveFilter,
          color: _filterColors[iw.category]!,
          isEven: index.isEven,
          showRemoveExtra: _manualExtraWords.contains(iw.word),
          onOpen: () => _openImportedWord(iw),
          onClassify: () => _startClassifyBatch(iw),
          onRemoveExtra: () => _removeFromManualExtra(iw),
          onRemoveChaoGang: () => _removeFromManualChaoGang(iw),
        );
      },
    );
  }

  /// 点击导入词表的一行：进入单词检测模式（真题语料中未出现过的词改为在原文面板定位）。
  Future<void> _openImportedWord(_ImportedWord iw) async {
    // 保存当前导入分析状态，以便后续返回
    _savedImportedText = _searchController.text;
    _savedImportedWords = List.from(_importedWords);
    _savedImportedActiveFilter = _importedActiveFilter;
    _savedImportedTotalWords = _importedTotalWords;
    _savedImportedFilterCounts
      ..clear()
      ..addAll(_importedFilterCounts);
    // 真题语料中未出现过的单词：不切检测模式，
    // 弹窗打开导入文档并定位到该单词（与打开真题文本逻辑一致）
    if (!iw.isInCorpus) {
      _showImportedInRightReader(iw.word);
      return;
    }
    _searchController.text = iw.word;
    _searchController.selection = TextSelection.collapsed(offset: iw.word.length);
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
    // 查词结果页：右侧保持空白，仅点击结果行时才加载被检测文本
    if (_results.isNotEmpty) {
      final first = _results.first;
      CorpusFile? corpus;
      for (final f in _corpusFiles) {
        if (f.path == first.filePath) {
          corpus = f;
          break;
        }
      }
      if (corpus != null) {
        await _openCorpusReader(
          corpus,
          keyword: first.keyword,
          matchOffset: first.matchOffset,
          collapseOthers: true,
          focusOnly: true,
        );
      }
    }
    // 主动点击导入词表单词：右侧同步展示被检测文本并定位到该词，
    // 避免沿用上一次面板内容（输入框查词时右侧仍保持空白）。
    _showDetectedTextInRightReader(keyword: iw.word);
  }

  /// 专有词「移出」：回到未筛选待用户重新归类（语料中出现过的词仍在真题词叠加列）。
  void _removeFromManualExtra(_ImportedWord iw) {
    _manualExtraWords.remove(iw.word);
    _classificationMemory.remove(iw.word.toLowerCase());
    _reclassifyImportedWord(iw, '未筛选');
    setState(() {
      if ((_filterCounts['专有词'] ?? 0) > 0) {
        _filterCounts['专有词'] = (_filterCounts['专有词'] ?? 0) - 1;
      }
    });
    _saveConfig();
  }

  /// 超标词「移出」：若同时是手工专有词则回落专有词，否则回到未筛选。
  void _removeFromManualChaoGang(_ImportedWord iw) {
    _manualChaoGangWords.remove(iw.word);
    _classificationMemory.remove(iw.word.toLowerCase());
    final newCat = _manualExtraWords.contains(iw.word) ? '专有词' : '未筛选';
    _reclassifyImportedWord(iw, newCat);
    setState(() {
      if ((_filterCounts['超标词'] ?? 0) > 0) {
        _filterCounts['超标词'] = (_filterCounts['超标词'] ?? 0) - 1;
      }
    });
    _saveConfig();
  }

  // ──────────────────────────────────────────────
  // 筛选归类弹窗（独立 StatefulWidget，确保 chip 选中状态正确刷新）
  // ──────────────────────────────────────────────
  Future<void> _startClassifyBatch(
    _ImportedWord iw, {
    Set<String>? cancelled,
  }) async {
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
        // 「转为拓展词」统一前置拦截：先自动弹出拓展词添加弹窗选择课标词原词，
        // 只有确认且选中有效课标词才转类；取消 / 未选有效课标词 → 该词保持
        // 原类别不转。弹窗中已点选的建议词根作为预填值带入，避免重复选择；
        // 拓展词写入、计数与导入分析面板同步均由该弹窗统一完成。
        final convertedToExtend = await _reclassifyToExtendWord(
          iw.word,
          initialBase: selectedBases.isNotEmpty ? selectedBases.first : null,
        );
        if (!convertedToExtend) {
          // 用户取消：该词保持原类别，并标记本轮不再对同一单词重复弹窗
          cancelled.add(iw.word);
        }
        break;
      case '超标词':
        _manualChaoGangWords.removeWhere(
          (e) => e.toLowerCase() == iw.word.toLowerCase(),
        );
        _manualChaoGangWords.add(iw.word);
        setState(() {
          _filterCounts['超标词'] = (_filterCounts['超标词'] ?? 0) + 1;
          _reclassifyImportedWordData(iw, '超标词');
        });
        _classificationMemory[iw.word.toLowerCase()] = '超标词';
        _saveConfig();
        break;
      case '专有词':
        _manualExtraWords.removeWhere(
          (e) => e.toLowerCase() == iw.word.toLowerCase(),
        );
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
    // 未筛选筛选模式：自动进入下一个未筛选单词，直至全部筛完
    if (_importedActiveFilter == '未筛选') {
      for (final next in _importedWords) {
        if (next.category == '未筛选' && !cancelled.contains(next.word)) {
          await _startClassifyBatch(next, cancelled: cancelled);
          return;
        }
      }
      // 未筛选词已全部处理完毕，停止连排并标记当前文件已处理
      if (_importedFilePath != null) {
        _processedFilePaths.add(_importedFilePath!);
        _saveConfig();
      }
      return;
    }
    // 第四关重构：真题词不参与用户筛选归类，批量筛选只针对「未筛选」词，
    // 因此这里不再自动跳到下一个真题词；当前词处理完即结束本轮。
    // 批量筛选走完——标记当前文件为已处理，下次打开自动积累
    if (_importedFilePath != null) {
      _processedFilePaths.add(_importedFilePath!);
      _saveConfig();
    }
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

  // 左栏标题行：真题 / 教材 两个切换入口 + 当前栏的「＋」导入按钮。
  // 两个入口互斥，切换即整栏换内容；默认停在真题。
  Widget _buildLeftTabHeader() {
    final isTextbook = _leftPanelIsTextbook;
    return Padding(
      key: _leftHeaderKey,
      // 对齐示意图：左卡内文字左内缩 16、表头上下内边距 12
      padding: const EdgeInsets.fromLTRB(kGap16, kGap12, kGap16, kGap12),
      child: Row(
        children: [
          // 窄栏时整体等比收缩，保证「真题 / 教材」与计数胶囊始终完整可见
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildLeftTab(
                      label: '真题',
                      count: _corpusFiles.length,
                      active: !isTextbook,
                      onTap: () => setState(() => _leftPanelIsTextbook = false),
                    ),
                    const SizedBox(width: kGap12),
                    _buildLeftTab(
                      label: '教材',
                      count: _textbookFiles.length,
                      active: isTextbook,
                      onTap: () => setState(() => _leftPanelIsTextbook = true),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 计数胶囊与「＋」之间保证至少 kGap8，避免视觉粘连
          const SizedBox(width: kGap8),
          Tooltip(
            message: isTextbook ? '导入教材' : '导入真题',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GlassPressable(radius: GlassTheme.rSm, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: InkWell(
                key: isTextbook ? _textbookBtnKey : _importBtnKey,
                onTap: isTextbook ? _showTextbookImportMenu : _showImportMenu,
                hoverColor: GlassTheme.accentSoft,
                borderRadius: BorderRadius.circular(6),
                child: const SizedBox(
                  width: 20,
                  height: 20,
                  child: Center(
                    // 恢复原「＋」字形（不是方形图标）
                    child: Text(
                      '＋',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1,
                        color: GlassTheme.ink2,
                      ),
                    ),
                  ),
                ),
              )),
            ),
          ),
        ],
      ),
    );
  }

  /// 左栏切换标签：标题 + 计数胶囊 + 当前态下划线（只做视觉，不改列表语义）。
  Widget _buildLeftTab({
    required String label,
    required int count,
    required bool active,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: GlassTheme.fSmall,
                    fontWeight: FontWeight.w600,
                    color: active ? GlassTheme.ink : GlassTheme.ink3,
                    height: 1,
                  ),
                ),
                const SizedBox(width: kGap8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: kGap8, vertical: kGap4),
                  decoration: BoxDecoration(
                    color: const Color(0x0D18181B), // 灰色计数胶囊
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: GlassTheme.fSmall,
                      color: GlassTheme.ink2,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: GlassTheme.dp(4)),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: GlassTheme.dp(22),
              height: GlassTheme.dp(2),
              decoration: BoxDecoration(
                color: active ? GlassTheme.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 真题文件列表（可勾选，参与语料统计） ====================
  /// 左栏真题行高 / 分组头高度（与 [_buildCorpusSize] 的整行吸附保持一致）
  static const double _kCorpusRowH = 36.0;
  static const double _kCorpusGroupH = 26.0;
  static const double _kCorpusHintH = 30.0;
  /// 内联真题原文高度（展开后固定高度、内部自行滚动）
  static const double _kCorpusReaderH = 200.0;

  /// 左栏真题列表的展示序列：内置分组头 / 隐藏提示 / 用户分组头 / 文件行 / 内联原文。
  /// 从结果行定位时进入聚焦态：只展示该套真题 + 其原文，其它年份不占位。
  List<({String kind, CorpusFile? file})> _corpusDisplayItems() {
    final focus = _corpusFocusPath;
    if (focus != null) {
      CorpusFile? target;
      for (final f in _corpusFiles) {
        if (f.path == focus) {
          target = f;
          break;
        }
      }
      if (target != null) {
        return <({String kind, CorpusFile? file})>[
          (kind: 'focusHint', file: null),
          (kind: 'file', file: target),
          if (_corpusReaderOpen.contains(target.path))
            (kind: 'reader', file: target),
        ];
      }
    }
    final items = <({String kind, CorpusFile? file})>[];
    if (_builtinFiles.isNotEmpty) {
      if (_builtinHidden) {
        items.add((kind: 'hidden', file: null));
      } else {
        items.add((kind: 'builtinHeader', file: null));
        if (!_builtinCollapsed) {
          for (final f in _builtinFiles) {
            items.add((kind: 'file', file: f));
            if (_corpusReaderOpen.contains(f.path)) {
              items.add((kind: 'reader', file: f));
            }
          }
        }
      }
    }
    if (_userCorpusFiles.isNotEmpty) {
      items.add((kind: 'userHeader', file: null));
      for (final f in _userCorpusFiles) {
        items.add((kind: 'file', file: f));
        if (_corpusReaderOpen.contains(f.path)) {
          items.add((kind: 'reader', file: f));
        }
      }
    }
    return items;
  }

  double _corpusItemHeight(({String kind, CorpusFile? file}) item) {
    switch (item.kind) {
      case 'hidden':
        return GlassTheme.dp(_kCorpusHintH);
      case 'focusHint':
        return GlassTheme.dp(24);
      case 'builtinHeader':
      case 'userHeader':
        return GlassTheme.dp(_kCorpusGroupH);
      case 'reader':
        return GlassTheme.dp(_kCorpusReaderH) + kGap6;
      default:
        return GlassTheme.dp(_kCorpusRowH);
    }
  }

  String? _firstCorpusDisplayPath(List<({String kind, CorpusFile? file})> items) {
    for (final it in items) {
      if (it.kind != 'file') continue;
      final f = it.file;
      if (f != null) return f.path;
    }
    return null;
  }

  Widget _buildCorpusList() {
    final items = _corpusDisplayItems();
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 32,
              color: GlassTheme.ink3,
            ),
            const SizedBox(height: kGap8),
            Text(
              '点击「真题导入」选择文件夹',
              style: TextStyle(fontSize: GlassTheme.fSmall, color: GlassTheme.ink3),
            ),
          ],
        ),
      );
    }
    // 列表视口按整行吸附：放不下的内容整行进入滚动，卡片边缘不出现被裁一半的行。
    final heights = items.map(_corpusItemHeight).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final double avail = constraints.maxHeight;
        final double natural = kGap8 * 2 + heights.fold<double>(0, (s, h) => s + h);
        double viewH = natural <= avail ? natural : avail;
        // 聚焦单套真题时列表占满整栏高度，且原文撑满剩余空间
        double? focusReaderH;
        if (_corpusFocusPath != null) {
          viewH = avail;
          final double hintH = GlassTheme.dp(24);
          final double rowH = GlassTheme.dp(_kCorpusRowH);
          final double rest = avail - kGap8 * 2 - hintH - rowH - kGap6;
          focusReaderH =
              rest < GlassTheme.dp(120) ? GlassTheme.dp(120) : rest;
        }
        if (_corpusFocusPath == null && natural > avail) {
          // 从顶部按整项累加，取不超过可用高度的最大整项集合
          double acc = kGap8 * 2;
          var shown = 0.0;
          for (final h in heights) {
            if (acc + h > avail) break;
            acc += h;
            shown += h;
          }
          viewH = shown > 0 ? acc : avail;
        }
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: viewH,
            child: _buildCorpusScrollingList(
              items,
              focusReaderH: focusReaderH,
            ),
          ),
        );
      },
    );
  }

  /// 真题文件列表（滚动区）：视口高度由 [_buildCorpusList] 按整行吸附后传入。
  /// [focusReaderH] 仅在聚焦单套真题时传入，用于让原文撑满左栏剩余高度。
  Widget _buildCorpusScrollingList(
    List<({String kind, CorpusFile? file})> items, {
    double? focusReaderH,
  }) {
    final firstPath = _firstCorpusDisplayPath(items);
    return ListView.builder(
      controller: _corpusListScrollController,
      padding: const EdgeInsets.symmetric(horizontal: kGap8, vertical: kGap8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        switch (item.kind) {
          case 'builtinHeader':
            return _buildCorpusGroupHeader(
              label: '内置真题',
              count: _builtinFiles.length,
              builtin: true,
            );
          case 'userHeader':
            return _buildCorpusGroupHeader(
              label: '我的导入',
              count: _userCorpusFiles.length,
              builtin: false,
            );
          case 'hidden':
            return _buildBuiltinHiddenHint();
          case 'focusHint':
            return _buildCorpusFocusHint();
          case 'reader':
            return _buildCorpusReader(
              item.file!,
              itemHeight: focusReaderH,
            );
          default:
            return _buildCorpusFileRow(
              item.file!,
              firstPath: firstPath,
            );
        }
      },
    );
  }

  /// 聚焦单套真题时的提示条：当前只显示这一套，点「显示全部」恢复完整列表。
  Widget _buildCorpusFocusHint() {
    var name = '';
    for (final f in _corpusFiles) {
      if (f.path == _corpusFocusPath) {
        name = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
        break;
      }
    }
    return SizedBox(
      height: GlassTheme.dp(24),
      child: Row(
        children: [
          const Icon(
            Icons.filter_alt_outlined,
            size: 13,
            color: GlassTheme.accentInk,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '仅显示 $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: GlassTheme.ink2),
            ),
          ),
          const SizedBox(width: kGap8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _corpusFocusPath = null),
              child: const Text(
                '显示全部',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: GlassTheme.accentInk,
                  decoration: TextDecoration.underline,
                  decorationColor: GlassTheme.accentInk,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组头：内置组可折叠 + 可隐藏；用户组只显示数量。
  Widget _buildCorpusGroupHeader({
    required String label,
    required int count,
    required bool builtin,
  }) {
    return SizedBox(
      height: GlassTheme.dp(_kCorpusGroupH),
      child: Row(
        children: [
          if (builtin)
            Icon(
              _builtinCollapsed
                  ? Icons.keyboard_arrow_right_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: GlassTheme.ink3,
            )
          else
            const SizedBox(width: 16),
          const SizedBox(width: kGap4),
          Text(
            label,
            style: const TextStyle(
              fontSize: GlassTheme.fMicro,
              fontWeight: FontWeight.w600,
              color: GlassTheme.ink3,
              height: 1,
            ),
          ),
          const SizedBox(width: kGap6),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: GlassTheme.fMicro,
              color: GlassTheme.ink3,
              height: 1,
            ),
          ),
          const Spacer(),
          // 折叠箭头（整组统一交互，避免 98 行逐个点）
          if (builtin)
            _corpusHeaderIcon(
              icon: _builtinCollapsed
                  ? Icons.unfold_more_rounded
                  : Icons.unfold_less_rounded,
              tooltip: _builtinCollapsed ? '展开内置真题' : '折叠内置真题',
              onTap: () {
                setState(() {
                  _builtinCollapsed = !_builtinCollapsed;
                });
                _saveConfig();
              },
            ),
          if (builtin) const SizedBox(width: kGap4),
          if (builtin)
            _corpusHeaderIcon(
              icon: Icons.visibility_off_outlined,
              tooltip: '隐藏内置真题',
              onTap: () {
                setState(() {
                  _builtinHidden = true;
                  _rebuildCorpusList();
                });
                _resetWordQueryState();
                _saveConfig();
              },
            ),
        ],
      ),
    );
  }

  Widget _corpusHeaderIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GlassPressable(
          radius: 6,
          hoverColor: GlassTheme.accentSoft,
          pressColor: const Color(0x294462F2),
          enabled: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 20,
              height: 20,
              child: Icon(icon, size: 14, color: GlassTheme.ink3),
            ),
          ),
        ),
      ),
    );
  }

  /// 内置真题被隐藏后的恢复入口（不删除任何文件，仅退出统计）。
  Widget _buildBuiltinHiddenHint() {
    return SizedBox(
      height: GlassTheme.dp(_kCorpusHintH),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GlassPressable(
          radius: GlassTheme.rSm,
          hoverColor: GlassTheme.accentSoft,
          pressColor: const Color(0x294462F2),
          enabled: true,
          child: InkWell(
            onTap: () {
              setState(() {
                _builtinHidden = false;
                _rebuildCorpusList();
              });
              _saveConfig();
            },
            borderRadius: BorderRadius.circular(GlassTheme.rSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kGap8),
              child: Row(
                children: [
                  const Icon(
                    Icons.visibility_outlined,
                    size: 14,
                    color: GlassTheme.accentInk,
                  ),
                  const SizedBox(width: kGap6),
                  Expanded(
                    child: Text(
                      '内置真题已隐藏（${_builtinFiles.length} 套）· 点击恢复',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: GlassTheme.fMicro,
                        color: GlassTheme.accentInk,
                        height: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 真题文件行：年份徽标 + 卷别名 + 内置标记（两级信息，便于 119 套内置真题扫读）。
  Widget _buildCorpusFileRow(CorpusFile file, {String? firstPath}) {
    final selected =
        file.path == _activePathOf(_corpusFiles, _activeCorpusPath,
            fallbackFirst: true, firstPathOverride: firstPath);
    final expanded = _corpusReaderOpen.contains(file.path);
    final base = file.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    final yearMatch = RegExp(r'^(\d{4})').firstMatch(base);
    final String yearLabel = yearMatch != null ? yearMatch.group(1)! : '';
    final String titleLabel = yearMatch != null
        ? base.substring(4).replaceFirst(RegExp(r'^年'), '')
        : base;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showCorpusFileContextMenu(details.globalPosition, file),
      child: GlassPressable(
        radius: GlassTheme.rMd,
        hoverColor: const Color(0x0A18181B),
        pressColor: const Color(0x294462F2),
        enabled: true,
        child: InkWell(
          onTap: () {
            setState(() {
              file.isSelected = !file.isSelected;
              _activeCorpusPath = file.path;
            });
          },
          borderRadius: BorderRadius.circular(GlassTheme.rMd),
          child: Container(
            height: GlassTheme.dp(_kCorpusRowH),
            padding: EdgeInsets.only(right: kGap8),
            decoration: BoxDecoration(
              color: selected ? const Color(0x1F4462F2) : null,
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
            ),
            child: Row(
              children: [
                // 左侧 2.5px 蓝色竖条
                SizedBox(
                  width: kGap8,
                  child: selected
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 2.5,
                            height: 20,
                            decoration: BoxDecoration(
                              color: GlassTheme.accent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        )
                      : null,
                ),
                if (yearLabel.isNotEmpty)
                  Container(
                    width: 30,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0x294462F2)
                          : const Color(0x0D18181B),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      yearLabel,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: selected ? GlassTheme.accentInk : GlassTheme.ink3,
                        height: 1,
                      ),
                    ),
                  )
                else
                  GlassFileTypeTag(label: _fileTypeLabel(file.name), selected: selected),
                const SizedBox(width: kGap6),
                Expanded(
                  child: Text(
                    titleLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: GlassTheme.fBody,
                      color: selected
                          ? GlassTheme.accentInk
                          : const Color(0xFF52525B),
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      height: 1,
                    ),
                  ),
                ),
                if (file.isBuiltin) ...[
                  const SizedBox(width: kGap4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0x174462F2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '内置',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: GlassTheme.accentInk,
                        height: 1,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: kGap4),
                _corpusReaderToggle(file, selected: selected, expanded: expanded),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 行尾展开按钮：点击在本套真题下方内联展示原文（再次点击收起）。
  Widget _corpusReaderToggle(
    CorpusFile file, {
    required bool selected,
    required bool expanded,
  }) {
    return Tooltip(
      message: expanded ? '收起真题原文' : '查看真题原文',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GlassPressable(
          radius: 6,
          hoverColor: GlassTheme.accentSoft,
          pressColor: const Color(0x294462F2),
          enabled: true,
          child: InkWell(
            onTap: () => _toggleCorpusReader(file),
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 20,
              height: 20,
              child: Icon(
                expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: selected ? GlassTheme.accentInk : GlassTheme.ink3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 内联真题原文：只读高亮展示，独立滚动；未加载完成时显示加载态。
  /// [itemHeight] 为整项高度（含底部间距），聚焦态下由左栏剩余高度决定。
  Widget _buildCorpusReader(CorpusFile file, {double? itemHeight}) {
    final path = file.path;
    final text = _corpusReaderTexts[path];
    final controller = _corpusReaderControllers[path];
    final double boxH =
        (itemHeight ?? (GlassTheme.dp(_kCorpusReaderH) + kGap6)) - kGap6;
    return Padding(
      padding: const EdgeInsets.only(bottom: kGap6),
      child: Container(
        height: boxH,
        decoration: BoxDecoration(
          color: const Color(0x0A18181B),
          borderRadius: BorderRadius.circular(GlassTheme.rMd),
          border: Border.all(color: GlassTheme.line),
        ),
        child: text == null || controller == null
            ? const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : TextField(
                key: _corpusReaderKeys.putIfAbsent(path, () => GlobalKey()),
                controller: controller,
                scrollController: _corpusReaderScrolls[path],
                readOnly: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontSize: 12,
                  color: GlassTheme.ink,
                  height: 1.5,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  fillColor: Colors.transparent,
                  contentPadding: EdgeInsets.all(kGap8),
                ),
              ),
      ),
    );
  }

  /// 展开 / 收起某套真题的内联原文。
  Future<void> _toggleCorpusReader(CorpusFile file) async {
    // 手动操作退出「仅显示这一套」的聚焦态，恢复完整真题列表
    if (_corpusFocusPath != null) {
      setState(() => _corpusFocusPath = null);
    }
    if (_corpusReaderOpen.contains(file.path)) {
      _closeCorpusReader(file.path);
      return;
    }
    await _openCorpusReader(file);
  }

  void _closeCorpusReader(String path) {
    setState(() => _corpusReaderOpen.remove(path));
    _corpusReaderControllers.remove(path)?.dispose();
    _corpusReaderScrolls.remove(path)?.dispose();
    _corpusReaderKeys.remove(path);
    _corpusReaderAnchors.remove(path);
    _corpusReaderTexts.remove(path);
  }

  /// 展开指定真题并（可选）定位到关键词。
  ///
  /// 从检测结果点击单词时传入 [keyword]/[matchOffset]，并把 [collapseOthers]
  /// 置为 true：其它年份的展开状态先折叠，再展开并定位到该词。
  Future<void> _openCorpusReader(
    CorpusFile file, {
    String keyword = '',
    int? matchOffset,
    bool collapseOthers = false,
    bool focusOnly = false,
  }) async {
    final path = file.path;
    if (collapseOthers) {
      for (final p in _corpusReaderOpen.where((p) => p != path).toList()) {
        _corpusReaderControllers.remove(p)?.dispose();
        _corpusReaderScrolls.remove(p)?.dispose();
        _corpusReaderKeys.remove(p);
        _corpusReaderAnchors.remove(p);
        _corpusReaderTexts.remove(p);
      }
    }
    // 打开真题时：左栏切回真题栏并只高亮该行
    setState(() {
      _leftPanelIsTextbook = false;
      _activeCorpusPath = path;
      _corpusFocusPath = focusOnly ? path : null;
      // 内置真题被折叠 / 隐藏时先恢复，否则展开项不可见
      if (file.isBuiltin) {
        _builtinHidden = false;
        _builtinCollapsed = false;
      }
      if (collapseOthers) {
        _corpusReaderOpen
          ..clear()
          ..add(path);
      } else {
        _corpusReaderOpen.add(path);
      }
      _corpusReaderControllers.remove(path)?.dispose();
      _corpusReaderControllers[path] =
          _HighlightController(_corpusReaderTexts[path] ?? '', keyword);
      _corpusReaderScrolls.putIfAbsent(path, () => ScrollController());
    });
    if (!_corpusReaderTexts.containsKey(path)) {
      String text = '';
      try {
        text = await _readFileTextCached(path);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _corpusReaderTexts[path] = text;
        _corpusReaderControllers.remove(path)?.dispose();
        _corpusReaderControllers[path] = _HighlightController(text, keyword);
      });
    }
    _scrollCorpusListToFile(path);
    final loaded = _corpusReaderTexts[path] ?? '';
    int? anchor = matchOffset;
    if (anchor == null && keyword.isNotEmpty) {
      // 与共用分词同口径（撇号等价、整词匹配）；找不到时 keywordMatchOffset 返回 -1
      final i = keywordMatchOffset(loaded, keyword);
      if (i >= 0) anchor = i;
    }
    if (anchor != null) _corpusReaderAnchors[path] = anchor;
    _jumpCorpusReaderToKeyword(
      path,
      loaded,
      keyword,
      anchor,
    );
  }

  /// 把左栏真题列表滚动到指定真题行，并让该行停在可视区中间。
  void _scrollCorpusListToFile(String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_corpusListScrollController.hasClients) return;
      final items = _corpusDisplayItems();
      double off = kGap8;
      double targetH = GlassTheme.dp(_kCorpusRowH);
      for (final it in items) {
        if (it.kind == 'file' && it.file?.path == path) {
          targetH = _corpusItemHeight(it);
          break;
        }
        off += _corpusItemHeight(it);
      }
      final pos = _corpusListScrollController.position;
      final center = off - (pos.viewportDimension - targetH) / 2;
      _corpusListScrollController.jumpTo(center.clamp(0.0, pos.maxScrollExtent));
    });
  }

  /// 把内联原文滚动到关键词处：优先用文本布局精确计算关键词所在行，
  /// 保证高亮落在可视区内；布局未就绪时回退到按字符比例定位。
  void _jumpCorpusReaderToKeyword(
    String path,
    String text,
    String keyword,
    int? matchOffset, [
    int attempt = 0,
  ]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sc = _corpusReaderScrolls[path];
      if (sc == null || !sc.hasClients) {
        // 展开项可能还没进入视口 / 还未布局，下一帧重试
        if (attempt < 6) {
          _jumpCorpusReaderToKeyword(path, text, keyword, matchOffset,
              attempt + 1);
        }
        return;
      }
      var off = matchOffset;
      if (off == null || off < 0) {
        off = keyword.isEmpty ? 0 : keywordMatchOffset(text, keyword);
        if (off < 0) off = 0;
      }
      final total = text.length;
      final safeOff = off < 0 ? 0 : (off > total ? total : off);
      final max = sc.position.maxScrollExtent;
      double target;
      final editable = _findRenderEditable(
        _corpusReaderKeys[path]?.currentContext?.findRenderObject(),
      );
      // 只有渲染层已装载完整原文时才用精确行定位，否则先按比例并继续重试
      final ready =
          editable != null && total > 0 && editable.plainText.length == total;
      if (ready) {
        final caret =
            editable.getLocalRectForCaret(TextPosition(offset: safeOff));
        // caret.top 是视口坐标（已含滚动偏移），换算成文本坐标后再定位
        target = caret.top + sc.position.pixels -
            sc.position.viewportDimension * 0.25;
      } else {
        final ratio = total <= 0 ? 0.0 : (safeOff / total).clamp(0.0, 1.0);
        target = max * ratio;
      }
      sc.jumpTo(target.clamp(0.0, max));
      if (!ready && attempt < 10) {
        _jumpCorpusReaderToKeyword(
            path, text, keyword, matchOffset, attempt + 1);
      }
    });
  }

  /// 在渲染树中查找 TextField 内部的 RenderEditable（用于精确文本定位）。
  RenderEditable? _findRenderEditable(RenderObject? root) {
    if (root == null) return null;
    if (root is RenderEditable) return root;
    RenderEditable? found;
    root.visitChildren((child) {
      found ??= _findRenderEditable(child);
    });
    return found;
  }

  Future<void> _showCorpusFileContextMenu(
    Offset position,
    CorpusFile file,
  ) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(value: 'open', child: Text('打开')),
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        // 内置真题随包发布，不提供单卷删除（可在分组头整组隐藏）
        if (!file.isBuiltin)
          const PopupMenuItem(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: Colors.red)),
          ),
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
        if (!mounted) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => _glassDialog(
            EswDialogShell(
              title: '确认删除',
              subtitle: '确定要永久删除 ${file.name} 吗？',
              icon: Icons.delete_outline,
              body: const SizedBox.shrink(),
              actions: EswDialogActions(
                children: [
                  EswDialogTextAction(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
                  EswDialogPrimaryAction(label: '删除', danger: true, onPressed: () => Navigator.pop(ctx, true)),
                ],
              ),
            )
          ),
        );
        if (confirm == true) {
          final f = File(file.path);
          if (await f.exists()) {
            await f.delete();
          }
          if (!mounted) return;
          setState(() {
            _userCorpusFiles.removeWhere((cf) => cf.path == file.path);
            _rebuildCorpusList();
          });
          // 删除后立即持久化，重启不再恢复该项
          _saveConfig();
        }
        break;
    }
  }

  // ---------- 筛选标签 ----------
  Widget _buildFilterChips() {
    return Container(
      key: const ValueKey('region-filters'),
      // 自适应高度：宽度不足时 chips 自动换行，容器随内容增高，
      // 不再以固定行高裁切导致压住下方「词频年份」标题。
      constraints: BoxConstraints(minHeight: GlassTheme.hFilterRow),
      padding: EdgeInsets.zero,
      child: Center(
        child: Wrap(
          spacing: kGap4,
          runSpacing: kGap4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              '筛选',
              style: TextStyle(
                fontSize: GlassTheme.fSmall,
                fontWeight: FontWeight.w600,
                color: GlassTheme.ink,
              ),
            ),
            const SizedBox(width: kGap8),
            ..._filters.map(
              (f) => GlassChip(
                label: f,
                count: _filterCounts[f] ?? 0,
                selected: _activeFilter == f,
                onTap: () => setState(() => _activeFilter = f),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 该单词当前所属的「超标词 / 专有词」词库类别（两个词库都不在时返回 null）。
  /// 用于「转为拓展词」时精确判定来源类别：转类成功后需把该词从原类别词库
  /// 中移出，并按实际来源类别增减分类计数。
  String? _wordOwnCategory(String word) {
    final lower = word.toLowerCase();
    if (_manualChaoGangWords.any((e) => e.toLowerCase() == lower)) {
      return '超标词';
    }
    if (_manualExtraWords.any((e) => e.toLowerCase() == lower)) {
      return '专有词';
    }
    return null;
  }

  /// 「转为拓展词」统一前置拦截入口。
  /// 任何把单词从「超标词 / 专有词」转为「拓展词」的路径都必须先经过这里：
  /// 自动弹出拓展词添加弹窗（_showExtendWordDialog）让用户选择课标词原词，
  /// 只有点击「确认」且选中了有效课标词才真正转类；
  /// 取消 / 关闭弹窗 / 未选择有效课标词 → 返回 false，单词保持原类别不变。
  /// [initialBase] 用于带入调用方已选定的课标词（如筛选归类弹窗点选的建议词根），
  /// 仍需用户在弹窗内再次确认。
  Future<bool> _reclassifyToExtendWord(
    String word, {
    String? initialBase,
    String? dialogTitle,
  }) async {
    if (!mounted) return false;
    // 第二点：归类弹窗内已选定课标词原词 → 直接完成转类，不再二次弹出
    // 「转为拓展词」独立弹窗；仅当调用方未给出有效课标词时才走该弹窗
    // （主界面独立「添加拓展词」入口仍走弹窗，行为保持不变）。
    final presetBase = initialBase?.trim().toLowerCase() ?? '';
    if (presetBase.isNotEmpty &&
        matchWordListKey(_standardWordsLowerKeySet, presetBase) != null) {
      _applyExtendConversion(word, presetBase, _wordOwnCategory(word));
      return true;
    }
    // 已是拓展词：弹窗降级为「修改课标词根」，不重复计数、不重复入列
    final alreadyExtend =
        matchWordEntryKey(_extendWords.toSet(), word) != null;
    final result = await _showExtendWordDialog(
      extendWord: word,
      dialogTitle:
          dialogTitle ??
          (alreadyExtend
              ? '修改 "$word" 的课标词根'
              : '将 "$word" 转为拓展词（请选择课标词原词）'),
      initialBase: initialBase ?? (alreadyExtend ? _extendBaseMap[word] : null),
    );
    // 弹窗内部已校验「有效课标词 + 用户确认」，true 即表示转类已执行
    return result == true;
  }

  /// 拓展词弹窗「课标词原词」候选生成。
  ///
  /// 这是弹窗输入的热路径：Autocomplete 每次输入 / 每次下拉重建都会调用它。
  /// 原始实现内联在 optionsBuilder 中，每次都把 `_wordsByFirstChar` 全量展开成
  /// 新 List 再交给 [baseWordCandidates]。抽成方法便于统一优化与性能自测。
  ///
  /// 任务④（运行速度）：
  /// 1) 全量课标词表按内容签名缓存 —— 原实现每次调用都 expand + toList 全量
  ///    重建（数千词），且新建的 List 身份每次都变，导致下层无法复用任何
  ///    预计算（小写词表 / 词干）；现在词表未变时直接复用同一 List 对象。
  /// 2) 候选结果按 (输入文本, 目标词) 记忆 —— 下拉重建、无关 setState 触发的
  ///    重复调用（同一次输入内可能发生多次）直接命中缓存。
  String? _extendCandFlatSig;
  List<String> _extendCandFlat = const <String>[];
  String? _extendCandMemoKey;
  List<String>? _extendCandMemoValue;

  /// 全量课标词表（首次访问/词表变化时重建；内容签名一致即复用同一实例）。
  List<String> _allStandardFlat() {
    var count = 0;
    var sum = 0;
    for (final entry in _wordsByFirstChar.entries) {
      count += entry.value.length;
      sum += entry.key.codeUnitAt(0) * entry.value.length;
    }
    final sig = '$count:$sum';
    if (_extendCandFlatSig != sig) {
      _extendCandFlat = _wordsByFirstChar.values.expand((e) => e).toList();
      _extendCandFlatSig = sig;
      _extendCandMemoKey = null;
      _extendCandMemoValue = null;
    }
    return _extendCandFlat;
  }

  List<String> _extendDialogCandidates(String text, String targetWord) {
    final key = '$text\u0000$targetWord';
    if (_extendCandMemoKey == key && _extendCandMemoValue != null) {
      return _extendCandMemoValue!;
    }
    final result = baseWordCandidates(text, _allStandardFlat(),
        targetWord: targetWord);
    _extendCandMemoKey = key;
    _extendCandMemoValue = result;
    return result;
  }

  /// 优化前实现快照（仅供 [EswPerf] 性能自测做同机同轮前后对比，生产路径不调用）。
  List<String> _extendDialogCandidatesLegacy(String text, String targetWord) {
    final all = _wordsByFirstChar.values.expand((e) => e).toList();
    return baseWordCandidatesLegacy(text, all, targetWord: targetWord);
  }

  // ---------- 拓展词关联对话框 ----------
  // 返回值 true=确认添加, false=点击取消按钮, null=点击弹窗外
  // [initialBase]：课标词预填值（可清空重选），仍需用户点「确认」才生效
  Future<bool?> _showExtendWordDialog({
    String? extendWord,
    String? dialogTitle,
    String? initialBase,
  }) async {
    final word = extendWord ?? _detectedWord;
    String selectedBase = initialBase ?? '';
    String searchText = initialBase ?? '';
    // 弹窗前记录单词当前所属类别：确认转类成功后需据此从原类别词库移出并精确计数
    final prevCategory = _wordOwnCategory(word);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            // 任务①（交互）：候选词点击 / 有效课标词回车一律等价于点「确认」——
            // 以该词为课标词原词立即提交生效，无需再点按钮；
            // 取消 / 右上角关闭 / 未选到有效课标词仍不产生任何改动。
            bool submitted = false;
            void commitSelection() {
              // 回车会先触发 Autocomplete 内部提交（可能已 pop），避免重复 pop 到下层路由
              if (submitted) return;
              if (selectedBase.isEmpty && searchText.isNotEmpty) {
                selectedBase = searchText.toLowerCase();
              }
              if (selectedBase.isEmpty) {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(const SnackBar(content: Text('请选择或输入课标词')));
                return;
              }
              if (matchWordListKey(
                    _standardWordsLowerKeySet,
                    selectedBase.toLowerCase(),
                  ) ==
                  null) {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(const SnackBar(content: Text('请输入有效的课标词')));
                return;
              }
              submitted = true;
              Navigator.of(ctx).pop(true);
            }

            return _glassDialog(
              // 统一玻璃弹窗骨架：标题 + 右上角 ✕ + 紧凑内容 + 统一按钮区
              // 视觉收紧：内容只有一行提示 + 一个输入框，面板宽度按内容收窄，
              // 去掉 AlertDialog 自带的多层内边距，消除四周大面积留白。
              EswDialogShell(
                // 宽度按内容自适应：长词标题自动放宽（仍受全站上下限约束），
                // 不再写死固定值，保证全站弹窗宽度彼此协调。
                minContent: EswDialog.measureTextWidth(
                  ctx,
                  dialogTitle ?? '将 "$word" 加入拓展词',
                  EswDialog.titleStyle,
                ),
                titleWidget: Text(
                  dialogTitle ?? '将 "$word" 加入拓展词',
                  style: EswDialog.titleStyle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                // 右上角关闭按钮：等同「取消」（pop false），不改动任何数据
                trailing: Tooltip(
                  message: '关闭',
                  child: _SyncDialogCloseButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                  ),
                ),
                body: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '请选择该词基于哪个课标词拓展：',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: kGap12),
                    Autocomplete<String>(
                      // 预填调用方已选定的课标词（可清空后重新搜索选择），
                      // 仅初始化输入框文本，仍以「确认」为准，不做隐式转类
                      initialValue: TextEditingValue(text: selectedBase),
                      optionsBuilder: (TextEditingValue value) {
                        // 双端统一候选：输入相关候选 + 空输入自动跳原词拆词候选
                        return _extendDialogCandidates(value.text, word);
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
                              horizontal: 10,
                              vertical: 10,
                            ),
                          ),
                          onChanged: (v) {
                            searchText = v;
                            // 输入内容与当前选中值不一致（含清空）时，旧选中值失效，
                            // 必须以输入内容或下拉选择为准，避免预填值被静默沿用
                            if (v.trim().toLowerCase() !=
                                selectedBase.toLowerCase()) {
                              selectedBase = '';
                            }
                          },
                          onSubmitted: (_) {
                            // 回车：先让 Autocomplete 提交高亮候选（若有），
                            // 再走统一提交判定 —— 输入的是有效课标词即直接确认
                            onSubmit();
                            commitSelection();
                          },
                        );
                      },
                      onSelected: (v) {
                        // 任务①：点击下拉候选词 = 直接以该词确认执行（等价点「确认」）
                        selectedBase = v;
                        searchText = v;
                        commitSelection();
                      },
                    ),
                  ],
                ),
                actions: EswDialogActions(
                  children: [
                    EswDialogTextAction(
                      label: '取消',
                      onPressed: () => Navigator.of(ctx).pop(false),
                    ),
                    EswDialogPrimaryAction(
                      label: '确认',
                      onPressed: commitSelection,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (result == true && selectedBase.isNotEmpty) {
      _applyExtendConversion(word, selectedBase, prevCategory);
    }
    return result;
  }

  /// 执行「转为拓展词」的实际数据变更（不含任何弹窗交互）。
  ///
  /// [base] 为已校验有效的课标词原词；[prevCategory] 为转类前的来源类别
  /// （超标词 / 专有词 / null），用于精确迁移分类计数与词库归属。
  /// 归类弹窗内直选课标词（不弹二级弹窗）与二级弹窗确认两条路径共用本方法。
  void _applyExtendConversion(
    String word,
    String base,
    String? prevCategory,
  ) {
    setState(() {
      final lower = word.toLowerCase();
      final wasExtend = _extendWordsLower.contains(lower);
      if (!wasExtend) {
        _extendWords.add(word);
        _extendWordsLower.add(lower);
        // 单词从超标词/专有词转变为拓展词：来源类别计数 -1（精确到实际来源），
        // 拓展词计数 +1；来源不在两个词库中时不误减其它类别计数
        if (prevCategory != null && (_filterCounts[prevCategory] ?? 0) > 0) {
          _filterCounts[prevCategory] = (_filterCounts[prevCategory] ?? 0) - 1;
        }
        _filterCounts['拓展词'] = (_filterCounts['拓展词'] ?? 0) + 1;
        // 转类语义：把该词从原类别词库列表中移出。
        // （旧实现只减计数不移除，会出现同一单词同时留在「超标词/专有词」
        //  与「拓展词」两个词库中的重复归类问题）
        if (prevCategory == '超标词') {
          _manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
        } else if (prevCategory == '专有词') {
          _manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
        }
        // 导入分析面板中同一单词同步归类为拓展词（含已保存的跨文件结果）
        for (final iw in List<_ImportedWord>.from(_importedWords)) {
          if (iw.word.toLowerCase() == lower && iw.category != '拓展词') {
            _reclassifyImportedWordData(iw, '拓展词');
          }
        }
      }
      _extendBaseMap[word] = base;
      _extendReverseIndex[lower] = base.toLowerCase();
      _activeFilter = '拓展词';
    });
    // 同步写入分类记忆，保证再次导入同一文件时能正确复用"拓展词"归类
    _classificationMemory[word.toLowerCase()] = '拓展词';
    _saveConfig();
  }

  // ---------- 词频年份 + 教材分布 ----------
  // ---------- 词频年份 + 教材分布 ----------
  Widget _buildYearDistribution() {
    final textbookCounts = <String, int>{};
    for (final r in _textbookResults) {
      textbookCounts[r.filePath] = (textbookCounts[r.filePath] ?? 0) + 1;
    }
    var yearTotal = 0;
    for (final v in _yearFrequency.values) {
      yearTotal += v;
    }
    return YearFilterBar(
      textbookItems: [
        for (final f in _textbookFiles.where((f) => f.isSelected))
          (path: f.path, name: f.name),
      ],
      textbookCounts: textbookCounts,
      years: _sortedYears,
      yearCounts: _yearFrequency,
      yearTotal: yearTotal,
      textbookTotal: _textbookResults.length,
      selectedYear: _selectedYear,
      selectedTextbook: _selectedTextbook,
      selectedTextbookName: _selectedTextbookName(),
      onSelectYear: _toggleYearFilter,
      onSelectTextbook: _toggleTextbookFilter,
      onClearYear: () => setState(() {
        _selectedYear = null;
        _filteredResults = List.from(_results);
        _filteredTextbookResults = List.from(_textbookResults);
      }),
      onClearTextbook: () => setState(() {
        _selectedTextbook = null;
        _filteredResults = List.from(_results);
        _filteredTextbookResults = List.from(_textbookResults);
      }),
    );
  }

  /// 统一点击筛选：年份格只筛该年份例句（教材例句无年份归属，按一致规则一并过滤）。
  void _toggleYearFilter(int year) {
    setState(() {
      _selectedYear = _selectedYear == year ? null : year;
      _selectedTextbook = null;
      _filteredResults = _selectedYear != null
          ? _results
              .where((r) => r.source.startsWith('${_selectedYear!}'))
              .toList()
          : List.from(_results);
      _filteredTextbookResults =
          _selectedYear != null ? <ResultRow>[] : List.from(_textbookResults);
    });
  }

  /// 统一点击筛选：教材格只筛该教材例句（真题例句无教材归属，按一致规则一并过滤）。
  void _toggleTextbookFilter(String path) {
    setState(() {
      _selectedTextbook = _selectedTextbook == path ? null : path;
      _selectedYear = null;
      _filteredTextbookResults = _selectedTextbook != null
          ? _textbookResults
              .where((r) => r.filePath == _selectedTextbook)
              .toList()
          : List.from(_textbookResults);
      _filteredResults =
          _selectedTextbook != null ? <ResultRow>[] : List.from(_results);
    });
  }

  // 当前选中的教材名称（用于"取消筛选"提示，去扩展名）
  String _selectedTextbookName() {
    if (_selectedTextbook == null) return '';
    return _textbookNameByPath(_selectedTextbook!);
  }

  // 根据文件路径返回教材显示名（去扩展名，用于例句列表"出处"列）
  String _textbookNameByPath(String path) {
    for (final cf in _textbookFiles) {
      if (cf.path == path) {
        final dotIdx = cf.name.lastIndexOf('.');
        return dotIdx > 0 ? cf.name.substring(0, dotIdx) : cf.name;
      }
    }
    return path;
  }

  // ---------- 检测结果表格----------
  // ④-5 结果表头：高 38，三列（序号 / 所在文本 / 出处），文字水平垂直居中，
  // 列间 1px 竖线。序号与出处列宽随窗口收缩，保证窄窗口下「所在文本」不被挤没。
  double get _resultIndexColW =>
      (MediaQuery.of(context).size.width * 0.06).clamp(48.0, 76.0);

  double get _resultSourceColW =>
      (MediaQuery.of(context).size.width * 0.16).clamp(110.0, 200.0);

  Widget _buildResultHeader() {
    return Container(
      height: GlassTheme.hTableHeader,
      padding: const EdgeInsets.symmetric(horizontal: kGap8),
      decoration: const BoxDecoration(
        color: Color(0x61FFFFFF), // rgba(255,255,255,0.38) 表头半透明白底（规范 2.8）
        border: Border(bottom: BorderSide(color: GlassTheme.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _resultIndexColW,
            child: Center(
              child: Text(
                '序号',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: GlassTheme.fMicro,
                  fontWeight: FontWeight.w600,
                  color: GlassTheme.ink3,
                  height: 1,
                ),
              ),
            ),
          ),
          Container(width: 1, height: 16, color: GlassTheme.line),
          Expanded(
            child: Center(
              child: Text(
                '所在文本',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: GlassTheme.fMicro,
                  fontWeight: FontWeight.w600,
                  color: GlassTheme.ink3,
                  height: 1,
                ),
              ),
            ),
          ),
          Container(width: 1, height: 16, color: GlassTheme.line),
          SizedBox(
            width: _resultSourceColW,
            child: Center(
              child: Text(
                '出处',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: GlassTheme.fMicro,
                  fontWeight: FontWeight.w600,
                  color: GlassTheme.ink3,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 检测结果列表（真题例句 + 教材例句 统一展示） ----------
  Widget _buildResultList() {
    final examCount = _filteredResults.length;
    final textbookCount = _filteredTextbookResults.length;
    if (examCount == 0 && textbookCount == 0) {
      // 空状态可滚动：窗口较矮（或历史列表展开压缩结果表）时，
      // 内容不足一屏居中显示，超出时内部滚动，避免纵向溢出被裁切。
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      // 第三关 ④：渐变只允许三处，空状态圆改纯色淡靛蓝
                      color: Color(0x1A4462F2), // rgba(68,98,242,.10)
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.search,
                      size: 28,
                      color: GlassTheme.accentInk,
                    ),
                  ),
                  const SizedBox(height: kGap12),
                  Text(
                    _selectedYear != null
                        ? '$_selectedYear年无匹配结果'
                        : '输入单词即可查看检测结果',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: GlassTheme.ink2,
                    ),
                  ),
                  const SizedBox(height: kGap8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: kGap12, vertical: kGap6),
                    decoration: BoxDecoration(
                      color: const Color(0x0F18181B), // 灰色徽标 rgba(24,24,27,0.06)
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '按 ',
                            style: TextStyle(
                              fontSize: 11,
                              color: GlassTheme.ink3,
                            ),
                          ),
                          const TextSpan(
                            text: 'Enter',
                            style: TextStyle(
                              fontSize: 11,
                              color: GlassTheme.accentInk,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(
                            text: ' 快捷检测',
                            style: TextStyle(
                              fontSize: 11,
                              color: GlassTheme.ink3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final total = examCount + textbookCount;
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: total,
      itemBuilder: (context, index) {
        // 真题在前、教材在后统一编号；点击行均可联动右侧原文面板定位
        final isTextbook = index >= examCount;
        final row = isTextbook
            ? _filteredTextbookResults[index - examCount]
            : _filteredResults[index];
        final source =
            isTextbook ? _textbookNameByPath(row.filePath) : row.source;
        // 整行可点击：点击任意位置（含「所在文本」列单词）联动左/右原文定位
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: InkWell(
            onTap: () => _showResultInRightReader(row),
            hoverColor: const Color(0x0A18181B),
            child: Container(
              key: ValueKey('${row.source}_${row.matchOffset}'),
              padding: const EdgeInsets.fromLTRB(kGap8, kGap6, kGap8, kGap6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: GlassTheme.line)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: _resultIndexColW,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: GlassTheme.ink3),
                    ),
                  ),
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: GlassTheme.line,
                  ),
                  Expanded(child: _buildContextRow(row)),
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: GlassTheme.line,
                  ),
                  SizedBox(
                    width: _resultSourceColW,
                    child: Text(
                      source,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12, color: GlassTheme.ink3),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
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
      style: const TextStyle(fontSize: 12, color: GlassTheme.ink),
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
      spans.add(
        TextSpan(
          text: tok,
          style: TextStyle(
            fontSize: 12,
            color: isSpace
                ? GlassTheme.ink
                : _afterColors[ci++ % _afterColors.length],
          ),
        ),
      );
    }
    return spans;
  }

  // ==================== 右侧原文面板（常驻，三栏布局最右侧） ====================
  Widget _buildRightReaderPanel() {
    final controller = _rightHighlightController;
    final isExamFile = _rightPanelRow != null;
    return Padding(
      padding: const EdgeInsets.all(GlassTheme.s12),
      child: GlassPanel(
        radius: GlassTheme.rXl,
        sigma: 12, // 任务④：词库列表弹窗面板，32 → 12（保留磨砂、降低成本）
        child: Column(
        children: [
          // 标题栏
          Container(
            height: GlassTheme.hHeader,
            padding: const EdgeInsets.symmetric(horizontal: kGap6),
            child: Row(
              children: [
                const Icon(
                  Icons.menu_book_outlined,
                  size: 16,
                  color: GlassTheme.ink2,
                ),
                const SizedBox(width: kGap7),
                Expanded(
                  child: Text(
                    _rightPanelTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: GlassTheme.fSmall,
                      fontWeight: FontWeight.w600,
                      color: GlassTheme.ink,
                    ),
                  ),
                ),
                if (_rightPanelKeyword.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(right: kGap4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x0D18181B), // 灰色胶囊 rgba(24,24,27,0.05)
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _rightPanelKeyword,
                      style: const TextStyle(
                        fontSize: GlassTheme.fMicro,
                        color: GlassTheme.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                GlassPressable(radius: GlassTheme.rSm, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: '关闭原文面板',
                  onPressed: () {
                    setState(() {
                      _rightPanelVisible = false;
                      _rightPanelTitle = '';
                      _rightPanelKeyword = '';
                      _rightPanelRow = null;
                                          });
                  },
                ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: GlassTheme.line),
          // 原文展示区
          Expanded(
            child: controller == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(kGap12),
                      child: Text(
                        '完成检测后此处展示被检测文本\n点击中间结果中的单词可自动定位',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: GlassTheme.ink3,
                          height: 1.6,
                        ),
                      ),
                    ),
                  )
                : TextField(
                    key: _rightReaderKey,
                    controller: controller,
                    scrollController: _rightScrollController,
                    readOnly: !isExamFile,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    contextMenuBuilder: _buildRightPanelContextMenu,
                    style: const TextStyle(
                      fontSize: 13,
                      color: GlassTheme.ink,
                      height: 1.5,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      // 视觉修正③：右侧原文面板正文区原继承全局 inputDecorationTheme
                      // 的 filled:true + fillColor:panelSolid（白 0.72），在 GlassPanel 之上
                      // 又叠了一层近实白，读起来像"纸张"、与主界面玻璃风格割裂。
                      // 此处显式关掉填充，让正文直接透出面板玻璃（0.58 白 + 模糊 + 描边）。
                      // 仅改视觉：不改高度、内边距与交互（选区/复制/替换逻辑不动）。
                      filled: false,
                      fillColor: Colors.transparent,
                      contentPadding: EdgeInsets.all(kGap8),
                      hintText: '原文内容',
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
  }

  /// 右侧原文面板选中文本的自定义菜单：复制 / 修改 / 查询（对齐安卓长按菜单）
  Widget _buildRightPanelContextMenu(
    BuildContext context,
    EditableTextState state,
  ) {
    final value = state.textEditingValue;
    final selText = value.selection.textInside(value.text);
    final selected = selText.trim();
    if (selected.isEmpty) return const SizedBox.shrink();
    // 精确计算选中核心文本（去除首尾空白）在全文中的 [start,end)，保证"仅替换选中文本"
    final coreStart = value.selection.start +
        (selText.length - selText.trimLeft().length);
    final coreEnd = value.selection.end -
        (selText.length - selText.trimRight().length);
    final isWord = RegExp(
      r"^(?:[a-zA-Z]+(?:\.[a-zA-Z]+)+\.?|[a-zA-Z]+(?:['’][a-zA-Z]+)*)$",
    ).hasMatch(selected);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: selected));
            state.hideToolbar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已复制 $selected')),
            );
          },
        ),
        ContextMenuButtonItem(
          label: '修改',
          onPressed: () {
            state.hideToolbar();
            _editRightPanelWord(selected, coreStart, coreEnd);
          },
        ),
        if (isWord)
          ContextMenuButtonItem(
            label: '查询',
            onPressed: () {
              state.hideToolbar();
              _searchController.text = selected;
              _searchController.selection = TextSelection.collapsed(
                offset: selected.length,
              );
              _onDetect();
            },
          ),
      ],
    );
  }

  /// 修改右侧面板中选中的文本（对齐安卓 _editWord 交互）：
  /// 长按/选中弹出 复制/修改/查询 菜单 → 点"修改"弹出修改弹窗（预填选中文本，
  /// 仅剩 取消/保存）→ 点"保存"立即替换该选中文本并高亮被修改内容。
  /// 弹窗必须使用 State 的 context：菜单条目 context 在 hideToolbar 移除菜单后已
  /// 失效，showDialog 用失效 context 找不到 Navigator、弹窗不弹出——即"修改按钮
  /// 点了没反应"的根因。
  Future<void> _editRightPanelWord(
    String selected,
    int selStart,
    int selEnd,
  ) async {
    final controller = _rightHighlightController;
    if (controller == null || !mounted) return;
    final inputCtrl = TextEditingController(text: selected);
    // 全站统一玻璃弹窗骨架（对齐 EswDialogShell 规范）：
    // ① 标题区带渐变图标 + 右侧 ✕ 关闭；② 副标题显示「原文」作为修改参照；
    // ③ 面板宽由内容自适应（minContent 360 ≥ 同类弹窗），不再被窄框挤压输入框；
    // ④ 输入框与按钮区间距由 gapHeaderBody / gapSection 统一控制，按钮右对齐；
    // ⑤ 去掉原先 AlertDialog 自带 actionsPadding，消除底部大块留白。
    // 业务逻辑（预填选中文本、保存返回新词）完全不变。
    final newWord = await showDialog<String>(
      context: context,
      builder: (ctx) => _glassDialog(
        EswDialogShell(
          icon: Icons.edit_outlined,
          title: '修改单词',
          subtitle: '原文：$selected',
          minContent: 360,
          trailing: Tooltip(
            message: '关闭',
            child: _SyncDialogCloseButton(
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ),
          body: TextField(
            controller: inputCtrl,
            autofocus: true,
            maxLines: 3,
            style: EswDialog.bodyStyle,
            decoration: InputDecoration(
              hintText: '输入替换后的单词',
              hintStyle: const TextStyle(color: GlassTheme.ink3),
              filled: true,
              fillColor: GlassTheme.panelSolid,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacingMd,
                vertical: AppTheme.spacingSm,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                borderSide: const BorderSide(color: GlassTheme.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                borderSide: const BorderSide(
                  color: GlassTheme.accent,
                  width: 1.5,
                ),
              ),
            ),
          ),
          actions: EswDialogActions(
            children: [
              EswDialogTextAction(
                label: '取消',
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              EswDialogPrimaryAction(
                label: '保存',
                onPressed: () =>
                    Navigator.of(ctx).pop(inputCtrl.text.trim()),
              ),
            ],
          ),
        ),
      ),
    );
    inputCtrl.dispose();
    if (!mounted || newWord == null || newWord.isEmpty) return;
    if (newWord == selected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('替换内容未变化')),
      );
      return;
    }
    // 仅替换选中区间 [selStart, selEnd)，并高亮被修改处（琥珀色背景）
    final old = controller.text;
    if (selStart < 0 || selEnd > old.length || selStart > selEnd) return;
    final newText =
        old.substring(0, selStart) + newWord + old.substring(selEnd);
    final hlStart = selStart;
    final hlEnd = hlStart + newWord.length;
    final spans = <({int start, int end})>[
      ...controller.editSpans,
      (start: hlStart, end: hlEnd),
    ];
    setState(() {
      _rightHighlightController?.dispose();
      _rightHighlightController = _HighlightController(
        newText,
        _rightPanelKeyword,
        spans,
      );
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已将 "$selected" 替换为 "$newWord"',
          ),
        ),
      );
    }
  }

  /// 被检测的导入文本（右侧面板唯一数据源）。
  ///
  /// 文档检测模式下输入框即当前被检测文本；从导入结果进入单词查词模式后
  /// 输入框已被查询词占用，回退到进入查词前保存的导入文本。
  /// 回退只对「从导入文档点词进入的查词」有效（[_cameFromImportedMode]）：
  /// 用户自行输入 / 从历史发起独立查词时，右侧没有可展示的被检测文本。
  String _detectedSourceText() {
    if (_inImportedMode) return _searchController.text;
    if (_cameFromImportedMode && _savedImportedText.isNotEmpty) {
      return _savedImportedText;
    }
    return '';
  }

  /// 用户从搜索框 / 历史 / 词库发起独立查词：退出「导入文档」语境。
  ///
  /// 之后点击结果行时右侧不再回退显示上一次导入的文档文本（无导入文档即留空）。
  void _beginIndependentQuery() {
    if (!_inImportedMode && !_cameFromImportedMode) return;
    setState(() {
      _inImportedMode = false;
      _cameFromImportedMode = false;
    });
  }

  /// 右侧面板展示被检测文本，并（可选）滚动定位到关键词。
  ///
  /// [occurrence] 指定定位第几次出现（从 0 开始），用于结果行多点命中时
  /// 尽量对准同一处；越界则回退到首次出现。
  /// 返回 false 表示当前没有可展示的被检测文本（纯查词模式，未导入文档）。
  bool _showDetectedTextInRightReader({
    String keyword = '',
    int occurrence = 0,
  }) {
    final text = _detectedSourceText();
    if (text.isEmpty) return false;
    final totalLen = text.length;
    final offset =
        keyword.isEmpty ? 0 : _keywordOccurrenceOffset(text, keyword, occurrence);
    setState(() {
      _rightPanelVisible = true;
      _rightPanelTitle = _importedFileName ?? '被检测文本';
      _rightPanelKeyword = keyword;
      _rightPanelOccurrence = occurrence;
      _rightPanelRow = null;
      final existing = _rightHighlightController;
      if (existing != null && existing.text == text) {
        // 文本未变：只换关键词，保留滚动位置（避免新 controller 把滚动重置到顶部）
        existing.setKeyword(keyword);
      } else {
        existing?.dispose();
        _rightHighlightController = _HighlightController(text, keyword);
      }
    });
    _jumpRightReaderTo(offset, totalLen);
    return true;
  }

  /// 收起右侧原文面板：无被检测的导入文本时不展示任何内容。
  void _hideRightReader() {
    if (!_rightPanelVisible && _rightHighlightController == null) return;
    setState(() {
      _rightPanelVisible = false;
      _rightPanelTitle = '';
      _rightPanelKeyword = '';
      _rightPanelOccurrence = 0;
      _rightPanelRow = null;
      _rightHighlightController?.dispose();
      _rightHighlightController = null;
    });
  }

  /// 取关键词第 [occurrence] 次出现的位置（0 起）；越界返回最后一次命中，
  /// 完全找不到返回 0。口径与共用分词一致：撇号等价、按完整词形匹配。
  int _keywordOccurrenceOffset(String text, String keyword, int occurrence) {
    if (keyword.isEmpty) return 0;
    var count = 0;
    var last = -1;
    for (final m in keywordMatchRegExp(keyword).allMatches(text)) {
      last = m.start;
      if (count == occurrence) return m.start;
      count++;
    }
    return last < 0 ? 0 : last;
  }

  /// 窗口尺寸变化后，按各自锚点把左右原文重新定位到关键词处。
  void _reanchorReaders() {
    for (final path in <String>{
      ..._corpusReaderOpen,
      ..._textbookReaderOpen,
    }) {
      final text = _corpusReaderTexts[path];
      final controller = _corpusReaderControllers[path];
      final anchor = _corpusReaderAnchors[path];
      if (text == null || controller == null || anchor == null) continue;
      if (controller.keyword.isEmpty) continue;
      _jumpCorpusReaderToKeyword(path, text, controller.keyword, anchor);
    }
    if (_rightPanelVisible && _rightPanelKeyword.isNotEmpty) {
      final text = _rightHighlightController?.text;
      if (text != null && text.isNotEmpty) {
        _jumpRightReaderTo(
          _keywordOccurrenceOffset(
            text,
            _rightPanelKeyword,
            _rightPanelOccurrence,
          ),
          text.length,
        );
      }
    }
  }

  /// 右侧原文滚动到指定字符位置：优先精确行位置，布局未就绪时回退比例。
  void _jumpRightReaderTo(int offset, int totalLen, [int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_rightScrollController.hasClients) {
        if (attempt < 10) _jumpRightReaderTo(offset, totalLen, attempt + 1);
        return;
      }
      final pos = _rightScrollController.position;
      double target;
      final editable = _findRenderEditable(
        _rightReaderKey.currentContext?.findRenderObject(),
      );
      // 只有渲染层已装载完整原文时才用精确行定位，否则先按比例并继续重试
      final ready = editable != null &&
          totalLen > 0 &&
          editable.plainText.length == totalLen;
      if (ready) {
        final safe = offset < 0 ? 0 : (offset > totalLen ? totalLen : offset);
        final caret = editable.getLocalRectForCaret(TextPosition(offset: safe));
        // caret.top 是视口坐标（已含滚动偏移），换算成文本坐标后再定位
        target = caret.top + pos.pixels - pos.viewportDimension * 0.25;
      } else {
        final ratio = totalLen <= 0 ? 0.0 : (offset / totalLen).clamp(0.0, 1.0);
        target = pos.maxScrollExtent * ratio;
      }
      _rightScrollController.jumpTo(target.clamp(0.0, pos.maxScrollExtent));
      // 面板首次展开时布局可能尚未稳定，连续几帧重算校正（幂等）
      if (attempt < 3 || (!ready && attempt < 10)) {
        _jumpRightReaderTo(offset, totalLen, attempt + 1);
      }
    });
  }

  /// 中间结果行点击联动：真题结果在左侧内联展开并定位，右侧展示被检测文本；
  /// 教材结果沿用右侧原文面板展示教材原文并定位。
  Future<void> _showResultInRightReader(ResultRow row) async {
    CorpusFile? corpus;
    for (final f in _corpusFiles) {
      if (f.path == row.filePath) {
        corpus = f;
        break;
      }
    }
    if (corpus != null) {
      // 左侧：折叠其它年份，展开该词所在年份并跳转到该词
      await _openCorpusReader(
        corpus,
        keyword: row.keyword,
        matchOffset: row.matchOffset,
        collapseOthers: true,
        focusOnly: true,
      );
      // 右侧：展示被检测的导入文本并跳转到该词（纯查词模式无导入文本则不动）
      // 同一单词多次命中时按当前行在同一单词结果中的序号对齐
      var occurrence = 0;
      final idx = _filteredResults.indexOf(row);
      if (idx > 0) {
        final kw = row.keyword.toLowerCase();
        for (var i = 0; i < idx; i++) {
          if (_filteredResults[i].keyword.toLowerCase() == kw) occurrence++;
        }
      }
      if (!_showDetectedTextInRightReader(
        keyword: row.keyword,
        occurrence: occurrence,
      )) {
        // 没有导入文档：右侧不显示任何内容（教材原文只在左栏内联展示）
        _hideRightReader();
      }
      return;
    }
    // 教材例句：左栏教材列表内联展开并定位该词；右侧始终保持被检测的导入文本
    setState(() {
      _leftPanelIsTextbook = true;
      _activeTextbookPath = row.filePath;
    });
    CorpusFile? textbook;
    for (final f in _textbookFiles) {
      if (f.path == row.filePath) {
        textbook = f;
        break;
      }
    }
    if (textbook != null) {
      await _openTextbookReader(
        textbook,
        keyword: row.keyword,
        matchOffset: row.matchOffset,
        collapseOthers: true,
        focusOnly: true,
      );
    }
    // 同一单词在教材结果中多次命中时按序号对齐
    var occurrence = 0;
    final idx = _filteredTextbookResults.indexOf(row);
    if (idx > 0) {
      final kw = row.keyword.toLowerCase();
      for (var i = 0; i < idx; i++) {
        if (_filteredTextbookResults[i].keyword.toLowerCase() == kw) {
          occurrence++;
        }
      }
    }
    if (!_showDetectedTextInRightReader(
      keyword: row.keyword,
      occurrence: occurrence,
    )) {
      // 没有导入文档：右侧不显示任何内容（教材原文只在左栏内联展示）
      _hideRightReader();
    }
  }

  /// 导入词点击联动：右侧面板展示被检测文本并滚动定位到该词
  void _showImportedInRightReader(String word) {
    if (_showDetectedTextInRightReader(keyword: word)) return;
    // 无被检测的导入文本时面板保持收起，不展示任何内容
    _hideRightReader();
  }


  /// 保存文件后，对比新旧文本，将不再出现的单词从超标词/拓展词/专有词中移除
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
        const SizedBox(width: kGap1),
        // 关键词：蓝色可点击，点击跳转到原文定佀
        GestureDetector(
          onTap: () => _showResultInRightReader(row),
          child: GlassPressable(radius: 4, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: Text.rich(
            TextSpan(
              text: row.keyword,
              style: const TextStyle(
                fontSize: 12,
                color: GlassTheme.accentInk,
                decoration: TextDecoration.underline,
                decorationColor: GlassTheme.accentInk,
              ),
            ),
            maxLines: 1,
          ),
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

  /// 玻璃弹窗包装：加厚玻璃材质（72% 白 + blur32 + 重投影，对应规范 2.9 对话框）
  Widget _glassDialog(Widget dialog) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // 第三关 ③：insetPadding 归零，让模糊遮罩铺满整个窗口（原 28/32 会在四周留出未处理的亮边）
      insetPadding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Stack(
          children: [
            // 全窗口背景模糊 blur5；压暗统一由 dialogTheme.barrierColor
            // rgba(24,24,27,.28) 提供，避免与内层遮罩叠加造成二次压暗
            Positioned.fill(
              child: ClipRect(
                child: FrostFilter(
                  enabled: false,
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28.0,
                  vertical: 32.0,
                ),
                child: Container(
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                    boxShadow: [
                      BoxShadow(
                        color: Color(
                          0x4018181B,
                        ), // rgba(24,24,27,0.25) 0 24px 60px
                        blurRadius: 60,
                        offset: Offset(0, 24),
                      ),
                    ],
                  ),
                  child: GlassPanel(
                    radius: 16, // 第三关 ③：弹窗圆角 16（规范 §2.9.1）
                    sigma: 12, // 任务④：32 → 12，保留磨砂观感、避开高 sigma 的成倍采样
                    color: GlassTheme.panelSolid,
                    borderColor: GlassTheme.line,
                    shrinkWrap: true, // 第三关 ③：弹窗玻璃收紧到内容宽度，不再铺满整窗口
                    child: dialog,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showHelp() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const _HelpPage()));
  }

  // ==================== 词库列表弹窗（复选 + 全选 + 3秒防抖批量操作） ====================

  /// 词库列表弹窗的展示列表：倒序展示 + 大小写不敏感子串过滤。
  /// 这是热路径 —— 弹窗内每次输入都会全量重建，词库达数千词时开销明显。
  /// 抽成独立方法，便于统一优化与性能自测（前后走同一条代码路径）。
  ///
  /// 任务④（运行速度）：① 单趟反向遍历产出结果，去掉中间 `reversed.toList()`
  /// 全量拷贝；② 同一 (词表, 输入) 记忆复用 —— 勾选/滚动等无关重建不再重算过滤。
  List<String>? _bankMemoSource;
  String? _bankMemoSearch;
  List<String>? _bankMemoValue;

  List<String> _bankSearchList(List<String> source, String search) {
    if (identical(source, _bankMemoSource) &&
        search == _bankMemoSearch &&
        _bankMemoValue != null) {
      return _bankMemoValue!;
    }
    final rev = source.reversed;
    final List<String> result;
    if (search.isEmpty) {
      result = rev.toList();
    } else {
      final loweredSearch = search.toLowerCase();
      result = <String>[
        for (final w in rev)
          if (w.toLowerCase().contains(loweredSearch)) w,
      ];
    }
    _bankMemoSource = source;
    _bankMemoSearch = search;
    _bankMemoValue = result;
    return result;
  }

  /// 优化前实现快照（仅供 [EswPerf] 性能自测做同机同轮前后对比，生产路径不调用）。
  List<String> _bankSearchListLegacy(List<String> source, String search) {
    final words = source.reversed.toList();
    if (search.isEmpty) return words;
    final loweredSearch = search.toLowerCase();
    return words
        .where((w) => w.toLowerCase().contains(loweredSearch))
        .toList();
  }

  Future<void> _showWordListDialog({
    required String title,
    required String emptyHint,
    required List<String> Function() getWords,
    required List<Widget> Function(
      String w,
      void Function(void Function()) setDialogState,
      BuildContext ctx,
    )
    trailingBuilder,
    // 仅供自动化截图自查：初始勾选词（生产调用不传）
    List<String>? initialSelected,
    // 词库导出标识（[kWordBankKinds] 中的 key：extend / overLimit / proper）。
    // 传入后列表顶部显示「导出Word版」「导出Excel版」两个按钮，点击即导出
    // 该词库真实已归类词（版式与「导出高频」同源）；null 表示不显示导出入口。
    String? bankKind,
  }) async {
    if (getWords().isEmpty) {
      showDialog(
        barrierDismissible: true,
        context: context,
        builder: (emptyCtx) => _glassDialog(
          EswDialogShell(
            title: title,
            subtitle: emptyHint,
            icon: Icons.info_outline,
            // 右上角关闭按钮：与有词列表时保持一致，保证任何状态下都可关闭
            trailing: Tooltip(
              message: '关闭词库列表',
              child: _SyncDialogCloseButton(
                onPressed: () {
                  if (emptyCtx.mounted) Navigator.pop(emptyCtx);
                },
              ),
            ),
            body: const SizedBox.shrink(),
            actions: EswDialogActions(
              children: [
                EswDialogPrimaryAction(label: '确定', onPressed: () => Navigator.pop(emptyCtx)),
              ],
            ),
          )
        ),
      );
      return;
    }
    _batchTimer?.cancel();
    _batchSelected.clear();
    if (initialSelected != null && initialSelected.isNotEmpty) {
      _batchSelected.addAll(initialSelected);
    }
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (listCtx) {
        String search = '';
        var dragOffset = Offset.zero;
        // 任务④（运行速度）：词表快照只取一次 —— 原实现每次重建（勾选、滚动、
        // 逐字输入）都调 getWords() 全量拷贝一份（数千词），且每次都是新对象
        // 使下层过滤无法复用缓存；弹窗打开期间行内操作都会关闭本弹窗，
        // 因此这里快照一次即可保持数据一致。
        final sourceWords = getWords();
        final wordCount = sourceWords.length;
        return StatefulBuilder(
          builder: (_, setDialogState) {
            // 批量操作改为页面底部按钮，不再使用 3 秒自动弹出弹窗
            final targets = switch (_batchSourceKind) {
              'extend' => const ['超标词', '专有词'],
              'chaogang' => const ['拓展词', '专有词'],
              'extra' => const ['拓展词', '超标词'],
              _ => const <String>[],
            };
            Future<void> doBatchReclassify(String target) async {
              // 转拓展词：_applyBatchReclassify 内部会逐词弹窗确认课标词原词，
              // 期间保持词库列表弹窗不变，全部确认/取消结束后再关闭
              await _applyBatchReclassify(target);
              if (!mounted) return;
              _batchSelected.clear();
                            setState(() {});
              if (listCtx.mounted) Navigator.pop(listCtx);
            }

            Future<void> doBatchDelete() async {
              final ok = await _applyBatchDelete();
              if (!ok) return; // 用户取消：保留选择状态，无副作用
              _batchSelected.clear();
                            setState(() {});
              if (listCtx.mounted) Navigator.pop(listCtx);
            }

            // 词库导出：点击即把当前词库真实已归类词导出为 Word / Excel。
            // 先关闭词库列表弹窗（避免双层弹窗挡住导出结果提示），再执行导出；
            // 数据源为词库实时状态（见 [_exportWordBank]），与界面列表完全一致，
            // 导出排版复用「导出高频」的同一套构建器。
            Future<void> doExportBank(String fmt) async {
              final kind = bankKind;
              if (kind == null) return;
              if (listCtx.mounted) Navigator.pop(listCtx);
              await _exportWordBank(kind: kind, format: fmt);
            }

            final filtered = _bankSearchList(sourceWords, search);
            // 性能探针钩子：把「按输入重建列表」的真实路径登记给自动化脚本，
            // 便于逐字输入采集帧耗时。仅在设置了 ESW_PERF_PROBE 时生效。
            if (EswPerf.enabled) {
              EswPerf.bankSearchDriver = (v) {
                setDialogState(() {
                  search = v;
                  _batchSelected.clear();
                });
              };
            }
            final allSelected =
                filtered.isNotEmpty &&
                filtered.every((w) => _batchSelected.contains(w));
            // 面板宽度：内容自适应（长单词列表 + 底部批量按钮属「宽内容档」），
            // 统一上限 EswDialog.wPanelWide，不再随窗口百分比在 520~820 之间浮动，
            // 避免同一弹窗随窗口缩放忽大忽小、与其它弹窗宽窄差距过大。
            final media = MediaQuery.sizeOf(context);
            final panelW = EswDialog.panelWidth(
              context,
              minContent: 560,
              maxWidth: EswDialog.wPanelWide,
            );
            // 列表区高度上限（随窗口高度自适应）：词条成千上万时改为列表内部滚动，
            // 弹窗不再被长列表无限撑高（竖向太高问题）。
            final listMaxH = (media.height * 0.42).clamp(180.0, 440.0);
            return Transform.translate(
              offset: dragOffset,
              child: _glassDialog(
                EswDialogShell(
                  width: panelW,
                  icon: Icons.menu_book_outlined,
                  titleWidget: Text(
                    _batchSelected.isEmpty
                        ? '$title（共$wordCount个）'
                        : '$title（已选${_batchSelected.length}个）',
                    style: EswDialog.titleStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onDrag: (d) => setDialogState(() => dragOffset += d),
                  // 右上角关闭按钮：点击关闭词库弹窗（不改动任何词库数据）
                  trailing: Tooltip(
                    message: '关闭词库列表',
                    child: _SyncDialogCloseButton(
                      onPressed: () {
                        if (listCtx.mounted) Navigator.pop(listCtx);
                      },
                    ),
                  ),
                  // 列表自身带滚动体：禁用外层整体滚动，避免滚动嵌套
                  scrollable: false,
                  body: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 顶部导出条：仅词库列表（传入 bankKind）显示，点击即导出
                      // 当前词库真实已归类词，不做类型/格式二次选择。
                      if (bankKind != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: kGap8),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.download_rounded,
                                size: 15,
                                color: GlassTheme.ink3,
                              ),
                              const SizedBox(width: kGap4),
                              Expanded(
                                child: Text(
                                  '导出$title（$wordCount词）',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: GlassTheme.ink3,
                                  ),
                                ),
                              ),
                              EswDialogGhostAction(
                                label: '导出Word版',
                                icon: Icons.description_outlined,
                                height: 30,
                                fontSize: 12.5,
                                onPressed: () => doExportBank('docx'),
                              ),
                              const SizedBox(width: kGap8),
                              EswDialogGhostAction(
                                label: '导出Excel版',
                                icon: Icons.table_chart_outlined,
                                height: 30,
                                fontSize: 12.5,
                                onPressed: () => doExportBank('xlsx'),
                              ),
                            ],
                          ),
                        ),
                      if (wordCount > 3) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: kGap8),
                          child: TextField(
                            decoration: const InputDecoration(
                              hintText: '搜索单词...',
                              prefixIcon: Icon(Icons.search, size: 18),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(6),
                                ),
                              ),
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
                          padding: EdgeInsets.symmetric(vertical: kGap16),
                          child: Center(
                            child: Text(
                              '暂无匹配单词',
                              style: TextStyle(color: GlassTheme.ink2),
                            ),
                          ),
                        ),
                      ],
                      if (filtered.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(
                            right: kGap16,
                            bottom: kGap4,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              const Text(
                                '全选',
                                style: TextStyle(fontSize: 12.5),
                              ),
                              Transform.scale(
                                scale: 0.9,
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
                                  },
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 列表区：高度上限 listMaxH，超出部分在列表内部滚动
                        Flexible(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: listMaxH),
                            child: ListView.builder(
                              padding: const EdgeInsets.only(right: kGap12),
                              // 任务④（运行速度）：词条数超过可视高度上限时不再 shrinkWrap。
                              // shrinkWrap=true 会强制在每次重建时布局全部词条（本库可达数千条，
                              // 逐字输入即 O(N) 重排）；而超出上限时两种写法的可见高度完全一致
                              // （都被 listMaxH 截断），因此长列表改为惰性构建，短列表维持紧凑自适应。
                              shrinkWrap: filtered.length * 25.0 <= listMaxH,
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final w = filtered[i];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 3,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 34,
                                        child: Text(
                                          '${i + 1}.',
                                          textAlign: TextAlign.right,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            color: GlassTheme.ink2,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: kGap8),
                                      Expanded(
                                        child: GlassPressable(radius: GlassTheme.rMd, hoverColor: const Color(0x0A18181B), pressColor: const Color(0x294462F2), enabled: true, child: InkWell(
                                          onTap: () {
                                            Navigator.pop(listCtx);
                                            _searchController.text = w;
                                            _beginIndependentQuery();
                                            _onDetect();
                                          },
                                          child: Text(
                                            w,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13.5,
                                              color: GlassTheme.accentInk,
                                              decoration:
                                                  TextDecoration.underline,
                                            ),
                                          ),
                                        )),
                                      ),
                                      ...trailingBuilder(
                                        w,
                                        setDialogState,
                                        listCtx,
                                      ),
                                      // 拓展词汇：勾选框左侧的小号编辑（铅笔）按钮，
                                      // 复用原「修改课标词根」流程（弹窗 → 成功后同步云端）
                                      if (_batchSourceKind == 'extend') ...[
                                        Tooltip(
                                          message: '修改课标词根',
                                          child: GlassPressable(
                                            radius: GlassTheme.rSm,
                                            hoverColor: const Color(0x0A18181B),
                                            pressColor: const Color(0x294462F2),
                                            child: InkWell(
                                              onTap: () async {
                                                final ok =
                                                    await _showExtendWordDialog(
                                                      extendWord: w,
                                                      dialogTitle:
                                                          '修改 "$w" 的课标词根',
                                                    );
                                                if (ok == true) {
                                                  if (listCtx.mounted) {
                                                    Navigator.pop(listCtx);
                                                  }
                                                  await _syncVocab();
                                                  if (mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          '课标词根已修改，已同步到云端',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                }
                                              },
                                              child: const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: Icon(
                                                  Icons.edit_outlined,
                                                  size: 15,
                                                  color: GlassTheme.ink2,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: kGap4),
                                      Transform.scale(
                                        scale: 0.9,
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
                        ),
                      ],
                    ],
                  ),
                  // 底部批量按钮区：整体居中（对齐观感更稳），按钮高度 36、
                  // 字号 13，宽度不足时自动换行且不挤压文字。
                  actions: _batchSelected.isEmpty
                      ? null
                      : SizedBox(
                          width: double.infinity,
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: kGap8,
                            runSpacing: kGap8,
                            children: [
                              for (final t in targets)
                                EswDialogGhostAction(
                                  label: '转为$t',
                                  height: 36,
                                  fontSize: 13,
                                  onPressed: () => doBatchReclassify(t),
                                ),
                              EswDialogPrimaryAction(
                                label: '删除所选单词',
                                icon: Icons.delete_outline,
                                danger: true,
                                height: 36,
                                fontSize: 13,
                                onPressed: doBatchDelete,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            );
          },
        );
      },
    );
    _batchTimer?.cancel();
    _batchSelected.clear();
    // 弹窗已关闭：注销性能探针钩子，避免残留回调（生产环境恒为 null）
    if (EswPerf.enabled) {
      EswPerf.bankSearchDriver = null;
    }
  }

  Future<void> _showExtendWordsDialog({List<String>? initialSelected}) async {
    _batchSourceKind = 'extend';
    await _showWordListDialog(
      title: '拓展词汇',
      bankKind: 'extend',
      initialSelected: initialSelected,
      emptyHint: '暂未添加任何拓展词。\n请先搜索标注词，再点击拓展词按钮添加。',
      getWords: () => List<String>.from(_extendWords),
      trailingBuilder: (w, setDialogState, ctx) {
        // 这里不返回任何额外按钮；行内的编辑入口由 _showWordListDialog
        // 统一渲染（仅 extend 列表在勾选框左侧显示小号铅笔按钮），
        // 批量转换/删除仍由勾选后 3 秒弹出的底部按钮完成。
        return [];
      },
    );
  }

  /// 【仅性能探针】打开一个「空路由弹窗」：只有路由 + 遮罩 + 极简内容，
  /// 用于把词库弹窗首开一次性开销归因到「路由机制」还是「弹窗内容」。
  Future<void> _probeOpenBareDialog() async {
    await showDialog<void>(
      barrierDismissible: true,
      context: context,
      builder: (_) => const SizedBox(
        width: 240,
        height: 120,
        child: ColoredBox(color: Color(0x33FFFFFF)),
      ),
    );
  }

  /// 【仅性能探针】打开一个「仅玻璃外壳弹窗」：路由 + 遮罩 + 真实玻璃弹窗外壳，
  /// 但不含词库列表内容，用于判定开销是否来自玻璃壳/模糊层。
  Future<void> _probeOpenShellDialog() async {
    await showDialog<void>(
      barrierDismissible: true,
      context: context,
      builder: (shellCtx) => _glassDialog(
        EswDialogShell(
          title: '预热诊断',
          subtitle: '仅外壳，无列表内容',
          icon: Icons.info_outline,
          trailing: _SyncDialogCloseButton(
            onPressed: () {
              if (shellCtx.mounted) Navigator.pop(shellCtx);
            },
          ),
          body: const SizedBox(height: 220),
          actions: EswDialogActions(
            children: [
              EswDialogPrimaryAction(
                label: '确定',
                onPressed: () => Navigator.pop(shellCtx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showChaoGangWordsDialog() async {
    _batchSourceKind = 'chaogang';
    await _showWordListDialog(
      title: '超标词汇',
      bankKind: 'overLimit',
      emptyHint: '暂未添加任何超标词。\n请先搜索标注词，再点击超标词按钮添加。',
      getWords: () => _manualChaoGangWords.toList(),
      trailingBuilder: (w, setDialogState, ctx) {
        // 仅保留勾选框与 3 秒后自动弹出的批量操作，不再显示行内转换/删除按钮
        return [];
      },
    );
  }

  Future<void> _showExtraWordsDialog({List<String>? initialSelected}) async {
    _batchSourceKind = 'extra';
    await _showWordListDialog(
      title: '专有词汇',
      bankKind: 'proper',
      initialSelected: initialSelected,
      emptyHint: '暂未添加任何专有词。\n请在导入分析中点击"跳过"按钮添加。',
      getWords: () => _manualExtraWords.toList(),
      trailingBuilder: (w, setDialogState, ctx) {
        // 仅保留勾选框与 3 秒后自动弹出的批量操作，不再显示行内转换/删除按钮
        return [];
      },
    );
  }

  // ==================== 批量转类 / 批量删除 ====================
  /// 批量转类。target == '拓展词' 属于「转拓展词」入口：不允许批量静默置类，
  /// 必须逐词弹出拓展词添加弹窗选择课标词原词，确认一个转一个；
  /// 取消 / 未选有效课标词的单词保持原类别不转，其余已确认的照常转为拓展词。
  Future<void> _applyBatchReclassify(String target) async {
    final words = _batchSelected.toList();
    if (target == '拓展词') {
      final total = words.length;
      for (int i = 0; i < words.length; i++) {
        if (!mounted) break;
        final w = words[i];
        // 多选批量时标注进度，让用户清楚还需确认多少个单词
        final ok = await _reclassifyToExtendWord(
          w,
          dialogTitle: total > 1
              ? '将 "$w" 转为拓展词（${i + 1}/$total，请选择课标词原词）'
              : null,
        );
        if (ok) _wordSyncService.markChanged(w);
      }
      _saveConfig();
      return;
    }
    for (final w in words) {
      _applyCategoryChange(w, target);
      _wordSyncService.markChanged(w);
      // 转到超标词/专有词时解除原有的拓展词关联（原逻辑保留）
      _extendBaseMap.remove(w);
      _extendReverseIndex.remove(w.toLowerCase());
    }
    _saveConfig();
  }

  Future<bool> _applyBatchDelete() async {
    final words = _batchSelected.toList();
    if (words.isEmpty) return false;
    // 大范围删除保护：与同步弹窗规则一致——
    // 删除超过 10 个 → 确认；超过 50 个 → 先自动备份云端再确认；取消无副作用
    if (words.length > 10) {
      final total =
          _extendWords.length +
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
      _extendWordsLower.remove(lower);
      _manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
      _manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
      _extendBaseMap.remove(w);
      _extendReverseIndex.remove(lower);
      _wordSyncService.markDeleted(w);
    }
    _saveConfig();
    return true;
  }

  String _genUserId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = (now * 1103515245 + 12345) & 0x7fffffff;
    return 'win_${now.toRadixString(36)}_${rand.toRadixString(36)}';
  }

  /// 汇总软件词库的拓展词→课标原词映射，序列化为 JSON 字符串供导出器使用。
  ///
  /// **数据源与界面"拓展词汇"列表页严格一致**：界面列表（_showExtendWordsDialog）
  /// 渲染的是运行时 _extendWords（来自 exe 同目录 esw_config.json 的
  /// extendWords 字段，词库同步/会话内添加亦写回该文件）。归属映射
  /// _extendBaseMap 来自同一文件的 extendBaseMap 字段。
  ///
  /// **双重白名单**：extendBaseMap 键中存在界面列表未展示的脏映射（如
  /// ind→in 缩略词映射：ind 不在 extendWords 列表中，界面词库没有该拓展词），
  /// 导出时必须剔除。因此仅保留「键 ∈ 界面 extendWords 集合」的映射，
  /// 确保导出词表的每个拓展词都真实存在于界面词库中。
  String _collectExtendBaseMapRaw() {
    final merged = <String, String>{};
    for (final e in _extendBaseMap.entries) {
      final k = e.key.toLowerCase().trim();
      final v = e.value.toLowerCase().trim();
      if (k.isEmpty || v.isEmpty) continue;
      // 键必须在界面"拓展词汇"列表集合内（_extendWordsLower 由 esw_config.json
      // extendWords 构建），不在集合内的映射一律剔除（如 ind）。
      if (!_extendWordsLower.contains(k)) continue;
      merged[k] = v;
    }
    return jsonEncode(merged);
  }

  /// 导出高频词表：统计真题语料词频，取前 3000 导出。先让用户选择
  /// Word(docx) 或 Excel(xlsx) 格式，再执行导出（排除星期/月份/序数词）。
  ///
  /// 本按钮与版式保持原样；三类词库的导出入口在各词库列表弹窗顶部
  /// （「导出Word版」/「导出Excel版」，见 [_exportWordBank]）。
  Future<void> _exportHighFreq() async {
    if (_highFreqExporting) return;
    _highFreqExporting = true;
    _ExportProgress? progress;
    try {
      // 格式选择：Word(docx) / Excel(xlsx)，取消则不导出
      final format = await showDialog<String>(
        context: context,
        builder: (dctx) {
          var pickedFormat = 'docx';
          return _glassDialog(
            StatefulBuilder(
              builder: (ctx, setDialogState) => EswDialogShell(
                title: '选择导出格式',
                subtitle: '请选择高频词表的导出格式：',
                icon: Icons.file_download_outlined,
                minContent: 300,
                body: EswOptionRow(
                  children: [
                    EswOptionTile(
                      label: 'Word',
                      desc: '.docx',
                      selected: pickedFormat == 'docx',
                      onTap: () =>
                          setDialogState(() => pickedFormat = 'docx'),
                    ),
                    EswOptionTile(
                      label: 'Excel',
                      desc: '.xlsx',
                      selected: pickedFormat == 'xlsx',
                      onTap: () =>
                          setDialogState(() => pickedFormat = 'xlsx'),
                    ),
                  ],
                ),
                actions: EswDialogActions(
                  children: [
                    EswDialogTextAction(
                      label: '取消',
                      onPressed: () => Navigator.pop(dctx),
                    ),
                    EswDialogPrimaryAction(
                      label: '导出',
                      onPressed: () => Navigator.pop(dctx, pickedFormat),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      if (format == null) return;

      // 确保词典数据库已部署到本地
      await DictionaryService.lookup('the');

      // 语料目录：不再内置 corpus，也不硬编码本机路径。
      // 仅使用用户主动导入的真题/教材语料：
      // 1) 已导入真题且全部来自同一目录 → 直接使用该目录；
      // 2) 否则弹窗引导导入真题或教材；导入后仍无法确定目录时让用户选择真题文件夹；
      // 3) 用户拒绝导入 → 提示"无法完成真题单词检测"并中止。
      String? corpusDir = _deriveCorpusDir();
      if (corpusDir == null) {
        final imported = await _promptCorpusImport();
        if (!imported) return;
        corpusDir = _deriveCorpusDir();
        if (corpusDir == null) {
          corpusDir = await FilePicker.getDirectoryPath(
              dialogTitle: '选择真题语料目录（含真题 txt 的文件夹）');
          if (corpusDir == null || corpusDir.isEmpty) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('无法完成真题单词检测：未提供真题语料目录')),
              );
            }
            return;
          }
        }
      }

      // 保存路径：检测系统真实桌面（Known Folder API / USERPROFILE），
      // 默认保存到桌面；文件名与扩展名随所选格式
      final desktopDir = await systemDesktopPath();
      final ext = format == 'docx' ? 'docx' : 'xlsx';
      final savePath = p.join(
          desktopDir, 'ESW-高考高频词表.$ext');

      // 预计用时：按语料规模动态估算（实测约 3 秒/MB，留足余量按 ~7 秒/MB 估算）
      var corpusBytes = 0;
      try {
        for (final f in Directory(corpusDir).listSync().whereType<File>()) {
          if (f.path.toLowerCase().endsWith('.txt')) {
            corpusBytes += f.lengthSync();
          }
        }
      } catch (_) {
        // 统计失败则使用默认估算
      }
      final estMinutes =
          (corpusBytes / (1024 * 1024) * 7 / 60).ceil().clamp(1, 999);

      // 等待提示：语料越多耗时越长，附带按语料规模估算的预计用时；
      // 延迟 0.5s 未完成才弹窗，小语料快速导出不闪屏。
      progress = await _beginExportProgress(
        '正在统计真题词频并生成词表…',
        hint: '预计总用时约$estMinutes分钟，请耐心等待',
      );

      final standardWordsRaw =
          await rootBundle.loadString('assets/standard_words.json');
      final appData = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          '.';
      final dbPath = p.join(appData, 'ESW', 'ecdict.db');

      // 拓展词严格以软件词库数据为准：合并运行时词库（_extendBaseMap，
      // 来自 esw_config.json 加载与词库同步）+ 共享/同步词库文件中的
      // extendBaseMap（shared_vocab.json / word_sync_state.json），传入
      // 导出器作为唯一拓展词归并依据（不再从 ecdict exchange 全量引入）。
      // extendWordsRaw 为界面"拓展词汇"列表的完整词集合（与列表页同一
      // 数据源 esw_config.json extendWords），导出器据此对课标词库
      // extensions 做同样的白名单过滤。
      final extendBaseMapRaw = _collectExtendBaseMapRaw();
      final extendWordsRaw =
          jsonEncode(_extendWords.map((w) => w.toLowerCase()).toList());

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
      await File(savePath).writeAsBytes(outBytes);
      WinWindowRepaint.burst();

      if (mounted) {
        final fmtName = result.format == 'docx' ? 'Word(docx)' : 'Excel(xlsx)';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '导出高频完成（$fmtName）：${result.exportedWords} 词（${result.corpusFileCount} 篇真题语料，已排除星期/月份/序数词 ${result.calendarOrdinalExcluded.length} 个），已保存至 $savePath',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[ExportHighFreq] error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出高频失败：$e')),
        );
      }
    } finally {
      // 失败分支此前未关闭进度窗，会残留遮挡界面，这里统一收尾
      progress?.close();
      _highFreqExporting = false;
    }
  }

  /// 导出三类词库（拓展词库 / 超标词库 / 专有词库）为 Word 或 Excel。
  ///
  /// 数据严格取自软件词库当前状态，不臆造任何词条：
  /// - 拓展词库：[_extendWords]（界面「拓展词汇」列表）+ 同源白名单映射
  ///   （[_collectExtendBaseMapRaw]，键已限定在界面拓展词集合内）；
  /// - 超标词库：[_manualChaoGangWords]（「超标词汇」分类已归类词）；
  /// - 专有词库：[_manualExtraWords]（「专有词汇」分类已归类词）。
  ///
  /// 排版完全复用高频统计的同一套构建器（[HighFreqExporter.exportWordBank]
  /// 内部调用 _buildDocx / _buildXlsx / _buildTxt）：标题结构、说明行、字号
  /// 字重、七类字色、页边距、表头与列顺序均与「导出高频」一致，仅数据源不同。
  /// Word 为纵向列举（词条加粗、释义另起），Excel 为分列表格。文件保存到桌面。
  Future<void> _exportWordBank({
    required String kind,
    required String format,
  }) async {
    final meta = kWordBankKinds.firstWhere(
      (k) => k.key == kind,
      orElse: () => kWordBankKinds.first,
    );

    final List<String> words;
    var baseMap = const <String, String>{};
    switch (kind) {
      case 'extend':
        words = List<String>.from(_extendWords);
        try {
          final raw = jsonDecode(_collectExtendBaseMapRaw());
          if (raw is Map) {
            baseMap = <String, String>{
              for (final e in raw.entries)
                e.key.toString(): e.value.toString(),
            };
          }
        } catch (e) {
          debugPrint('[ExportWordBank] extendBaseMap 解析失败：$e');
          baseMap = const <String, String>{};
        }
        break;
      case 'overLimit':
        words = _manualChaoGangWords.toList();
        break;
      case 'proper':
        words = _manualExtraWords.toList();
        break;
      default:
        words = const <String>[];
    }

    if (words.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${meta.label}为空，暂无词条可导出')),
        );
      }
      return;
    }

    // 等待提示：词库可达数千词，生成 Word/Excel 需逐词读词典释义，
    // 实测可达数秒以上；延迟 0.5s 未完成才弹窗，小词库导出不闪屏。
    final progress = await _beginExportProgress(
      '正在生成${meta.label}（${words.length}词，${format == 'xlsx' ? 'Excel' : 'Word'}版）…',
      hint: '词条越多耗时越长，请耐心等待',
    );
    try {
      // 词典库：缺失/版本过低时自动从 assets 部署，返回可读绝对路径
      final dbPath = await DictionaryService.ensureDeployedDbPath();
      final desktopDir = await systemDesktopPath();
      final ext = format == 'xlsx' ? 'xlsx' : 'docx';
      final savePath = p.join(desktopDir, 'ESW-${meta.title}.$ext');

      final result = await HighFreqExporter.exportWordBank(
        kind: kind,
        words: words,
        baseMap: baseMap,
        dbPath: dbPath,
        format: format,
      );
      await File(savePath).writeAsBytes(result.bytes);
      WinWindowRepaint.burst();

      if (!mounted) return;
      final fmtName = result.format == 'xlsx' ? 'Excel(xlsx)' : 'Word(docx)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '导出${meta.label}完成（$fmtName）：${result.wordCount} 词'
            '（词典释义命中 ${result.dictHit} 词），已保存至 $savePath',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (e, st) {
      debugPrint('[ExportWordBank] error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出${meta.label}失败：$e')),
        );
      }
    } finally {
      progress.close();
    }
  }

  /// 时间戳同步：逐词比对，谁新谁赢。
  /// 云端有变动时弹窗让用户选择同意/拒绝，无网络时静默。
  Future<void> _syncVocab() async {
    // 点击即给出可见反馈，避免「点了没反应」的观感
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('正在同步词库…'),
      ),
    );
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

      // 同步失败（无凭据 / 鉴权被拒 / 网络 / 超时 / 云端错误）：
      // 历史实现一律静默成"已是最新"，换电脑的用户完全无从判断。
      if (result['success'] != true) {
        await _handleSyncFailure(result);
        return;
      }

      // 新机首次同步（换电脑）：本地词库为空、云端有词 → 整库恢复，不弹逐词冲突。
      if (result['bootstrap'] == true) {
        final words = <String, Map<String, String>>{};
        final raw = result['bootstrap_words'];
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
        await _applyBootstrapWords(words);
        final ebm = result['extendBaseMap'] as Map<String, dynamic>?;
        if (ebm != null) _mergeExtendBaseMap(ebm);
        return;
      }

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
            if (!mounted) return;
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
            final action =
                d['action'] as String; // 'accept' / 'reject' / 'upload_local'
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
            pushLocalWords[w.toLowerCase()] = {
              'original_case': w,
              'category': '拓展词',
            };
          }
          for (final w in _manualChaoGangWords) {
            pushLocalWords[w.toLowerCase()] = {
              'original_case': w,
              'category': '超标词',
            };
          }
          for (final w in _manualExtraWords) {
            pushLocalWords[w.toLowerCase()] = {
              'original_case': w,
              'category': '专有词',
            };
          }
          await _wordSyncService.sync(
            localWords: pushLocalWords,
            localExtendBaseMap: _extendBaseMap,
            source: 'win',
          );
        }
      }
      final ebm = result['extendBaseMap'] as Map<String, dynamic>?;
      if (ebm != null) _mergeExtendBaseMap(ebm);
      final cm = <String, String>{};
      for (final w in _extendWords) {
        cm[w.toLowerCase()] = '拓展词';
      }
      for (final w in _manualChaoGangWords) {
        cm[w.toLowerCase()] = '超标词';
      }
      for (final w in _manualExtraWords) {
        cm[w.toLowerCase()] = '专有词';
      }
      _classificationMemory
        ..clear()
        ..addAll(cm);
      _saveConfig();
      if (mounted) {
        setState(() {});
        final msg = result['push_failed'] == true
            ? '同步完成，但本地变更上传失败（网络或云端权限），请稍后重试'
            : remoteChanges.isEmpty
                ? '同步完成 (已是最新)'
                : '同步完成 (已处理${remoteChanges.length}条云端变更)';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
        _maybePromptCorpusImport();
      }
    } catch (e) {
      // 原实现 catch (_) {} 静默吞异常：同步失败（如无网络）时界面毫无变化，
      // 用户会以为「同步词库按钮点击无反应」。现改为显式反馈失败原因，本地数据不变。
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 4),
            content: Text('同步失败：$e'),
          ),
        );
      }
    }
  }

  /// 合并云端 extendBaseMap（词形映射表），只补齐本地缺失项。
  void _mergeExtendBaseMap(Map<String, dynamic> ebm) {
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

  /// 同步失败的分类提示。
  ///
  /// 换电脑后"同步词库没反应"的核心体验问题：历史实现把无凭据/鉴权失败
  /// 全部静默吞成"已是最新"，用户无法判断是没账号、账号错，还是云端没数据。
  /// no_config / auth 给出可操作入口（直接填写账号），其余给出可读原因。
  Future<void> _handleSyncFailure(Map<String, dynamic> result) async {
    final kind = result['error_kind']?.toString() ?? 'unknown';
    final msg = result['error']?.toString() ?? '未知原因';
    if (!mounted) return;

    if (kind == 'no_config' || kind == 'auth') {
      final open = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _glassDialog(
          EswDialogShell(
            title: kind == 'no_config' ? '未配置同步账号' : '同步账号无效',
            subtitle: kind == 'no_config'
                ? '本机没有找到可用的坚果云同步账号，因此无法同步词库。\n\n'
                    '可以在这里直接填写坚果云账号与应用密码（只保存在本机，不随程序分发）。'
                : '坚果云拒绝了当前同步账号：$msg\n\n'
                    '请在坚果云「安全设置」里重新生成应用密码后填写。',
            icon: Icons.key_rounded,
            body: const SizedBox.shrink(),
            actions: EswDialogActions(
              children: [
                EswDialogTextAction(
                  label: '稍后',
                  onPressed: () => Navigator.pop(ctx, false),
                ),
                EswDialogPrimaryAction(
                  label: '填写同步账号',
                  onPressed: () => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ),
        ),
      );
      if (open == true) await _showSyncAccountDialog();
      return;
    }

    final hint = kind == 'timeout'
        ? '同步超时：网络较慢或云端无响应，请稍后重试。'
        : kind == 'network'
            ? '网络不可用：请检查网络连接后重试。'
            : kind == 'http'
                ? '云端返回错误：$msg'
                : '同步失败：$msg';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 6), content: Text(hint)),
    );
  }

  /// 手动填写同步账号（换电脑 / 换密码 / 内置凭据失效时的兜底入口）。
  Future<void> _showSyncAccountDialog() async {
    final cfg = await WebDavConfig.load();
    final baseCtrl = TextEditingController(
        text: (cfg?.baseUrl.isNotEmpty ?? false)
            ? cfg!.baseUrl
            : 'https://dav.jianguoyun.com/dav/esw_sync');
    final userCtrl = TextEditingController(text: cfg?.username ?? '');
    final pwdCtrl = TextEditingController(text: cfg?.password ?? '');
    final sourceLabel = switch (cfg?.source) {
      'user' => '用户配置文件',
      'localappdata' => '%LOCALAPPDATA%\\ESW',
      'portable' => '程序同目录',
      'bundled' => '随包内置配置',
      _ => '未找到',
    };
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        var testing = false;
        var status = '';
        var statusOk = false;
        return StatefulBuilder(
          builder: (ctx2, setDialogState) => _glassDialog(
            EswDialogShell(
              title: '同步账号',
              subtitle: '当前凭据来源：$sourceLabel。\n'
                  '填写坚果云账号与「应用密码」（坚果云 → 账户信息 → 安全设置 → 添加应用），'
                  '保存后只写入本机用户目录，不会随安装包分发。',
              icon: Icons.cloud_sync_rounded,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _accountField('服务地址', baseCtrl),
                  const SizedBox(height: kGap10),
                  _accountField('账号（邮箱）', userCtrl),
                  const SizedBox(height: kGap10),
                  _accountField('应用密码', pwdCtrl, obscure: true),
                  if (status.isNotEmpty) ...[
                    const SizedBox(height: kGap12),
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: GlassTheme.fSmall,
                        color: statusOk ? GlassTheme.green : const Color(0xFFD14343),
                      ),
                    ),
                  ],
                ],
              ),
              actions: EswDialogActions(
                children: [
                  EswDialogTextAction(
                    label: '取消',
                    onPressed: () => Navigator.pop(ctx, false),
                  ),
                  EswDialogGhostAction(
                    label: testing ? '测试中…' : '测试连接',
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
                            final probe =
                                await _wordSyncService.verifyAccount(testCfg);
                            if (!mounted) return;
                            setDialogState(() {
                              testing = false;
                              statusOk = probe['ok'] == true;
                              status = probe['message']?.toString() ?? '';
                            });
                          },
                  ),
                  EswDialogPrimaryAction(
                    label: '保存并同步',
                    onPressed: () => Navigator.pop(ctx, true),
                  ),
                ],
              ),
            ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('服务地址 / 账号 / 应用密码都不能为空')),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('账号保存失败：无法写入本机用户目录')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('同步账号已保存，正在同步词库…')),
      );
      await _syncVocab();
    }
  }

  Widget _accountField(String label, TextEditingController ctrl,
      {bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: GlassTheme.fSmall, color: Color(0xFF6B6B73))),
        const SizedBox(height: kGap6),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          style: const TextStyle(fontSize: GlassTheme.fBody),
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: kGap10, vertical: kGap10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(GlassTheme.rMd),
            ),
          ),
        ),
      ],
    );
  }

  /// 新机首次同步：把云端整库一次性恢复到本地。
  ///
  /// 上万词逐条落地会长时间占满主线程（实测 12973 词约 4.5 秒），
  /// 这里每 500 词让出一次事件循环并刷新进度条，避免窗口"假死"。
  Future<void> _applyBootstrapWords(
      Map<String, Map<String, String>> words) async {
    if (words.isEmpty) return;
    final total = words.length;
    final progress = ValueNotifier<int>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    var dialogOpen = false;

    if (mounted) {
      dialogOpen = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _glassDialog(
          EswDialogShell(
            title: '正在从云端恢复词库',
            subtitle: '检测到本机词库为空，云端有 $total 个词，正在一次性恢复。',
            icon: Icons.cloud_download_rounded,
            body: ValueListenableBuilder<int>(
              valueListenable: progress,
              builder: (c, v, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: total == 0 ? null : (v / total).clamp(0.0, 1.0),
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: kGap8),
                  Text('$v / $total',
                      style: const TextStyle(fontSize: GlassTheme.fSmall)),
                ],
              ),
            ),
            actions: null,
          ),
        ),
      );
    }

    var applied = 0;
    var index = 0;
    for (final e in words.entries) {
      final cat = e.value['category'] ?? '';
      final orig = e.value['original_case'] ?? e.key;
      if (cat.isNotEmpty) {
        _applyCategoryChange(orig, cat);
        applied++;
      }
      index++;
      if (index % 500 == 0) {
        progress.value = index;
        await Future<void>.delayed(Duration.zero);
      }
    }
    progress.value = total;

    if (dialogOpen && navigator.canPop()) navigator.pop();
    progress.dispose();

    if (!mounted) return;
    final cm = <String, String>{};
    for (final w in _extendWords) {
      cm[w.toLowerCase()] = '拓展词';
    }
    for (final w in _manualChaoGangWords) {
      cm[w.toLowerCase()] = '超标词';
    }
    for (final w in _manualExtraWords) {
      cm[w.toLowerCase()] = '专有词';
    }
    _classificationMemory
      ..clear()
      ..addAll(cm);
    _saveConfig();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text('已从云端恢复 $applied 个词（拓展 ${_extendWords.length} / '
            '超标 ${_manualChaoGangWords.length} / 专有 ${_manualExtraWords.length}）'),
      ),
    );
    _maybePromptCorpusImport();
  }

  void _applyCategoryChange(String word, String category) {
    final lower = word.toLowerCase();
    _extendWords.removeWhere((e) => e.toLowerCase() == lower);
    _extendWordsLower.remove(lower);
    _manualChaoGangWords.removeWhere((e) => e.toLowerCase() == lower);
    _manualExtraWords.removeWhere((e) => e.toLowerCase() == lower);
    switch (category) {
      case '拓展词':
        if (!_extendWordsLower.contains(lower)) {
          _extendWords.add(word);
          _extendWordsLower.add(lower);
        }
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
      builder: (ctx) => _glassDialog(
        EswDialogShell(
          title: '删除确认',
          subtitle: '本次操作将删除 $delCount 个单词（词库当前共 $total 个）。\n\n$backupMsg\n\n确认要继续执行该删除操作吗？',
          icon: Icons.warning_amber_rounded,
          body: const SizedBox.shrink(),
          actions: EswDialogActions(
            children: [
              EswDialogTextAction(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
              EswDialogPrimaryAction(label: '确认删除', danger: true, onPressed: () => Navigator.pop(ctx, true)),
            ],
          ),
        )
      ),
    );
    return res ?? false;
  }

  /// 返回每个单词的用户决策列表（null 表示用户取消整个操作）。
  /// 每条决策: {word, action: 'accept'|'reject'|'upload_local', category}
  ///
  /// 第三轮清单「弹窗专项」第 16 项：只重构视觉与布局——
  /// 440 宽加厚玻璃（白 .72 + blur32 + 圆角 16，由 _glassDialog 统一提供）、
  /// 38 渐变图标块头部、词卡 + 淡彩状态标签、三个操作按钮只在词卡内出现一次、
  /// 底部「已处理 x / N」+「全部接收」+「完成」、全部处理完自动关闭 + Toast 汇总。
  /// 三个操作（接收更新 / 拒绝更新 / 上传本地）与逐词确认流程保持原样。
  Future<List<Map<String, String>>?> _showSyncConflictDialog(
    List<dynamic> changes,
  ) async {
    final decisions = <String, String>{};
    // 默认不预选任何词：用户点哪个按钮就立即执行哪个（接受云端/拒绝云端）
    final processed = <String>{};
    final scrollController = ScrollController();
    final cardKeys = <int, GlobalKey>{
      for (var i = 0; i < changes.length; i++) i: GlobalKey(),
    };
    final messenger = ScaffoldMessenger.of(context);
    // 第 16 项规格：宽 440（比标准 400 稍宽以容纳词卡）；窗口过窄时按可用宽度收紧
    // 面板宽度：内容自适应（顶部说明 + 词卡操作按钮组的所需宽度），
    // 统一夹在全站常规档上下限内，不再按窗口宽度在 320~440 之间浮动。
    final panelWidth = EswDialog.panelWidth(context, minContent: 400);
    var closing = false;

    try {
      return await showDialog<List<Map<String, String>>?>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (builderCtx, setDialogState) {
              final categories = ['拓展词', '超标词', '专有词'];

              Map<String, dynamic> changeAt(int i) =>
                  changes[i] as Map<String, dynamic>;

              // 只汇总用户已逐词处理的决策：未处理的词不纳入结果
              // （保持原「取消」按钮语义：已单独处理的决策照旧回传）
              List<Map<String, String>> collected() {
                final result = <Map<String, String>>[];
                for (final ch in changes) {
                  final c = ch as Map<String, dynamic>;
                  final w = c['word'] as String;
                  final d = decisions[w];
                  if (d == null) continue;
                  result.add({
                    'word': w,
                    'action': d,
                    'category': d == 'accept'
                        ? (c['new_category'] as String? ?? '')
                        : '',
                  });
                }
                return result;
              }

              // 关闭前的 Toast 汇总：接收 x · 拒绝 y · 上传 z
              void toastSummary(List<Map<String, String>> result) {
                var accept = 0;
                var reject = 0;
                var upload = 0;
                for (final d in result) {
                  switch (d['action']) {
                    case 'accept':
                      accept++;
                    case 'reject':
                      reject++;
                    case 'upload_local':
                      upload++;
                  }
                }
                messenger.showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 4),
                    content: Text(
                      '词库更新完成：接收 $accept · 拒绝 $reject · 上传 $upload',
                    ),
                  ),
                );
              }

              // 关闭弹窗并回传已处理决策（Toast 默认开启；右上 ✕ 静默退出）
              void finish({bool toast = true}) {
                if (closing) return;
                closing = true;
                final result = collected();
                Navigator.pop(ctx, result.isEmpty ? null : result);
                if (toast && result.isNotEmpty) toastSummary(result);
              }

              // 全部处理完毕：稍作停留让最后一张词卡的状态标签可见，再自动关闭 + Toast
              void autoFinish() {
                if (closing) return;
                closing = true;
                final result = collected();
                Future.delayed(const Duration(milliseconds: 260), () {
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx, result.isEmpty ? null : result);
                  if (result.isNotEmpty) toastSummary(result);
                });
              }

              // 逐词决策：打状态标签 + 按钮组置灰，并自动聚焦下一条未处理词卡
              void apply(int index, String action) {
                final word = changeAt(index)['word'] as String;
                setDialogState(() {
                  decisions[word] = action;
                  processed.add(word);
                });
                if (processed.length >= changes.length) {
                  autoFinish();
                  return;
                }
                var next = -1;
                for (var step = 1; step <= changes.length; step++) {
                  final i = (index + step) % changes.length;
                  if (!processed.contains(changeAt(i)['word'] as String)) {
                    next = i;
                    break;
                  }
                }
                if (next < 0) return;
                final nextIndex = next;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  final target = cardKeys[nextIndex]?.currentContext;
                  if (target == null) return;
                  Scrollable.ensureVisible(
                    target,
                    alignment: 0.15,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                  );
                });
              }

              // 一条云端变更 = 一张词卡：白 .5 玻璃小卡 + 淡彩状态标签 + 唯一一组操作按钮
              Widget buildCard(int i) {
                final ch = changeAt(i);
                final word = ch['word'] as String;
                final oldCat = (ch['old_category'] as String?) ?? '无';
                final newCat = (ch['new_category'] as String?) ?? '';
                final isRemoteDeleted =
                    (ch['reason'] as String?) == 'remote_deleted';
                final decision = decisions[word];
                final isDone = processed.contains(word);
                final currentCat = categories.contains(newCat)
                    ? newCat
                    : categories.first;
                return Container(
                  key: cardKeys[i],
                  // padding 12×14（第 16 项规格）
                  padding: const EdgeInsets.symmetric(
                    horizontal: kGap12,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    // 白 .5 玻璃小卡（规范色板：只用淡彩，不用饱和色块）
                    color: const Color(0x80FFFFFF),
                    borderRadius: BorderRadius.circular(GlassTheme.rMd),
                    border: Border.all(color: GlassTheme.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              word,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: GlassTheme.ink,
                                height: 1.2,
                              ),
                            ),
                          ),
                          const SizedBox(width: kGap8),
                          _SyncStatusTag(decision: decision),
                        ],
                      ),
                      const SizedBox(height: kGap6),
                      Text(
                        isRemoteDeleted
                            ? '云端已删除'
                            : '分类变更：$oldCat → $newCat',
                        style: const TextStyle(
                          fontSize: GlassTheme.fSmall,
                          color: GlassTheme.ink2,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: kGap12),
                      // 三个操作按钮只在这一处出现；处理完整组变淡（opacity .4）且不可再点
                      Opacity(
                        opacity: isDone ? 0.4 : 1,
                        child: IgnorePointer(
                          ignoring: isDone,
                          child: Row(
                            children: [
                              Expanded(
                                child: Tooltip(
                                  message: '应用这条云端更新',
                                  child: _SyncCardAction(
                                    label: '接收更新',
                                    icon: Icons.check,
                                    primary: true,
                                    onPressed: () => apply(i, 'accept'),
                                  ),
                                ),
                              ),
                              const SizedBox(width: kGap8),
                              Expanded(
                                child: Tooltip(
                                  message: '拒绝这条云端更新，保留本地',
                                  child: _SyncCardAction(
                                    label: '拒绝更新',
                                    onPressed: () => apply(i, 'reject'),
                                  ),
                                ),
                              ),
                              const SizedBox(width: kGap8),
                              Expanded(
                                child: Tooltip(
                                  message: '以本地为准，将本地删除同步到云端',
                                  child: _SyncCardAction(
                                    label: '上传本地',
                                    icon: Icons.upload_outlined,
                                    onPressed: () => apply(i, 'upload_local'),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (isDone && decision == 'accept' && !isRemoteDeleted) ...[
                        const SizedBox(height: kGap10),
                        Row(
                          children: [
                            const Text(
                              '分类: ',
                              style: TextStyle(
                                fontSize: GlassTheme.fMicro,
                                color: GlassTheme.ink3,
                                height: 1,
                              ),
                            ),
                            const SizedBox(width: kGap8),
                            DropdownButton<String>(
                              value: currentCat,
                              isDense: true,
                              underline: const SizedBox(),
                              style: const TextStyle(
                                fontSize: GlassTheme.fBody,
                                color: GlassTheme.ink,
                              ),
                              items: categories
                                  .map(
                                    (c) => DropdownMenuItem(
                                      value: c,
                                      child: Text(c),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (selected) {
                                if (selected == null) return;
                                setDialogState(() {
                                  ch['new_category'] = selected;
                                });
                              },
                            ),
                          ],
                        ),
                      ],
                      if (isDone && decision == 'accept' && isRemoteDeleted) ...[
                        const SizedBox(height: kGap10),
                        const Text(
                          '确认后本地删除',
                          style: TextStyle(
                            fontSize: GlassTheme.fMicro,
                            color: Color(0xFFD93A3F),
                            height: 1,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }

              return _glassDialog(
                EswDialogWidth(
                  width: panelWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── 头部：38×38 渐变图标块 + 标题/副标题 + ✕ ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          kGap16,
                          kGap16,
                          kGap12,
                          kGap12,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: GlassTheme.accent,
                                borderRadius: BorderRadius.circular(
                                  GlassTheme.rMd,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x1418181B),
                                    blurRadius: 6,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.sync,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: kGap12),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '云端词库有更新',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: GlassTheme.ink,
                                      height: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: kGap4),
                                  Text(
                                    '逐词确认 · 共 ${changes.length} 条待处理',
                                    style: const TextStyle(
                                      fontSize: GlassTheme.fSmall,
                                      color: GlassTheme.ink2,
                                      height: 1.2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: kGap8),
                            Tooltip(
                              message: '取消本次操作，不做任何改动',
                              child: _SyncDialogCloseButton(
                                onPressed: () => finish(toast: false),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(
                        height: 1,
                        thickness: 1,
                        color: GlassTheme.line,
                      ),
                      // ── 内容区：词卡纵向排列，间距 8，可滚动 ──
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: ListView.separated(
                            controller: scrollController,
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(
                              kGap16,
                              kGap12,
                              kGap16,
                              kGap12,
                            ),
                            itemCount: changes.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: kGap8),
                            itemBuilder: (_, i) => buildCard(i),
                          ),
                        ),
                      ),
                      const Divider(
                        height: 1,
                        thickness: 1,
                        color: GlassTheme.line,
                      ),
                      // ── 底部：已处理计数（左） + 全部接收 / 完成（右） ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          kGap16,
                          kGap12,
                          kGap16,
                          kGap12,
                        ),
                        child: Row(
                          children: [
                            Text(
                              '已处理 ${processed.length} / ${changes.length}',
                              style: const TextStyle(
                                fontSize: GlassTheme.fMicro,
                                color: GlassTheme.ink3,
                                height: 1,
                              ),
                            ),
                            const Spacer(),
                            // 批量处理剩余：全部按「接收云端更新」处理
                            Tooltip(
                              message: '全部应用云端更新，不删除本地词',
                              child: EswDialogGhostAction(
                                label: '全部接收',
                                onPressed: () {
                                  setDialogState(() {
                                    for (final ch in changes) {
                                      final c = ch as Map<String, dynamic>;
                                      final w = c['word'] as String;
                                      decisions[w] = 'accept';
                                      processed.add(w);
                                    }
                                  });
                                  autoFinish();
                                },
                              ),
                            ),
                            const SizedBox(width: kGap8),
                            EswDialogPrimaryAction(
                              label: '完成',
                              onPressed: () => finish(),
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
    } finally {
      scrollController.dispose();
    }
  }

  void _checkUpdate() async {
    const currentVersion = '1.6.3';
    try {
      final response = await http
          .get(
            Uri.parse(
              'https://api.github.com/repos/beenhow/ESW/releases/latest',
            ),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 8));
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
      final latestVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;
      if (_compareVersions(latestVersion, currentVersion) > 0) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => _glassDialog(
              EswDialogWidth(
                minContent: 360,
                child: AlertDialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                insetPadding: EdgeInsets.zero,
                titlePadding: const EdgeInsets.fromLTRB(kGap16, kGap16, kGap16, 0),
                contentPadding: const EdgeInsets.fromLTRB(kGap16, kGap10, kGap16, kGap12),
                actionsPadding: const EdgeInsets.fromLTRB(kGap16, kGap10, kGap16, kGap12),
                title: const Text('发现新版本'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('当前版本：$currentVersion\n最新版本：$latestVersion\n\n请选择下载入口：'),
                  const SizedBox(height: kGap12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      GlassPressable(radius: GlassTheme.rMd, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: InkWell(
                        onTap: () async {
                          Navigator.pop(ctx);
                          try {
                            await launchUrl(
                              Uri.parse(
                                'https://github.com/beenhow/ESW/releases',
                              ),
                              mode: LaunchMode.externalApplication,
                            );
                          } catch (e) {
                            // 打开外部浏览器失败时静默处理
                          }
                        },
                        child: const Column(
                          children: [
                            Icon(Icons.code, size: 36, color: GlassTheme.ink2),
                            SizedBox(height: kGap4),
                            Text('GitHub', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      )),
                      GlassPressable(radius: GlassTheme.rMd, hoverColor: GlassTheme.accentSoft, pressColor: const Color(0x294462F2), enabled: true, child: InkWell(
                        onTap: () async {
                          Navigator.pop(ctx);
                          try {
                            await launchUrl(
                              Uri.parse('https://wwbcj.lanzouu.com/b02qeywze'),
                              mode: LaunchMode.externalApplication,
                            );
                          } catch (e) {
                            // 打开外部浏览器失败时静默处理
                          }
                        },
                        child: const Column(
                          children: [
                            Icon(
                              Icons.cloud_download,
                              size: 36,
                              color: GlassTheme.ink2,
                            ),
                            SizedBox(height: kGap4),
                            Text(
                              '蓝奏云\n(密码 52pj)',
                              style: TextStyle(fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )),
                    ],
                  ),
                ],
              ),
              actions: [
                  EswDialogTextAction(label: '稍后', onPressed: () => Navigator.pop(ctx)),
              ],
              ),
              ),
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

  /// 是否来自内置真题包（随安装包发布、首启释放到用户目录）。
  /// 内置文件与用户自行导入的文件互不覆盖，左栏分区展示。
  final bool isBuiltin;
  CorpusFile({
    required this.name,
    required this.path,
    this.isSelected = true,
    this.isBuiltin = false,
  });
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
/// 文件纯文本缓存条目（绑定文件修改时间与大小做失效校验）
class _CachedFileText {
  final String text;
  final int modified;
  final int size;

  /// 小写文本懒缓存：查询路径对同一文件反复 toLowerCase 是主要 CPU 开销，
  /// 转换结果按文件缓存后，重复查词不再重建小写字符串。
  String? _lowerText;
  String get textLower => _lowerText ??= text.toLowerCase();

  _CachedFileText({
    required this.text,
    required this.modified,
    required this.size,
  });
}

class _HighlightController extends TextEditingController {
  String _keyword;

  /// 当前高亮关键词（窗口缩放后按此重新定位）
  String get keyword => _keyword;

  /// 同一文本内切换关键词时原地更新，避免替换 controller 导致滚动位置被重置
  void setKeyword(String kw) {
    if (_keyword == kw) return;
    _keyword = kw;
    _cachedRegex = null;
    _cachedKeyword = null;
    notifyListeners();
  }

  /// 用户修改处区间（"修改"保存后追加），渲染时以琥珀色高亮标记
  final List<({int start, int end})> editSpans;
  _HighlightController(
    String text,
    this._keyword, [
    List<({int start, int end})>? editSpans,
  ]) : editSpans = editSpans ?? const [],
       super(text: text);

  /// 懒缓存正则实例：关键词不变时避免每次重建/编译 RegExp
  RegExp? _cachedRegex;
  String? _cachedKeyword;
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    final baseStyle = style ?? const TextStyle();
    // 关键词匹配区间（keyword 为空时跳过，避免产生零宽匹配）
    final kwRanges = <({int start, int end})>[];
    if (_keyword.isNotEmpty) {
      var regex = _cachedRegex;
      if (regex == null || _cachedKeyword != _keyword) {
        // 与共用分词同口径：撇号等价（couldn’t 也能命中 couldn't）、按完整词形匹配
        regex = keywordMatchRegExp(_keyword);
        _cachedRegex = regex;
        _cachedKeyword = _keyword;
      }
      for (final m in regex.allMatches(text)) {
        if (m.end > m.start) {
          kwRanges.add((start: m.start, end: m.end));
        }
      }
    }
    // 切割点统一分段：编辑区间优先高亮（琥珀），其余命中关键词则黄色高亮
    final cutSet = <int>{0, text.length};
    for (final s in editSpans) {
      cutSet.add(s.start);
      cutSet.add(s.end);
    }
    for (final s in kwRanges) {
      cutSet.add(s.start);
      cutSet.add(s.end);
    }
    final cuts = cutSet.toList()..sort();
    final spans = <TextSpan>[];
    for (var i = 0; i < cuts.length - 1; i++) {
      final a = cuts[i], b = cuts[i + 1];
      if (a >= b) continue;
      final seg = text.substring(a, b);
      final inEdit = editSpans.any((s) => a >= s.start && b <= s.end);
      if (inEdit) {
        spans.add(
          TextSpan(
            text: seg,
            style: baseStyle.copyWith(
              fontWeight: FontWeight.bold,
              color: const Color(0xFFB71C1C),
              backgroundColor: const Color(0xFFFFE082),
            ),
          ),
        );
        continue;
      }
      final inKw = kwRanges.any((s) => a >= s.start && b <= s.end);
      spans.add(
        TextSpan(
          text: seg,
          style: inKw
              ? baseStyle.copyWith(
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF0D47A1),
                  backgroundColor: const Color(0x66FFEB3B),
                  decoration: TextDecoration.underline,
                )
              : baseStyle,
        ),
      );
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

  /// 玻璃弹窗包装：与主界面一致的玻璃面板风格 + 遮罩 blur5
  Widget _glassDialog(Widget dialog) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // 第三关 ③：insetPadding 归零，让模糊遮罩铺满整个窗口
      insetPadding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Stack(
          children: [
            // 全窗口背景模糊 blur5；压暗统一由 dialogTheme.barrierColor
            // rgba(24,24,27,.28) 提供，避免与内层遮罩叠加造成二次压暗
            Positioned.fill(
              child: ClipRect(
                child: FrostFilter(
                  enabled: false,
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28.0,
                  vertical: 32.0,
                ),
                child: Container(
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                    boxShadow: [
                      BoxShadow(
                        color: Color(
                          0x4018181B,
                        ), // rgba(24,24,27,0.25) 0 24px 60px
                        blurRadius: 60,
                        offset: Offset(0, 24),
                      ),
                    ],
                  ),
                  child: GlassPanel(
                    radius: 16, // 第三关 ③：弹窗圆角 16（规范 §2.9.1）
                    sigma: 12, // 任务④：32 → 12，保留磨砂观感、避开高 sigma 的成倍采样
                    color: GlassTheme.panelSolid,
                    borderColor: GlassTheme.line,
                    shrinkWrap: true, // 第三关 ③：弹窗玻璃收紧到内容宽度，不再铺满整窗口
                    child: dialog,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onChipTap(String s) {
    debugPrint('[ClassifyDialog] chip tapped as 拓展词: $s');
    widget.selectedBases.clear();
    widget.selectedBases.add(s);
    Navigator.pop(context, '拓展词');
  }

  void _submitTypedWord(String trimmed, BuildContext ctx) {
    if (!widget.standardWordsLowerKeySet.contains(trimmed)) {
      ScaffoldMessenger.of(
        ctx,
      ).showSnackBar(const SnackBar(content: Text('请输入有效的课标词')));
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
        child: _glassDialog(
          // 全站统一玻璃弹窗骨架：24×24 渐变图标 + 标题(可拖动) + 右上角 ✕ + 统一按钮区
          EswDialogShell(
            minContent: 360,
            icon: Icons.filter_alt_outlined,
            titleWidget: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: Text(
                '将 "${widget.word}" 筛选归类',
                style: EswDialog.titleStyle,
              ),
            ),
            trailing: Tooltip(
              message: '关闭',
              child: _SyncDialogCloseButton(
                onPressed: () => Navigator.pop(context),
              ),
            ),
            scrollable: false,
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 32,
                  child: widget.suggestions.isNotEmpty
                      ? Row(
                          children: List.generate(widget.suggestions.length, (
                            i,
                          ) {
                            final s = widget.suggestions[i];
                            final isSelected = _chipSelections.contains(s);
                            return Flexible(
                              child: Padding(
                                padding: const EdgeInsets.only(right: kGap4),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: GestureDetector(
                                    onTap: () => _onChipTap(s),
                                    child: GlassPressable(
                                      radius: 16,
                                      hoverColor: GlassTheme.accentSoft,
                                      pressColor: const Color(0x294462F2),
                                      enabled: true,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? GlassTheme.accentSoft
                                              : const Color(0x0D18181B),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          border: Border.all(
                                            color: isSelected
                                                ? GlassTheme.accent
                                                : const Color(0x40C4C6CE),
                                            width: isSelected ? 2.0 : 1.0,
                                          ),
                                        ),
                                        child: Text(
                                          s,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: isSelected
                                                ? GlassTheme.accentInk
                                                : GlassTheme.ink,
                                            fontWeight: isSelected
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                          ),
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
                const SizedBox(height: kGap8),
                Autocomplete<String>(
                  optionsBuilder: (v) {
                    if (v.text.isEmpty) return const Iterable.empty();
                    final lower = v.text.toLowerCase();
                    final bucket = widget.wordsByFirstChar[lower[0]];
                    if (bucket == null) return const Iterable.empty();
                    final matches = bucket
                        .where((k) => k.startsWith(lower))
                        .toList();
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
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                      ),
                    );
                  },
                  onSelected: _submitAutoComplete,
                ),
              ],
            ),
            actions: EswDialogActions(
              // 第一点：底部两个归类按钮整体水平居中；
              // 鼠标悬停到哪个按钮，哪个按钮即变蓝（hoverBlue 纯蓝态）
              alignment: MainAxisAlignment.center,
              children: [
                EswDialogGhostAction(
                  label: '专有词',
                  hoverBlue: true,
                  onPressed: () => _submitButton('专有词'),
                ),
                EswDialogPrimaryAction(
                  label: '超标词',
                  hoverBlue: true,
                  onPressed: () => _submitButton('超标词'),
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

  /// 词库归属（互斥口径）：课标词 / 拓展词 / 超标词 / 专有词 / 未筛选。
  /// 四个词库都不收录的词归「未筛选」，其中在真题语料出现过的（isInCorpus）
  /// 同时出现在真题词列与未筛选列，由用户在未筛选列手动归类。
  final String category;
  final int frequency;
  final bool isInCorpus; // 是否出现在真题语料中（真题词列的判定依据）
  final int totalFreq; // 真题词频：该词在选中真题语料中的出现次数
  const _ImportedWord({
    required this.word,
    required this.category,
    required this.frequency,
    required this.isInCorpus,
    this.totalFreq = 0,
  });
}

// ==================== 导出表格数据 ====================
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
        content:
            '点击「导出结果」按钮，将当前分析结果导出为 Word 文档（.docx），不同词类以不同颜色高亮标注并附带分类统计汇总表。',
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
      backgroundColor: GlassTheme.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          '使用说明',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: GlowBackground(
        // 独立页宽度自适应：内容列统一上限 EswDialog.wPageMax（宽窗口下居中、
        // 不被拉伸成超长行），窄窗口下自动收窄铺满，不再随窗口无边铺开。
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: EswDialog.wPageMax),
            child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: kGap12),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: kGap4),
        itemBuilder: (_, i) {
          final item = items[i];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: kGap16, vertical: kGap6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
            color: GlassTheme.panel,
            child: Padding(
              padding: const EdgeInsets.all(kGap16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(item.icon, size: 22, color: GlassTheme.accent),
                  const SizedBox(width: kGap12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: TextStyle(
                            fontSize: EswDialog.fTitle,
                            fontWeight: FontWeight.w600,
                            color: GlassTheme.ink,
                          ),
                        ),
                        const SizedBox(height: kGap4),
                        Text(
                          item.content,
                          style: TextStyle(
                            fontSize: EswDialog.fOption,
                            color: GlassTheme.ink2,
                            height: 1.5,
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
        ),
          ),
        ),
      ),
    );
  }
}

// ==================== 检测扫描 worker isolate（常驻后台线程） ====================
/// 跨 isolate 数据类型：仅使用 Dart 基础类型与 record，保证可发送。
typedef _ScanTarget = ({String path, String name});
typedef _ScanRow = ({
  String before,
  String keyword,
  String after,
  String source,
  String filePath,
  int matchOffset,
  String sentence,
});
typedef _ScanOut = ({
  List<_ScanRow> rows,
  Map<int, int> yearFreq,
  int totalFreq,
});

/// 常驻扫描 worker 主循环：持有语料文本与小写缓存，
/// 重复查询零拷贝零重转，彻底消除每次 spawn isolate 的开销。
void _scanWorkerMain(SendPort sp) {
  final texts = <String, String>{};
  final textsLower = <String, String>{};
  final versions = <String, int>{};
  final port = ReceivePort();
  sp.send(port.sendPort);
  port.listen((msg) {
    final m = msg as Map;
    switch (m['type']) {
      case 'updateTexts':
        // 增量同步文件文本：仅新增/变化的文件
        for (final e in m['entries'] as List) {
          final em = e as Map;
          final path = em['path'] as String;
          final text = em['text'] as String;
          texts[path] = text;
          textsLower[path] = text.toLowerCase();
          versions[path] = em['version'] as int;
        }
        break;
      case 'scan':
        final reqId = m['reqId'] as int;
        final keyword = m['keyword'] as String;
        final targets = <_ScanTarget>[];
        for (final t in m['targets'] as List) {
          final tm = t as Map;
          targets.add(
              (path: tm['path'] as String, name: tm['name'] as String));
        }
        final includeYears = m['includeYears'] as bool;
        try {
          final out = _scanCorpusWorker(
              keyword, targets, includeYears, texts, textsLower);
          sp.send({
            'type': 'scanResult',
            'reqId': reqId,
            'rows': [
              for (final r in out.rows)
                {
                  'before': r.before,
                  'keyword': r.keyword,
                  'after': r.after,
                  'source': r.source,
                  'filePath': r.filePath,
                  'matchOffset': r.matchOffset,
                  'sentence': r.sentence,
                },
            ],
            'yearFreq': out.yearFreq,
            'totalFreq': out.totalFreq,
          });
        } catch (e, st) {
          sp.send({
            'type': 'scanError',
            'reqId': reqId,
            'error': '$e\n$st',
          });
        }
        break;
    }
  });
}

/// 在 worker 内执行全文扫描：正则匹配 + 上下文提取 + 句子提取。
/// 文本与小写缓存来自 worker 常驻内存，不重复拷贝、不重复转换。
_ScanOut _scanCorpusWorker(
    String keyword,
    List<_ScanTarget> targets,
    bool includeYears,
    Map<String, String> texts,
    Map<String, String> textsLower) {
  final rows = <_ScanRow>[];
  final yearFreq = <int, int>{};
  var totalFreq = 0;
  final pattern = RegExp('\\b${RegExp.escape(keyword)}\\b');
  for (final t in targets) {
    final text = texts[t.path];
    if (text == null || text.isEmpty) continue;
    final lowerText = textsLower[t.path] ?? text.toLowerCase();
    final matches = pattern.allMatches(lowerText);
    for (final m in matches) {
      if (includeYears) {
        totalFreq++;
        final yearMatch = _MainWindowState._yearPrefixRegex.firstMatch(t.name);
        if (yearMatch != null) {
          final y = int.parse(yearMatch.group(1)!);
          yearFreq[y] = (yearFreq[y] ?? 0) + 1;
        }
      }
      // 上下文：在关键词两侧各取约等量字符，并修正到词边界
      int beforeStart =
          (m.start - _MainWindowState._maxContextHalf).clamp(0, text.length);
      int afterEnd =
          (m.end + _MainWindowState._maxContextHalf).clamp(0, text.length);
      // 向外扩展到完整词边界
      while (beforeStart > 0 &&
          !_MainWindowState._whitespaceRegex.hasMatch(text[beforeStart - 1])) {
        beforeStart--;
      }
      while (afterEnd < text.length &&
          !_MainWindowState._whitespaceRegex.hasMatch(text[afterEnd])) {
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
      rows.add((
        before: before,
        keyword: text.substring(m.start, m.end),
        after: after,
        source: t.name,
        filePath: t.path,
        matchOffset: m.start,
        sentence: _extractSentenceIsolate(text, m.start, m.end),
      ));
    }
  }
  return (rows: rows, yearFreq: yearFreq, totalFreq: totalFreq);
}

/// 提取匹配位置所在的完整句子（isolate 版，逻辑与 _extractSentence 一致）
String _extractSentenceIsolate(String text, int matchStart, int matchEnd) {
  int sentenceStart = matchStart;
  while (sentenceStart > 0) {
    if (_MainWindowState._sentenceEndRegex.hasMatch(text[sentenceStart - 1])) {
      break;
    }
    sentenceStart--;
  }
  int sentenceEnd = matchEnd;
  while (sentenceEnd < text.length) {
    if (_MainWindowState._sentenceEndRegex.hasMatch(text[sentenceEnd])) {
      sentenceEnd++; // 包含结尾标点
      break;
    }
    sentenceEnd++;
  }
  return text.substring(sentenceStart, sentenceEnd).trim();
}

// ==================== 逐词确认弹窗（第三轮清单第 16 项）局部组件 ====================
// 只服务于云端词库「逐词确认」弹窗的视觉重构；全部走设计令牌，不用饱和色块。

/// 词卡右上角的状态标签：待确认=灰 / 已接收=淡蓝底蓝字 / 已拒绝=灰字带删除线 /
/// 已上传=淡紫底紫字（规范：只做淡彩标签，禁止饱和色块）。
class _SyncStatusTag extends StatelessWidget {
  const _SyncStatusTag({this.decision});

  /// null=待确认；accept=已接收；reject=已拒绝；upload_local=已上传
  final String? decision;

  @override
  Widget build(BuildContext context) {
    var label = '待确认';
    var fg = GlassTheme.ink2;
    var bg = const Color(0x0D18181B);
    var strike = false;
    switch (decision) {
      case 'accept':
        label = '已接收';
        fg = GlassTheme.accentInk;
        bg = GlassTheme.accentSoft;
      case 'reject':
        label = '已拒绝';
        fg = GlassTheme.ink3;
        strike = true;
      case 'upload_local':
        label = '已上传';
        fg = GlassTheme.accentInk;
        bg = GlassTheme.accentSoft;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kGap8, vertical: kGap4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fg,
          height: 1,
          decoration: strike
              ? TextDecoration.lineThrough
              : TextDecoration.none,
          decorationColor: fg,
        ),
      ),
    );
  }
}

/// 词卡内的操作按钮：等宽、高 32、圆角 8。
/// primary = 淡蓝底 --accent-soft + 蓝字 + 蓝边（hover 加深）；ghost = 玻璃幽灵（灰字灰边）。
class _SyncCardAction extends StatefulWidget {
  const _SyncCardAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool primary;

  @override
  State<_SyncCardAction> createState() => _SyncCardActionState();
}

class _SyncCardActionState extends State<_SyncCardAction> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final hovered = _hovered;
    final Color bg;
    final Color border;
    final Color fg;
    if (widget.primary) {
      bg = _pressed
          ? const Color(0x294462F2)
          : (hovered ? const Color(0x244462F2) : GlassTheme.accentSoft);
      border = GlassTheme.accent;
      fg = GlassTheme.accentInk;
    } else {
      bg = _pressed
          ? const Color(0x294462F2)
          : (hovered ? GlassTheme.accentSoft : const Color(0x8CFFFFFF));
      border = hovered ? GlassTheme.accentLine : GlassTheme.line;
      fg = hovered ? GlassTheme.accentInk : GlassTheme.ink2;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(GlassTheme.rSm),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 14, color: fg),
                  const SizedBox(width: kGap6),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: GlassTheme.fSmall,
                    fontWeight: FontWeight.w600,
                    color: fg,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹窗右上角关闭按钮（✕）。
class _SyncDialogCloseButton extends StatefulWidget {
  const _SyncDialogCloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_SyncDialogCloseButton> createState() => _SyncDialogCloseButtonState();
}

class _SyncDialogCloseButtonState extends State<_SyncDialogCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered ? GlassTheme.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(GlassTheme.rSm),
          ),
          child: Icon(
            Icons.close,
            size: 16,
            color: _hovered ? GlassTheme.accentInk : GlassTheme.ink2,
          ),
        ),
      ),
    );
  }
}

/// 导出任务等待提示控制器：统一管理进度弹窗的阶段文案、已用时计时与关闭时机。
/// 由 [State] 侧的 `_beginExportProgress` 创建，导出结束（成功/失败/中途返回）
/// 必须在 finally 中调用 [close]，否则弹窗会残留遮挡界面。
class _ExportProgress {
  _ExportProgress(this.stage, this.elapsed);

  final ValueNotifier<String> stage;
  final ValueNotifier<double> elapsed;
  Timer? _ticker;
  BuildContext? _dialogCtx;
  bool _closed = false;

  bool get isClosed => _closed;

  void attachDialog(BuildContext ctx) => _dialogCtx = ctx;

  /// 每 0.5 秒累加已用时；主线程被计算占满时计时会被推迟，恢复后自动追上。
  void startTicking() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      elapsed.value = elapsed.value + 0.5;
    });
  }

  /// 切换阶段文案并让出一帧，避免主线程被计算占满时文案迟迟不刷新。
  Future<void> setStage(String text) async {
    if (_closed || stage.value == text) return;
    stage.value = text;
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _ticker?.cancel();
    _ticker = null;
    final ctx = _dialogCtx;
    _dialogCtx = null;
    if (ctx != null) {
      try {
        Navigator.of(ctx).pop();
      } catch (_) {
        // 弹窗已被移除时忽略，避免收尾阶段抛出的异常掩盖真实导出结果
      }
      // 弹窗关闭后整窗重绘，防止顶栏残留对话框投影形成条带
      WinWindowRepaint.burst();
    }
  }
}

/// 导出进度弹窗内容：靛蓝进度环 + 阶段文案 + 已用时。
/// 视觉与全站弹窗一致（玻璃面板、统一字体层级与强调色），仅作为 _glassDialog 的 body。
class _ExportProgressBody extends StatelessWidget {
  const _ExportProgressBody({required this.progress, this.hint});

  final _ExportProgress progress;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 2.6,
              color: GlassTheme.accent,
              backgroundColor: GlassTheme.accentSoft,
            ),
          ),
          const SizedBox(height: kGap16),
          ValueListenableBuilder<String>(
            valueListenable: progress.stage,
            builder: (_, stage, __) => Text(
              stage,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: GlassTheme.fBody,
                height: 1.55,
                color: GlassTheme.accentInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: kGap8),
          ValueListenableBuilder<double>(
            valueListenable: progress.elapsed,
            builder: (_, sec, __) => Text(
              '已用时 ${sec.toStringAsFixed(0)} 秒，${hint ?? '长文档请耐心等待'}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: GlassTheme.fBody,
                height: 1.55,
                color: GlassTheme.ink2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
