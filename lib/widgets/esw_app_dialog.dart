import 'package:flutter/material.dart';

import '../theme/esw_tokens.dart';
import '../theme/responsive.dart';

/// Android 端统一弹窗套件（视觉与 Windows 版 dialog_kit 同源，按手机等比缩放）。
///
/// 只承载排版与视觉：圆角面板 + 顶部图标徽标 + 标题/正文层级 + 右对齐按钮区，
/// 全部尺寸随 [EswResponsive] 因子缩放；颜色一律取自 [EswColors]，禁止写 Color 字面量。

/// 弹窗按钮/选项描述。
class EswDialogChoice<T> {
  const EswDialogChoice({
    required this.label,
    required this.value,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final T value;

  /// 主操作（实心主色按钮）。
  final bool primary;

  /// 危险操作（实心红按钮）。
  final bool danger;
}

/// 轻提示弹窗：单个「知道了」按钮。
Future<void> showEswAlert(
  BuildContext context, {
  required String title,
  String? message,
  IconData? icon,
  String okLabel = '知道了',
  bool dismissible = true,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: dismissible,
    barrierColor: _barrier,
    builder: (ctx) => _EswDialogFrame(
      title: title,
      message: message,
      icon: icon,
      actions: [
        _EswDialogButton(
          label: okLabel,
          primary: true,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ],
    ),
  );
}

/// 确认弹窗：左「取消」右主操作，返回 true 表示确认。
Future<bool> showEswConfirm(
  BuildContext context, {
  required String title,
  String? message,
  IconData? icon,
  String cancelLabel = '取消',
  String okLabel = '确定',
  bool danger = false,
  bool dismissible = true,
}) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: dismissible,
    barrierColor: _barrier,
    builder: (ctx) => _EswDialogFrame(
      title: title,
      message: message,
      icon: icon,
      iconDanger: danger,
      actions: [
        _EswDialogButton(
          label: cancelLabel,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        _EswDialogButton(
          label: okLabel,
          primary: true,
          danger: danger,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// 多选项弹窗：返回所选 [EswDialogChoice.value]，取消返回 null。
Future<T?> showEswChoice<T>(
  BuildContext context, {
  required String title,
  String? message,
  IconData? icon,
  required List<EswDialogChoice<T>> choices,
  bool dismissible = true,
}) {
  // 选项文字过长时（如「Word(docx)」「Excel(xlsx)」这类横排放不下的标签）
  // 一律改为纵向满宽，避免按钮内文字被挤压伸缩或截断成省略号。
  final longLabel = choices.any((c) => _labelWidth(c.label) > 5.5);
  final vertical = choices.length > 2 || longLabel;
  return showDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierColor: _barrier,
    builder: (ctx) => _EswDialogFrame(
      title: title,
      message: message,
      icon: icon,
      actionsVertical: vertical,
      actions: [
        for (final c in choices)
          _EswDialogButton(
            label: c.label,
            primary: c.primary,
            danger: c.danger,
            fullWidth: vertical,
            onPressed: () => Navigator.of(ctx).pop(c.value),
          ),
      ],
    ),
  );
}

/// 估算按钮标签的视觉宽度（全角字符按 1、半角按 0.55 计），
/// 用于判断横排等宽按钮是否放得下该标签（超过约 5.5 即视为过长）。
double _labelWidth(String label) {
  var w = 0.0;
  for (final r in label.runes) {
    w += r > 0x2E80 ? 1.0 : 0.55;
  }
  return w;
}

/// 自定义内容弹窗：承载表单/列表/多按钮等复杂内容，排版骨架与其它弹窗一致。
/// [actions] 传入按钮列表（建议 1 个满宽、2 个等宽、3 个及以上纵向堆叠）。
Future<T?> showEswCustom<T>(
  BuildContext context, {
  required String title,
  String? message,
  IconData? icon,
  bool iconDanger = false,
  Widget? content,
  List<Widget> actions = const [],
  bool dismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierColor: _barrier,
    builder: (ctx) => _EswDialogFrame(
      title: title,
      message: message,
      icon: icon,
      iconDanger: iconDanger,
      content: content,
      actions: actions,
    ),
  );
}

/// 弹窗按钮工厂：供 [showEswCustom] 的自定义 actions 复用同一套视觉。
Widget eswDialogAction({
  required String label,
  required VoidCallback? onPressed,
  bool primary = false,
  bool danger = false,
  bool enabled = true,
}) {
  return _EswDialogButton(
    label: label,
    primary: primary,
    danger: danger,
    onPressed: enabled ? onPressed ?? () {} : () {},
    disabled: !enabled,
  );
}

/// 进度弹窗（不可关闭）：标题 + 一行说明 + 细进度条，调用方负责 pop。
Widget eswProgressDialog({required String title, String? message}) {
  return Builder(
    builder: (ctx) {
      final f = EswResponsive.factorOf(ctx);
      return PopScope(
        canPop: false,
        child: _EswDialogFrame(
          title: title,
          message: message,
          icon: Icons.hourglass_top_rounded,
          content: Padding(
            padding: EdgeInsets.only(top: EswSpace.sm * f),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(EswRadius.small * f),
              child: LinearProgressIndicator(
                minHeight: 3 * f,
                backgroundColor: EswColors.primarySoft,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  EswColors.primary,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

final Color _barrier = EswColors.textPrimary.withValues(alpha: 0.32);

/// 面板骨架：居中图标徽标 + 居中标题 + 居中正文 + 对称按钮区。
///
/// 对称规则（手机窄屏视觉一致性的关键）：
///   1. 图标、标题、正文一律水平居中，视觉重心落在面板中轴；
///   2. 两个按钮等宽平分（Expanded），高度、圆角、字号完全一致；
///   3. 单个按钮满宽，三个及以上选项改为纵向满宽堆叠，不出现左右偏移的碎按钮。
class _EswDialogFrame extends StatelessWidget {
  const _EswDialogFrame({
    required this.title,
    this.message,
    this.icon,
    this.iconDanger = false,
    this.content,
    this.actions = const [],
    this.actionsVertical = false,
  });

  final String title;
  final String? message;
  final IconData? icon;
  final bool iconDanger;
  final Widget? content;
  final List<Widget> actions;

  /// 选项多于两个时改为纵向满宽排列，避免横排拥挤、保证左右对称。
  final bool actionsVertical;

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    final accent = iconDanger ? EswColors.red : EswColors.primary;
    final accentSoft = iconDanger
        ? EswColors.red.withValues(alpha: 0.10)
        : EswColors.primarySoft;
    // 按钮排布：1 个满宽；2 个等宽平分；3 个及以上纵向堆叠。
    final vertical = actionsVertical || actions.length > 2;
    // 弹窗在页面 EswResponsive.wrap 之外弹出，系统字号倍率若不收窄，
    // 超大字体（部分 ROM 可到 1.3+）会把按钮文字顶出按钮边界导致看不清。
    // 这里与页面保持同一套收窄区间，保证弹窗内字号同样是「按屏幕缩放后的适度值」。
    final media = MediaQuery.of(context);
    final sysRaw = media.textScaler.scale(14) / 14;
    final scaler = TextScaler.linear(sysRaw.clamp(0.85, 1.20));
    return MediaQuery(
      data: media.copyWith(textScaler: scaler),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
        ),
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: EdgeInsets.symmetric(horizontal: 32 * f),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 322 * f, minWidth: 0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: EswColors.card,
                borderRadius: BorderRadius.circular(EswRadius.card * f),
                boxShadow: EswShadow.card,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  EswSpace.xl * f,
                  EswSpace.xl * f,
                  EswSpace.xl * f,
                  EswSpace.lg * f,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (icon != null) ...[
                      Center(
                        child: Container(
                          width: 52 * f,
                          height: 52 * f,
                          decoration: BoxDecoration(
                            color: accentSoft,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, size: 26 * f, color: accent),
                        ),
                      ),
                      SizedBox(height: EswSpace.md * f),
                    ],
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: EswText.titleSmall.copyWith(
                        fontSize: 17 * f,
                        fontWeight: FontWeight.w700,
                        color: EswColors.textPrimary,
                        height: 1.32,
                      ),
                    ),
                    if (message != null && message!.isNotEmpty) ...[
                      SizedBox(height: EswSpace.sm * f),
                      Text(
                        message!,
                        textAlign: TextAlign.center,
                        style: EswText.bodySmall.copyWith(
                          fontSize: 13 * f,
                          height: 1.68,
                          color: EswColors.textSecondary,
                        ),
                      ),
                    ],
                    if (content != null) content!,
                    if (actions.isNotEmpty) ...[
                      SizedBox(height: EswSpace.lg * f),
                      if (vertical)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < actions.length; i++) ...[
                              if (i > 0) SizedBox(height: EswSpace.sm * f),
                              actions[i],
                            ],
                          ],
                        )
                      else
                        Row(
                          // 高度必须由按钮自己决定：Dialog 内容纵向不受限，
                          // 若用 stretch 会把无限高传给按钮，触发布局断言。
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            for (var i = 0; i < actions.length; i++) ...[
                              if (i > 0) SizedBox(width: EswSpace.sm * f),
                              Expanded(child: actions[i]),
                            ],
                          ],
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹窗按钮：primary 为实心主色（危险操作为红），其余为浅灰底次级按钮。
///
/// 两种按钮同高同圆角，横排时等宽平分，保证左右完全对称。
class _EswDialogButton extends StatelessWidget {
  const _EswDialogButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
    this.fullWidth = false,
    this.disabled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool danger;
  final bool fullWidth;

  /// 禁用态（如「测试连接」进行中），保持同尺寸同排版，仅降低不透明度。
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    final h = 46 * f;
    final radius = BorderRadius.circular(EswRadius.control * f);
    final textStyle = EswText.label.copyWith(
      fontSize: 14.5 * f,
      fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
      height: 1.2,
    );
    final Widget child = FittedBox(
      // 文字按按钮可用宽度等比缩放，绝不横向溢出、绝不省略截断；
      // 配合「长标签自动纵向满宽」，任何屏幕/字号下按钮文字都完整可读。
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        softWrap: false,
        style: textStyle,
      ),
    );
    final button = SizedBox(
      width: fullWidth ? double.infinity : null,
      height: h,
      child: primary
          ? FilledButton(
              onPressed: disabled ? null : onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: danger ? EswColors.red : EswColors.primary,
                foregroundColor: EswColors.card,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: EswSpace.md * f),
                shape: RoundedRectangleBorder(borderRadius: radius),
                textStyle: textStyle,
              ),
              child: child,
            )
          : TextButton(
              onPressed: disabled ? null : onPressed,
              style: TextButton.styleFrom(
                backgroundColor: EswColors.page,
                foregroundColor: EswColors.textSecondary,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: EswSpace.md * f),
                shape: RoundedRectangleBorder(borderRadius: radius),
                textStyle: textStyle,
              ),
              child: child,
            ),
    );
    // 禁用态保持同尺寸同排版，仅整体降透明度，避免按钮跳动。
    return disabled ? Opacity(opacity: 0.5, child: button) : button;
  }
}
