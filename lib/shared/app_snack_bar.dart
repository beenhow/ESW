import 'package:flutter/material.dart';
import '../theme/esw_tokens.dart';

/// 统一精致提示条（SnackBar）：浮动圆角、三态（主题色/成功绿/失败红）、带图标。
enum AppSnackBarType { info, success, error }

/// 全局统一提示条。替代各处默认样式 SnackBar（业务弹窗保留 AlertDialog）。
/// 由 android_app.dart 迁出共享，供 word_bank_page 等页面复用，避免循环 import。
void showAppSnackBar(
  BuildContext context,
  String message, {
  AppSnackBarType type = AppSnackBarType.info,
  Duration? duration,
}) {
  final (bg, fg, icon) = switch (type) {
    AppSnackBarType.success => (
        EswColors.green,
        Colors.white,
        Icons.check_circle_outline,
      ),
    AppSnackBarType.error => (
        EswColors.red,
        Colors.white,
        Icons.error_outline,
      ),
    AppSnackBarType.info => (
        EswColors.primary,
        Colors.white,
        Icons.info_outline,
      ),
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: bg,
        elevation: 4,
        margin: const EdgeInsets.all(EswSpace.lg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EswRadius.card),
        ),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fg, size: 20),
            const SizedBox(width: EswSpace.sm),
            Flexible(
              child: Text(
                message,
                style: EswText.body.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        duration: duration ??
            (type == AppSnackBarType.error
                ? const Duration(seconds: 4)
                : const Duration(seconds: 2)),
      ),
    );
}
