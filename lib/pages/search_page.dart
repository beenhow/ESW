import 'package:flutter/material.dart';
import '../theme/esw_tokens.dart';
import '../theme/responsive.dart';
import '../widgets/esw_widgets.dart';

/// 查词页：真题查词（左对齐标题 + 副标题）。
/// 纯视觉层重做，业务查词逻辑由父组件回调驱动。
class SearchPage extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  /// 是否展示查询结果区（父组件判定 _searchResult 非空）。
  final bool resultVisible;

  /// 结果区内容（父组件按原逻辑构建，通常是一张 EswCard 包裹的结果卡）。
  final Widget Function(BuildContext) resultBuilder;

  /// 最近查询历史（单词列表）。
  final List<String> history;

  /// 单词副标题（词义 + 出现份数 / 词性标签），异步取数。
  final Future<String> Function(String word) subtitleOf;

  final VoidCallback onClearHistory;
  final ValueChanged<String> onHistoryTap;

  const SearchPage({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.resultVisible,
    required this.resultBuilder,
    required this.history,
    required this.subtitleOf,
    required this.onClearHistory,
    required this.onHistoryTap,
  });

  @override
  Widget build(BuildContext context) {
    return EswResponsive.wrap(
      context,
      SafeArea(
        child: Column(
          children: [
            EswPageHeader(
              title: '真题查词',
              subtitle: '输入单词即可查看真题出处',
            ),
            Padding(
              padding: EswResponsive.inset(
                context,
                left: EswSpace.lg,
                right: EswSpace.lg,
                bottom: EswSpace.md,
              ),
              child: EswSearchField(
                controller: controller,
                focusNode: focusNode,
                hintText: '输入英文单词，如 gorilla',
                onChanged: onChanged,
                onSubmitted: onSubmitted,
              ),
            ),
            Expanded(
              child: ListView(
                padding: EswResponsive.inset(
                  context,
                  left: EswSpace.lg,
                  top: EswSpace.xs,
                  right: EswSpace.lg,
                  bottom: EswSpace.xxxl,
                ),
                children: [
                  if (resultVisible)
                    resultBuilder(context)
                  else if (history.isEmpty)
                    EswEmptyState(
                      icon: Icons.search_off_rounded,
                      title: '查过的词会留在这里',
                      description: '输入单词并回车，即可查看真题出处与词义，最近查询会显示在下方。',
                    )
                  else ...[
                    EswSectionHeader(
                      title: '最近查询',
                      actionLabel: '清空',
                      onAction: onClearHistory,
                    ),
                    SizedBox(height: EswResponsive.s(context, EswSpace.md)),
                    for (final word in history)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: EswResponsive.s(context, EswSpace.md),
                        ),
                        child: _HistoryCard(
                          word: word,
                          subtitleOf: subtitleOf,
                          onTap: () => onHistoryTap(word),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 历史词卡片：首字母色块 chip + 单词 + 副标题（词义 / 份数）+ 箭头。
class _HistoryCard extends StatelessWidget {
  final String word;
  final Future<String> Function(String word) subtitleOf;
  final VoidCallback onTap;

  const _HistoryCard({
    required this.word,
    required this.subtitleOf,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    return EswCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(EswRadius.card),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: EswSpace.lg * f,
            vertical: EswSpace.md * f,
          ),
          child: Row(
            children: [
              EswLetterChip(letter: word, color: EswColors.primary),
              SizedBox(width: EswSpace.md * f),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      word,
                      style: EswText.bodyMedium.copyWith(
                        color: EswColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    FutureBuilder<String>(
                      future: subtitleOf(word),
                      builder: (context, snap) {
                        final text = snap.hasData && snap.data!.isNotEmpty
                            ? snap.data!
                            : '点击查看词义与真题出处';
                        return Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: EswText.bodySmall.copyWith(
                            color: EswColors.textSecondary,
                          ),
                        );
                      },
                    ),
                  ],
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
  }
}
