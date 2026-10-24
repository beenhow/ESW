// 导出汇总条目单测：以附件设计图为基准，校验条目顺序、命名、数值与配色，
// 以及"结果为 0 的类别不显示"规则。
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/export_summary.dart';

void main() {
  test('条目顺序/命名/数值/配色与设计图一致', () {
    final items = buildExportSummaryItems(
      totalRawCount: 3096,
      dedupCount: 1278,
      filterCounts: const {
        '拓展词': 511,
        '超标词': 23,
        '专有词': 54,
        '未筛选': 1,
      },
      standardCategoryCounts: const {'初中': 389, '必修': 200, '选修': 100},
    );

    expect(
      items.map((e) => e.label).toList(),
      const [
        '全套词词数',
        '去重总词数',
        '初中课标词',
        '必修课标词',
        '选修课标词',
        '拓展词',
        '超标词',
        '专有词',
        '未筛选',
      ],
    );
    expect(
      items.map((e) => e.value).toList(),
      const [3096, 1278, 389, 200, 100, 511, 23, 54, 1],
    );
    // 七类配色 + 字重以用户给出的导出样式图为准：
    // 初中黑加粗 / 必修深蓝加粗 / 选修浅蓝 / 拓展深绿加粗 / 超标红 / 专有紫 / 未筛选土红
    expect(
      items.map((e) => e.colorHex).toList(),
      const [
        '000000', // 全套词词数 黑
        '000000', // 去重总词数 黑
        '000000', // 初中课标词 黑
        '0B3D91', // 必修课标词 深蓝
        '00B0F0', // 选修课标词 浅蓝
        '006400', // 拓展词 深绿
        'FF0000', // 超标词 红
        '800080', // 专有词 紫
        'A0522D', // 未筛选 土红
      ],
    );
    expect(
      items.map((e) => e.bold).toList(),
      const [false, false, true, true, false, true, false, false, false],
    );
  });

  test('七类标注说明片段：逐类取规范色与字重，末尾跟该类统计词数', () {
    final items = buildExportSummaryItems(
      totalRawCount: 100,
      dedupCount: 80,
      filterCounts: const {
        '拓展词': 5,
        '超标词': 3,
        '专有词': 2,
        '未筛选': 4,
      },
      standardCategoryCounts: const {'初中': 10, '必修': 6, '选修': 0},
    );
    final segs = exportAnnotateLegendSegments(items);
    expect(segs.map((e) => e.label).toList(), const [
      '初中课标词',
      '必修课标词',
      '选修课标词',
      '拓展词',
      '超标词',
      '专有词',
      '未筛选',
    ]);
    expect(segs.map((e) => e.count).toList(), const [10, 6, 0, 5, 3, 2, 4]);
    expect(segs.map((e) => e.colorHex).toList(), const [
      '000000',
      '0B3D91',
      '00B0F0',
      '006400',
      'FF0000',
      '800080',
      'A0522D',
    ]);
    expect(segs.map((e) => e.bold).toList(),
        const [true, true, false, true, false, false, false]);
  });

  test('结果为 0 的类别不显示，总数类条目始终显示', () {
    final items = buildExportSummaryItems(
      totalRawCount: 0,
      dedupCount: 0,
      filterCounts: const {'超标词': 0, '专有词': 3, '未筛选': 0},
      standardCategoryCounts: const {'初中': 0, '必修': 0, '选修': 0},
    );
    expect(items.map((e) => e.label).toList(), const ['全套词词数', '去重总词数', '专有词']);
    expect(items.map((e) => e.value).toList(), const [0, 0, 3]);
  });

  test('设计图未列出的既有类别非 0 时补在末尾', () {
    final items = buildExportSummaryItems(
      totalRawCount: 10,
      dedupCount: 8,
      filterCounts: const {'真题词': 5, '其他': 2, '超标词': 0},
      standardCategoryCounts: const {'初中': 1, '必修': 0, '选修': 0},
    );
    expect(
      items.map((e) => e.label).toList(),
      const ['全套词词数', '去重总词数', '初中课标词', '真题词', '其他'],
    );
  });
}
