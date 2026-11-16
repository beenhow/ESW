import 'package:flutter/services.dart';

/// 调用系统「打开方式」打开本机文件（Android：Intent.ACTION_VIEW + FileProvider）。
///
/// - 成功后返回 true，系统会自行弹出可处理该文件的应用（Word/WPS/文本编辑器等）；
/// - 无可用应用、文件不存在、通道不可用（如单元测试/桌面端）时返回 false，
///   调用方应退回到应用内的展示方案（如重新打开检测结果页）。
class AndroidOpenFile {
  AndroidOpenFile._();

  static const MethodChannel _channel = MethodChannel('esw/open_file');

  static Future<bool> open(String path) async {
    if (path.trim().isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('open', {'path': path});
      return ok ?? false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[AndroidOpenFile] 打开失败: ${e.code} ${e.message}');
      return false;
    } on MissingPluginException {
      // 非 Android 平台 / 通道未注册：交由调用方兜底
      return false;
    }
  }
}
