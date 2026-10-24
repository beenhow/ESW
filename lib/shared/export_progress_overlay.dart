import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/esw_tokens.dart';

/// 安卓端导出等待提示（浮动进度层）：延迟浮现 + 阶段文案 + 实时已用时。
///
/// 行为约定：
/// - 导出开始后延迟 [defaultDelay]（约 500 ms）仍未结束才浮现，快速导出不闪屏；
/// - 浮现后不可关闭（无关闭按钮、遮罩吸收点击、非路由不响应返回键），
///   只能由业务侧 [close] 收起；
/// - 内容为进度环 + 阶段文案 + "已用时 X 秒"（每 0.5 秒刷新一次）；
/// - [setStage] 可中途切换阶段文案；
/// - 导出结束（成功 / 异常 / 提前返回）必须在 finally 中调用 [close]，绝不残留。
///
/// 用法：
/// ```dart
/// final progress = ExportProgressOverlay.begin(context, stage: '正在导出…请稍候');
/// try {
///   await progress.setStage('正在生成文档…');
///   // ... 导出逻辑
/// } finally {
///   progress.close();
/// }
/// ```
class ExportProgressOverlay {
  ExportProgressOverlay._(this._context, this._stage, this._hint);

  /// 默认浮现延迟：短于该耗时的导出不弹提示，避免闪一下。
  static const Duration defaultDelay = Duration(milliseconds: 500);

  final BuildContext _context;
  final ValueNotifier<String> _stage;
  final String? _hint;
  final DateTime _startedAt = DateTime.now();
  final ValueNotifier<int> _elapsedSeconds = ValueNotifier<int>(0);

  OverlayEntry? _entry;
  Timer? _delayTimer;
  Timer? _ticker;
  bool _closed = false;

  bool get isClosed => _closed;

  /// 开始计时，并在 [delay] 后浮现提示层（若届时导出已结束则不浮现）。
  static ExportProgressOverlay begin(
    BuildContext context, {
    required String stage,
    String? hint,
    Duration delay = defaultDelay,
  }) {
    final progress = ExportProgressOverlay._(
      context,
      ValueNotifier<String>(stage),
      hint,
    );
    progress._start(delay);
    return progress;
  }

  void _start(Duration delay) {
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _tick(),
    );
    if (delay <= Duration.zero) {
      _show();
      return;
    }
    _delayTimer = Timer(delay, _show);
  }

  /// 计时用真实时间差计算，主线程被计算占满时恢复后自动追上。
  void _tick() {
    if (_closed) return;
    _elapsedSeconds.value = DateTime.now().difference(_startedAt).inSeconds;
  }

  void _show() {
    _delayTimer = null;
    if (_closed || _entry != null) return;
    final overlay = _overlayOf();
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (_) => _ExportProgressLayer(
        stage: _stage,
        elapsedSeconds: _elapsedSeconds,
        hint: _hint,
      ),
    );
    _entry = entry;
    try {
      overlay.insert(entry);
    } catch (_) {
      _entry = null;
    }
  }

  OverlayState? _overlayOf() {
    try {
      return Overlay.of(_context, rootOverlay: true);
    } catch (_) {
      return null;
    }
  }

  /// 切换阶段文案；让出一帧调度，主线程繁忙时也能尽快刷新界面。
  Future<void> setStage(String text) async {
    if (_closed || _stage.value == text) return;
    _stage.value = text;
    _tick();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }

  /// 收起提示层并释放资源；可重复调用（幂等）。
  void close() {
    if (_closed) return;
    _closed = true;
    _delayTimer?.cancel();
    _delayTimer = null;
    _ticker?.cancel();
    _ticker = null;
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      try {
        entry.remove();
      } catch (_) {
        // 宿主 Overlay 已销毁时忽略，避免收尾异常掩盖真实导出结果
      }
    }
    _elapsedSeconds.dispose();
    _stage.dispose();
  }
}

/// 提示层视觉：半透明遮罩 + 居中浮层卡片（圆角 / 留白 / 字号全部取自 EswTokens）。
class _ExportProgressLayer extends StatelessWidget {
  const _ExportProgressLayer({
    required this.stage,
    required this.elapsedSeconds,
    this.hint,
  });

  final ValueNotifier<String> stage;
  final ValueNotifier<int> elapsedSeconds;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final hintText = hint;
    return Stack(
      children: [
        // 遮罩：吸收全部点击与滑动，导出期间界面不可操作、提示无法被点掉
        Positioned.fill(
          child: AbsorbPointer(
            child: ColoredBox(
              color: EswColors.textPrimary.withValues(alpha: 0.18),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: EswSpace.xxxl),
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 320),
                padding: const EdgeInsets.symmetric(
                  horizontal: EswSpace.xxl,
                  vertical: EswSpace.xl,
                ),
                decoration: BoxDecoration(
                  color: EswColors.card,
                  borderRadius: BorderRadius.circular(EswRadius.card),
                  boxShadow: EswShadow.card,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: EswColors.primary,
                        backgroundColor: EswColors.primarySoft,
                      ),
                    ),
                    const SizedBox(height: EswSpace.lg),
                    ValueListenableBuilder<String>(
                      valueListenable: stage,
                      builder: (_, text, __) => Text(
                        text,
                        textAlign: TextAlign.center,
                        style: EswText.bodyMedium.copyWith(
                          color: EswColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: EswSpace.sm),
                    ValueListenableBuilder<int>(
                      valueListenable: elapsedSeconds,
                      builder: (_, sec, __) => Text(
                        '已用时 $sec 秒',
                        textAlign: TextAlign.center,
                        style: EswText.bodySmall.copyWith(
                          color: EswColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (hintText != null) ...[
                      const SizedBox(height: EswSpace.xs),
                      Text(
                        hintText,
                        textAlign: TextAlign.center,
                        style: EswText.bodySmall.copyWith(
                          color: EswColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
