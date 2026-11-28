import 'package:esw/high_freq_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('导出高频：选「全部年份」时窗口必须为 0，不被输入框默认 5 年覆盖', () {
    expect(
      exportYearWindowFromSelection(allYears: true, recentYears: 5),
      0,
    );
    expect(
      exportYearWindowFromSelection(allYears: true, recentYears: 30),
      0,
    );
  });

  test('导出高频：自定义年数按输入生效，并夹紧在 1..30', () {
    expect(
      exportYearWindowFromSelection(allYears: false, recentYears: 8),
      8,
    );
    expect(
      exportYearWindowFromSelection(allYears: false, recentYears: 0),
      1,
    );
    expect(
      exportYearWindowFromSelection(allYears: false, recentYears: 99),
      30,
    );
  });
}
