// 导出定稿课标词库为 xlsx（词表 + 统计 + 取舍说明），供人工查看。
//
// 数据源：assets/standard_words.json（运行时同一份文件）。
// 运行：dart run tool/export_final_library.dart
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';

void main() {
  final raw = utf8.decode(
      File('assets/standard_words.json').readAsBytesSync());
  final data = jsonDecode(raw) as Map<String, dynamic>;

  final rows = <MapEntry<String, Map<String, dynamic>>>[];
  for (final e in data.entries) {
    rows.add(MapEntry(e.key, (e.value as Map).cast<String, dynamic>()));
  }
  rows.sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

  final byCat = <String, int>{};
  var extEntries = 0;
  var extTotal = 0;
  for (final r in rows) {
    final cat = (r.value['category'] as String?) ?? '';
    byCat[cat] = (byCat[cat] ?? 0) + 1;
    final exts = r.value['extensions'];
    if (exts is List && exts.isNotEmpty) {
      extEntries++;
      extTotal += exts.length;
    }
  }

  final excel = Excel.createExcel();
  final sheet = excel['词表'];
  sheet.appendRow(<CellValue?>[
    TextCellValue('序号'),
    TextCellValue('单词'),
    TextCellValue('类别'),
    TextCellValue('词性'),
    TextCellValue('释义'),
    TextCellValue('变体/拓展（extensions）'),
  ]);
  var no = 0;
  for (final r in rows) {
    no++;
    final exts = r.value['extensions'];
    sheet.appendRow(<CellValue?>[
      IntCellValue(no),
      TextCellValue(r.key),
      TextCellValue((r.value['category'] as String?) ?? ''),
      TextCellValue((r.value['pos'] as String?) ?? ''),
      TextCellValue((r.value['def'] as String?) ?? ''),
      TextCellValue(exts is List ? exts.map((e) => '$e').join(', ') : ''),
    ]);
  }

  final stat = excel['统计'];
  stat.appendRow(<CellValue?>[TextCellValue('项目'), TextCellValue('数值')]);
  void kv(String k, Object v) => stat.appendRow(
      <CellValue?>[TextCellValue(k), TextCellValue('$v')]);
  kv('总条数', rows.length);
  kv('初中', byCat['初中'] ?? 0);
  kv('必修', byCat['必修'] ?? 0);
  kv('选修', byCat['选修'] ?? 0);
  kv('专有词', byCat['专有词'] ?? 0);
  kv('带 extensions 的条目数', extEntries);
  kv('extensions 成员总数', extTotal);
  kv('数据文件', 'assets/standard_words.json');

  final note = excel['说明'];
  void line(String s) => note.appendRow(<CellValue?>[TextCellValue(s)]);
  line('《课标词库》定稿说明（共 ${rows.length} 条）');
  line('');
  line('一、整体构成');
  line('总条数 ${rows.length} 条：初中 ${byCat['初中'] ?? 0}、必修 ${byCat['必修'] ?? 0}、'
      '选修 ${byCat['选修'] ?? 0}、专有词 ${byCat['专有词'] ?? 0}。');
  line('其中 $extEntries 条带变体/拓展信息（extensions），成员合计 $extTotal 个；'
      '变体不单独占词条，统计时并入主条。');
  line('');
  line('二、高中主干来源');
  line('以《普通高中英语课程标准》词表 3172 个词形为主干（来源文件 pdf_wordlist.csv，'
      '含“主词 / 括号并列变体”两列），级别取自课标标注：无星号为义务教育（本库记为“初中”），'
      '** 为必修，*** 为选修。词性与释义来自词典库 ecdict。');
  line('');
  line('三、数词与专有词的纳入');
  line('57 个数词（one/two/…/hundred/thousand 等）直接作为“初中”词条加入，不另设类别。');
  line('专有名词共 ${byCat['专有词'] ?? 0} 条统一标为“专有词”：可正常查词、查词频，'
      '但不计入高频导出（导出统计会跳过该类别）。');
  line('专有词同时并入用户自建的“专有词库”（manualExtraWords），按小写去重；'
      '两处数据并存，互不覆盖。');
  line('按最新要求：用户自建的拓展词、超标词、专有词三个词库由用户自行维护，'
      '本次不修改、不清理、不与课标库合并。');
  line('');
  line('四、英美拼写合并（26 对）');
  line('26 对英美拼写合并为一条：主条取课标 PDF 的主词写法（英式），美式写法挂到主条 '
      'extensions，不再单独占条。合并后总条数由 3324 降为 ${rows.length}。');
  line('26 对：analyse←analyze、apologise←apologize、centre←center、'
      'centimetre←centimeter、colour←color、criticise←criticize、dialogue←dialog、'
      'favour←favor、favourite←favorite、flavour←flavor、gramme←gram、'
      'honour←honor、humour←humor、kilometre←kilometer、labour←labor、'
      'metre←meter、millimetre←millimeter、neighbour←neighbor、'
      'neighbourhood←neighborhood、organise←organize、programme←program、'
      'realise←realize、recognise←recognize、theatre←theater、grey←gray、'
      'practise←practice。');
  line('查词、页面词频、导出高频三处都按“变体→主条”归并：查 practice 得到 practise 的词族，'
      '频次合并为一条；全量逐词核对 entries=2987、mismatches=0。');
  line('');
  line('五、小学课标词 505 比对结论');
  line('小学课标词 PDF（505 条，扫描件经 OCR 并逐页人工核对）与高中课标词表 3172 词形逐条比对：'
      '505/505 全部已收录，缺失 0 条，无需新增或改动。');
  line('比对时 a/an 拆成 a、an 两个词头（共 506 个词头）；505 中的 1 个（China）在课标清单里'
      '标为必修，其余为义务教育（初中）词；库内 China/Chinese/English 按专有词处理。');
  line('');
  line('六、四项修订的最终结果');
  line("1) o'clock：原条目键为弯撇号 o’clock（U+2019），直撇号输入查不到；"
      "已统一为直撇号 o'clock，查表时弯撇号会折叠为直撇号，两种写法都能命中，"
      "搜索补全同样按折叠后的键匹配。");
  line('2) men/women/mice：分别加入 man/woman/mouse 的 extensions，作为复数形式并入主条统计；'
      '不新增独立词条。');
  line('3) Internet：加入 internet 的 extensions，仅作为大小写变体归并，不新增词条。');
  line('4) 单词检测整词化：检测链路不再用子串匹配。修正 3 处 Android 端子串命中'
      '（打开真题定位、按内容查找语料文件、长文定位截取），统一改为整词正则/整词偏移；'
      '导出例句中的 contains 仅作整词判定前的快速预检；词库搜索框的子串检索属搜索功能，保留。'
      '效果：men 不会命中 women/achievement，he 不会命中 the。');
  line('');
  line('七、取舍说明');
  line('主条选英式：以课标 PDF 主词为准，便于与课标原文对照；用另一写法查询时同样归并到主条。');
  line('真题语料以美式为主（26 对统计约美式 72%、英式 28%），但合并后统计不受影响，'
      '故仍保留英式主条，不逐条反转。');
  line('专有词不计入高频导出：避免地名/人名/机构名占据高频词表名额，但保留查词与词频功能。');
  line('课标库 extensions 仅在“拓展词汇”白名单内参与词族/导出统计；'
      'men/women/mice/Internet 若未列入用户的拓展词列表，查词仍可通过反向索引定位到'
      '所属课标原词（Windows 端会顺带补入拓展词列表，Android 端仅显示归属）。');
  line('');
  line('生成时间：${DateTime.now().toIso8601String().substring(0, 19)}');

  excel.delete('Sheet1');
  final bytes = excel.save();
  final out = '课标词库_定稿_${rows.length}词_20261127.xlsx';
  File(out).writeAsBytesSync(bytes!);
  stdout.writeln('written: $out');
}
