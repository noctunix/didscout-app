import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didscout_app/settings/app_settings.dart';
import 'package:didscout_app/settings/settings_repository.dart';
import 'package:didscout_app/ui/settings_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpPage(WidgetTester tester) async {
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });

    await tester.pumpWidget(MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the persisted defaults once loaded', (tester) async {
    await pumpPage(tester);

    expect(find.text('2000 ms'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('3 min'), findsOneWidget);
  });

  testWidgets('toggling a switch and saving persists it', (tester) async {
    await pumpPage(tester);

    await tester.tap(
      find.widgetWithText(
        SwitchListTile,
        'Record only while connected to power',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final saved = await const SettingsRepository().load();
    expect(saved.recordOnlyWhilePoweredOn, isTrue);
  });

  testWidgets('reset to defaults restores a changed value', (tester) async {
    await const SettingsRepository().save(
      const AppSettings.defaultValues().copyWith(readTimeoutMs: 9000),
    );
    await pumpPage(tester);
    expect(find.text('9000 ms'), findsOneWidget);

    await tester.tap(find.byTooltip('Reset to defaults'));
    await tester.pumpAndSettle();

    expect(find.text('2000 ms'), findsOneWidget);
    final saved = await const SettingsRepository().load();
    expect(saved.readTimeoutMs, 2000);
  });
}
