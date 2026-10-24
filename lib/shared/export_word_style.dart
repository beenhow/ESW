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

/// 七类词的规范样式表（用户导出样式图口径）。
///
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
  // 未筛选：土红色（不加粗）
  ExportCategory.unfiltered: ExportWordStyle(
    colorHex: 'A0522D',
    shadeHex: 'F0E0D6',
  ),
};

/// 取某类词的规范样式；非规范七类（真题词 / 其他）返回 null，表示不参与配色标注。
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

/// 导出文档中的标注说明文本（各格式共用，保证说明与配色、字重一致）。
String exportAnnotateLegend() =>
    '标注说明：初中课标词 黑色加粗；必修课标词 深蓝色加粗；选修课标词 浅蓝色；'
    '拓展词 深绿色加粗；超标词 红色；专有词 紫色；未筛选 土红色。';
