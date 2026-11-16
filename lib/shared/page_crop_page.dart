import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/esw_tokens.dart';
import '../theme/responsive.dart';
import 'scan_ocr_service.dart';

/// 拍照后的「识别范围校正」页。
///
/// 打开即调用原生边界检测给出初始四角，用户可拖动四角微调，
/// 确认后做透视校正裁切，只把文档区域交给 OCR，去掉桌面、阴影、页边。
/// 返回：校正后的图片路径；点「重拍」返回字符串 'retake'；直接返回 null 表示放弃扫描。
class PageCropPage extends StatefulWidget {
  final String imagePath;

  const PageCropPage({super.key, required this.imagePath});

  @override
  State<PageCropPage> createState() => _PageCropPageState();
}

class _PageCropPageState extends State<PageCropPage> {
  ui.Image? _image;
  List<Offset> _quad = ScanQuad.inset(0.02).points;
  bool _detecting = true;
  bool _applying = false;
  bool _autoDetected = false;
  int _activeCorner = -1;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (!mounted) return;
      setState(() => _hint = '图片读取失败，请重拍');
    }
    await _detect();
  }

  Future<void> _detect() async {
    if (!mounted) return;
    setState(() => _detecting = true);
    try {
      final quad = await ScanOcrService.detectQuad(widget.imagePath);
      if (!mounted) return;
      final isFull = quad.topLeft.dx <= 0.021 && quad.bottomRight.dx >= 0.979;
      setState(() {
        _quad = quad.points;
        _autoDetected = !isFull;
        _hint = isFull ? '未找到明显的文本边界，请拖动四角手动框选' : '已自动框选文本范围，可拖动四角微调';
      });
    } on ScanException catch (e) {
      if (!mounted) return;
      setState(() => _hint = e.message);
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  Future<void> _apply() async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final path = await ScanOcrService.warpQuad(
        widget.imagePath,
        ScanQuad.inset(0).copyWithPoints(_quad),
      );
      if (!mounted) return;
      Navigator.of(context).pop(path);
    } on ScanException catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      _showHint(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _applying = false);
      _showHint('裁切失败，请重试');
    }
  }

  void _showHint(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = EswResponsive.factorOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(f),
            Expanded(child: _buildCanvas(f)),
            _buildBottomBar(f),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(double f) {
    return SizedBox(
      height: 52 * f,
      child: Row(
        children: [
          IconButton(
            onPressed: _applying ? null : () => Navigator.of(context).pop(),
            icon: Icon(Icons.close, color: Colors.white, size: 22 * f),
          ),
          Expanded(
            child: Text(
              '调整识别范围',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16 * f,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(width: 48 * f),
        ],
      ),
    );
  }

  Widget _buildCanvas(double f) {
    final image = _image;
    if (image == null) {
      return Center(
        child: SizedBox(
          width: 28 * f,
          height: 28 * f,
          child: const CircularProgressIndicator(strokeWidth: 2.4, color: EswColors.primary),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final box = Size(c.maxWidth, c.maxHeight);
        final imgW = image.width.toDouble();
        final imgH = image.height.toDouble();
        final scale = (box.width / imgW) < (box.height / imgH)
            ? box.width / imgW
            : box.height / imgH;
        final rect = Rect.fromLTWH(
          (box.width - imgW * scale) / 2,
          (box.height - imgH * scale) / 2,
          imgW * scale,
          imgH * scale,
        );
        final screenPts = _quad
            .map((p) => Offset(rect.left + p.dx * rect.width, rect.top + p.dy * rect.height))
            .toList();

        return SizedBox.expand(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) {
              final hitR = 44 * f;
              var best = -1;
              var bestDist = double.infinity;
              for (var i = 0; i < screenPts.length; i++) {
                final dist = (screenPts[i] - d.localPosition).distance;
                if (dist < hitR && dist < bestDist) {
                  best = i;
                  bestDist = dist;
                }
              }
              setState(() => _activeCorner = best);
            },
            onPanUpdate: (d) {
              if (_activeCorner < 0) return;
              final nx = ((d.localPosition.dx - rect.left) / rect.width).clamp(0.0, 1.0);
              final ny = ((d.localPosition.dy - rect.top) / rect.height).clamp(0.0, 1.0);
              setState(() {
                final pts = List<Offset>.from(_quad);
                pts[_activeCorner] = Offset(nx, ny);
                _quad = pts;
                _autoDetected = false;
              });
            },
            onPanEnd: (_) => setState(() => _activeCorner = -1),
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _QuadPainter(
                      points: screenPts,
                      active: _activeCorner,
                      accent: EswColors.primary,
                      handleRadius: 11 * f,
                    ),
                  ),
                ),
                if (_detecting)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 12 * f,
                    child: Center(
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 14 * f, vertical: 7 * f),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(20 * f),
                        ),
                        child: Text(
                          '正在识别文本边界…',
                          style: TextStyle(color: Colors.white, fontSize: 12.5 * f),
                        ),
                      ),
                    ),
                  )
                else if (_hint != null)
                  Positioned(
                    left: 12 * f,
                    right: 12 * f,
                    bottom: 12 * f,
                    child: Center(
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 14 * f, vertical: 7 * f),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(20 * f),
                        ),
                        child: Text(
                          _hint!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 12.5 * f),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(double f) {
    return Container(
      padding: EdgeInsets.fromLTRB(14 * f, 10 * f, 14 * f, 14 * f),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _ghostButton('自动识别', Icons.auto_fix_high, _detecting ? null : _detect, f),
              SizedBox(width: 8 * f),
              _ghostButton('整幅', Icons.crop_free, () {
                setState(() {
                  _quad = ScanQuad.inset(0).points;
                  _autoDetected = false;
                  _hint = '已选择整幅图';
                });
              }, f),
              SizedBox(width: 8 * f),
              _ghostButton('重拍', Icons.refresh, () => Navigator.of(context).pop('retake'), f),
            ],
          ),
          SizedBox(height: 10 * f),
          SizedBox(
            width: double.infinity,
            height: 46 * f,
            child: FilledButton(
              onPressed: _applying || _detecting ? null : _apply,
              style: FilledButton.styleFrom(
                backgroundColor: EswColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12 * f),
                ),
              ),
              child: _applying
                  ? SizedBox(
                      width: 18 * f,
                      height: 18 * f,
                      child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      _autoDetected ? '使用此范围开始识别' : '使用此范围开始识别',
                      style: TextStyle(fontSize: 15 * f, fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ghostButton(String label, IconData icon, VoidCallback? onTap, double f) {
    final enabled = onTap != null;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10 * f),
        child: Container(
          height: 40 * f,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10 * f),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16 * f, color: enabled ? Colors.white : Colors.white38),
              SizedBox(width: 5 * f),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: enabled ? Colors.white : Colors.white38,
                    fontSize: 13 * f,
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

class _QuadPainter extends CustomPainter {
  final List<Offset> points;
  final int active;
  final Color accent;
  final double handleRadius;

  _QuadPainter({
    required this.points,
    required this.active,
    required this.accent,
    required this.handleRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length != 4) return;
    final poly = Path()..addPolygon(points, true);

    // 选区外压暗，突出只看文档区域
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      poly,
    );
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.55));

    canvas.drawPath(
      poly,
      Paint()
        ..style = PaintingStyle.fill
        ..color = accent.withValues(alpha: 0.10),
    );

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = Colors.white;
    canvas.drawPath(poly, border);

    // 三分参考线，帮助对齐文本行的水平
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.28);
    for (var i = 1; i <= 2; i++) {
      final t = i / 3.0;
      final pTop = Offset.lerp(points[0], points[1], t)!;
      final pBottom = Offset.lerp(points[3], points[2], t)!;
      canvas.drawLine(pTop, pBottom, grid);
      final pLeft = Offset.lerp(points[0], points[3], t)!;
      final pRight = Offset.lerp(points[1], points[2], t)!;
      canvas.drawLine(pLeft, pRight, grid);
    }

    for (var i = 0; i < 4; i++) {
      final isActive = i == active;
      final r = isActive ? handleRadius * 1.25 : handleRadius;
      canvas.drawCircle(points[i], r, Paint()..color = Colors.white);
      canvas.drawCircle(
        points[i],
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) =>
      old.active != active || !_samePoints(old.points, points);

  bool _samePoints(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
