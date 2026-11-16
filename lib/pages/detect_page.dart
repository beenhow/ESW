import 'package:flutter/material.dart';
import '../theme/esw_tokens.dart';
import '../theme/responsive.dart';
import '../widgets/esw_widgets.dart';

/// 检测页历史条目（由父组件基于 _detectHistory 构造）。
class DetectHistoryItem {
  final String fileName;
  final String subtitle;
  final VoidCallback onTap;

  /// 有扫描原图时的查看回调；为空则不显示原图入口。
  final VoidCallback? onPhotoTap;

  const DetectHistoryItem({
    required this.fileName,
    required this.subtitle,
    required this.onTap,
    this.onPhotoTap,
  });
}

/// 检测页：文本检测（分段导入 + 语料统计卡 + 文本域 + 开始分析）。
/// 纯视觉层重做，导入 / 分析业务逻辑由父组件回调驱动。
class DetectPage extends StatefulWidget {
  /// 已导入真题 / 教材数量；null 表示加载中。
  final int? corpusCount;
  final int? textbookCount;

  /// 按年份统计的真题语料词库命中单词数（{年份: 命中次数}）。
  /// null 表示统计中 / 加载中；空 Map 表示无年份数据。
  final Map<int, int>? yearHits;

  /// 按教材文件统计的教材语料词库命中单词数（{教材名(去扩展名): 命中次数}）。
  /// null 表示统计中 / 加载中；空 Map 表示无教材数据。
  final Map<String, int>? textbookHits;

  /// 四类词占比数据：[课标词, 拓展词, 超标词, 专有词]。
  final List<int> categoryCounts;

  final Future<void> Function() onImportCorpus;
  final Future<void> Function() onImportTextbook;
  final VoidCallback onImportFile;

  /// 扫描文档内容：调起系统相机拍文档、识别文字后自动进入检测。
  final VoidCallback onScanDocument;

  /// 扫描识别进行中（按钮置灰，避免重复点击）。
  final bool scanning;
  final TextEditingController pasteController;
  final FocusNode pasteFocus;
  final ValueChanged<String> onAnalyze;
  final List<DetectHistoryItem> history;
  final VoidCallback onClearHistory;

  const DetectPage({
    super.key,
    required this.corpusCount,
    required this.textbookCount,
    required this.yearHits,
    required this.textbookHits,
    required this.categoryCounts,
    required this.onImportCorpus,
    required this.onImportTextbook,
    required this.onImportFile,
    required this.onScanDocument,
    this.scanning = false,
    required this.pasteController,
    required this.pasteFocus,
    required this.onAnalyze,
    required this.history,
    required this.onClearHistory,
  });

  @override
  State<DetectPage> createState() => _DetectPageState();
}

class _DetectPageState extends State<DetectPage> {
  @override
  Widget build(BuildContext context) {
    final corpus = widget.corpusCount ?? 0;
    final textbook = widget.textbookCount ?? 0;
    final ready =
        (widget.corpusCount ?? -1) >= 0 &&
        (widget.textbookCount ?? -1) >= 0 &&
        (corpus > 0 || textbook > 0);
    final loading = widget.corpusCount == null || widget.textbookCount == null;

    return EswResponsive.wrap(
      context,
      SafeArea(
        child: Column(
          children: [
            const EswPageHeader(title: '文本检测', subtitle: '粘贴或导入，自动比对你的词库'),
            // 主内容固定布局：分段 / 统计卡 / 文件按钮 / 粘贴框 / 格式提示 /
            // 主按钮始终完整可见，仅「最近检测」历史区在剩余空间内独立滚动。
            // 所有间距、行高、图标尺寸统一乘屏幕缩放系数（基准 360×800dp）。
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final f = EswResponsive.factorOf(context);
                  // ── 结构恒定原则（输入框可输入的关键）──
                  // 页面结构绝不随「键盘是否弹出」切换：Expanded ↔ SingleChildScrollView
                  // 互切、flex 比例变动都会重建输入框 Element，焦点随之丢失，表现为
                  // 「点了输入框打不进字」。此处整页常驻滚动视图，各区块使用固定高度，
                  // 内容高度与键盘无关；键盘弹出只让页面可滚动，输入框始终存在可点。
                  final historyList = ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: widget.history.length,
                    itemBuilder: (context, index) {
                      final item = widget.history[index];
                      return Padding(
                        padding: EdgeInsets.only(bottom: EswSpace.sm * f),
                        child: EswCard(
                          padding: EdgeInsets.zero,
                          onTap: item.onTap,
                          child: EswListTile(
                            leading: Container(
                              width: 40 * f,
                              height: 40 * f,
                              decoration: BoxDecoration(
                                color: EswColors.primarySoft,
                                borderRadius: BorderRadius.circular(
                                  EswRadius.small,
                                ),
                              ),
                              child: Icon(
                                Icons.description_outlined,
                                size: 20 * f,
                                color: EswColors.primary,
                              ),
                            ),
                            title: item.fileName,
                            subtitle: item.subtitle,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (item.onPhotoTap != null)
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: item.onPhotoTap,
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 6 * f,
                                      ),
                                      child: Icon(
                                        Icons.image_outlined,
                                        size: 18 * f,
                                        color: EswColors.primary,
                                      ),
                                    ),
                                  ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20 * f,
                                  color: EswColors.textSecondary,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );

                  // 格式 / 大小提示：窄屏或系统大字体时自动换行，不撑爆单行。
                  final formattedHintRow = Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: EswSpace.md * f,
                    runSpacing: EswSpace.xs * f,
                    children: const [
                      Text(
                        '格式：.txt / .doc / .docx / .pdf',
                        style: EswText.bodySmall,
                      ),
                      Text('大小上限：200MB', style: EswText.bodySmall),
                    ],
                  );

                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      EswSpace.lg * f,
                      0,
                      EswSpace.lg * f,
                      EswSpace.md * f,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 语料维护入口：只负责「导入」，不做真假题切换。
                        // 旧版分段控件一点击就弹文件选择器，用户误以为是在切页签，
                        // 流程很不直观；这里改为两个明确的导入按钮。
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: widget.onImportCorpus,
                                icon: Icon(
                                  Icons.folder_copy_outlined,
                                  size: 18 * f,
                                ),
                                label: const Text('导入真题'),
                              ),
                            ),
                            SizedBox(width: EswSpace.sm * f),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: widget.onImportTextbook,
                                icon: Icon(
                                  Icons.menu_book_outlined,
                                  size: 18 * f,
                                ),
                                label: const Text('导入教材'),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: EswSpace.sm * f),
                        _CorpusStatCard(
                          corpus: corpus,
                          textbook: textbook,
                          yearHits: widget.yearHits,
                          textbookHits: widget.textbookHits,
                          loading: loading,
                          ready: ready,
                        ),
                        SizedBox(height: EswSpace.sm * f),
                        EswDashedButton(
                          label: '选择文件检测',
                          icon: Icons.folder_open_rounded,
                          onPressed: widget.onImportFile,
                        ),
                        SizedBox(height: EswSpace.xs * f),
                        // 扫描文档内容：拍一张文档照片 → 本地识别文字 → 自动进入检测。
                        // 与「选择文件检测」并列为同一组导入入口，其他逻辑不变。
                        EswDashedButton(
                          label: widget.scanning ? '正在识别…' : '扫描文档内容',
                          icon: Icons.document_scanner_outlined,
                          onPressed: () {
                            if (widget.scanning) return;
                            widget.onScanDocument();
                          },
                        ),
                        SizedBox(height: EswSpace.sm * f),
                        // 固定高度：不再随键盘/剩余空间伸缩，保证点击区域恒定
                        SizedBox(
                          height: 168 * f,
                          child: _PasteCard(
                            controller: widget.pasteController,
                            focusNode: widget.pasteFocus,
                          ),
                        ),
                        SizedBox(height: EswSpace.xs * f),
                        formattedHintRow,
                        SizedBox(height: EswSpace.md * f),
                        EswPrimaryButton(
                          label: '开始分析',
                          icon: Icons.analytics_outlined,
                          onPressed: () =>
                              widget.onAnalyze(widget.pasteController.text),
                        ),
                        if (widget.history.isNotEmpty) ...[
                          SizedBox(height: EswSpace.md * f),
                          EswSectionHeader(
                            title: '最近检测',
                            actionLabel: '清空',
                            onAction: widget.onClearHistory,
                          ),
                          SizedBox(height: EswSpace.xs * f),
                          SizedBox(height: 176 * f, child: historyList),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 语料统计卡（1.5.7 纯文字形态）：标题 + 状态胶囊 + 一行统计文字，
/// 无数据时补一行浅灰提示文案；不含年份格 / 教材格等任何交互格子。
class _CorpusStatCard extends StatelessWidget {
  final int corpus;
  final int textbook;
  final Map<int, int>? yearHits;
  final Map<String, int>? textbookHits;
  final bool loading;
  final bool ready;

  const _CorpusStatCard({
    required this.corpus,
    required this.textbook,
    required this.yearHits,
    required this.textbookHits,
    required this.loading,
    required this.ready,
  });

  @override
  Widget build(BuildContext context) {
    final totalHits = yearHits == null
        ? 0
        : yearHits!.values.fold<int>(0, (a, b) => a + b);
    final totalTextbookHits = textbookHits == null
        ? 0
        : textbookHits!.values.fold<int>(0, (a, b) => a + b);
    final f = EswResponsive.factorOf(context);

    // 提示只在"确实还没有任何语料"时出现；一旦导入过真题或教材就不再提示，
    // 避免已导入语料却仍顶着一条"请导入…"的告警条。
    final statsReady = yearHits != null && textbookHits != null;
    final hasCorpus = corpus > 0 || textbook > 0;
    final String? hint = hasCorpus
        ? null
        : (statsReady
              ? '暂无语料，请导入以年份开头的真题文件（如 2023全国卷.txt）或教材文件'
              : '正在统计真题与教材命中单词数…');

    return EswCard(
      padding: EdgeInsets.all(EswSpace.md * f),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '已导入语料',
                style: EswText.bodyMedium.copyWith(
                  color: EswColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (loading)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: EswSpace.sm * f,
                    vertical: 2 * f,
                  ),
                  decoration: BoxDecoration(
                    color: EswColors.primarySoft,
                    borderRadius: BorderRadius.circular(EswRadius.small),
                  ),
                  child: Text(
                    '加载中…',
                    style: EswText.chip.copyWith(color: EswColors.primary),
                  ),
                )
              else if (ready)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: EswSpace.sm * f,
                    vertical: 2 * f,
                  ),
                  decoration: BoxDecoration(
                    color: EswColors.green.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(EswRadius.small),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6 * f,
                        height: 6 * f,
                        decoration: BoxDecoration(
                          color: EswColors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      SizedBox(width: EswSpace.xs * f),
                      Text(
                        '已就绪',
                        style: EswText.chip.copyWith(color: EswColors.green),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: EswSpace.sm * f,
                    vertical: 2 * f,
                  ),
                  decoration: BoxDecoration(
                    color: EswColors.primarySoft,
                    borderRadius: BorderRadius.circular(EswRadius.small),
                  ),
                  child: Text(
                    '待导入',
                    style: EswText.chip.copyWith(color: EswColors.primary),
                  ),
                ),
            ],
          ),
          SizedBox(height: EswSpace.sm * f),
          Text(
            '共 $corpus 份真题 · $textbook 份教材 · 真题命中 $totalHits 次 · 教材命中 $totalTextbookHits 次',
            style: EswText.caption.copyWith(color: EswColors.textSecondary),
          ),
          if (hint != null) ...[
            SizedBox(height: EswSpace.md * f),
            // 提示文案用浅灰底圆角条包裹，文字左对齐（对齐截图形态）
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: EswSpace.md * f,
                vertical: EswSpace.sm * f,
              ),
              decoration: BoxDecoration(
                color: EswColors.page,
                borderRadius: BorderRadius.circular(EswRadius.small),
              ),
              child: Text(
                hint,
                textAlign: TextAlign.left,
                style: EswText.bodySmall.copyWith(
                  color: EswColors.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 粘贴文本域卡片：白底圆角 + 实时计数 0 / 20000。
/// 高度由外层 Expanded 决定，输入区随剩余空间弹性伸缩（小屏不溢出）。
class _PasteCard extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  const _PasteCard({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    // 整卡可点：点在内边距 / 计数行等空白处也直接聚焦输入框，
    // 避免「点了卡片没反应、以为打不进字」。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!focusNode.hasFocus) focusNode.requestFocus();
      },
      child: Container(
        padding: EdgeInsets.fromLTRB(
          EswSpace.md * f,
          EswSpace.sm * f,
          EswSpace.md * f,
          EswSpace.xs * f,
        ),
        decoration: BoxDecoration(
          color: EswColors.card,
          borderRadius: BorderRadius.circular(EswRadius.card),
          border: Border.all(color: EswColors.border, width: 1),
          boxShadow: EswShadow.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                maxLines: null,
                minLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                // 键盘弹出时把输入框滚到可视区上方，避免被键盘顶住看不见光标
                scrollPadding: EdgeInsets.only(bottom: 200 * f),
                textAlignVertical: TextAlignVertical.top,
                style: EswText.bodyMedium.copyWith(
                  color: EswColors.textPrimary,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: '粘贴需要检测的文本，或使用上方「选择文件检测」导入…',
                  hintStyle: EswText.bodySmall.copyWith(
                    color: EswColors.textSecondary,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            SizedBox(height: EswSpace.xs * f),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final len = value.text.length;
                return Align(
                  alignment: Alignment.bottomRight,
                  child: Text(
                    '$len / 20000',
                    style: EswText.bodySmall.copyWith(
                      color: len >= 20000
                          ? EswColors.red
                          : EswColors.textSecondary,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
