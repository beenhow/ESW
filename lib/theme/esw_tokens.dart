import 'package:flutter/material.dart';

/// ESW 设计令牌（唯一颜色 / 圆角 / 间距 / 字号 / 阴影来源）。
///
/// 硬约束：全项目只允许使用本文件 EswColors 定义的颜色；
/// 圆角走 EswRadius、间距走 EswSpace（4 的倍数）、字号字重走 EswText、
/// 阴影走 EswShadow。除本文件外禁止再写 `Color(0xFF...)`、`fontSize:`,
/// `BorderRadius.circular(` 字面量。
class EswColors {
  EswColors._();

  // ---- 品牌 / 中性色 ----
  static const Color primary = Color(0xFF2F5DA8); // 主色
  static const Color primarySoft = Color(0xFFE8EFFA); // 主字浅底
  static const Color page = Color(0xFFF6F7F9); // 页面底色
  static const Color card = Color(0xFFFFFFFF); // 卡片
  static const Color textPrimary = Color(0xFF1B1B1F); // 正文
  static const Color textSecondary = Color(0xFF9A9AA8); // 辅助
  static const Color ink3 = Color(0xFF9C9C9C); // 底部导航未选中灰
  static const Color border = Color(0xFFE8EFFA); // 1px 浅线

  // ---- 语义色 ----
  static const Color blue = Color(0xFF4A7CFF);
  static const Color green = Color(0xFF38C17D);
  static const Color orange = Color(0xFFFF9F1C);
  static const Color red = Color(0xFFFF4D4F);
  static const Color grey = Color(0xFF9C9C9C);
}

/// 圆角梯度：卡片 20 / 按钮、输入框 14 / 小元件 10。
class EswRadius {
  EswRadius._();

  static const double card = 20;
  static const double control = 14;
  static const double small = 10;
}

/// 间距（4 的倍数）。
class EswSpace {
  EswSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double xxxxl = 40;
}

/// 字号 / 字重规范。组件中如需改色请用 `copyWith(color: ...)`，
/// 不得新增 `fontSize` 字面量。
class EswText {
  EswText._();

  static const TextStyle display = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w700,
    height: 1.2,
  );
  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const TextStyle titleSmall = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );
  static const TextStyle bodyMedium = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );
  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );
  static const TextStyle label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
  static const TextStyle chip = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const TextStyle unit = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );
}

/// 阴影规范：卡片轻投影 / 主按钮主色投影 / 输入框聚焦光晕。
class EswShadow {
  EswShadow._();

  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x121B1B1F),
      blurRadius: 12,
      offset: Offset(0, 2),
    ),
  ];
  static const List<BoxShadow> button = [
    BoxShadow(
      color: Color(0x332F5DA8),
      blurRadius: 16,
      offset: Offset(0, 6),
    ),
  ];
  static const List<BoxShadow> glow = [
    BoxShadow(
      color: Color(0x332F5DA8),
      blurRadius: 14,
      spreadRadius: 2,
    ),
  ];
}
