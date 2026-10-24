import 'package:flutter/material.dart';
import '../theme/esw_tokens.dart';

/// ESW 公共组件库。全部组件只使用设计令牌（EswColors / EswRadius /
/// EswSpace / EswText / EswShadow），禁止任何颜色 / 字号 / 圆角字面量。

/// 页面头部：左对齐标题 + 灰色副标题 + 右侧图标按钮。
class EswPageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> actions;

  const EswPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        EswSpace.lg,
        EswSpace.lg,
        EswSpace.lg,
        EswSpace.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: EswText.title.copyWith(color: EswColors.textPrimary)),
                const SizedBox(height: EswSpace.xs),
                Text(
                  subtitle,
                  style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
                ),
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: EswSpace.md),
            ...actions,
          ],
        ],
      ),
    );
  }
}

/// 搜索框：高 54，聚焦时主色描边 + 4px 光晕，160ms 平滑过渡。
class EswSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const EswSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  State<EswSearchField> createState() => _EswSearchFieldState();
}

class _EswSearchFieldState extends State<EswSearchField> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focusNode.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      height: 54,
      decoration: BoxDecoration(
        color: EswColors.card,
        borderRadius: BorderRadius.circular(EswRadius.control),
        border: Border.all(
          color: focused ? EswColors.primary : EswColors.border,
          width: 1.5,
        ),
        boxShadow: focused ? EswShadow.glow : EswShadow.card,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        style: EswText.body.copyWith(color: EswColors.textPrimary),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hintText,
          hintStyle: EswText.body.copyWith(color: EswColors.textSecondary),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 22,
            color: focused ? EswColors.primary : EswColors.textSecondary,
          ),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: Icon(
                      Icons.cancel_rounded,
                      size: 20,
                      color: EswColors.textSecondary,
                    ),
                    onPressed: () {
                      widget.controller.clear();
                      widget.onChanged('');
                    },
                  ),
          ),
          filled: true,
          fillColor: EswColors.card,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: EswSpace.lg,
            vertical: EswSpace.md,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(EswRadius.control),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(EswRadius.control),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(EswRadius.control),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}

/// 区块标题：左对齐标题 + 右侧操作（如"清空"）。
class EswSectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EswSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: EswText.titleSmall.copyWith(color: EswColors.textPrimary),
          ),
        ),
        if (actionLabel != null)
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(EswRadius.small),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: EswSpace.sm,
                vertical: EswSpace.xs,
              ),
              child: Text(
                actionLabel!,
                style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
              ),
            ),
          ),
      ],
    );
  }
}

/// 通用卡片：白底 + 20 圆角 + 轻投影，替代灰色硬描边。
class EswCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  const EswCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(EswSpace.lg),
    this.margin = EdgeInsets.zero,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: EswColors.card,
        borderRadius: BorderRadius.circular(EswRadius.card),
        border: Border.all(color: EswColors.border, width: 1),
        boxShadow: EswShadow.card,
      ),
      child: child,
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EswRadius.card),
      child: card,
    );
  }
}

/// 首字母色块圆形 chip。
class EswLetterChip extends StatelessWidget {
  final String letter;
  final Color color;

  const EswLetterChip({
    super.key,
    required this.letter,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final first = letter.isEmpty ? '?' : letter[0].toUpperCase();
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: Text(
        first,
        style: EswText.titleSmall.copyWith(color: color),
      ),
    );
  }
}

/// 通用列表行：首字母 chip / 标题 + 副标题 / 右侧箭头，自带 ripple。
class EswListTile extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const EswListTile({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(
      horizontal: EswSpace.lg,
      vertical: EswSpace.md,
    ),
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EswRadius.card),
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            leading,
            const SizedBox(width: EswSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: EswText.bodyMedium.copyWith(color: EswColors.textPrimary),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 空状态：图标 + 标题 + 说明。
class EswEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const EswEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return EswCard(
      padding: const EdgeInsets.symmetric(
        horizontal: EswSpace.xxl,
        vertical: EswSpace.xxxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: EswColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: EswColors.primary),
          ),
          const SizedBox(height: EswSpace.lg),
          Text(
            title,
            style: EswText.bodyMedium.copyWith(color: EswColors.textPrimary),
          ),
          const SizedBox(height: EswSpace.xs),
          Text(
            description,
            textAlign: TextAlign.center,
            style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 分段控件：选中主色底白字，未选中浅底灰字；160ms 过渡。
class EswSegmented extends StatelessWidget {
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const EswSegmented({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(EswSpace.xs),
      decoration: BoxDecoration(
        color: EswColors.page,
        borderRadius: BorderRadius.circular(EswRadius.control),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: EswSpace.xs),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                height: 40,
                decoration: BoxDecoration(
                  color: i == selectedIndex
                      ? EswColors.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(EswRadius.small),
                ),
                child: InkWell(
                  onTap: () => onChanged(i),
                  borderRadius: BorderRadius.circular(EswRadius.small),
                  child: Center(
                    child: Text(
                      options[i],
                      style: EswText.label.copyWith(
                        color: i == selectedIndex
                            ? EswColors.card
                            : EswColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 统计卡：白底、标题小色点、语义色大数字、右下占比、右上 16% 光晕。
class EswStatCard extends StatelessWidget {
  final String label;
  final String countText;
  final Color color;
  final String ratioText;
  final VoidCallback? onTap;

  const EswStatCard({
    super.key,
    required this.label,
    required this.countText,
    required this.color,
    required this.ratioText,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return EswCard(
      padding: const EdgeInsets.all(EswSpace.lg),
      onTap: onTap,
      child: Stack(
        children: [
          // 右上角 16% 透明圆形光晕
          Positioned(
            top: -EswSpace.xl,
            right: -EswSpace.xl,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: EswSpace.sm),
                  Expanded(
                    child: Text(
                      label,
                      style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: EswSpace.md),
              Text(
                countText,
                style: EswText.display.copyWith(color: color),
              ),
              const SizedBox(height: EswSpace.sm),
              Text(
                ratioText,
                style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 虚线描边按钮（选择文件检测）。
class EswDashedButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const EswDashedButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: EswColors.primary,
        radius: EswRadius.control,
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(EswRadius.control),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: EswColors.primary),
              const SizedBox(width: EswSpace.sm),
              Text(
                label,
                style: EswText.bodyMedium.copyWith(color: EswColors.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()
      ..addRRect(rrect)
      ..close();
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    const dash = 6.0;
    const gap = 4.0;
    final metrics = path.computeMetrics().toList();
    for (final metric in metrics) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, distance + dash),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// 实心主色按钮（第一视觉动线），带主色投影。
class EswPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;

  const EswPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(EswRadius.control),
        boxShadow: onPressed == null ? null : EswShadow.button,
      ),
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: icon == null
            ? const SizedBox.shrink()
            : Icon(icon, size: 20),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: EswColors.primary,
          foregroundColor: EswColors.card,
          disabledBackgroundColor: EswColors.primary.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EswRadius.control),
          ),
          textStyle: EswText.bodyMedium,
        ),
      ),
    );
  }
}

/// 设置列表项：图标底 + 标题（可带副标题）+ 右侧箭头。
class EswSettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const EswSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EswRadius.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: EswSpace.lg,
          vertical: EswSpace.md,
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: EswColors.primarySoft,
                borderRadius: BorderRadius.circular(EswRadius.small),
              ),
              child: Icon(icon, size: 19, color: EswColors.primary),
            ),
            const SizedBox(width: EswSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: EswText.body.copyWith(color: EswColors.textPrimary),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: EswText.bodySmall.copyWith(color: EswColors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: EswColors.textSecondary,
              ),
          ],
        ),
      ),
    );
  }
}

/// 底部导航：选中主色图标 + 主色文字 + 下方 4px 主色小圆点，未选中 ink3。
class EswBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onChanged;
  final List<String> labels;
  final List<IconData> icons;
  final List<IconData> selectedIcons;

  const EswBottomNav({
    super.key,
    required this.currentIndex,
    required this.onChanged,
    required this.labels,
    required this.icons,
    required this.selectedIcons,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: EswColors.card,
        border: Border(top: BorderSide(color: EswColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onChanged(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          i == currentIndex ? selectedIcons[i] : icons[i],
                          size: 24,
                          color: i == currentIndex
                              ? EswColors.primary
                              : EswColors.ink3,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          labels[i],
                          style: EswText.bodySmall.copyWith(
                            color: i == currentIndex
                                ? EswColors.primary
                                : EswColors.ink3,
                            fontWeight: i == currentIndex
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        const SizedBox(height: 2),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            color: i == currentIndex
                                ? EswColors.primary
                                : Colors.transparent,
                            shape: BoxShape.circle,
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
    );
  }
}
