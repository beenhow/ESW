/// 检测结果导出汇总条目构建（纯函数，供 Windows 端各格式导出共用）。
///
/// 条目名称、顺序、配色与字重以产品导出样式图为准：
///   全套词词数 | 去重总词数 | 初中课标词 | 必修课标词 | 选修课标词 |
///   拓展词 | 超标词 | 专有词 | 未筛选
///   （规范表之外的既有类别非 0 时补在末尾）
/// 配色 / 字重统一取自 shared/export_word_style.dart——与导出文档原文标注
/// 共用同一份规范表，避免汇总条目与正文标注两处配色漂移：
///   初中课标词 黑色加粗、必修课标词 深蓝色加粗、选修课标词 浅蓝色、
///   拓展词 深绿色加粗、超标词 红色、专有词 紫色、未筛选 土红色；
/// 每条条目 = 类别名 + 该类统计词数（value）。
/// 结果为 0 的类别不显示（"全套词词数 / 去重总词数"属总数类条目，始终显示）。
library;

import 'shared/export_word_style.dart' as spec;

/// 单个汇总条目：名称 + 数值（该类统计词数）+ 该类型标注色与字重。
class ExportSummaryItem {
  const ExportSummaryItem(
    this.label,
    this.value,
    this.colorHex, {
    this.alwaysShow = false,
    this.bold = false,
  });

  /// 条目名称
  final String label;

  /// 该类统计词数
  final int value;

  /// 该类型标注色（十六进制，不含 #）
  final String colorHex;

  /// 数值为 0 时是否仍然显示（仅总数类条目为 true）
  final bool alwaysShow;

  /// 是否加粗（规范：初中 / 必修课标词、拓展词加粗）
  final bool bold;

  /// 中性黑：总数条目与规范表之外的既有类别
  static const String black = '000000';

  /// 取规范分类的样式（配色 + 字重）；非规范七类返回 null。
  static spec.ExportWordStyle? styleOf(String category) =>
      spec.exportWordStyleOf(category);

  @override
  String toString() => '$label: $value';
}

/// 构建导出汇总条目列表。
///
/// [totalRawCount] 全套词词数（按词频累加）；[dedupCount] 去重总词数；
/// [filterCounts] 分类计数（键：拓展词/超标词/专有词/未筛选/真题词/其他…）；
/// [standardCategoryCounts] 课标词按级别拆分计数（键：初中/必修/选修）。
List<ExportSummaryItem> buildExportSummaryItems({
  required int totalRawCount,
  required int dedupCount,
  required Map<String, int> filterCounts,
  required Map<String, int> standardCategoryCounts,
}) {
  int c(String key) => filterCounts[key] ?? 0;

  /// 规范七类条目：配色与字重一律取自规范表，避免各处漂移。
  ExportSummaryItem ofCategory(String label, String category, int value) {
    final style = spec.exportWordStyleOf(category);
    return ExportSummaryItem(
      label,
      value,
      style?.colorHex ?? ExportSummaryItem.black,
      bold: style?.bold ?? false,
    );
  }

  final items = <ExportSummaryItem>[
    ExportSummaryItem('全套词词数', totalRawCount, ExportSummaryItem.black,
        alwaysShow: true),
    ExportSummaryItem('去重总词数', dedupCount, ExportSummaryItem.black,
        alwaysShow: true),
    // 课标词按课标级别拆分为初中 / 必修 / 选修三行
    ofCategory('初中课标词', spec.ExportCategory.standardJunior,
        standardCategoryCounts['初中'] ?? 0),
    ofCategory('必修课标词', spec.ExportCategory.standardCompulsory,
        standardCategoryCounts['必修'] ?? 0),
    ofCategory('选修课标词', spec.ExportCategory.standardElective,
        standardCategoryCounts['选修'] ?? 0),
    ofCategory('拓展词', spec.ExportCategory.extend, c('拓展词')),
    ofCategory('超标词', spec.ExportCategory.overLimit, c('超标词')),
    ofCategory('专有词', spec.ExportCategory.proper, c('专有词')),
    ofCategory('未筛选', spec.ExportCategory.unfiltered, c('未筛选')),
    // 规范表之外的既有检测口径类别：非 0 时补在末尾，避免非 0 统计缺项
    // （真题词不参与配色标注，保持中性黑）
    ExportSummaryItem('真题词', c('真题词'), ExportSummaryItem.black),
    ExportSummaryItem('其他', c('其他'), ExportSummaryItem.black),
  ];
  return items.where((e) => e.alwaysShow || e.value > 0).toList();
}

/// 七类标注说明片段（每类以规范色 + 字重呈现，末尾跟该类统计词数）。
///
/// 供 DOCX / PDF 等需要逐类着色的格式生成「标注说明」，与汇总条目、
/// 导出文档原文标注共用同一份规范表（shared/export_word_style.dart）。
List<({String label, String colorHex, bool bold, int count})>
    exportAnnotateLegendSegments(List<ExportSummaryItem> items) {
  final byLabel = <String, ExportSummaryItem>{
    for (final e in items) e.label: e,
  };
  final out = <({String label, String colorHex, bool bold, int count})>[];
  for (final label in spec.ExportCategory.all) {
    final style = spec.exportWordStyleOf(label);
    out.add((
      label: label,
      colorHex: style?.colorHex ?? ExportSummaryItem.black,
      bold: style?.bold ?? false,
      count: byLabel[label]?.value ?? 0,
    ));
  }
  return out;
}
