import 'dart:async';

import '../bridge/recording_controller.dart';
import '../settings/app_settings.dart';
import '../settings/settings_repository.dart';
import 'power_monitor.dart';

/// Wires [PowerMonitor]'s connection changes to [RecordingController],
/// honoring [AppSettings.autoStartOnPower]/[AppSettings.recordOnlyWhilePoweredOn].
/// Settings are (re)loaded on every power transition rather than cached, same
/// as [RecordingController.start] reloads them — so a change made on the
/// settings screen takes effect on the very next plug/unplug, not just the
/// next app launch. Lives only as long as its owner (the recording page)
/// keeps it around, matching these settings' "app must be open" condition.
class PowerRecordingCoordinator {
  PowerRecordingCoordinator({
    required this.controller,
    required PowerMonitor powerMonitor,
    Future<AppSettings> Function()? loadSettings,
  }) : _loadSettings = loadSettings ?? const SettingsRepository().load {
    _subscription = powerMonitor.connectionChanges.listen(
      (connection) => unawaited(_onConnectionChanged(connection)),
    );
  }

  final RecordingController controller;
  final Future<AppSettings> Function() _loadSettings;
  StreamSubscription<PowerConnection>? _subscription;

  Future<void> _onConnectionChanged(PowerConnection connection) async {
    AppSettings settings;
    try {
      settings = await _loadSettings();
    } catch (_) {
      // Without settings there is no configured behavior to act on.
      return;
    }
    if (connection == PowerConnection.connected) {
      if (settings.autoStartOnPower && controller.canStart) {
        await controller.start();
      }
    } else if (settings.recordOnlyWhilePoweredOn && controller.canStop) {
      await controller.stop(reason: 'power disconnected');
    }
  }

  void dispose() {
    unawaited(_subscription?.cancel());
  }
}
