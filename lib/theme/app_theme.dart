import 'package:flutter/material.dart';

/// ESW 应用统一主题常量
class AppTheme {
  AppTheme._();

  // ── 主色系（现代柔和配色，教育场景低刺激） ──
  static const primaryBlue = Color(0xFF2F6BDF);
  static const primaryYellow = Color(0xFFF5A800);
  static const orange = Color(0xFFE8590C);
  static const green = Color(0xFF2F9E44);
  static const red = Color(0xFFE03131);
  static const grey = Color(0xFF6B7280);
  static const lightBlue = Color(0xFF74C0FC);
  static const teal = Color(0xFF12B886);
  static const purple = Color(0xFF7048E8);

  // ── 表面/背景色 (层级: lightest → lighter → light，中性蓝灰系) ──
  static const surfaceLightest = Color(0xFFF8FAFC);
  static const surfaceLighter = Color(0xFFF2F5F9);
  static const surfaceLight = Color(0xFFEBF0F6);

  // ── 边框色 ──
  static const borderLight = Color(0xFFE3E7EE);
  static const borderLighter = Color(0xFFEDF0F5);

  // ── 文本色 ──
  static const textPrimary = Color(0xFF1F2937);
  static const textSecondary = Color(0xFF4B5563);
  static const textHint = Color(0xFF98A2B3);
  static const textDisabled = Color(0xFFCBD2D9);

  // ── 间距体系 ──
  static const double spacingXs = 4;
  static const double spacingSm = 8;
  static const double spacingMd = 12;
  static const double spacingLg = 16;
  static const double spacingXl = 20;

  // ── 字体层级 ──
  static const double fontSizeCaption = 10;
  static const double fontSizeBodySmall = 11;
  static const double fontSizeBody = 13;
  static const double fontSizeBodyLarge = 14;
  static const double fontSizeTitle = 16;

  // ── 圆角 ──
  static const double radiusSm = 8;
  static const double radiusMd = 10;
  static const double radiusLg = 14;
  static const double radiusXl = 24;

  // ── 阴影 ──
  static const BoxShadow shadowLight = BoxShadow(
    color: Color(0x0A000000),
    blurRadius: 6,
    offset: Offset(0, 2),
  );
  static const BoxShadow shadowMedium = BoxShadow(
    color: Color(0x12000000),
    blurRadius: 10,
    offset: Offset(0, 3),
  );
}
