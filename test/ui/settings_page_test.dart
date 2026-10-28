import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didscout_app/settings/app_settings.dart';
import 'package:didscout_app/settings/settings_repository.dart';
import 'package:didscout_app/ui/settings_page.dart';

const _scoutAndRecordKnownLabel = 'Scout and record known signals';
const _keepSamplingLabel = 'Keep sampling found DIDs';

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

  testWidgets('toggling scout while recording off disables scout while '
      'driving', (tester) async {
    await pumpPage(tester);

    final scoutWhileDriving = find.widgetWithText(
      SwitchListTile,
      'Scout while driving',
    );
    expect(
      tester.widget<SwitchListTile>(scoutWhileDriving).onChanged,
      isNotNull,
    );

    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Scout while recording'),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(scoutWhileDriving).onChanged, isNull);
  });

  testWidgets('toggling scout while recording persists it', (tester) async {
    await pumpPage(tester);

    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Scout while recording'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final saved = await const SettingsRepository().load();
    expect(saved.scoutWhileRecording, isFalse);
  });

  testWidgets('shows the recording mode and found-DID switch from loaded '
      'settings', (tester) async {
    await pumpPage(tester);

    expect(
      tester
          .widget<RadioGroup<RecordingMode>>(
            find.byType(RadioGroup<RecordingMode>),
          )
          .groupValue,
      RecordingMode.scoutOnly,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, _keepSamplingLabel),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('selecting a recording mode and saving persists it', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.tap(
      find.widgetWithText(
        RadioListTile<RecordingMode>,
        _scoutAndRecordKnownLabel,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final saved = await const SettingsRepository().load();
    expect(saved.recordingMode, RecordingMode.scoutAndRecordKnown);
  });

  testWidgets('toggling keep sampling found DIDs persists it', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(SwitchListTile, _keepSamplingLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final saved = await const SettingsRepository().load();
    expect(saved.keepSamplingFoundDids, isFalse);
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
