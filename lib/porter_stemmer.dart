/// Porter Stemmer - 经典英文词干提取算法。
///
/// 纯算法实现，零依赖，零网络请求。
///
/// 该实现严格遵循 M.F. Porter 1980 年发表的原始算法规范：
/// https://tartarus.org/martin/PorterStemmer/def.txt
///
/// 示例：
///   porterStem('running')     => 'run'
///   porterStem('happiness')   => 'happi'
///   porterStem('antigravity') => 'antigrav'
///   porterStem('nationalized') => 'nation'
///
/// 使用方式：
///   import 'porter_stemmer.dart';
///   final stem = porterStem('running'); // 'run'
library porter_stemmer;

/// 对外暴露的唯一入口函数。
///
/// 输入一个英文单词，返回其词干。
/// 大写字母会被统一转为小写处理；长度小于等于 2 的单词原样返回。
String porterStem(String word) {
  if (word.isEmpty) return word;

  // 统一转小写，仅处理 ASCII 字母；其余字符原样返回。
  final lower = word.toLowerCase();
  for (int i = 0; i < lower.length; i++) {
    final c = lower.codeUnitAt(i);
    if (c < 0x61 || c > 0x7a) {
      // 含非 a-z 字符，不做词干化，原样返回。
      return word;
    }
  }

  // Porter 算法规定：长度不超过 2 的单词不做处理。
  if (lower.length <= 2) return lower;

  final stemmer = _PorterStemmer(lower);
  return stemmer.stem();
}

/// 内部实现类：持有单词的可变字符缓冲区并逐步应用各步骤规则。
class _PorterStemmer {
  /// 字符缓冲区（全部为 a-z 小写字符）。
  List<int> _b;

  _PorterStemmer(String word) : _b = word.codeUnits.toList();

  /// 当前单词字符串。
  String get _word => String.fromCharCodes(_b);

  /// 执行完整的 5 个步骤并返回词干。
  String stem() {
    _step1a();
    _step1b();
    _step1c();
    _step2();
    _step3();
    _step4();
    _step5a();
    _step5b();
    return _word;
  }

  // ---------------------------------------------------------------------------
  // 基础判定函数
  // ---------------------------------------------------------------------------

  static const int _cA = 0x61; // 'a'
  static const int _cE = 0x65; // 'e'
  static const int _cI = 0x69; // 'i'
  static const int _cO = 0x6f; // 'o'
  static const int _cU = 0x75; // 'u'
  static const int _cY = 0x79; // 'y'

  /// 判定位置 [i] 处的字符是否为辅音。
  ///
  /// 元音定义为 a、e、i、o、u；字母 y 的判定依赖上下文：
  /// 当 y 前一个字符是辅音（或 y 位于词首）时，y 视为元音，否则视为辅音。
  bool _isConsonant(int i) {
    final c = _b[i];
    if (c == _cA || c == _cE || c == _cI || c == _cO || c == _cU) {
      return false;
    }
    if (c == _cY) {
      // y 在词首视为辅音；否则取决于前一个字符：
      // 前一个是辅音 => y 为元音（返回 false）；前一个是元音 => y 为辅音（返回 true）。
      if (i == 0) return true;
      return !_isConsonant(i - 1);
    }
    return true;
  }

  /// 计算给定长度 [len] 前缀（词干部分）的 measure 值 m。
  ///
  /// measure 即 VC 序列出现的次数。将单词表示为
  ///   [C](VC){m}[V]
  /// 的形式，m 即中间 VC 组的数量。
  ///
  /// 例如：
  ///   TR、EE、TREE          => m = 0
  ///   TROUBLE、OATS、TREES  => m = 1
  ///   TROUBLES、PRIVATE     => m = 2
  int _measure(int len) {
    int n = 0; // VC 序列计数
    int i = 0;

    // 跳过开头的辅音序列 [C]。
    while (true) {
      if (i >= len) return n;
      if (!_isConsonant(i)) break;
      i++;
    }
    i++; // 此时 i-1 为第一个元音，指向元音之后。

    // 交替扫描 (VC)* 结构。
    while (true) {
      // 扫描元音序列。
      while (true) {
        if (i >= len) return n;
        if (_isConsonant(i)) break;
        i++;
      }
      i++;
      n++; // 完成一个 VC 序列。
      // 扫描辅音序列。
      while (true) {
        if (i >= len) return n;
        if (!_isConsonant(i)) break;
        i++;
      }
      i++;
    }
  }

  /// 判断长度为 [len] 的前缀中是否含有元音。
  bool _containsVowel(int len) {
    for (int i = 0; i < len; i++) {
      if (!_isConsonant(i)) return true;
    }
    return false;
  }

  /// 判断长度为 [len] 的前缀是否以双写辅音结尾（如 -TT、-SS）。
  bool _doubleConsonant(int len) {
    if (len < 2) return false;
    if (_b[len - 1] != _b[len - 2]) return false;
    return _isConsonant(len - 1);
  }

  /// 判断长度为 [len] 的前缀是否以 “辅音-元音-辅音” 结尾，
  /// 且最后一个辅音不是 w、x、y（*o 条件）。
  ///
  /// 用于处理如 -CVC 结尾时需要补 e 的情况。
  bool _cvc(int len) {
    if (len < 3) return false;
    if (!_isConsonant(len - 1)) return false;
    if (_isConsonant(len - 2)) return false;
    if (!_isConsonant(len - 3)) return false;
    final c = _b[len - 1];
    if (c == 0x77 || c == 0x78 || c == _cY) return false; // w, x, y
    return true;
  }

  /// 判断当前缓冲区是否以字符串 [s] 结尾。
  bool _endsWith(String s) {
    final sl = s.length;
    if (sl > _b.length) return false;
    final offset = _b.length - sl;
    for (int i = 0; i < sl; i++) {
      if (_b[offset + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 将缓冲区末尾长度为 [suffixLen] 的后缀替换为字符串 [replacement]。
  void _replaceEnd(int suffixLen, String replacement) {
    final keep = _b.length - suffixLen;
    _b = _b.sublist(0, keep)..addAll(replacement.codeUnits);
  }

  /// 返回去掉长度为 [suffixLen] 的后缀后，剩余词干的 measure 值。
  int _measureBeforeSuffix(int suffixLen) {
    return _measure(_b.length - suffixLen);
  }

  // ---------------------------------------------------------------------------
  // Step 1a: 复数与 -ed/-ing 前的名词复数处理。
  //   SSES -> SS   (caresses -> caress)
  //   IES  -> I    (ponies   -> poni)
  //   SS   -> SS   (caress   -> caress)
  //   S    -> ""   (cats     -> cat)
  // ---------------------------------------------------------------------------
  void _step1a() {
    if (_endsWith('sses')) {
      _replaceEnd(4, 'ss');
    } else if (_endsWith('ies')) {
      _replaceEnd(3, 'i');
    } else if (_endsWith('ss')) {
      // 保持不变。
    } else if (_endsWith('s')) {
      _replaceEnd(1, '');
    }
  }

  // ---------------------------------------------------------------------------
  // Step 1b: 处理 -eed / -ed / -ing。
  //   (m>0) EED -> EE     (agreed -> agree, feed -> feed)
  //   (*v*) ED  -> ""     (plastered -> plaster)
  //   (*v*) ING -> ""     (motoring  -> motor)
  // 若 ED / ING 被移除，则执行后续清理：
  //   AT -> ATE, BL -> BLE, IZ -> IZE
  //   末尾双写辅音（非 l/s/z）=> 去掉一个
  //   (m=1 且 *o) => 补 E
  // ---------------------------------------------------------------------------
  void _step1b() {
    bool removed = false;

    if (_endsWith('eed')) {
      if (_measureBeforeSuffix(3) > 0) {
        _replaceEnd(3, 'ee');
      }
    } else if (_endsWith('ed')) {
      if (_containsVowel(_b.length - 2)) {
        _replaceEnd(2, '');
        removed = true;
      }
    } else if (_endsWith('ing')) {
      if (_containsVowel(_b.length - 3)) {
        _replaceEnd(3, '');
        removed = true;
      }
    }

    if (removed) {
      if (_endsWith('at') || _endsWith('bl') || _endsWith('iz')) {
        _replaceEnd(0, 'e');
      } else if (_doubleConsonant(_b.length)) {
        final last = _b[_b.length - 1];
        // 末尾若为 l、s、z 则不删。
        if (last != 0x6c && last != 0x73 && last != 0x7a) {
          _b = _b.sublist(0, _b.length - 1);
        }
      } else if (_measure(_b.length) == 1 && _cvc(_b.length)) {
        _replaceEnd(0, 'e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Step 1c: (*v*) Y -> I  (happy -> happi, sky -> sky)
  // ---------------------------------------------------------------------------
  void _step1c() {
    if (_endsWith('y') && _containsVowel(_b.length - 1)) {
      _b[_b.length - 1] = _cI;
    }
  }

  // ---------------------------------------------------------------------------
  // Step 2: 名词性后缀映射（均要求去后缀后 m>0）。
  // ---------------------------------------------------------------------------
  void _step2() {
    // 按后缀映射表逐项匹配（顺序遵循原始算法）。
    const List<List<String>> rules = [
      ['ational', 'ate'],
      ['tional', 'tion'],
      ['enci', 'ence'],
      ['anci', 'ance'],
      ['izer', 'ize'],
      ['bli', 'ble'], // Porter 后期修订：abli -> able 归并为 bli -> ble
      ['alli', 'al'],
      ['entli', 'ent'],
      ['eli', 'e'],
      ['ousli', 'ous'],
      ['ization', 'ize'],
      ['ation', 'ate'],
      ['ator', 'ate'],
      ['alism', 'al'],
      ['iveness', 'ive'],
      ['fulness', 'ful'],
      ['ousness', 'ous'],
      ['aliti', 'al'],
      ['iviti', 'ive'],
      ['biliti', 'ble'],
      ['logi', 'log'], // Porter 修订项
    ];
    _applyRules(rules, minMeasure: 0);
  }

  // ---------------------------------------------------------------------------
  // Step 3: 形容词/派生后缀（均要求去后缀后 m>0）。
  // ---------------------------------------------------------------------------
  void _step3() {
    const List<List<String>> rules = [
      ['icate', 'ic'],
      ['ative', ''],
      ['alize', 'al'],
      ['iciti', 'ic'],
      ['ical', 'ic'],
      ['ful', ''],
      ['ness', ''],
    ];
    _applyRules(rules, minMeasure: 0);
  }

  // ---------------------------------------------------------------------------
  // Step 4: 更多后缀移除（均要求去后缀后 m>1）。
  // ---------------------------------------------------------------------------
  void _step4() {
    // -ion 需额外满足前一个字符为 s 或 t。
    if (_endsWith('ion')) {
      final keep = _b.length - 3;
      if (keep > 0 && _measure(keep) > 1) {
        final prev = _b[keep - 1];
        if (prev == 0x73 || prev == 0x74) {
          // 前置字符为 s 或 t
          _replaceEnd(3, '');
          return;
        }
      }
    }

    const List<List<String>> rules = [
      ['al', ''],
      ['ance', ''],
      ['ence', ''],
      ['er', ''],
      ['ic', ''],
      ['able', ''],
      ['ible', ''],
      ['ant', ''],
      ['ement', ''],
      ['ment', ''],
      ['ent', ''],
      ['ou', ''],
      ['ism', ''],
      ['ate', ''],
      ['iti', ''],
      ['ous', ''],
      ['ive', ''],
      ['ize', ''],
    ];

    for (final rule in rules) {
      final suffix = rule[0];
      if (_endsWith(suffix)) {
        if (_measureBeforeSuffix(suffix.length) > 1) {
          _replaceEnd(suffix.length, '');
        }
        return; // 匹配到即停止（无论是否满足 measure 条件）。
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Step 5a: 结尾 E 的移除。
  //   (m>1) E        -> ""
  //   (m=1 且 非 *o) E -> ""
  // ---------------------------------------------------------------------------
  void _step5a() {
    if (_endsWith('e')) {
      final stemLen = _b.length - 1;
      final m = _measure(stemLen);
      if (m > 1) {
        _replaceEnd(1, '');
      } else if (m == 1 && !_cvc(stemLen)) {
        _replaceEnd(1, '');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Step 5b: (m>1 且 双写辅音 且 以 L 结尾) => 去掉一个 L。
  //   controll -> control
  // ---------------------------------------------------------------------------
  void _step5b() {
    if (_endsWith('l') &&
        _doubleConsonant(_b.length) &&
        _measure(_b.length) > 1) {
      _b = _b.sublist(0, _b.length - 1);
    }
  }

  // ---------------------------------------------------------------------------
  // 辅助：按规则表匹配并替换后缀（第一条命中即返回）。
  // [minMeasure] 为去后缀后词干需满足的最小 measure（严格大于）。
  // ---------------------------------------------------------------------------
  void _applyRules(List<List<String>> rules, {required int minMeasure}) {
    for (final rule in rules) {
      final suffix = rule[0];
      final replacement = rule[1];
      if (_endsWith(suffix)) {
        if (_measureBeforeSuffix(suffix.length) > minMeasure) {
          _replaceEnd(suffix.length, replacement);
        }
        return; // 命中一条即停止。
      }
    }
  }
}
