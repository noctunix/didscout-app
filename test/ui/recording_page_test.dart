import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/ui/recording_page.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    // The default 800x600 test surface is too short to fit the status card,
    // phase grid, note input and marker list at once; use a phone-sized
    // surface instead so interacting with later widgets doesn't require
    // scrolling the page's ListView into view first.
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });

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

    // Button widgets wrap their child in their own (unlabelled) Semantics
    // node, so the closest Semantics ancestor of the text isn't necessarily
    // the labelled one the page sets; search all Semantics nodes instead.
    final chargeSemantics = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where(
          (widget) => widget.properties.label?.contains('Charge') ?? false,
        );
    expect(chargeSemantics, isNotEmpty);
    expect(chargeSemantics.first.properties.label, contains('current phase'));
  });

  testWidgets('adding a note shows it in the marker list', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'voltage reads 402V');
    await tester.tap(find.widgetWithText(FilledButton, 'Add note'));
    await tester.pump();

    expect(find.text('voltage reads 402V'), findsOneWidget);
  });
}
