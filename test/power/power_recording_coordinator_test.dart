import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` — this
// test needs it anyway, to build a fake in place of the real native channel.
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/power/power_monitor.dart';
import 'package:didscout_app/power/power_recording_coordinator.dart';
import 'package:didscout_app/settings/app_settings.dart';

/// A native API that resolves every call immediately with the
/// "everything works" result, same fake shape as
/// `recording_controller_test.dart`'s own.
class _FakeNativeObdApi extends NativeObdApi {
  @override
  Future<void> configure(ObdBridgeConfigMessage config) async {}

  @override
  Future<ObdPermissionStatusMessage> permissionStatus() async =>
      ObdPermissionStatusMessage.granted;

  @override
  Future<ObdPermissionStatusMessage> requestPermissions() async =>
      ObdPermissionStatusMessage.granted;

  @override
  Future<List<ObdAdapterMessage>> scanAdapters(int durationMs) async => [
    ObdAdapterMessage(handle: 'cx', advertisedName: 'OBDLink CX', rssi: -50),
  ];

  @override
  Future<ObdLinkStateMessage> connect(String handle) async =>
      ObdLinkStateMessage(
        state: ObdLinkStateValueMessage.connected,
        adapterHandle: handle,
      );

  @override
  Future<bool> startRecording(ObdStartRecordingRequest request) async => true;

  @override
  Future<void> stopRecording(String sessionId) async {}
}

void main() {
  // `RecordingController.start` wires `ObdEventsApi` (for discovery
  // results) through a real `BasicMessageChannel`, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late RecordingController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('power_coordinator_test_');
  });

  RecordingController buildController() => RecordingController(
    bridge: ObdBridge(DidscoutPolicy(), nativeApi: _FakeNativeObdApi()),
    recordingsDirectory: () async => tempDir,
    sessionIdFactory: () => 'power-test-session',
    requestRuntimePermissions: (_) async {},
    tickInterval: const Duration(hours: 1),
    discoveryPumpInterval: const Duration(hours: 1),
    // Discovery isn't what these tests exercise; avoid the real
    // `path_provider` round trip so the tight timing budgets below (tens
    // of milliseconds) stay reliable under load.
    loadDiscoveryState: () async => DiscoveryState(),
    saveDiscoveryState: (_) async {},
  );

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test(
    'auto-starts the recording once power connects when the setting is on',
    () async {
      controller = buildController();
      final coordinator = PowerRecordingCoordinator(
        controller: controller,
        powerMonitor: PowerMonitor(
          batteryStateStream: Stream.value(BatteryState.charging),
        ),
        loadSettings: () async =>
            const AppSettings.defaultValues().copyWith(autoStartOnPower: true),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.phase, RecordingPhase.recording);
      coordinator.dispose();
    },
  );

  test('does nothing on power connect when the setting is off', () async {
    controller = buildController();
    final coordinator = PowerRecordingCoordinator(
      controller: controller,
      powerMonitor: PowerMonitor(
        batteryStateStream: Stream.value(BatteryState.charging),
      ),
      loadSettings: () async => const AppSettings.defaultValues(),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.phase, RecordingPhase.idle);
    coordinator.dispose();
  });

  test('stops a running recording with reason "power disconnected" once '
      'unplugged, when record-only-while-powered is on', () async {
    controller = buildController();
    await controller.start();
    expect(controller.phase, RecordingPhase.recording);

    final coordinator = PowerRecordingCoordinator(
      controller: controller,
      powerMonitor: PowerMonitor(
        batteryStateStream: Stream.value(BatteryState.discharging),
      ),
      loadSettings: () async => const AppSettings.defaultValues().copyWith(
        recordOnlyWhilePoweredOn: true,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.phase, RecordingPhase.finished);
    expect(controller.nativeStopBanner, contains('power disconnected'));
    coordinator.dispose();
  });

  test('leaves a running recording alone on power disconnect when the '
      'setting is off', () async {
    controller = buildController();
    await controller.start();

    final coordinator = PowerRecordingCoordinator(
      controller: controller,
      powerMonitor: PowerMonitor(
        batteryStateStream: Stream.value(BatteryState.discharging),
      ),
      loadSettings: () async => const AppSettings.defaultValues(),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.phase, RecordingPhase.recording);
    coordinator.dispose();
  });
}
