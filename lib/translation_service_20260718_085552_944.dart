import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// 离线翻译服务：Google ML Kit 内置 EN→ZH 翻译模型。
/// 首次使用时自动下载语言模型（约 30MB），之后完全离线。
class TranslationService {
  static final Map<String, String> _cache = {};
  static OnDeviceTranslator? _translator;
  static bool _modelReady = false;
  static bool _downloading = false;

  /// 确保翻译模型已下载（首次需网络）。
  static Future<void> _ensureModel() async {
    if (_modelReady) return;
    final manager = OnDeviceTranslatorModelManager();
    final code = TranslateLanguage.chinese.bcpCode;
    final downloaded = await manager.isModelDownloaded(code);
    if (!downloaded) {
      _downloading = true;
      await manager.downloadModel(code);
      _downloading = false;
    }
    _modelReady = true;
  }

  /// 获取单词的中文释义（EN→ZH 翻译）。
  static Future<String?> getChineseMeaning(String word) async {
    if (_cache.containsKey(word)) return _cache[word];
    if (_downloading) return null;

    try {
      await _ensureModel();
      _translator ??= OnDeviceTranslator(
        sourceLanguage: TranslateLanguage.english,
        targetLanguage: TranslateLanguage.chinese,
      );

      final result = await _translator!.translateText(word);
      if (result.isNotEmpty) {
        _cache[word] = result;
        return result;
      }
    } catch (_) {}
    return null;
  }

  static void dispose() {
    _translator?.close();
    _translator = null;
  }
}
