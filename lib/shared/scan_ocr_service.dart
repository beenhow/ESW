import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// 扫描识别结果。
class ScanTextResult {
  /// 整理后的文本（段落之间空一行）。
  final String text;

  /// 识别到的段落数（由原生文字块计数得到）。
  final int paragraphs;

  /// 拍照得到的原图路径（临时文件），便于失败时回看。
  final String imagePath;

  const ScanTextResult({
    required this.text,
    required this.paragraphs,
    required this.imagePath,
  });

  /// 可用于检测的英文词数（粗略校验，与检测切词口径一致）。
  int get latinWordCount => RegExp(r'[A-Za-z]{2,}').allMatches(text).length;
}

/// 扫描失败（相机不可用、识别异常等）时抛出，界面据此提示。
class ScanException implements Exception {
  final String message;
  const ScanException(this.message);

  @override
  String toString() => message;
}

/// 归一化的四个角点，顺序固定为左上、右上、右下、左下，取值 0..1。
class ScanQuad {
  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  const ScanQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  /// 整幅图范围（内缩 [inset]）。
  factory ScanQuad.inset(double inset) => ScanQuad(
        topLeft: Offset(inset, inset),
        topRight: Offset(1 - inset, inset),
        bottomRight: Offset(1 - inset, 1 - inset),
        bottomLeft: Offset(inset, 1 - inset),
      );

  factory ScanQuad.fromList(List<dynamic> values) {
    double at(int i) => (values[i] as num).toDouble().clamp(0.0, 1.0);
    return ScanQuad(
      topLeft: Offset(at(0), at(1)),
      topRight: Offset(at(2), at(3)),
      bottomRight: Offset(at(4), at(5)),
      bottomLeft: Offset(at(6), at(7)),
    );
  }

  List<Offset> get points => [topLeft, topRight, bottomRight, bottomLeft];

  List<double> toList() => [
        topLeft.dx, topLeft.dy,
        topRight.dx, topRight.dy,
        bottomRight.dx, bottomRight.dy,
        bottomLeft.dx, bottomLeft.dy,
      ];

  ScanQuad copyWithPoints(List<Offset> pts) => ScanQuad(
        topLeft: pts[0].clampToUnit(),
        topRight: pts[1].clampToUnit(),
        bottomRight: pts[2].clampToUnit(),
        bottomLeft: pts[3].clampToUnit(),
      );
}

extension on Offset {
  Offset clampToUnit() =>
      Offset(dx.clamp(0.0, 1.0), dy.clamp(0.0, 1.0));
}

/// 扫描文档内容：调用系统相机拍照 → 原生 ML Kit 离线识别 → 整理成可检测文本。
///
/// 识别在设备本地完成（模型随 APK 打包），不联网、不上传照片。
class ScanOcrService {
  static const MethodChannel _channel = MethodChannel('esw/ocr');
  static const MethodChannel _scanChannel = MethodChannel('esw/scan');
  static final ImagePicker _picker = ImagePicker();

  /// 智能检测文本区域边界；检测不可靠时原生侧会回退到整图内缩 2%。
  static Future<ScanQuad> detectQuad(String imagePath) async {
    try {
      final payload = await _scanChannel.invokeMethod<Map>('detectQuad', {
        'path': imagePath,
      });
      final raw = payload?['quad'] as List?;
      if (raw != null && raw.length == 8) return ScanQuad.fromList(raw);
    } on PlatformException catch (e) {
      throw ScanException(e.message ?? '边界检测失败，可手动调整范围');
    } on MissingPluginException {
      throw const ScanException('当前设备不支持边界检测');
    }
    return ScanQuad.inset(0.02);
  }

  /// 按四角做透视校正裁切，返回校正后的图片路径。
  static Future<String> warpQuad(String imagePath, ScanQuad quad) async {
    try {
      final payload = await _scanChannel.invokeMethod<Map>('warpQuad', {
        'path': imagePath,
        'quad': quad.toList(),
        'maxSide': 2600,
      });
      final out = payload?['path'] as String?;
      if (out != null && out.isNotEmpty) return out;
      throw const ScanException('裁切失败，请重试');
    } on PlatformException catch (e) {
      throw ScanException(e.message ?? '裁切失败，请重试');
    } on MissingPluginException {
      throw const ScanException('当前设备不支持裁切校正');
    }
  }

  /// 拍照并识别一页文字。
  ///
  /// 用户取消拍照返回 null；识别异常抛 [ScanException]。
  static Future<ScanTextResult?> scanPageFromCamera() async {
    final path = await capturePage();
    if (path == null) return null;
    return recognizeImage(path);
  }

  /// 第一步：调起系统相机拍一页文档，返回照片路径；用户取消返回 null。
  static Future<String?> capturePage() async {
    XFile? shot;
    try {
      shot = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        // 限制长边像素：既能保证 A4 正文可辨，又不至于让识别/内存耗时过长
        maxWidth: 3000,
        imageQuality: 95,
      );
    } on PlatformException catch (e) {
      throw ScanException(_cameraErrorText(e));
    } catch (e) {
      throw ScanException('相机无法启动：$e');
    }
    return shot?.path;
  }

  /// 第二步：识别照片中的文字，按页面 / 段落整理后返回。
  static Future<ScanTextResult> recognizeImage(String imagePath) async {
    Map? payload;
    try {
      payload = await _channel.invokeMethod<Map>('recognizeText', {
        'path': imagePath,
      });
    } on PlatformException catch (e) {
      throw ScanException(e.message ?? '文字识别失败，请重试');
    } on MissingPluginException {
      throw const ScanException('当前设备不支持扫描识别');
    }

    final raw = (payload?['text'] as String?) ?? '';
    final paragraphs = (payload?['blocks'] as int?) ?? 0;
    final text = normalize(raw);
    if (text.isEmpty) {
      throw const ScanException('未识别到文字，请对准文档、保持清晰后重拍');
    }
    return ScanTextResult(
      text: text,
      paragraphs: paragraphs,
      imagePath: imagePath,
    );
  }

  /// 释放原生识别器占用的资源（页面销毁时调用，可重复调用）。
  static Future<void> dispose() async {
    try {
      await _channel.invokeMethod<bool>('close');
    } catch (_) {
      // 释放失败不影响业务，下次扫描会重新创建识别器
    }
  }

  /// 文本整理：
  /// 1. 去掉行尾多余空白、压缩重复空格；
  /// 2. 修复换行造成的连字符断词（exam-\nple → example）；
  /// 3. 丢弃纯页码/纯符号行；
  /// 4. 段落之间保持一个空行，便于阅读与后续编辑。
  static String normalize(String raw) {
    if (raw.trim().isEmpty) return '';

    final paragraphs = <String>[];
    final buffer = <String>[];

    void flush() {
      if (buffer.isEmpty) return;
      var para = buffer.join(' ');
      // 合并断词：词尾连字符 + 空格 + 小写字母开头
      para = para.replaceAllMapped(
        RegExp(r'([A-Za-z])-\s+([a-z])'),
        (m) => '${m[1]}${m[2]}',
      );
      para = para.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
      if (para.isNotEmpty) paragraphs.add(para);
      buffer.clear();
    }

    for (final lineRaw in raw.split('\n')) {
      final line = lineRaw.replaceAll('\u00a0', ' ').trim();
      if (line.isEmpty) {
        flush();
        continue;
      }
      // 纯页码 / 纯符号行（如 "12"、"—— 12 ——"）不入正文
      final stripped = line.replaceAll(RegExp(r'[\s\-—_·•.。,，:;|/\\]+'), '');
      if (stripped.isEmpty || RegExp(r'^\d{1,4}$').hasMatch(stripped)) {
        continue;
      }
      buffer.add(line);
    }
    flush();

    return paragraphs.join('\n\n');
  }

  static String _cameraErrorText(PlatformException e) {
    final code = e.code.toLowerCase();
    if (code.contains('camera_access_denied') ||
        code.contains('photo_access_denied') ||
        code.contains('permission')) {
      return '未获得相机权限，请在系统设置中允许本应用使用相机后重试';
    }
    if (code.contains('no_available_camera')) {
      return '未检测到可用的相机';
    }
    return '相机无法启动：${e.message ?? e.code}';
  }

  /// 把扫描文本落成临时 txt，便于「最近检测」里回看原文。
  static Future<String> saveTempText(
    String text, {
    required String name,
  }) async {
    final dir = Directory('${Directory.systemTemp.path}/esw_scan');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File('${dir.path}/$safeName.txt');
    await file.writeAsString(text, flush: true);
    return file.path;
  }

  /// 把裁切后的原图另存到扫描目录，供后续「原图比对」使用。
  ///
  /// 相机插件返回的照片路径可能被系统随时清理，因此这里复制一份稳定副本。
  static Future<String?> savePhoto(String sourcePath, {required String name}) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return null;
      final dir = Directory('${Directory.systemTemp.path}/esw_scan');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final ext = sourcePath.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final target = File('${dir.path}/$safeName.$ext');
      await src.copy(target.path);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  /// 申请相机权限（自定义实时预览页直连相机，必须由本应用持有权限）。
  static Future<bool> requestCameraPermission() async {
    try {
      final granted = await _scanChannel.invokeMethod<bool>(
        'requestCameraPermission',
      );
      return granted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 后置摄像头传感器方向（顺时针角度，通常 90）。
  ///
  /// 图像流给到 Dart 的是传感器原始方向画面，需按该角度旋转才与预览对齐。
  static Future<int> sensorOrientation() async {
    try {
      final value = await _scanChannel.invokeMethod<int>('sensorOrientation');
      return value ?? 90;
    } on PlatformException {
      return 90;
    } on MissingPluginException {
      return 90;
    }
  }
}
