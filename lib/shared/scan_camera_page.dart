import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'scan_ocr_service.dart';

/// 扫描文档：自定义实时预览页（不经过系统相机界面）。
///
/// 交互链路：
/// 1. 进入即打开后置相机实时预览，页内每 ~300ms 取一帧做「纸张区域」检测，
///    自动把四角框贴到文档边界；
/// 2. 检测不准时用户可直接拖动四个角点微调（拖动后自动检测不再覆盖用户调整）；
/// 3. 点快门 → 停止取流 → 拍全图 → 按当前四角做透视校正裁切 →
///    返回裁切后的图片路径，交由上层做 OCR 与检测。
///
/// 说明：本页锁定竖屏，图像流按传感器方向（顺时针 `sensorOrientation`）
/// 旋到显示方向后再定位边界，避免出现「框转 90 度」的错位。
class ScanCameraPage extends StatefulWidget {
  const ScanCameraPage({super.key});

  /// 打开扫描相机页，返回裁切后的图片绝对路径；用户取消时返回 null。
  static Future<String?> open(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const ScanCameraPage(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<ScanCameraPage> createState() => _ScanCameraPageState();
}

class _ScanCameraPageState extends State<ScanCameraPage> {
  CameraController? _controller;
  int _sensorOrientation = 90;
  bool _initializing = true;
  String? _error;
  bool _capturing = false;

  /// 当前边界框（归一化，相对预览画面）。
  ScanQuad _quad = ScanQuad.inset(0.05);

  /// 用户是否手动调整过；一旦手动调整，自动检测不再覆盖。
  bool _manual = false;

  /// 最近一次自动检测结果（用于「自动识别」按钮复位）。
  ScanQuad? _autoQuad;

  bool _processing = false;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    final granted = await ScanOcrService.requestCameraPermission();
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '未获得相机权限\n请在系统设置中允许本应用使用相机后重试';
      });
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _initializing = false;
          _error = '未检测到可用的相机';
        });
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      _sensorOrientation = await ScanOcrService.sensorOrientation();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
      await controller.startImageStream(_onFrame);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '相机无法启动：${e.description ?? e.code}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '相机无法启动：$e';
      });
    }
  }

  // ------------------------------------------------------------ 实时边界检测

  void _onFrame(CameraImage image) {
    if (_processing) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameAt) < const Duration(milliseconds: 300)) {
      return;
    }
    _lastFrameAt = now;
    _processing = true;
    try {
      final frameRect = _detectPageRect(image);
      if (frameRect != null) {
        final shown = _rotateRectClockwise(frameRect, _sensorOrientation);
        final quad = ScanQuad(
          topLeft: shown.topLeft,
          topRight: shown.topRight,
          bottomRight: shown.bottomRight,
          bottomLeft: shown.bottomLeft,
        );
        _autoQuad = quad;
        if (!_manual) {
          _updateQuad(quad);
        }
      }
    } catch (_) {
      // 单帧识别异常直接丢弃，不影响预览
    } finally {
      _processing = false;
    }
  }

  /// 在当前 YUV 帧中定位纸张区域，返回帧坐标系下的归一化矩形。
  ///
  /// 思路：纸张通常比桌面亮、占比大。先按分位亮度求阈值，再统计每列 / 每行
  /// 的亮像素覆盖率，取覆盖率过半的最长连续区间作为文档边界；对比度不足或
  /// 结果明显异常（过小 / 几乎铺满）时返回 null，界面沿用兜底框。
  Rect? _detectPageRect(CameraImage image) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0 || bytes.isEmpty) return null;

    const step = 6;
    final stride = plane.bytesPerRow;
    final rawStride = plane.bytesPerPixel ?? 1;
    final pixelStride = rawStride == 0 ? 1 : rawStride;

    final hist = List<int>.filled(256, 0);
    var total = 0;
    for (var y = 0; y < height; y += step) {
      final rowStart = y * stride;
      for (var x = 0; x < width; x += step) {
        final idx = rowStart + x * pixelStride;
        if (idx >= bytes.length) continue;
        hist[bytes[idx]]++;
        total++;
      }
    }
    if (total == 0) return null;

    int percentile(int p) {
      final target = (total * p / 100).floor();
      var acc = 0;
      for (var i = 0; i < 256; i++) {
        acc += hist[i];
        if (acc >= target) return i;
      }
      return 255;
    }

    final lo = percentile(10);
    final hi = percentile(90);
    if (hi - lo < 24) return null; // 对比度不足，交给兜底框
    final threshold = ((lo + hi) / 2).round();

    final colCount = (width / step).ceil();
    final rowCount = (height / step).ceil();
    final cols = List<int>.filled(colCount, 0);
    final rows = List<int>.filled(rowCount, 0);
    for (var y = 0; y < height; y += step) {
      final rowStart = y * stride;
      final ri = y ~/ step;
      if (ri >= rowCount) break;
      for (var x = 0; x < width; x += step) {
        final idx = rowStart + x * pixelStride;
        if (idx >= bytes.length) continue;
        if (bytes[idx] < threshold) continue;
        final ci = x ~/ step;
        if (ci >= colCount) continue;
        cols[ci]++;
        rows[ri]++;
      }
    }

    final rangeX = _longestRange(cols, rowCount);
    final rangeY = _longestRange(rows, colCount);
    if (rangeX == null || rangeY == null) return null;

    final left = (rangeX.$1 * step) / width;
    final right = math.min(1.0, ((rangeX.$2 + 1) * step) / width);
    final top = (rangeY.$1 * step) / height;
    final bottom = math.min(1.0, ((rangeY.$2 + 1) * step) / height);
    if (right - left < 0.25 || bottom - top < 0.18) return null;
    if (right - left > 0.985 && bottom - top > 0.985) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// 取覆盖率过半的最长连续区间（下标闭区间）。
  (int, int)? _longestRange(List<int> cover, int span) {
    if (span <= 0) return null;
    final need = span * 0.5;
    int? bestStart;
    int? bestEnd;
    int? start;
    for (var i = 0; i < cover.length; i++) {
      final hit = cover[i] >= need;
      if (hit) {
        start ??= i;
      } else if (start != null) {
        if (bestStart == null || (i - 1 - start) > (bestEnd! - bestStart)) {
          bestStart = start;
          bestEnd = i - 1;
        }
        start = null;
      }
    }
    if (start != null) {
      if (bestStart == null ||
          (cover.length - 1 - start) > (bestEnd! - bestStart)) {
        bestStart = start;
        bestEnd = cover.length - 1;
      }
    }
    if (bestStart == null) return null;
    return (bestStart, bestEnd!);
  }

  /// 把帧坐标系矩形按顺时针 [degrees] 旋转到显示坐标系。
  Rect _rotateRectClockwise(Rect rect, int degrees) {
    final d = ((degrees % 360) + 360) % 360;
    switch (d) {
      case 90:
        return Rect.fromLTRB(
          1 - rect.bottom,
          rect.left,
          1 - rect.top,
          rect.right,
        );
      case 180:
        return Rect.fromLTRB(
          1 - rect.right,
          1 - rect.bottom,
          1 - rect.left,
          1 - rect.top,
        );
      case 270:
        return Rect.fromLTRB(
          rect.top,
          1 - rect.right,
          rect.bottom,
          1 - rect.left,
        );
      default:
        return rect;
    }
  }

  void _updateQuad(ScanQuad quad) {
    if (!mounted) return;
    setState(() => _quad = quad);
  }

  // -------------------------------------------------------------------- 拍照

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing || !controller.value.isInitialized) {
      return;
    }
    setState(() => _capturing = true);
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final shot = await controller.takePicture();
      final cropped = await ScanOcrService.warpQuad(shot.path, _quad);
      if (!mounted) return;
      Navigator.of(context).pop(cropped);
    } catch (e) {
      if (!mounted) return;
      setState(() => _capturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('拍照失败：$e')),
      );
      try {
        await controller.startImageStream(_onFrame);
      } catch (_) {
        // 恢复取流失败时保持静态预览，用户可重试或退出
      }
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      if (controller.value.isStreamingImages) {
        unawaited(controller.stopImageStream().catchError((_) {}));
      }
      unawaited(controller.dispose());
    }
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }

  // -------------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_error != null)
              _buildError(_error!)
            else if (_initializing)
              const Center(child: CircularProgressIndicator())
            else
              _buildPreview(),
            _buildTopBar(),
            if (_controller != null && !_initializing) _buildBottomBar(),
            if (_capturing)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text('正在处理图片…', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white70,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = _previewRect(controller, box);
        return Stack(
          children: [
            Positioned(
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: CameraPreview(controller),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _QuadPainter(
                    quad: _quad,
                    previewRect: rect,
                    auto: !_manual,
                  ),
                ),
              ),
            ),
            ..._buildHandles(rect),
          ],
        );
      },
    );
  }

  /// 预览实际的显示矩形（保持比例居中）。
  Rect _previewRect(CameraController controller, Size box) {
    var aspect = 3 / 4;
    final raw = controller.value.aspectRatio;
    if (raw > 0) aspect = 1 / raw; // 竖屏显示：宽 / 高
    final boxAspect = box.width / box.height;
    double w;
    double h;
    if (boxAspect > aspect) {
      h = box.height;
      w = h * aspect;
    } else {
      w = box.width;
      h = w / aspect;
    }
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Offset _toScreen(Offset norm, Rect rect) => Offset(
        rect.left + norm.dx * rect.width,
        rect.top + norm.dy * rect.height,
      );

  Offset _toNorm(Offset screen, Rect rect) => Offset(
        ((screen.dx - rect.left) / rect.width).clamp(0.0, 1.0),
        ((screen.dy - rect.top) / rect.height).clamp(0.0, 1.0),
      );

  List<Widget> _buildHandles(Rect rect) {
    final points = _quad.points;
    final widgets = <Widget>[];
    for (var i = 0; i < points.length; i++) {
      final p = _toScreen(points[i], rect);
      widgets.add(
        Positioned(
          left: p.dx - 26,
          top: p.dy - 26,
          width: 52,
          height: 52,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => setState(() => _manual = true),
            onPanUpdate: (details) {
              final pts = List<Offset>.from(_quad.points);
              pts[i] = _toNorm(p + details.delta, rect);
              _updateQuad(_quad.copyWithPoints(pts));
            },
            child: Center(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF2F80ED), width: 3),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 6),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildTopBar() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const Expanded(
              child: Text(
                '对准文档，自动识别边界；可拖动四角微调',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sideButton(
              icon: Icons.auto_fix_high,
              label: '自动识别',
              onTap: () {
                final auto = _autoQuad;
                setState(() {
                  _manual = false;
                  if (auto != null) _quad = auto;
                });
              },
            ),
            GestureDetector(
              onTap: _capture,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: Colors.white70, width: 4),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 10),
                  ],
                ),
                child: const Icon(
                  Icons.camera_alt,
                  color: Color(0xFF2F80ED),
                  size: 30,
                ),
              ),
            ),
            _sideButton(
              icon: Icons.crop_free,
              label: '整幅',
              onTap: () => setState(() {
                _manual = true;
                _quad = ScanQuad.inset(0);
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// 画出选区外的压暗遮罩 + 边界线。
class _QuadPainter extends CustomPainter {
  _QuadPainter({
    required this.quad,
    required this.previewRect,
    required this.auto,
  });

  final ScanQuad quad;
  final Rect previewRect;
  final bool auto;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = quad.points
        .map(
          (n) => Offset(
            previewRect.left + n.dx * previewRect.width,
            previewRect.top + n.dy * previewRect.height,
          ),
        )
        .toList();
    final poly = Path()..addPolygon(pts, true);
    final full = Path()..addRect(Offset.zero & size);
    final overlay = Path.combine(PathOperation.difference, full, poly);
    canvas.drawPath(
      overlay,
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );
    canvas.drawPath(
      poly,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = (auto ? const Color(0xFF2F80ED) : Colors.white)
            .withValues(alpha: 0.35),
    );
    canvas.drawPath(
      poly,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) {
    return oldDelegate.quad != quad ||
        oldDelegate.previewRect != previewRect ||
        oldDelegate.auto != auto;
  }
}
