import 'package:flutter/material.dart';
import '../theme/esw_tokens.dart';
import '../theme/responsive.dart';

/// ESW 公共组件库。全部组件只使用设计令牌（EswColors / EswRadius /
/// EswSpace / EswText / EswShadow），禁止任何颜色 / 字号 / 圆角字面量。

/// 页面头部：居中标题 + 居中灰色副标题 + 右侧图标按钮。
///
/// 标题与副标题在整行宽度内居中；actions 用 Stack 绝对定位贴右侧，
/// 不占用文本行的宽度（因此不会把居中文字挤偏）。文本区左右各留出
/// actions 占位宽度，保证窄屏时文字不会压到按钮上。
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
    final f = EswResponsive.factorOf(context);
    // 文本区两侧预留的 actions 占位宽度（对称留白 => 文本仍严格居中）
    final double actionReserve = actions.isEmpty
        ? 0
        : (EswSpace.xxxl + EswSpace.md) * f * actions.length.clamp(1, 2);
    return Padding(
      padding: EswResponsive.inset(
        context,
        left: EswSpace.lg,
        top: EswSpace.lg,
        right: EswSpace.lg,
        bottom: EswSpace.md,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: actionReserve),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: EswText.title.copyWith(
                    color: EswColors.textPrimary,
                    height: 1.2,
                  ),
                ),
                SizedBox(height: EswSpace.xs * f),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: EswText.bodySmall.copyWith(
                    color: EswColors.textSecondary,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          if (actions.isNotEmpty)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: actions,
              ),
            ),
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

  /// 设计态高度（内部会再乘屏幕缩放系数）。
  final double height;

  const EswSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
    required this.onSubmitted,
    this.height = 54,
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
    final f = EswResponsive.factorOf(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      height: widget.height * f,
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
    final f = EswResponsive.factorOf(context);
    return Container(
      width: 40 * f,
      height: 40 * f,
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

  /// 自定义内边距；不传时使用随屏幕缩放的默认值。
  final EdgeInsetsGeometry? padding;

  const EswListTile({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EswRadius.card),
      child: Padding(
        padding: padding ??
            EdgeInsets.symmetric(
              horizontal: EswSpace.lg * f,
              vertical: EswSpace.md * f,
            ),
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
    final f = EswResponsive.factorOf(context);
    return EswCard(
      padding: EdgeInsets.symmetric(
        horizontal: EswSpace.xxl * f,
        vertical: EswSpace.xxxl * f,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64 * f,
            height: 64 * f,
            decoration: BoxDecoration(
              color: EswColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30 * f, color: EswColors.primary),
          ),
          SizedBox(height: EswSpace.lg * f),
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
    final f = EswResponsive.factorOf(context);
    return Container(
      padding: EdgeInsets.all(EswSpace.xs * f),
      decoration: BoxDecoration(
        color: EswColors.page,
        borderRadius: BorderRadius.circular(EswRadius.control),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) SizedBox(width: EswSpace.xs * f),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                height: 40 * f,
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

/// 统计卡：白底、标题小色点、语义色大数字、右上 16% 光晕。
/// 卡内仅保留「色点 + 类目名（灰色小字）」一行与下方大号加粗同色数字。
class EswStatCard extends StatelessWidget {
  final String label;
  final String countText;
  final Color color;
  final VoidCallback? onTap;

  const EswStatCard({
    super.key,
    required this.label,
    required this.countText,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    final content = Stack(
      children: [
        // 右上角 16% 透明圆形光晕
        Positioned(
          top: -EswSpace.xl * f,
          right: -EswSpace.xl * f,
          child: Container(
            width: 56 * f,
            height: 56 * f,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8 * f,
                  height: 8 * f,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: EswSpace.sm * f),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EswText.bodySmall.copyWith(
                      color: EswColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: EswSpace.sm * f),
            Text(
              countText,
              maxLines: 1,
              style: EswText.display.copyWith(color: color),
            ),
          ],
        ),
      ],
    );
    return EswCard(
      padding: EdgeInsets.all(EswSpace.md * f),
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 被放进固定高度的格子（2×2 统计卡）时，内容超高则整块等比缩小，
          // 保证任何屏幕 / 任何格高都不会溢出。
          if (!constraints.hasBoundedHeight) return content;
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: SizedBox(width: constraints.maxWidth, child: content),
          );
        },
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
    final f = EswResponsive.factorOf(context);
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: EswColors.primary,
        radius: EswRadius.control,
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52 * f,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(EswRadius.control),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20 * f, color: EswColors.primary),
              SizedBox(width: EswSpace.sm * f),
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
    final f = EswResponsive.factorOf(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: height * f,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(EswRadius.control),
        boxShadow: onPressed == null ? null : EswShadow.button,
      ),
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: icon == null
            ? const SizedBox.shrink()
            : Icon(icon, size: 20 * f),
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

  /// 紧凑模式：缩小图标与上下内边距，用于一屏内塞下多项设置。
  final bool dense;

  const EswSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.dense = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EswRadius.card),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: EswSpace.lg * f,
          vertical: (dense ? EswSpace.sm : EswSpace.md) * f,
        ),
        child: Row(
          children: [
            Container(
              width: (dense ? 32 : 38) * f,
              height: (dense ? 32 : 38) * f,
              decoration: BoxDecoration(
                color: EswColors.primarySoft,
                borderRadius: BorderRadius.circular(EswRadius.small),
              ),
              child: Icon(icon, size: (dense ? 17 : 19) * f, color: EswColors.primary),
            ),
            SizedBox(width: EswSpace.md * f),
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
                size: 20 * f,
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
    final f = EswResponsive.factorOf(context);
    return Container(
      decoration: BoxDecoration(
        color: EswColors.card,
        border: Border(top: BorderSide(color: EswColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64 * f,
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
                          size: 24 * f,
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
