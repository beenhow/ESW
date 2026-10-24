import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass_theme.dart';

/// ESW 弹窗设计套件（视觉基准：参考图「导出检测结果」弹窗）
///
/// 视觉要点（V10）：磨砂玻璃面板 + 面板圆角 12 + 面板宽「按内容自适应」并夹在全站统一
/// 上下限内（常规 300~460；宽内容档最多 720，需显式 opt-in）+
/// 标题/副标题层级分明 + 紧凑选项块（高 33、圆角 9）+ 取消为灰色文字按钮 / 主操作为蓝紫渐变按钮。
/// 本文件只承载排版与视觉，不改变任何业务逻辑；内部元素顺序由调用方决定。
class EswDialog {
  EswDialog._();

  // ── 面板 ──
  // V9 收紧：在 V8（34%/18-16-14）基础上再显著压缩——面板宽 34%→29%、上限 460→392，
  // 内边距 18/16/14→15/12/11，控件高 38/32→33/30，圆角 14/10→12/9，字号略降，
  // 消除大窗口下的空旷与拥挤并存观感；弹窗内元素顺序与功能保持不变。
  static const double rPanel = 12; // 面板圆角
  static const double rBlock = 9; // 选项块 / 按钮圆角
  static const double padH = kGap16; // 左右内边距
  static const double padT = kGap12; // 上内边距
  static const double padB = kGap12; // 下内边距

  // ── 间距 ──
  static const double gapTitleSub = kGap4; // 标题 → 副标题
  static const double gapHeaderBody = kGap9; // 标题区 → 内容
  static const double gapSection = kGap18; // 内容块之间 / 内容 → 按钮区
  static const double gapOpt = kGap6; // 选项块之间
  static const double gapAction = kGap10; // 按钮之间

  // ── 尺寸 ──
  static const double hOption = 33; // 选项块高
  static const double hAction = 30; // 按钮高

  // ── 宽度体系（V10：内容自适应 + 全站统一上下限）──
  /// 全站统一下限：再短的提示 / 确认类弹窗也不窄于该值。
  static const double wPanelMin = 300;
  /// 常规档上限：较长说明、多列选项类弹窗。
  static const double wPanelMax = 460;
  /// 宽内容档上限：词库列表 / 词卡列表等「宽内容」弹窗需显式声明
  /// `maxWidth: EswDialog.wPanelWide` 才可使用，避免全站面板宽差距过大。
  static const double wPanelWide = 720;
  /// 独立页面（整页路由，如使用说明）内容列上限：宽窗口下内容居中、不被拉伸成超长行。
  static const double wPageMax = 760;
  /// 面板两侧距窗口边缘的最小安全距离（窗口过窄时防溢出）。
  static const double wScreenInset = 24;

  // ── 字号层级 ──
  static const double fTitle = 14.5; // 标题：最大加粗
  static const double fSubtitle = 11; // 副标题
  static const double fOption = 11.5; // 选项文字
  static const double fHint = 10.5; // 辅助说明

  /// 面板宽度：按「内容所需宽度」取宽，全站统一夹在 [wPanelMin] ~ [maxWidth]
  /// （默认 [wPanelMax]），最后按窗口宽度做安全收敛。
  ///
  /// 关于「不要忽大忽小」：旧版按「屏宽 29%」取宽，同一弹窗随窗口缩放而变宽变窄，
  /// 且不同弹窗各自写死宽度（词库列表 520~820 vs 确认框 288），宽窄差距很大。
  /// 现改为纯内容驱动——面板宽只取决于内容（调用方给的 [minContent] +
  /// 标题 / 副标题文本自然宽），与窗口大小无关（仅窗口过窄时收敛），
  /// 因此同一弹窗每次打开宽度一致，全站宽度落在统一的两档上下限内。
  static double panelWidth(
    BuildContext context, {
    double minContent = 0,
    double maxWidth = wPanelMax,
    String? title,
    String? subtitle,
  }) {
    final sw = MediaQuery.sizeOf(context).width;
    final hi = math.max(wPanelMin, maxWidth);
    final innerMax = math.max(0.0, hi - padH * 2);
    var content = math.max(0.0, minContent);
    // 标题 / 副标题文本自然宽参与估宽：短标题收窄、长说明放宽（仍受上下限约束）
    content = math.max(content, measureTextWidth(context, title, titleStyle));
    content = math.max(content, measureTextWidth(context, subtitle, subtitleStyle));
    final double w;
    if (content <= 0) {
      w = wPanelMin;
    } else {
      w = (math.min(content, innerMax) + padH * 2).clamp(wPanelMin, hi).toDouble();
    }
    return math.min(w, math.max(240, sw - wScreenInset * 2));
  }

  /// 文本自然宽（不换行时的一行宽），用于内容自适应估宽；空文本返回 0。
  static double measureTextWidth(
    BuildContext context,
    String? text,
    TextStyle style,
  ) {
    if (text == null || text.isEmpty) return 0;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  static const TextStyle titleStyle = TextStyle(
    fontSize: fTitle,
    fontWeight: FontWeight.w700,
    color: GlassTheme.ink,
    height: 1.25,
  );

  static const TextStyle subtitleStyle = TextStyle(
    fontSize: fSubtitle,
    color: GlassTheme.ink2,
    height: 1.5,
  );

  static const TextStyle bodyStyle = TextStyle(
    fontSize: fOption,
    color: GlassTheme.ink,
    height: 1.55,
  );
}

/// 弹窗内容骨架：面板宽按内容自适应（全站统一上下限）+ 统一内边距 + 标题区 / 内容 / 按钮区三段结构。
class EswDialogShell extends StatelessWidget {
  const EswDialogShell({
    super.key,
    this.title,
    this.subtitle,
    this.titleWidget,
    this.icon,
    this.trailing,
    required this.body,
    this.actions,
    this.width,
    this.minContent = 0,
    this.maxWidth = EswDialog.wPanelMax,
    this.scrollable = true,
    this.padding,
    this.onDrag,
  });

  /// 标题文本（与 [titleWidget] 二选一）。
  final String? title;

  /// 自定义标题控件（如需拖动等交互）。
  final Widget? titleWidget;

  /// 副标题（标题下方一行说明，形成层级）。
  final String? subtitle;

  /// 标题左侧渐变图标。
  final IconData? icon;

  /// 标题行右侧附加控件。
  final Widget? trailing;

  final Widget body;

  /// 按钮区，通常为 [EswDialogActions]。
  final Widget? actions;

  /// 直接指定面板宽度；一般留空，交由 [EswDialog.panelWidth] 按内容自适应计算
  /// （留空是保证全站弹窗宽窄一致的推荐做法）。
  final double? width;

  /// 内容最小宽度（用于宽表格 / 长列表类弹窗，保证内容不被压窄）。
  final double minContent;

  /// 宽度上限（默认常规档 [EswDialog.wPanelMax]；宽内容弹窗可显式放宽到
  /// [EswDialog.wPanelWide]，但不得随意突破，以免全站面板宽忽大忽小）。
  final double maxWidth;

  /// true（默认）时内容整体可滚动，适用于表单类简单内容；
  /// 内部自带 ListView 等滚动体的弹窗应传 false。
  final bool scrollable;

  final EdgeInsetsGeometry? padding;
  final ValueChanged<Offset>? onDrag;

  @override
  Widget build(BuildContext context) {
    final w = width ??
        EswDialog.panelWidth(
          context,
          minContent: minContent,
          maxWidth: maxWidth,
          title: title,
          subtitle: subtitle,
        );
    final Widget? header = (title == null && titleWidget == null)
        ? null
        : _buildHeader();
    final Widget bodyWidget = Flexible(
      child: scrollable ? SingleChildScrollView(child: body) : body,
    );
    return SizedBox(
      width: w,
      child: Padding(
        padding:
            padding ??
            const EdgeInsets.fromLTRB(
              EswDialog.padH,
              EswDialog.padT,
              EswDialog.padH,
              EswDialog.padB,
            ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (header != null) ...[
              header,
              const SizedBox(height: EswDialog.gapHeaderBody),
            ],
            bodyWidget,
            if (actions != null) ...[
              const SizedBox(height: EswDialog.gapSection),
              actions!,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final Widget titleChild =
        titleWidget ??
        Text(title!, style: EswDialog.titleStyle, maxLines: 2, overflow: TextOverflow.ellipsis);
    final heading = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        titleChild,
        if (subtitle != null) ...[
          const SizedBox(height: EswDialog.gapTitleSub),
          Text(subtitle!, style: EswDialog.subtitleStyle),
        ],
      ],
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: GlassTheme.grad,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x334462F2),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, size: 14, color: Colors.white),
          ),
          const SizedBox(width: kGap8),
        ],
        Expanded(child: heading),
        if (trailing != null) trailing!,
      ],
    );
    if (onDrag == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => onDrag!(d.delta),
        child: row,
      ),
    );
  }
}

/// 按钮区：默认右对齐（左取消 / 右主操作）。
class EswDialogActions extends StatelessWidget {
  const EswDialogActions({
    super.key,
    required this.children,
    this.alignment = MainAxisAlignment.end,
  });

  final List<Widget> children;
  final MainAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final row = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) row.add(const SizedBox(width: EswDialog.gapAction));
      row.add(children[i]);
    }
    return Row(mainAxisAlignment: alignment, children: row);
  }
}

/// 灰色文字按钮（取消 / 次要操作，参考图左下）。
class EswDialogTextAction extends StatefulWidget {
  const EswDialogTextAction({
    super.key,
    required this.label,
    this.onPressed,
    this.danger = false,
    this.height = EswDialog.hAction,
    this.fontSize = EswDialog.fOption,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  /// 按钮高度与字号（默认沿用套件基准值，可按弹窗需要放大）。
  final double height;
  final double fontSize;

  @override
  State<EswDialogTextAction> createState() => _EswDialogTextActionState();
}

class _EswDialogTextActionState extends State<EswDialogTextAction> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;
    final Color idle = widget.danger ? const Color(0xFFD93A3F) : GlassTheme.ink2;
    final Color hoveredColor = widget.danger
        ? const Color(0xFFBF2E33)
        : GlassTheme.accentInk;
    final Color hoverBg = widget.danger
        ? const Color(0x14E5484D)
        : GlassTheme.accentSoft;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0, // 第三关 ⑤：按压统一 .96 / 80ms
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: widget.height,
            padding: const EdgeInsets.symmetric(horizontal: kGap12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? hoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(EswDialog.rBlock),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: widget.fontSize,
                fontWeight: FontWeight.w500,
                color: enabled ? (hovered ? hoveredColor : idle) : GlassTheme.ink3,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 蓝紫渐变主按钮（参考图右下「导出」）。
class EswDialogPrimaryAction extends StatefulWidget {
  const EswDialogPrimaryAction({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.danger = false,
    this.hoverBlue = false,
    this.minWidth = 92,
    this.height = EswDialog.hAction,
    this.fontSize = EswDialog.fOption,
  });

  /// 按钮高度与字号（默认沿用套件基准值，可按弹窗需要放大）。
  final double height;
  final double fontSize;

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// 危险操作用红色渐变（删除确认等），保持"主操作突出"的同时语义明确。
  final bool danger;

  /// 悬停时改用纯蓝底（归类弹窗要求：鼠标悬停到哪个按钮，哪个按钮即变蓝；
  /// 仅在该按钮上生效，移出即恢复原蓝紫渐变）。
  final bool hoverBlue;
  final double minWidth;

  @override
  State<EswDialogPrimaryAction> createState() => _EswDialogPrimaryActionState();
}

class _EswDialogPrimaryActionState extends State<EswDialogPrimaryAction> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;
    // 悬停纯蓝态：鼠标停在按钮上时整块变蓝（归类弹窗要求），移出恢复原渐变
    final hoverBlueOn = widget.hoverBlue && hovered;
    final gradient = widget.danger
        ? const LinearGradient(
            begin: Alignment(-0.866, -0.5),
            end: Alignment(0.866, 0.5),
            colors: [Color(0xFFE5484D), Color(0xFFF0636A)],
          )
        : (hoverBlueOn
              ? const LinearGradient(
                  begin: Alignment(-0.866, -0.5),
                  end: Alignment(0.866, 0.5),
                  colors: [Color(0xFF2F6BFF), Color(0xFF1E5BE0)],
                )
              // 第三关 ⑤：悬停轻微提亮 / 按压加深（与 GlassGradientButton 统一）
              : (_pressed
                    ? GlassGradientButton.gradPressed
                    : (_hovered
                          ? GlassGradientButton.gradHover
                          : GlassTheme.grad)));
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0, // 第三关 ⑤：按压统一 .96 / 80ms
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: widget.height,
            constraints: BoxConstraints(minWidth: widget.minWidth),
            padding: const EdgeInsets.symmetric(horizontal: kGap16),
            decoration: BoxDecoration(
              gradient: enabled ? gradient : null,
              color: enabled ? null : const Color(0x1F18181B),
              borderRadius: BorderRadius.circular(EswDialog.rBlock),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: (widget.danger
                                ? const Color(0xFFE5484D)
                                : GlassTheme.accent)
                            .withValues(alpha: hovered ? 0.34 : 0.24),
                        blurRadius: hovered ? 14 : 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: 15,
                    color: enabled ? Colors.white : GlassTheme.ink3,
                  ),
                  const SizedBox(width: kGap7),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: widget.fontSize,
                    fontWeight: FontWeight.w600,
                    color: enabled ? Colors.white : GlassTheme.ink3,
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

/// 玻璃描边次要按钮（多按钮弹窗中的中间项）。
class EswDialogGhostAction extends StatefulWidget {
  const EswDialogGhostAction({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.hoverBlue = false,
    this.height = EswDialog.hAction,
    this.fontSize = EswDialog.fOption,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// 悬停时改用纯蓝底 + 白字（归类弹窗要求：鼠标悬停到哪个按钮，哪个按钮即变蓝）。
  final bool hoverBlue;

  /// 按钮高度与字号（默认沿用套件基准值，可按弹窗需要放大）。
  final double height;
  final double fontSize;

  @override
  State<EswDialogGhostAction> createState() => _EswDialogGhostActionState();
}

class _EswDialogGhostActionState extends State<EswDialogGhostAction> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;
    // 悬停纯蓝态：鼠标停在按钮上时整块变蓝（归类弹窗要求）
    final hoverBlueOn = widget.hoverBlue && hovered;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0, // 第三关 ⑤：按压统一 .96 / 80ms
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: widget.height,
            padding: const EdgeInsets.symmetric(horizontal: kGap12),
            decoration: BoxDecoration(
              color: hoverBlueOn
                  ? const Color(0xFF2F6BFF)
                  : (hovered ? GlassTheme.accentSoft : const Color(0x8CFFFFFF)),
              borderRadius: BorderRadius.circular(EswDialog.rBlock),
              border: Border.all(
                color: hoverBlueOn
                    ? const Color(0xFF2F6BFF)
                    : (hovered ? const Color(0xFFC7D2FE) : GlassTheme.line),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: 15,
                    color: hoverBlueOn
                        ? Colors.white
                        : (hovered ? GlassTheme.accentInk : GlassTheme.ink2),
                  ),
                  const SizedBox(width: kGap7),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: widget.fontSize,
                    fontWeight: FontWeight.w500,
                    color: enabled
                        ? (hoverBlueOn
                              ? Colors.white
                              : (hovered
                                    ? GlassTheme.accentInk
                                    : GlassTheme.ink2))
                        : GlassTheme.ink3,
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

/// 紧凑单选块（参考图「范围 / 格式」选项块）：高 33、圆角 9、选中蓝边 + 浅蓝底。
class EswOptionTile extends StatefulWidget {
  const EswOptionTile({
    super.key,
    required this.label,
    this.desc,
    this.selected = false,
    this.onTap,
    this.height = EswDialog.hOption,
    this.icon,
  });

  final String label;
  final String? desc;
  final bool selected;
  final VoidCallback? onTap;
  final double height;
  final IconData? icon;

  @override
  State<EswOptionTile> createState() => _EswOptionTileState();
}

class _EswOptionTileState extends State<EswOptionTile> {
  bool _hovered = false;
  bool _pressed = false; // 第三关 ⑤：按压缩放反馈状态

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final hovered = _hovered && widget.onTap != null;
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        // 第三关 ⑤：可点元素补按压缩放反馈（§3.1 / §4.7 第 8 条）
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: widget.onTap == null
              ? null
              : (_) => setState(() => _pressed = true),
          onTapUp: widget.onTap == null
              ? null
              : (_) => setState(() => _pressed = false),
          onTapCancel: widget.onTap == null
              ? null
              : () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: widget.height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? GlassTheme.accentSoft
                  : (hovered
                        ? const Color(0xB8FFFFFF)
                        : const Color(0x8CFFFFFF)),
              borderRadius: BorderRadius.circular(EswDialog.rBlock),
              border: Border.all(
                color: selected
                    ? GlassTheme.accent
                    : (hovered ? const Color(0x66C4C6CE) : GlassTheme.line),
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(
                        widget.icon,
                        size: 14,
                        color: selected
                            ? GlassTheme.accentInk
                            : GlassTheme.ink2,
                      ),
                      const SizedBox(width: kGap7),
                    ],
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: EswDialog.fOption,
                        fontWeight: FontWeight.w600,
                        color: selected ? GlassTheme.accentInk : GlassTheme.ink,
                        height: 1,
                      ),
                    ),
                  ],
                ),
                if (widget.desc != null) ...[
                  const SizedBox(height: kGap4),
                  Text(
                    widget.desc!,
                    style: const TextStyle(
                      fontSize: EswDialog.fHint,
                      color: GlassTheme.ink3,
                      height: 1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一行等宽选项块（自动均分 + 8px 间隔）。
class EswOptionRow extends StatelessWidget {
  const EswOptionRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final row = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        row.add(const SizedBox(width: EswDialog.gapOpt));
        row.add(Expanded(child: children[i]));
      } else {
        row.add(Expanded(child: children[i]));
      }
    }
    return Row(children: row);
  }
}

/// 辅助说明文字（弹窗内最小字号）。
class EswDialogHint extends StatelessWidget {
  const EswDialogHint(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: EswDialog.fHint,
      color: GlassTheme.ink3,
      height: 1.5,
    );
    if (icon == null) return Text(text, style: style);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 13, color: GlassTheme.ink3),
        const SizedBox(width: kGap7),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}

/// 弹窗宽度约束：把面板宽度统一到「内容自适应 + 全站统一上下限」
/// （默认 [EswDialog.wPanelMin] ~ [EswDialog.wPanelMax]），
/// 内容较宽的弹窗（表格 / 长列表）可用 [minContent] 保底、用 [maxWidth] 显式放宽，
/// 避免被压窄或宽窄忽大忽小。
/// 与 [EswDialogShell] 的宽度规则共用 [EswDialog.panelWidth]。
class EswDialogWidth extends StatelessWidget {
  const EswDialogWidth({
    super.key,
    required this.child,
    this.minContent = 0,
    this.maxWidth = EswDialog.wPanelMax,
    this.width,
  });

  final Widget child;

  /// 内容最小宽度（面板宽度不会小于该值 + 左右内边距）。
  final double minContent;

  /// 宽度上限（默认常规档；宽内容弹窗可显式放宽到 [EswDialog.wPanelWide]）。
  final double maxWidth;

  /// 直接指定面板宽度（一般不需要）。
  final double? width;

  @override
  Widget build(BuildContext context) {
    final w = width ??
        EswDialog.panelWidth(
          context,
          minContent: minContent,
          maxWidth: maxWidth,
        );
    return SizedBox(width: w, child: child);
  }
}
