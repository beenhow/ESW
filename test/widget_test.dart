import 'package:flutter_test/flutter_test.dart';
import 'package:esw/main.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const EswApp());
    expect(find.text('ESW'), findsOneWidget);
  });
}
