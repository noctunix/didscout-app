import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/ui/recording_page.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: RecordingPage()));
  }

  testWidgets('start recording button is disabled', (tester) async {
    await pumpPage(tester);

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start recording'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('tapping a phase button adds and highlights that phase', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Charge'), findsOneWidget);
    await tester.tap(find.text('Charge'));
    await tester.pump();

    // The marker list (newest first) now shows a "Charge" entry in addition
    // to the phase button itself.
    expect(find.text('Charge'), findsNWidgets(2));

    final highlighted = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.text('Charge').first,
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(highlighted.properties.label, contains('current phase'));
  });

  testWidgets('adding a note shows it in the marker list', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'voltage reads 402V');
    await tester.tap(find.widgetWithText(FilledButton, 'Add note'));
    await tester.pump();

    expect(find.text('voltage reads 402V'), findsOneWidget);
  });
}
