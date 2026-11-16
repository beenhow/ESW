import 'dart:io';

import 'package:flutter/material.dart';

/// 扫描原图查看页：用于和识别结果做人工比对。
///
/// 识别结果可能有误，最终以原图为准：本页默认全屏展示拍照后保存的图片，
/// 支持双指缩放 / 双击放大 / 拖动查看细节；若上层提供识别文本，可一键
/// 在底部浮层展开文本作对照。
class ScanPhotoPage extends StatefulWidget {
  const ScanPhotoPage({
    super.key,
    required this.imagePath,
    this.text,
    this.title = '原图比对',
  });

  /// 原图绝对路径（拍照裁切后保存的图片）。
  final String imagePath;

  /// 对应的识别文本；为空时只展示图片。
  final String? text;

  final String title;

  /// 打开原图查看页。
  static Future<void> open(
    BuildContext context, {
    required String imagePath,
    String? text,
    String title = '原图比对',
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ScanPhotoPage(
          imagePath: imagePath,
          text: text,
          title: title,
        ),
      ),
    );
  }

  @override
  State<ScanPhotoPage> createState() => _ScanPhotoPageState();
}

class _ScanPhotoPageState extends State<ScanPhotoPage> {
  final TransformationController _transform = TransformationController();
  bool _showText = false;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_transform.value == Matrix4.identity()) {
      _transform.value = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
    } else {
      _transform.value = Matrix4.identity();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = (widget.text ?? '').trim().isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        actions: [
          if (hasText)
            TextButton(
              onPressed: () => setState(() => _showText = !_showText),
              child: Text(
                _showText ? '只看原图' : '对照文本',
                style: const TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: _showText ? 3 : 1,
            child: GestureDetector(
              onDoubleTap: _toggleZoom,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 6,
                child: Center(
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '原图已被清理或移动，无法显示',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_showText)
            Expanded(
              flex: 2,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFF151515),
                  border: Border(
                    top: BorderSide(color: Colors.white24),
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    widget.text!.trim(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
