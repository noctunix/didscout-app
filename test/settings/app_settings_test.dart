import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/settings/app_settings.dart';

void main() {
  group('AppSettings.defaultValues', () {
    const defaults = AppSettings.defaultValues();

    test('matches the documented defaults', () {
      expect(defaults.readTimeoutMs, 2000);
      expect(defaults.reconnectBackoffMinS, 2);
      expect(defaults.reconnectBackoffMaxS, 60);
      expect(defaults.neverGiveUpReconnecting, isTrue);
      expect(defaults.reconnectAttempts, 20);
      expect(defaults.stopAfterNoVehicleDataMinutes, 30);
      expect(defaults.maxReadsPerSecond, 6);
      expect(defaults.surveyIntervalMinutes, 3);
      expect(defaults.chargeReminderIntervalMinutes, 5);
      expect(defaults.autoStartOnPower, isFalse);
      expect(defaults.recordOnlyWhilePoweredOn, isFalse);
      expect(defaults.scoutWhileRecording, isTrue);
      expect(defaults.scoutWhileDriving, isTrue);
    });

    test('derived values convert to the units ObdLimitsMessage expects', () {
      expect(defaults.maxReconnectAttemptsPerGap, 100000);
      expect(defaults.reconnectBackoffMinMs, 2000);
      expect(defaults.reconnectBackoffMaxMs, 60000);
      expect(defaults.idleVehicleStopAfterMs, 1800000);
      expect(defaults.surveyIntervalMs, 180000);
      expect(defaults.chargeReminderInterval, const Duration(minutes: 5));
    });

    test('maxReconnectAttemptsPerGap falls back to reconnectAttempts once '
        'never-give-up is off', () {
      final settings = defaults.copyWith(
        neverGiveUpReconnecting: false,
        reconnectAttempts: 7,
      );
      expect(settings.maxReconnectAttemptsPerGap, 7);
    });
  });

  test('copyWith only changes the given fields', () {
    const defaults = AppSettings.defaultValues();
    final changed = defaults.copyWith(
      readTimeoutMs: 3000,
      autoStartOnPower: true,
    );

    expect(changed.readTimeoutMs, 3000);
    expect(changed.autoStartOnPower, isTrue);
    expect(changed.reconnectBackoffMinS, defaults.reconnectBackoffMinS);
    expect(changed.surveyIntervalMinutes, defaults.surveyIntervalMinutes);
  });

  test('toJson/fromJson round trip preserves every field', () {
    const settings = AppSettings(
      readTimeoutMs: 1500,
      reconnectBackoffMinS: 4,
      reconnectBackoffMaxS: 90,
      neverGiveUpReconnecting: false,
      reconnectAttempts: 42,
      stopAfterNoVehicleDataMinutes: 15,
      maxReadsPerSecond: 8,
      surveyIntervalMinutes: 7,
      chargeReminderIntervalMinutes: 10,
      autoStartOnPower: true,
      recordOnlyWhilePoweredOn: true,
      scoutWhileRecording: false,
      scoutWhileDriving: false,
    );

    final roundTripped = AppSettings.fromJson(settings.toJson());

    expect(roundTripped, settings);
  });

  test('fromJson falls back to defaults for missing keys', () {
    final settings = AppSettings.fromJson(const {'readTimeoutMs': 3333});

    expect(settings.readTimeoutMs, 3333);
    expect(
      settings.reconnectBackoffMinS,
      const AppSettings.defaultValues().reconnectBackoffMinS,
    );
    expect(settings.autoStartOnPower, isFalse);
    expect(settings.scoutWhileRecording, isTrue);
    expect(settings.scoutWhileDriving, isTrue);
  });
}
