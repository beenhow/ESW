/// ESW 双端共用：导出文档「七类词」配色与字重规范。
///
/// 规范来源（用户给出的导出样式图）：
///   初中课标词 黑色加粗 / 必修课标词 深蓝色加粗 / 选修课标词 浅蓝色 /
///   拓展词 深绿色加粗 / 超标词 红色 / 专有词 紫色 / 未筛选 土红色。
/// 导出汇总（每类条目后跟该类统计词数）与导出文档原文标注共用本表，
/// 避免汇总、原文标注、图例说明三处配色各自漂移。
library;

/// 导出分类键（与 [kExportWordStyles] 的键、汇总条目、原文标注共用）。
class ExportCategory {
  ExportCategory._();

  static const String standardJunior = '初中课标词';
  static const String standardCompulsory = '必修课标词';
  static const String standardElective = '选修课标词';
  static const String extend = '拓展词';
  static const String overLimit = '超标词';
  static const String proper = '专有词';
  static const String unfiltered = '未筛选';

  /// 规范七类（顺序即汇总 / 图例展示顺序）。
  static const List<String> all = <String>[
    standardJunior,
    standardCompulsory,
    standardElective,
    extend,
    overLimit,
    proper,
    unfiltered,
  ];
}

/// 单类词的导出样式：颜色 + 是否加粗 + 底纹色。
///
/// 底纹使用范围（用户口径）：底纹只用于 PDF 导出的原文标注；
/// Word（.docx/.doc）导出结果不加底纹，只规范字色与字重；
/// TXT 为纯文本，无法着色也无法加底纹，保持原样。
class ExportWordStyle {
  /// 颜色（6 位 RGB，无 # 前缀；与 OOXML / RTF 的写法保持一致）。
  final String colorHex;

  /// 是否加粗（规范：初中课标词、必修课标词、拓展词加粗）。
  final bool bold;

  /// 底纹色（6 位 RGB，无 #；规范色的极淡同色，保证彩色字仍清晰可读）。
  ///
  /// 仅 PDF 导出使用；Word 导出不得使用（见类注释）。
  final String? shadeHex;

  const ExportWordStyle({
    required this.colorHex,
    this.bold = false,
    this.shadeHex,
  });

  /// 带 # 前缀的十六进制写法（PDF / HTML 等使用）。
  String get dashedHex => '#$colorHex';

  /// 底纹色的带 # 写法；无底纹时为 null。
  String? get dashedShadeHex => shadeHex == null ? null : '#$shadeHex';
}

/// 规范样式表（导出样式图口径；Android 与 Windows 共用）。
///
/// 表中保留历史字重（初中 / 必修 / 拓展加粗）供 Android 端沿用；
/// Windows 端方案一通过 `colorBold: false` 关闭加粗，只靠颜色区分。
/// 未筛选词在 Windows 导出前会被前置拦截（必须先归类），其历史样式仅保留
/// 给 Android 与统计口径使用，不会出现在 Windows 导出文档中。
/// shadeHex 为各类规范色的极淡同色底纹，仅 PDF 导出原文标注使用。
const Map<String, ExportWordStyle> kExportWordStyles = {
  // 初中课标词：黑色加粗
  ExportCategory.standardJunior: ExportWordStyle(
    colorHex: '000000',
    bold: true,
    shadeHex: 'D9D9D9',
  ),
  // 必修课标词：深蓝色加粗
  ExportCategory.standardCompulsory: ExportWordStyle(
    colorHex: '0B3D91',
    bold: true,
    shadeHex: 'D6E0F5',
  ),
  // 选修课标词：浅蓝色（不加粗）
  ExportCategory.standardElective: ExportWordStyle(
    colorHex: '00B0F0',
    shadeHex: 'D6F0FC',
  ),
  // 拓展词：深绿色加粗
  ExportCategory.extend: ExportWordStyle(
    colorHex: '006400',
    bold: true,
    shadeHex: 'D6E9D7',
  ),
  // 超标词：红色（不加粗）
  ExportCategory.overLimit: ExportWordStyle(
    colorHex: 'FF0000',
    shadeHex: 'FFDBDB',
  ),
  // 专有词：紫色（不加粗）
  ExportCategory.proper: ExportWordStyle(
    colorHex: '800080',
    shadeHex: 'EBD9F0',
  ),
  // 未筛选：土红色（Windows 导出已拦截，不会落盘）
  ExportCategory.unfiltered: ExportWordStyle(
    colorHex: 'A0522D',
    shadeHex: 'F0E0D6',
  ),
};

/// 取某类词的规范样式；真题词 / 其他返回 null，表示不参与配色标注。
///
/// Windows 导出通过 `annotateUnfiltered: false` 跳过未筛选词：
/// 导出前已有前置拦截，双保险确保未筛选词绝不会被标记。
ExportWordStyle? exportWordStyleOf(String? category) =>
    category == null ? null : kExportWordStyles[category];

/// 取某类词的底纹色（无 # 前缀的 6 位 RGB）；无底纹权限/非规范类别时返回 null。
///
/// 仅供 PDF 导出原文标注使用；Word 导出禁止调用（Word 不加底纹）。
String? exportShadeHexOf(String? category) =>
    exportWordStyleOf(category)?.shadeHex;

/// 课标词课标级别（初中 / 必修 / 选修）→ 导出分类。
/// 级别未知时按「初中课标词」处理（沿用导出统计既有口径：查不到级别的课标词计入初中）。
String standardExportCategory(String level) {
  switch (level) {
    case '必修':
      return ExportCategory.standardCompulsory;
    case '选修':
      return ExportCategory.standardElective;
    default:
      return ExportCategory.standardJunior;
  }
}

/// 检测结果的词库归属 → 导出原文标注分类（双端唯一口径）。
///
/// 安卓检测分类为「课标词 / 拓展词 / 超标词 / 专有词 / 其他」，Windows 为
/// 「课标词 / 拓展词 / 超标词 / 专有词 / 未筛选」，两端都必须经本函数落到同一
/// 套七类导出分类上（原文标注、标注说明、汇总统计共用）：
/// - 课标词：按课标级别细分为「初中课标词 / 必修课标词 / 选修课标词」，
///   级别缺失时按初中处理（与 [standardExportCategory] 的统计口径一致）；
/// - 拓展词 / 超标词 / 专有词：原样透传；
/// - 未筛选 / 其他：真题语料出现过 → 「真题词」（叠加维度，不参与标注）；
///   四库均不收录且未在语料出现 → 「未筛选」（导出不标注，且导出前会被拦截）。
String exportAnnotateCategoryOfDetected({
  required String category,
  String standardLevel = '',
  bool isInCorpus = false,
}) {
  switch (category) {
    case '课标词':
      return standardExportCategory(standardLevel);
    case ExportCategory.extend:
    case ExportCategory.overLimit:
    case ExportCategory.proper:
      return category;
    case '未筛选':
    case '其他':
      return isInCorpus ? '真题词' : ExportCategory.unfiltered;
    default:
      return category;
  }
}

/// 七类规范色按规范顺序排列的色表，
/// 供 RTF 颜色表等「按索引引用颜色」的格式使用（索引 1 起对应本表第 1 项）。
List<String> exportPaletteHex() {
  final list = <String>[];
  for (final c in ExportCategory.all) {
    final hex = kExportWordStyles[c]?.colorHex;
    if (hex != null) list.add(hex);
  }
  return list;
}

/// 导出原文标注的方案（导出弹窗由用户二选一）。
///
/// - [color]：沿用既有导出，按单词类型标不同颜色（七类规范色表）；
/// - [typography]：全文单词统一 Times New Roman 常规体，按类型用
///   加粗 / 单下划线 / 30% 灰底纹 / 点线下划线区分，不加任何符号。
enum ExportAnnotateScheme {
  color,
  typography,
}

/// 方案二统一使用的西文字体。
const String kExportTypographyFont = 'Times New Roman';

/// 方案二专有词的 30% 灰底纹填充色（30% 黑度，黑字仍清晰）。
const String kExportScheme2ShadeFill = 'B3B3B3';

/// 方案二的单类词标记：加粗 / 下划线线型 / 灰底纹。
///
/// 课标词（初中 / 必修 / 选修）统一不区分，保持默认 TNR 常规体；
/// 「真题词」不参与标注（它只是“在真题文档里出现但不在标注类型内”的词）。
class ExportScheme2Style {
  final bool bold;

  /// OOXML `w:u` 取值（'single' / 'dotted'）；null 表示无下划线。
  final String? underline;

  /// OOXML `w:shd` 填充色（无 # 前缀）；null 表示无底纹。
  final String? shadeFill;

  const ExportScheme2Style({
    this.bold = false,
    this.underline,
    this.shadeFill,
  });
}

/// 方案二：类别 -> 标记组合（用户指定的简化映射）。
///
/// - 课标词（初中 / 必修 / 选修）：默认字体，不标注；
/// - 拓展词：加粗；
/// - 超标词：单线下划线；
/// - 专有词：30% 灰底纹。
/// 未筛选词不标注（导出前会被拦截，要求先归类完毕）。
const Map<String, ExportScheme2Style> kExportScheme2Styles = {
  ExportCategory.standardJunior: ExportScheme2Style(),
  ExportCategory.standardCompulsory: ExportScheme2Style(),
  ExportCategory.standardElective: ExportScheme2Style(),
  ExportCategory.extend: ExportScheme2Style(bold: true),
  ExportCategory.overLimit: ExportScheme2Style(underline: 'single'),
  ExportCategory.proper: ExportScheme2Style(shadeFill: kExportScheme2ShadeFill),
};

/// 取某类词在方案二下的标记；未筛选 / 真题词 / 其他 / 未知返回 null，
/// 表示不标注（正文仍是 TNR 常规体）。
ExportScheme2Style? exportScheme2StyleOf(String? category) =>
    category == null ? null : kExportScheme2Styles[category];

/// 导出文档中的标注说明文本（各格式共用，保证说明与实际标注一致）。
///
/// [scheme] 与用户在导出弹窗中的选择一致：方案一描述七类配色，
/// 方案二描述加粗 / 下划线 / 灰底纹映射。
String exportAnnotateLegend({
  ExportAnnotateScheme scheme = ExportAnnotateScheme.color,
}) {
  if (scheme == ExportAnnotateScheme.typography) {
    return '标注说明（黑白打印可辨）：课标词（初中/必修/选修）默认字体不标注；'
        '拓展词 加粗；超标词 单线下划线；专有词 30% 灰底纹；'
        '真题词不标注。全文西文统一 $kExportTypographyFont 常规体。';
  }
  return '标注说明：初中课标词 黑色；必修课标词 深蓝色；选修课标词 浅蓝色；'
      '拓展词 深绿色；超标词 红色；专有词 紫色（仅用颜色区分，不加粗）。';
}
