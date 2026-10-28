import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didscout_app/settings/app_settings.dart';
import 'package:didscout_app/settings/settings_repository.dart';

void main() {
  const repository = SettingsRepository();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load returns defaults when nothing has ever been saved', () async {
    final settings = await repository.load();
    expect(settings, const AppSettings.defaultValues());
  });

  test('save then load round trips the full settings', () async {
    const settings = AppSettings(
      readTimeoutMs: 2500,
      reconnectBackoffMinS: 3,
      reconnectBackoffMaxS: 45,
      neverGiveUpReconnecting: false,
      reconnectAttempts: 12,
      stopAfterNoVehicleDataMinutes: 20,
      maxReadsPerSecond: 7,
      surveyIntervalMinutes: 4,
      chargeReminderIntervalMinutes: 8,
      autoStartOnPower: true,
      recordOnlyWhilePoweredOn: false,
      scoutWhileRecording: false,
      scoutWhileDriving: false,
      recordingMode: RecordingMode.scoutAndRecordKnown,
      keepSamplingFoundDids: false,
    );

    await repository.save(settings);
    final loaded = await repository.load();

    expect(loaded, settings);
  });

  test('loading a blob saved before recording mode existed migrates to '
      'defaults for the new keys', () async {
    final legacy = const AppSettings.defaultValues().toJson()
      ..remove('recordingMode')
      ..remove('keepSamplingFoundDids');
    SharedPreferences.setMockInitialValues({
      'didscout_app_settings_v1': jsonEncode(legacy),
    });

    final settings = await repository.load();

    expect(settings.recordingMode, RecordingMode.scoutOnly);
    expect(settings.keepSamplingFoundDids, isTrue);
  });

  test(
    'a corrupt stored value falls back to defaults instead of throwing',
    () async {
      SharedPreferences.setMockInitialValues({
        'didscout_app_settings_v1': 'not valid json{{{',
      });

      final settings = await repository.load();

      expect(settings, const AppSettings.defaultValues());
    },
  );

  test('resetToDefaults overwrites a previously saved value', () async {
    await repository.save(
      const AppSettings.defaultValues().copyWith(readTimeoutMs: 9999),
    );

    await repository.resetToDefaults();
    final loaded = await repository.load();

    expect(loaded, const AppSettings.defaultValues());
  });
}
