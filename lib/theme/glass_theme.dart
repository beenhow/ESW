import 'package:flutter/material.dart';
import 'dart:ui' show FontFeature, ImageFilter;

// ════════════════════════════════════════════════════════════════════
// 间距刻度常量 —— 规范 §4.9「间距总表」的唯一权威定义处
// 声明位置与取值范围与 esw-ui-flutter骨架.dart 顶部完全一致：
// 全站所有 SizedBox / Padding / EdgeInsets / Wrap.spacing 只准引用下列常量，
// 严禁再出现自造的裸数值。
//   主刻度五级：kGap4 / kGap8 / kGap12 / kGap16 / kGap20
//     ├─ 区块间    12（弹窗内各选项组之间 18）
//     ├─ 组件间     8（统计卡之间 12）
//     ├─ 元素间     4（§4.9 明列细分见下）
//     └─ 面板内边距 16 / 20
// ════════════════════════════════════════════════════════════════════

/// 元素间间距（§4.9 元素级）
const double kGap4 = 4.0;

/// 组件间间距（§4.9 组件级）
const double kGap8 = 8.0;

/// 区块间距（§4.9 布局级）
const double kGap12 = 12.0;

/// 面板内边距（§4.9 面板级）
const double kGap16 = 16.0;

/// 面板内边距（宽侧，§4.9 面板级）
const double kGap20 = 20.0;

// ── §4.9 间距总表明列的元素级细分刻度（必须引用，不得写成裸数值） ──
const double kGap1 = 1.0; // 文件列表项之间
const double kGap6 = 6.0; // 年份格之间（横向与纵向）、计数胶囊↔标题/＋号
const double kGap7 = 7.0; // 图标与文字
const double kGap9 = 9.0; // 统计卡标签行→大数字

// ── §4.9 间距总表明列的组件级/弹窗例外刻度 ──
const double kGap10 = 10.0; // 卡片标题行→列表首行、弹窗双按钮之间
const double kGap18 = 18.0; // 弹窗内各选项组之间
const double kGap13 = 13.0; // 工具栏按钮与筛选胶囊水平内衬（第二关遗留补常量）


/// ESW 玻璃透镜设计令牌与可复用玻璃组件
/// 设计规范：ESW「真题课标词」UI 玻璃透镜改版设计规范.md
class GlassTheme {
  GlassTheme._();

  // ── 颜色令牌 ──
  static const Color bg = Color(0xFFFAFAFA); // 窗口基色（规范 #FAFAFA）
  static const Color panel = Color(0x94FFFFFF); // 玻璃面板底色 rgba(255,255,255,0.58)
  static const Color panelSolid = Color(0xB8FFFFFF); // 输入框等局部 rgba(255,255,255,0.72)
  static const Color line = Color(0x1418181B); // 描边 rgba(24,24,27,0.08)（规范 §3.1）
  static const Color lineHi = Color(0xBFFFFFFF); // 顶部高光 rgba(255,255,255,0.75)
  static const Color ink = Color(0xFF18181B); // 主文字
  static const Color ink2 = Color(0xFF71717A); // 次级文字
  static const Color ink3 = Color(0xFFA1A1AA); // 弱化文字
  static const Color accent = Color(0xFF4462F2); // 唯一强调色（靛蓝，规范 1.1）
  static const Color accentInk = Color(0xFF3348CF); // 强调色深版（hover/选中文字）
  static const Color accentSoft = Color(0x174462F2); // 选中态底色 rgba(68,98,242,0.09)
  static const Color violet = Color(0xFF8B5CF6); // 渐变副色
  static const Color green = Color(0xFF22C55E); // 同步状态绿点

  /// 主渐变（按钮 / 选中胶囊 / logo / 版本徽标），120deg ≈ 左上偏下→右下偏上
  static const LinearGradient grad = LinearGradient(
    begin: Alignment(-0.866, -0.5),
    end: Alignment(0.866, 0.5),
    colors: [accent, violet],
  );

  // ── 字号层级（全站仅 5 档） ──
  static const double fMicro = 11; // 表头、徽标
  static const double fSmall = 12; // 胶囊、辅助说明
  static const double fBody = 12.5; // 列表项、按钮
  static const double fInput = 13; // 输入框
  static const double fNum = 24; // 统计大数字

  // ── 圆角 ──
  // 基准来源：主界面设计示意图逐板块量取（角区四角内缩法，示意图与应用 1:1 对应——
  // 守卫测试锁定的 side w248 / 左栏分隔线 x268 与示意图实测完全一致）。
  //   玻璃面板/大卡/年份格/结果面板 四角内缩 8 -> r=8
  //   统计卡 8.2 / 次按钮 8.5 -> r=8
  //   搜索输入框四角内缩 5~6 -> r=6（示意图中输入框明显比卡片"方"）
  // 结论：卡片/面板/按钮统一 r8（原 rXl=12 明显大于示意图，rLg=10 亦偏大），
  //       输入框与小徽标保持 r6。
  // V8 复查：用户反馈"整体圆角偏小"，在全站统一的基础上整体上调 2px，
  //   面板/大卡/按钮/中卡统一 r10，输入框与小徽标 r8（保持"更方一点"的层级差）。
  static const double rSm = 8; // 小徽标/标签/搜索输入框
  static const double rMd = 10; // 中卡/年份格/列表行/chip
  static const double rLg = 10; // 按钮
  // 第三关 ②：面板圆角回到 12（规范 §1.2 玻璃配方 border-radius:12px、
  // esw-ui-flutter骨架.dart GlassPanel 默认 radius: 12）。按钮/年份格/列表行仍为 r10，
  // 保持“面板 > 控件”的圆角层级。
  static const double rXl = 12; // 玻璃面板/大卡/统计卡

  // ── 间距刻度 ──
  // 统一指向文件顶部的 kGap 常量（规范 §4.9 唯一定义处），
  // s* 仅为历史调用点的别名，保证全站只有一套间距刻度。
  static const double s4 = kGap4;
  static const double s8 = kGap8;
  static const double s12 = kGap12;
  static const double s16 = kGap16;
  static const double s20 = kGap20;

  // ── 窗口自适应缩放（任务②：各板块 / 文字 / 按钮随窗口大小自动缩放） ──
  /// 设计基准窗口尺寸 = 主界面示意图 1:1 量取时的窗口，也是程序默认启动尺寸。
  /// 窗口 ≥ 基准时不放大（保持 1:1 版式与结构守卫断言的绝对尺寸）。
  static const Size baseWindow = Size(1200, 680);

  /// 缩放下限：窗口小于 900×600（window_manager 最小窗口尺寸）时不再继续收缩，
  /// 避免文字小到不可读。
  static const double minScale = 0.75;

  /// 当前缩放系数（1.0 = 设计基准尺寸）。
  static double uiScale = 1.0;

  /// 依据窗口逻辑尺寸刷新缩放系数，返回是否发生变化。
  static bool updateUiScale(Size size) {
    if (size.width <= 0 || size.height <= 0) return false;
    final byW = size.width / baseWindow.width;
    final byH = size.height / baseWindow.height;
    var v = byW < byH ? byW : byH;
    if (v > 1.0) v = 1.0;
    if (v < minScale) v = minScale;
    if ((v - uiScale).abs() < 0.005) return false;
    uiScale = v;
    return true;
  }

  /// 布局尺寸随窗口缩放（设计尺寸 → 当前窗口尺寸）。
  static double dp(double v) => v * uiScale;

  // ── 组件高度（随窗口自适应缩放） ──
  static double get hListItem => dp(32);
  static double get hToolBtn => dp(32);
  static double get hSearchBtn => dp(40);
  static double get hChip => dp(28);
  // 布局骨架尺寸（规范 6.2）：④-1 搜索行 40 / ④-2 统计卡 72 / ④-3 筛选行 30 /
  // ④-4 词频面板 146 / ④-5 结果表表头 38
  // 与示意图 1:1 实测一致（示意图：搜索行 38 / 统计卡 72 / 筛选项行 26 /
  // 年份面板 149 / 表头 37）；基准窗口下取值不变，窗口变小时按比例收缩。
  static double get hSearchRow => dp(40);
  static double get hStatCard => dp(72);
  static double get hFilterRow => dp(30);
  static double get hWordPanel => dp(146);
  static double get hTableHeader => dp(38);
  static double get hHeader => dp(38);
  static double get hTitleBar => dp(42);
  static double get hToolbar => dp(44);
}

/// 窗口最底层柔光背景（让玻璃"有东西可透"）
class GlowBackground extends StatelessWidget {
  const GlowBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: GlassTheme.bg),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const IgnorePointer(child: CustomPaint(painter: _GlowPainter())),
          child,
        ],
      ),
    );
  }
}

/// 条带区域的确定性柔光底层：把「整窗柔光在 [offsetY] 处的同一段像素」直接
/// 画进条带自身，并给条带套一层独立 [RepaintBoundary]。
///
/// 为什么需要：标题栏/工具栏原本是「透明 Container 叠在整窗 GlowBackground 之上」。
/// 一旦某一帧只重绘了条带这块脏区（主线程长任务导致的掉帧后局部重绘、系统保存
/// 对话框弹出/关闭引起的区域刷新），条带下方并没有柔光，直接露出 Scaffold 的
/// 纯色底，于是顶栏出现一条与下方界面明显不同的横向色带，看起来像界面被切开。
/// 这里让条带自身携带与背景逐像素同源的柔光（同一 _GlowPainter、同一窗口尺寸、
/// 按 offsetY 平移），条带无论重绘多少次、被单独重绘多少遍，都与整窗背景一致。
class GlowBand extends StatelessWidget {
  const GlowBand({super.key, required this.offsetY, required this.child});

  /// 条带顶端在整窗坐标系中的 y 偏移（标题栏 = 0，工具栏 = 标题栏高度）。
  final double offsetY;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final windowSize = MediaQuery.sizeOf(context);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: GlowBandPainter(
                  offsetY: offsetY,
                  windowSize: windowSize,
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// [GlowBand] 的绘制器：先铺 [GlassTheme.bg] 底色，再把整窗柔光按 [offsetY]
/// 平移后裁剪绘制 —— 像素结果与 [GlowBackground] 同源，条带与背景无缝相接。
class GlowBandPainter extends CustomPainter {
  const GlowBandPainter({required this.offsetY, required this.windowSize});

  final double offsetY;
  final Size windowSize;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = GlassTheme.bg);
    canvas.save();
    canvas.clipRect(rect);
    canvas.translate(0, -offsetY);
    const _GlowPainter().paint(canvas, windowSize);
    canvas.restore();
  }

  @override
  bool shouldRepaint(GlowBandPainter oldDelegate) =>
      oldDelegate.offsetY != offsetY || oldDelegate.windowSize != windowSize;
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter();

  /// 柔光层 = 参考稿 esw-ui-高级感精修版v3-对齐精修.html 的 .window background-image，
  /// 并与对照骨架 esw-ui-flutter骨架.dart 的 _Window 五团 _Glow 逐项对齐：
  /// 左上靛蓝 .30 / 780 ・ 右上紫 .26 / 820 ・ 右下青绿 .22 / 660 ・
  /// 左下暖橙 .18 / 560 ・ 中上靛蓝 .08 / 500。
  /// 第三轮清单第 8 项：透明度 .18~.30、直径 ≥600，窗口四角必须都能明显看到颜色
  /// （骨架注释：「透明度必须 ≥ .18：柔光不可见 = 玻璃不可见」）。
  /// 定位换算自骨架的 Positioned（top/bottom/left/right 负偏移），按 1280×720 基准
  /// 折算为「圆心宽高百分比 + px 偏移」，保证窗口缩放时四角光团仍贴角。
  /// 尺寸取骨架 size 作为光斑直径（半径 = size/2），透明度取骨架 opacity 原值。
  static const List<_GlowSpec> _glows = <_GlowSpec>[
    // 左上靛蓝：骨架 _Glow(kAccent, .30, 780)，圆心外移贴左上角保证角部可见
    _GlowSpec(0.1600, 0.1800, 0, 470, 470, Color(0x4D4462F2), 1.0),
    // 右上紫：骨架 _Glow(kViolet, .26, 820)
    _GlowSpec(0.8400, 0.2000, 0, 480, 480, Color(0x428B5CF6), 1.0),
    // 右下青绿：骨架 _Glow(#0EA5A4, .22, 660)，直径提到 800 保证右下角可见。
    // 第三轮清单第 15 项：透明度 .22 → .17（0x2B），圆心沿右下对角再外推约 42px
    //（水平 / 垂直各 +30），让柔光回到"隐约氛围"，不再被读成一块色块。
    _GlowSpec(0.8400, 0.8200, 30, 400, 400, Color(0x2B0EA5A4), 1.0,
        cxOffsetPx: 30),
    // 左下暖橙：骨架 _Glow(kAmber, .18, 560)，直径提到 800 保证左下角可见
    _GlowSpec(0.1600, 0.8400, 0, 400, 400, Color(0x2EF59E0B), 1.0),
    // 中上靛蓝：骨架 _Glow(kAccent, .08, 500)，弱补偿光，保持原样
    _GlowSpec(0.4920, 0.4600, 0, 250, 250, Color(0x144462F2), 1.0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 环境底光：ref_html.png 实测该窗口十点 B-R 均落在 2~3.5 的冷偏基线上，
    // 而 5 团椭圆只压住四个角、窗口中部为零，故补一层覆盖全窗的极淡冷光对齐基线。
    _paintAmbient(canvas, rect);
    // 与 CSS 多背景层叠顺序一致：先声明的在上层，故倒序绘制。
    for (final g in _glows.reversed) {
      _paintGlow(
        canvas,
        rect,
        Offset(size.width * g.cxPct + g.cxOffsetPx,
            size.height * g.cyPct + g.cyOffsetPx),
        Size(g.rx * 2, g.ry * 2),
        g.color,
        g.stop,
      );
    }
  }

  /// 覆盖全窗的环境底光：近均匀铺底（渐变半径 1.8x 短边，94% 起淡出）避免硬边
  void _paintAmbient(Canvas canvas, Rect rect) {
    final paint = Paint()
      ..shader = const RadialGradient(
        radius: 1.8,
        colors: [
          Color(0x113C3C7B),
          Color(0x113C3C7B),
          Color(0x003C3C7B),
        ],
        stops: <double>[0, 0.94, 1],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  /// center 为该光团圆心（允许落在窗口边界之外），radius 为渐变椭圆外接矩形
  void _paintGlow(Canvas canvas, Rect rect, Offset center, Size radius,
      Color color, double stop) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
        stops: <double>[0, stop],
      ).createShader(
        Rect.fromCenter(center: center, width: radius.width, height: radius.height),
      );
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 单团柔光规格：圆心百分比定位 + px 偏移，rx/ry 为椭圆水平/垂直半径
class _GlowSpec {
  const _GlowSpec(this.cxPct, this.cyPct, this.cyOffsetPx, this.rx, this.ry,
      this.color, this.stop,
      {this.cxOffsetPx = 0});

  final double cxPct;
  final double cyPct;
  final double cyOffsetPx;

  /// 圆心水平方向的额外像素偏移（正数向右），用于把光团沿对角线再往外推。
  final double cxOffsetPx;
  final double rx;
  final double ry;
  final Color color;
  final double stop;
}

/// 玻璃模糊层 —— `BackdropFilter` 的可降级替代（任务④ 运行速度）。
///
/// 背景模糊是这套 UI 里最贵的一次光栅操作：每块 `BackdropFilter` 都要
/// `saveLayer` 一次，再对整个面板区域做高斯采样；窗口越大、面板越多、
/// 叠得越厚，每帧代价越高。而本应用的背景是「近白柔光渐变」（基色 #FAFAFA
/// + 极淡冷光团），面板底色又是 0x94 / 0xB8 这种高不透明度白，
/// 底下几乎看不出模糊与不模糊的区别，却要为此付出成倍的光栅耗时。
///
/// 故大面板（标题栏 / 工具栏 / 结果表 / 统计卡 / 弹窗遮罩）统一改走本组件：
/// 关闭模糊后颜色、描边、顶部高光、圆角完全不变，只是不再对背景做模糊采样。
/// 需要真玻璃观感的小面板可保留 `enabled: true`。
class FrostFilter extends StatelessWidget {
  const FrostFilter({
    super.key,
    required this.filter,
    required this.child,
    this.enabled = true,
  });

  /// 全局总开关：默认开启模糊；启动时可由环境变量 `ESW_NO_BLUR=1` 整体关闭，
  /// 用于性能 A/B 对比（不影响任何业务逻辑）。
  static bool blurOn = true;

  /// 模糊滤镜（与 `BackdropFilter.filter` 语义一致）
  final ImageFilter filter;

  final Widget child;

  /// 单点开关：false 表示该处不做背景模糊（视觉近似）。与全局开关取与。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || !blurOn) return child;
    return BackdropFilter(filter: filter, child: child);
  }
}

/// 玻璃面板：半透明白底 + 背景模糊 + 顶部 1px 内高光 + 透明描边 + 轻落影
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = GlassTheme.rXl,
    this.color = GlassTheme.panel,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.borderColor = GlassTheme.line,
    this.sigma = 20,
    this.shrinkWrap = false,
  });

  final Widget child;
  final double radius;
  final Color color;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color borderColor;
  final double sigma;

  /// 第三关 ③：true 时面板尺寸由内容决定（用于弹窗玻璃面板，避免在
  /// 宽松约束下被 Stack 撑满整屏）。默认 false，主界面面板行为不变。
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(color: Color(0x0D18181B), blurRadius: 2, offset: Offset(0, 1)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        // 任务④（运行速度）：sigma<=0 视为「不做模糊」，此时不产生 saveLayer
        child: FrostFilter(
          enabled: sigma > 0,
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: borderColor),
            ),
            child: Stack(
              children: [
                // 第三关 ③：shrinkWrap 时用普通 child 决定 Stack 尺寸（弹窗收紧到内容），
                // 否则沿用 Positioned.fill 让面板铺满父约束（主界面面板行为）。
                if (shrinkWrap)
                  Padding(padding: padding, child: child)
                else
                  Positioned.fill(
                    child: Padding(padding: padding, child: child),
                  ),
                // 顶部 1px 白色内高光（玻璃的灵魂），覆盖在内容最上层
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 1,
                    color: GlassTheme.lineHi,
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

/// 玻璃按钮（幽灵按钮）：无边框透明底，hover 时强调色浅底 + 深版文字（规范 2.2）
class GlassGhostButton extends StatefulWidget {
  const GlassGhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  /// 按钮高度；为空时按当前窗口缩放系数取 GlassTheme.hToolBtn/hSearchBtn。
  final double? height;

  @override
  State<GlassGhostButton> createState() => _GlassGhostButtonState();
}

class _GlassGhostButtonState extends State<GlassGhostButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
    // 任务④（运行速度）：hover 态小按钮 -> 独立图层，避免 hover/按压牵动整窗重绘
Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;
    return RepaintBoundary(child: Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: enabled
          ? (_) => setState(() => _pressed = true)
          : null,
      onPointerUp: enabled
          ? (_) => setState(() => _pressed = false)
          : null,
      onPointerCancel: enabled
          ? (_) => setState(() => _pressed = false)
          : null,
      child: AnimatedScale(
        scale: _pressed && enabled ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: enabled ? widget.onPressed : null,
            child: Container(
          height: widget.height ?? GlassTheme.hToolBtn,
          padding: const EdgeInsets.symmetric(horizontal: GlassTheme.s12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(GlassTheme.rLg),
            color: (_pressed && enabled)
                ? const Color(0x294462F2) // rgba(68,98,242,0.16) 按压底色加深（第三关 ⑤）
                : (hovered
                      ? GlassTheme.accentSoft
                      : const Color(0x8CFFFFFF)), // rgba(255,255,255,0.55) 玻璃底
            border: Border.all(color: GlassTheme.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D18181B), // rgba(24,24,27,0.05) 极轻落影
                blurRadius: 2,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(
                      widget.icon,
                      size: 14,
                      color: hovered ? GlassTheme.accentInk : GlassTheme.ink2,
                    ),
                    const SizedBox(width: kGap7),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: GlassTheme.fBody,
                      color: hovered ? GlassTheme.accentInk : GlassTheme.ink2,
                      height: 1,
                    ),
                  ),
                ],
              ),
              // 顶部内高光 rgba(255,255,255,0.7)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    color: const Color(0xB3FFFFFF),
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
        ),
      ),
    ));
  }
}

/// 主渐变按钮（搜索行导出按钮 / 主操作）
class GlassGradientButton extends StatefulWidget {
  const GlassGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  /// 按钮高度；为空时按当前窗口缩放系数取 GlassTheme.hToolBtn/hSearchBtn。
  final double? height;

  /// 按压时加深渐变（两色各乘 0.94）
  static const LinearGradient gradPressed = LinearGradient(
    begin: Alignment(-0.866, -0.5),
    end: Alignment(0.866, 0.5),
    colors: [Color(0xFF405CE4), Color(0xFF8357E7)],
  );

  /// 悬停时轻微提亮渐变（两色各乘 1.04，与 gradPressed 的 0.94 对应；第三关 ⑤）
  static const LinearGradient gradHover = LinearGradient(
    begin: Alignment(-0.866, -0.5),
    end: Alignment(0.866, 0.5),
    colors: [Color(0xFF4766FC), Color(0xFF9160FF)],
  );

  @override
  State<GlassGradientButton> createState() => _GlassGradientButtonState();
}

class _GlassGradientButtonState extends State<GlassGradientButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
    // 任务④（运行速度）：渐变主按钮 -> 独立图层，避免 hover/按压牵动整窗重绘
Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return RepaintBoundary(child: Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: enabled
          ? (_) => setState(() => _pressed = true)
          : null,
      onPointerUp: enabled
          ? (_) => setState(() => _pressed = false)
          : null,
      onPointerCancel: enabled
          ? (_) => setState(() => _pressed = false)
          : null,
      child: AnimatedScale(
        scale: _pressed && enabled ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: MouseRegion(
          cursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
          onExit: enabled ? (_) => setState(() => _hovered = false) : null,
          child: Container(
          height: widget.height ?? GlassTheme.hSearchBtn,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(GlassTheme.rLg),
            gradient: enabled
                ? (_pressed
                      ? GlassGradientButton.gradPressed
                      : (_hovered
                            ? GlassGradientButton.gradHover
                            : GlassTheme.grad))
                : null,
            color: enabled ? null : GlassTheme.ink3.withValues(alpha: 0.4),
            boxShadow: enabled
                ? const [
                    BoxShadow(
                      color: Color(0x523F3FEB), // rgba(80,80,235,0.32) 主按钮投影
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(GlassTheme.rLg),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: enabled ? widget.onPressed : null,
                    borderRadius: BorderRadius.circular(GlassTheme.rLg),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: GlassTheme.s16),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, size: 16, color: Colors.white),
                            const SizedBox(width: kGap7),
                          ],
                          Text(
                            widget.label,
                            style: const TextStyle(
                              fontSize: GlassTheme.fBody,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // inset 顶部高光 rgba(255,255,255,0.25)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Container(
                      height: 1,
                      color: const Color(0x40FFFFFF),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
          ),
      ),
    ));
  }
}

/// 玻璃矩形按钮（标题栏/工具栏次操作）：玻璃描边矩形 + 顶部内高光 + 极轻投影，
/// hover 时 accent-soft 底 + #C7D2FE 边 + accent-ink 字（对应规范 2.2 / 6.1）
class GlassToolButton extends StatefulWidget {
  const GlassToolButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height,
    this.iconSize = 14,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  /// 按钮高度；为空时按当前窗口缩放系数取 GlassTheme.hToolBtn/hSearchBtn。
  final double? height;
  final double iconSize;

  @override
  State<GlassToolButton> createState() => _GlassToolButtonState();
}

class _GlassToolButtonState extends State<GlassToolButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
    // 任务④（运行速度）：工具栏按钮 -> 独立图层，避免 hover/按压牵动整窗重绘
Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;
    return RepaintBoundary(child: Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: enabled
          ? (_) => setState(() => _pressed = true)
          : null,
      onPointerUp: enabled
          ? (_) => setState(() => _pressed = false)
          : null,
      onPointerCancel: enabled
          ? (_) => setState(() => _pressed = false)
          : null,
      child: AnimatedScale(
        scale: _pressed && enabled ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          // 修复：原实现只做了按下缩放视觉反馈，未把 onPressed 接入点击手势，
          // 导致工具栏“使用说明/同步词库/导出高频”点击无反应。与 GlassChip/GlassGhostButton 对齐补上点击手势。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? widget.onPressed : null,
            child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: widget.height ?? GlassTheme.hToolBtn,
        padding: const EdgeInsets.symmetric(horizontal: kGap13), // 第二关遗留：水平内衬 12→13（规范 §4.9）
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(GlassTheme.rMd),
          color: (_pressed && enabled)
              ? const Color(0x294462F2) // rgba(68,98,242,0.16) 按压底色加深（第三关 ⑤）
              : (hovered
                    ? GlassTheme.accentSoft
                    : const Color(0x8CFFFFFF)), // rgba(255,255,255,0.55) 玻璃底（规范 2.2）
          border: Border.all(
            color: hovered ? const Color(0xFFC7D2FE) : GlassTheme.line,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0D18181B), // rgba(24,24,27,0.05) 极轻落影
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: widget.iconSize,
                    color: hovered ? GlassTheme.accentInk : GlassTheme.ink2,
                  ),
                  const SizedBox(width: kGap7),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: GlassTheme.fBody,
                    height: 1,
                    color: hovered ? GlassTheme.accentInk : GlassTheme.ink2,
                    fontWeight: hovered ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
            // 顶部内高光 rgba(255,255,255,0.7)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Container(
                  height: 1,
                  color: const Color(0xB3FFFFFF),
                ),
              ),
            ),
          ],
        ),
        ),
        ),
        ),
      ),
    ));
  }
}

/// 玻璃筛选胶囊：半透明白底 + 1px line 描边；hover 时 accent-ink 字 + #C7D2FE 边；
/// 选中态主渐变底白字 + 淡紫投影（对应规范 2.5）
class GlassChip extends StatefulWidget {
  const GlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  State<GlassChip> createState() => _GlassChipState();
}

class _GlassChipState extends State<GlassChip> {
  bool _hovered = false;
  bool _pressed = false;

  @override
    // 任务④（运行速度）：筛选胶囊 -> 独立图层，避免 hover/按压牵动整窗重绘
Widget build(BuildContext context) {
    final selected = widget.selected;
    final hovered = _hovered;
    return RepaintBoundary(child: Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: GlassTheme.hChip,
          padding: const EdgeInsets.symmetric(horizontal: kGap13), // 第二关遗留：水平内衬 12→13
          decoration: BoxDecoration(
            gradient: selected ? GlassTheme.grad : null,
            color: selected
                ? null
                : (_pressed
                      ? const Color(0x294462F2) // rgba(68,98,242,0.16) 按压加深（第三关 ⑤）
                      : (hovered ? GlassTheme.accentSoft : Colors.transparent)),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : (hovered ? const Color(0xFFC7D2FE) : GlassTheme.line),
            ),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x475050EB), // rgba(80,80,235,0.28)
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: GlassTheme.fSmall,
                  color: selected
                      ? Colors.white
                      : (hovered ? GlassTheme.accentInk : GlassTheme.ink2),
                  fontWeight: selected
                      ? FontWeight.w600
                      : (hovered ? FontWeight.w600 : FontWeight.w400),
                  height: 1,
                ),
              ),
              if (widget.count != null) ...[
                const SizedBox(width: kGap4),
                Text(
                  '${widget.count}',
                  style: TextStyle(
                    fontSize: GlassTheme.fSmall,
                    color: selected
                        ? Colors.white
                        : (hovered
                              ? GlassTheme.accentInk
                              : const Color(0xFF8A8A93)),
                    fontWeight: FontWeight.w600,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
        ),
        ),
      ),
    ));
  }
}

/// 通用悬停 / 按压反馈容器（第三关 ⑤）：hover 叠淡色底、按下叠加深色底并
/// AnimatedScale(.96, 80ms)。自身不参与布局（Stack(StackFit.passthrough) + Positioned
/// 叠加层），不改动子元素的尺寸与位置，也不引入 InkWell 水波纹。
class GlassPressable extends StatefulWidget {
  const GlassPressable({
    super.key,
    required this.child,
    this.enabled = true,
    this.radius = GlassTheme.rMd,
    this.hoverColor = const Color(0x0A18181B), // rgba(24,24,27,0.04)
    this.pressColor = const Color(0x294462F2), // rgba(68,98,242,0.16)
  });

  final Widget child;
  final bool enabled;
  final double radius;
  final Color hoverColor;
  final Color pressColor;

  @override
  State<GlassPressable> createState() => _GlassPressableState();
}

class _GlassPressableState extends State<GlassPressable> {
  bool _hovered = false;
  bool _pressed = false;

  @override
    // 任务④（运行速度）：通用可按压容器（列表行等） -> 独立图层，避免 hover/按压牵动整窗重绘
Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final hovered = _hovered && enabled;
    final pressed = _pressed && enabled;
    return RepaintBoundary(child: Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onPointerUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onPointerCancel: enabled ? (_) => setState(() => _pressed = false) : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: enabled ? (_) => setState(() => _hovered = false) : null,
        child: AnimatedScale(
          scale: pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              RepaintBoundary(child: widget.child),
              if (hovered || pressed)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: pressed ? widget.pressColor : widget.hoverColor,
                        borderRadius: BorderRadius.circular(widget.radius),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ));
  }
}

/// 彩色光晕圆点（统计卡标签行）
class GlowDot extends StatelessWidget {
  const GlowDot({super.key, required this.color, this.size = 7});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size + 6,
      height: size + 6,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 渐变 logo 徽标：ESW 文字徽标，高 20、最小宽 40、圆角 7、蓝紫渐变底（规范 4.3）
class GlassLogo extends StatelessWidget {
  const GlassLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 20,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: kGap7),
      decoration: BoxDecoration(
        // 第三轮清单第 10 项：蓝→紫 120° 渐变（#4462F2 → #8B5CF6），
        // 紫色在 65% 处即完全呈现，保证 40×20 的小徽标右下角也能辨识出紫色。
        gradient: const LinearGradient(
          begin: Alignment(-0.866, -0.5),
          end: Alignment(0.866, 0.5),
          colors: [Color(0xFF4462F2), Color(0xFF8B5CF6)],
          stops: [0.0, 0.65],
        ),
        borderRadius: BorderRadius.circular(7),
      ),
      child: const Text(
        'ESW',
        style: TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          height: 1,
        ),
      ),
    );
  }
}

/// 版本徽标（accent-soft 底 + accent-ink 字）
class GlassVersionBadge extends StatelessWidget {
  const GlassVersionBadge({super.key, required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: GlassTheme.s8, vertical: kGap4),
      decoration: BoxDecoration(
        color: GlassTheme.accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        version,
        style: const TextStyle(
          fontSize: GlassTheme.fMicro,
          color: GlassTheme.accentInk,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}

/// 中性灰文件类型标签（选中行由外层切换为 accent 实底白字）
class GlassFileTypeTag extends StatelessWidget {
  const GlassFileTypeTag({super.key, required this.label, this.selected = false});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 15,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? GlassTheme.accent : const Color(0x0D18181B),
        borderRadius: BorderRadius.circular(GlassTheme.rSm - 2),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 8.5,
          color: selected ? Colors.white : const Color(0xFF9A9AA1),
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
