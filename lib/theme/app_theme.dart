import 'package:flutter/material.dart';

/// ESW 应用统一主题常量
class AppTheme {
  AppTheme._();

  // ── 主色系 ──
  static const primaryBlue = Color(0xFF1565C0);
  static const orange = Color(0xFFE65100);
  static const green = Color(0xFF2E7D32);
  static const red = Color(0xFFD32F2F);
  static const grey = Color(0xFF757575);
  static const lightBlue = Color(0xFF42A5F5);
  static const teal = Color(0xFF00897B);
  static const purple = Color(0xFF6A1B9A);

  // ── 表面/背景色 (层级: lightest → lighter → light) ──
  static const surfaceLightest = Color(0xFFFCFCFD);
  static const surfaceLighter = Color(0xFFF8F9FB);
  static const surfaceLight = Color(0xFFF5F6F8);

  // ── 边框色 ──
  static const borderLight = Color(0xFFDEE2E6);
  static const borderLighter = Color(0xFFE8E8EC);

  // ── 文本色 ──
  static const textPrimary = Color(0xFF212121);
  static const textSecondary = Color(0xFF555555);
  static const textHint = Color(0xFF888888);
  static const textDisabled = Color(0xFFBDBDBD);

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
  static const double radiusSm = 6;
  static const double radiusMd = 8;
  static const double radiusLg = 12;
  static const double radiusXl = 20;

  // ── 阴影 ──
  static const BoxShadow shadowLight = BoxShadow(
    color: Color(0x0A000000),
    blurRadius: 4,
    offset: Offset(0, 2),
  );
  static const BoxShadow shadowMedium = BoxShadow(
    color: Color(0x14000000),
    blurRadius: 8,
    offset: Offset(0, 2),
  );
}
