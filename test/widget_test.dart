import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/main.dart';

void main() {
  testWidgets('app shows the recording page', (tester) async {
    await tester.pumpWidget(const DidscoutApp());

    expect(find.text('didscout'), findsOneWidget);
    expect(find.text('Start recording'), findsOneWidget);
  });
}
