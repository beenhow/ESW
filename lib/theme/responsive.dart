import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// ESW 屏幕自适应等比缩放工具（1.5.8 起查词 / 检测 / 词库三页统一使用）。
///
/// 设计基准：360 × 800dp（主流安卓机竖屏逻辑尺寸）。
/// 缩放系数 = min(可用宽 / 360, 可用高 / 800) × 0.95，并按设备形态微调后
/// clamp 到允许区间。1.5.8 起在原有等比缩放基础上补齐多品牌兼容：
///
///   1. 高度基准改用「扣除系统栏后的可用高度」（viewPadding），
///      挖孔屏 / 三键导航 / 全屏手势条机型的实际可绘制区域差异不再吃掉布局；
///   2. 长条窄屏（19.5:9、20:9、21:9 等）高度富余，改为以宽度为主缩放并
///      轻度放大，避免内容被压扁、上下留大片空白；
///   3. 平板 / 折叠屏展开（最短边 ≥ 600dp）放宽上限并限制内容宽度居中，
///      避免元素被拉伸到失真；
///   4. 系统字号倍率（小米 / 华为 / OPPO 等默认可达 1.15~1.3）参与换算时
///      收窄区间，防止「系统大字体 + 页面缩放」双重放大造成溢出；
///   5. 极小屏（320×480 等）允许缩到 0.72，保证内容不被裁切。
///
/// 用法：
///   1. 页面根部包一层 `EswResponsive.wrap(context, child)`，字号随 scale 缩放，
///      宽屏设备自动限制内容宽度并居中；
///   2. 间距 / 行高 / 图标等显式尺寸用 `EswResponsive.s(context, v)` 或
///      `EswResponsive.factorOf(context)` 相乘，保证与字号同步缩放。
class EswResponsive {
  EswResponsive._();

  /// 设计基准宽（dp）。
  static const double baseWidth = 360;

  /// 设计基准高（dp）。
  static const double baseHeight = 800;

  /// 相对 1.5.7 视觉的整体收紧系数（约缩小 5%）。
  static const double uiScale = 0.95;

  /// 缩放系数下限（极小屏，如 320×480）。
  static const double minScale = 0.72;

  /// 手机缩放系数上限。
  static const double maxPhoneScale = 1.18;

  /// 平板 / 折叠屏展开的缩放系数上限。
  static const double maxTabletScale = 1.45;

  /// 平板 / 折叠屏展开时的内容最大宽度（dp），超出则居中留白。
  static const double tabletContentWidth = 560;

  /// 横屏手机的内容最大宽度（dp）。
  static const double landscapeContentWidth = 520;

  /// 参与系统字号倍率换算的参考字号。
  static const double _refFontSize = 14;

  /// 是否为平板 / 折叠屏展开形态（最短边 ≥ 600dp）。
  static bool isTablet(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return false;
    final size = media.size;
    return math.min(size.width, size.height) >= 600;
  }

  /// 内容最大宽度：宽屏设备限制并居中，手机返回无限（占满）。
  static double contentMaxWidth(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return double.infinity;
    final size = media.size;
    if (size.width <= 0 || size.height <= 0) return double.infinity;
    if (math.min(size.width, size.height) >= 600) return tabletContentWidth;
    if (size.width > size.height) return landscapeContentWidth;
    return double.infinity;
  }

  /// 当前设备的等比缩放系数。
  static double factorOf(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final size = media?.size ?? const Size(baseWidth, baseHeight);
    if (size.width <= 0 || size.height <= 0) return uiScale;

    // 可用高度：扣除状态栏 / 导航栏 / 手势条等系统栏占位，
    // 兼容各品牌不同的系统栏高度与虚拟按键策略。
    final insets = media?.padding ?? EdgeInsets.zero;
    var availHeight = size.height - insets.top - insets.bottom;
    if (availHeight <= 0) availHeight = size.height;

    final widthRatio = size.width / baseWidth;
    final heightRatio = availHeight / baseHeight;
    final aspect = size.width / size.height;

    double scale;
    if (aspect < 0.47) {
      // 长条窄屏（≥19.5:9）：高度富余，按宽度为主并轻度放大，填满可视区域。
      scale = widthRatio * uiScale * 1.05;
    } else {
      scale = math.min(widthRatio, heightRatio) * uiScale;
    }

    final maxScale = isTablet(context) ? maxTabletScale : maxPhoneScale;
    return scale.clamp(minScale, maxScale);
  }

  /// 按缩放系数换算单个尺寸（间距 / 行高 / 图标尺寸等）。
  static double s(BuildContext context, double value) =>
      value * factorOf(context);

  /// 按缩放系数换算四边距（传原始设计值，内部统一乘 scale）。
  static EdgeInsets inset(
    BuildContext context, {
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) {
    final f = factorOf(context);
    return EdgeInsets.fromLTRB(
      left * f,
      top * f,
      right * f,
      bottom * f,
    );
  }

  /// 页面根包裹：字号按 scale 缩放（叠加系统字号设置），
  /// 显式尺寸由调用方用 [s] / [factorOf] 同步缩放；
  /// 宽屏设备在此统一限制内容宽度并居中。
  static Widget wrap(BuildContext context, Widget child) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return child;
    // 保留用户在系统设置里调整的字号倍率，再叠加本页的 scale。
    // 系统倍率收窄到 0.85~1.20：多数国产 ROM 默认 1.15~1.3，
    // 与页面缩放叠加会直接顶爆固定一屏的布局。
    final sysRaw = media.textScaler.scale(_refFontSize) / _refFontSize;
    final sysFactor = sysRaw.clamp(0.85, 1.20);
    final factor = (factorOf(context) * sysFactor).clamp(0.68, 1.90);
    Widget content = MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(factor)),
      child: child,
    );

    final maxWidth = contentMaxWidth(context);
    if (maxWidth.isFinite) {
      content = Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: content,
        ),
      );
    }
    return content;
  }
}
