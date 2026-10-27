import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/main.dart';

void main() {
  testWidgets('home page shows the not-implemented placeholder', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DidscoutApp());

    expect(find.text('didscout'), findsOneWidget);
    expect(find.text('Recording is not implemented yet.'), findsOneWidget);
  });
}
