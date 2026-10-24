/// 筛选体系的纯规则层（无 UI 依赖，便于单元测试）。
///
/// 第四关重构后的口径：
/// - **真题词是叠加维度**：只要单词在真题语料中出现过（inCorpus），就出现在
///   真题词列；它与课标词 / 拓展词 / 超标词 / 专有词互不排斥，同一个词可以
///   既在真题词列、又属于某个词库类别。真题词不作为词库归属（category）。
/// - **词库归属互相排斥**：课标词 / 拓展词 / 超标词 / 专有词 / 未筛选 五类里，
///   一个词只归一类。
/// - **未筛选**：课标 / 拓展 / 超标 / 专有 四个词库都不收录的词，一律归「未筛选」，
///   与其是否在语料出现过无关。其中**在语料出现过**的词会同时出现在真题词列与
///   未筛选列（两列重合），由用户在未筛选列手动归入拓展词 / 超标词 / 专有词；
///   在语料没出现过的词只出现在未筛选列。
library;

/// 真题词：叠加维度，由语料自动判定；不是词库归属（category 不再取此值）。
const String kFilterZhenti = '真题词';

/// 课标词：既定数据，不可手动归入。
const String kFilterStandard = '课标词';

const String kFilterExtend = '拓展词';
const String kFilterOverLimit = '超标词';
const String kFilterProper = '专有词';
const String kFilterUnfiltered = '未筛选';

/// 筛选列顺序（与界面标签顺序一致）。
const List<String> kWordFilters = [
  kFilterZhenti,
  kFilterStandard,
  kFilterExtend,
  kFilterOverLimit,
  kFilterProper,
  kFilterUnfiltered,
];

/// 用户对「未筛选」词可手动归入的类别：仅拓展词 / 超标词 / 专有词。
const List<String> kManualAssignableCategories = [
  kFilterExtend,
  kFilterOverLimit,
  kFilterProper,
];

/// 归属互相排斥的五类（真题词为叠加维度，不在此列）。
const List<String> kExclusiveFilters = [
  kFilterStandard,
  kFilterExtend,
  kFilterOverLimit,
  kFilterProper,
  kFilterUnfiltered,
];

/// 归一化词库归属：历史数据里残留的 category == 真题词 一律按「未筛选」处理
/// （真题词已改为纯叠加维度，词库归属只剩五类）。
String normalizeFilterCategory(String category) =>
    category == kFilterZhenti ? kFilterUnfiltered : category;

/// 单个单词参与筛选所需的全部状态。
class WordFilterState {
  /// 词库归属（互斥口径）：课标词 / 拓展词 / 超标词 / 专有词 / 未筛选。
  final String category;

  /// 是否在真题语料中出现过（真题词列的判定依据，与 category 相互独立）。
  final bool isInCorpus;

  const WordFilterState({required this.category, required this.isInCorpus});
}

/// 判定单词的词库归属（互斥口径）。
///
/// 优先级：历史归类（仅四个词库类别）> 超标词 > 拓展词 > 课标词 > 专有词 >
/// 未筛选（四个词库都不收录，无论语料是否出现过）。
///
/// [remembered] 只接受四个词库类别；历史遗留的「真题词 / 未筛选」被忽略，
/// 由最新词库归属重新推导，避免旧口径残留。
String resolveFilterCategory({
  required bool inCorpus,
  required bool inStandard,
  required bool inExtend,
  required bool inChaoGang,
  required bool inProper,
  String? remembered,
}) {
  final mem = remembered;
  if (mem != null &&
      mem != kFilterZhenti &&
      mem != kFilterUnfiltered &&
      kExclusiveFilters.contains(mem)) {
    return mem;
  }
  if (inChaoGang) return kFilterOverLimit;
  if (inExtend) return kFilterExtend;
  if (inStandard) return kFilterStandard;
  if (inProper) return kFilterProper;
  // 四个词库均未收录：一律未筛选。语料出现过的词由 isInCorpus 额外计入真题词列。
  return kFilterUnfiltered;
}

/// 统计各筛选标签的词数。
///
/// 真题词为叠加口径（inCorpus 即计入），因此真题词数会与其余五类重合，
/// 各列之和允许大于去重总词数；其余五类按 category 计数，「在语料出现但四库
/// 不收录」的词同时计入真题词与未筛选。
Map<String, int> buildFilterCounts(Iterable<WordFilterState> words) {
  final counts = <String, int>{for (final f in kWordFilters) f: 0};
  for (final w in words) {
    if (w.isInCorpus) counts[kFilterZhenti] = counts[kFilterZhenti]! + 1;
    final cat = normalizeFilterCategory(w.category);
    counts[cat] = (counts[cat] ?? 0) + 1;
  }
  return counts;
}

/// 判断单词是否应出现在某个筛选列中。
///
/// - 真题词列：只看是否在真题语料出现过（叠加，可与词库类别重合）；
/// - 未筛选列：category == 未筛选（四个词库都不收录），语料是否出现过不影响；
/// - 其余四列：按词库归属精确匹配。
bool matchesFilterColumn({
  required String filter,
  required String category,
  required bool isInCorpus,
}) {
  switch (filter) {
    case kFilterZhenti:
      return isInCorpus;
    case kFilterUnfiltered:
      return normalizeFilterCategory(category) == kFilterUnfiltered;
    default:
      return normalizeFilterCategory(category) == filter;
  }
}

/// 只有「未筛选」归属的词才提供筛选（手动归类）入口；
/// 语料出现过的未筛选词同样可以手动归类（真题词列与未筛选列重合，入口只在未筛选列）。
bool canAssignManually(WordFilterState state) =>
    normalizeFilterCategory(state.category) == kFilterUnfiltered;
