// 启动冒烟测试（Windows 主界面）：真实渲染 WinEswApp，验证自绘标题栏与窗口三键存在。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:esw/windows_app.dart';

void main() {
  testWidgets('App launches：Windows 主界面可真实渲染', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    kEswStructureGuardTestMode = true;
    addTearDown(() => kEswStructureGuardTestMode = false);

    await tester.pumpWidget(const WinEswApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 自绘标题栏：应用名 + 窗口三键；标题栏区域 key 存在
    expect(find.text('真题课标词'), findsOneWidget);
    expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('region-titlebar')), findsOneWidget);
  });
}
