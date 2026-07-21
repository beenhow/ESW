import 'dart:convert';
import 'package:http/http.dart' as http;

/// AI 词根识别服务。
/// 通过调用 LLM API 识别目标词的根词/原词，弥补纯规则匹配在复合词、
/// 不规则变形等场景下的不足。
/// 使用方法：先调用 [configure] 配置 API 端点，再调用 [getBaseWords]。
class AiBaseWordService {
  static String? _endpoint;
  static String? _apiKey;
  static String _model = 'gpt-3.5-turbo';

  /// 内存缓存：word → baseWords（逗号分隔）
  static final Map<String, String> _cache = {};

  /// 配置 API 端点，未配置时 [getBaseWords] 返回 null（降级为纯规则匹配）。
  static void configure({
    required String endpoint,
    String? apiKey,
    String model = 'gpt-3.5-turbo',
  }) {
    _endpoint = endpoint;
    _apiKey = apiKey;
    _model = model;
  }

  /// 是否已配置 API 端点。
  static bool get isConfigured => _endpoint != null && _endpoint!.isNotEmpty;

  /// 获取目标词的根词列表。
  /// 返回逗号分隔的根词（如 "water,color"），复合词返回多个。
  /// 失败或未配置时返回 null，调用方应降级为纯规则匹配。
  static Future<String?> getBaseWords(String word) async {
    if (!isConfigured) return null;
    if (_cache.containsKey(word)) return _cache[word];

    try {
      final response = await http.post(
        Uri.parse(_endpoint!),
        headers: {
          'Content-Type': 'application/json',
          if (_apiKey != null && _apiKey!.isNotEmpty)
            'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'system',
              'content': 'You are a linguistic morphology expert. '
                  'Given an English word, identify its base/root word(s). '
                  'Consider inflectional changes (running→run), '
                  'derivational prefixes (unhappy→happy, antigravity→gravity), '
                  'derivational suffixes (happiness→happy), '
                  'compound words (watercolorist→water+color, walkways→walk+way). '
                  'For compound words, return ALL base words separated by comma and space. '
                  'Reply ONLY with the base word(s), nothing else. '
                  'If the word is already a base word, return it as-is.',
            },
            {'role': 'user', 'content': word},
          ],
          'temperature': 0,
          'max_tokens': 50,
        }),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text =
            (data['choices']?[0]?['message']?['content'] ?? '').trim();
        if (text.isNotEmpty) {
          _cache[word] = text;
          return text;
        }
      }
    } catch (_) {
      // 静默失败，降级为纯规则匹配
    }
    return null;
  }
}
