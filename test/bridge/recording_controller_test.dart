import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` — this
// test needs it anyway, to build a fake in place of the real native channel.
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/session/session_markers.dart';

/// Records every call made through it instead of ever reaching a real
/// native channel. All results are the "everything works" case unless a
/// test overrides a field below before calling [RecordingController.start].
class _FakeNativeObdApi extends NativeObdApi {
  ObdPermissionStatusMessage permissionStatusResult =
      ObdPermissionStatusMessage.granted;
  ObdPermissionStatusMessage requestPermissionsResult =
      ObdPermissionStatusMessage.granted;
  List<ObdAdapterMessage> scanResult = [
    ObdAdapterMessage(handle: 'weak', advertisedName: 'weak CX', rssi: -80),
    ObdAdapterMessage(
      handle: 'strong',
      advertisedName: 'strong CX',
      rssi: -40,
    ),
  ];
  ObdLinkStateValueMessage connectResult = ObdLinkStateValueMessage.connected;
  bool startRecordingResult = true;

  ObdBridgeConfigMessage? lastConfig;
  String? lastConnectedHandle;
  ObdStartRecordingRequest? lastStartRecordingRequest;
  String? lastStoppedSessionId;

  @override
  Future<void> configure(ObdBridgeConfigMessage config) async {
    lastConfig = config;
  }

  @override
  Future<ObdPermissionStatusMessage> permissionStatus() async =>
      permissionStatusResult;

  @override
  Future<ObdPermissionStatusMessage> requestPermissions() async =>
      requestPermissionsResult;

  @override
  Future<List<ObdAdapterMessage>> scanAdapters(int durationMs) async =>
      scanResult;

  @override
  Future<ObdLinkStateMessage> connect(String handle) async {
    lastConnectedHandle = handle;
    return ObdLinkStateMessage(state: connectResult, adapterHandle: handle);
  }

  @override
  Future<bool> startRecording(ObdStartRecordingRequest request) async {
    lastStartRecordingRequest = request;
    return startRecordingResult;
  }

  @override
  Future<void> stopRecording(String sessionId) async {
    lastStoppedSessionId = sessionId;
  }
}

void main() {
  late Directory tempDir;
  late _FakeNativeObdApi fakeNative;
  late RecordingController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('didscout_test_');
    fakeNative = _FakeNativeObdApi();
    controller = RecordingController(
      bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
      recordingsDirectory: () async => tempDir,
      sessionIdFactory: () => 'fixed-session-id',
      clock: () => DateTime.utc(2026, 1, 1, 12),
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('starts idle, able to start, unable to stop or share', () {
    expect(controller.phase, RecordingPhase.idle);
    expect(controller.canStart, isTrue);
    expect(controller.canStop, isFalse);
    expect(controller.canShare, isFalse);
  });

  test(
    'a full connect-and-record flow picks the strongest-RSSI adapter',
    () async {
      await controller.start();

      expect(controller.phase, RecordingPhase.recording);
      expect(fakeNative.lastConnectedHandle, 'strong');
      expect(controller.canStart, isFalse);
      expect(controller.canStop, isTrue);
      expect(controller.canShare, isFalse);
    },
  );

  test('configures the bridge with didscout-specific values', () async {
    await controller.start();

    final config = fakeNative.lastConfig;
    expect(config, isNotNull);
    expect(config!.activityClassName, 'de.noctunix.didscout_app.MainActivity');
    expect(config.smallIconResourceName, 'ic_launcher');
    expect(config.sharedPreferencesName, 'didscout_bridge');
    expect(config.bufferFormatId, 'didscout-buffer');
  });

  test('sends a plan whose commands all pass didscout\'s own policy', () async {
    await controller.start();

    final plan = fakeNative.lastStartRecordingRequest!.plan;
    final policy = DidscoutPolicy();
    final filter = GuardedCommandFilter(policy);
    void checkAll(Iterable<String> commands) {
      for (final command in commands) {
        expect(
          filter.check(command),
          isA<GuardAllowed>(),
          reason: 'expected $command to be allowed',
        );
      }
    }

    checkAll(plan.init);
    checkAll(plan.resync);
    for (final module in plan.modules) {
      checkAll(module.setup);
    }
    checkAll(plan.steps.map((step) => step.command));
  });

  test('holds the wake lock for the duration of the recording', () async {
    await controller.start();

    expect(
      fakeNative.lastStartRecordingRequest!.options.holdWakeLock,
      isTrue,
    );
  });

  test('stop → finished, shareable buffer file', () async {
    await controller.start();
    await controller.stop();

    expect(controller.phase, RecordingPhase.finished);
    expect(controller.canStart, isTrue);
    expect(controller.canStop, isFalse);
    expect(controller.canShare, isTrue);
    expect(fakeNative.lastStoppedSessionId, isNotNull);
    expect(controller.bufferFilePath, isNotNull);
    expect(controller.shareableFiles, contains(controller.bufferFilePath));
  });

  test('stop is a no-op unless currently recording', () async {
    await controller.stop();
    expect(controller.phase, RecordingPhase.idle);
  });

  test('no adapter found leaves the controller startable again', () async {
    fakeNative.scanResult = [];

    await controller.start();

    expect(controller.phase, RecordingPhase.noAdapterFound);
    expect(controller.canStart, isTrue);
  });

  test('denied permissions leave the controller startable again', () async {
    fakeNative.permissionStatusResult = ObdPermissionStatusMessage.denied;
    fakeNative.requestPermissionsResult = ObdPermissionStatusMessage.denied;

    await controller.start();

    expect(controller.phase, RecordingPhase.permissionDenied);
    expect(controller.canStart, isTrue);
  });

  test('a connect failure leaves the controller startable again', () async {
    fakeNative.connectResult = ObdLinkStateValueMessage.failed;

    await controller.start();

    expect(controller.phase, RecordingPhase.error);
    expect(controller.canStart, isTrue);
  });

  test('markers added before a session starts are flushed to the sidecar', () async {
    controller.addPhase(MarkerPhase.drive);
    controller.addNote('voltage reads 402V');

    await controller.start();

    final markersFile = File(controller.markersFilePath!);
    final lines = await markersFile.readAsLines();
    expect(lines, hasLength(2));
    expect(jsonDecode(lines[0])['kind'], 'phase');
    expect(jsonDecode(lines[0])['phase'], 'drive');
    expect(jsonDecode(lines[1])['kind'], 'note');
    expect(jsonDecode(lines[1])['text'], 'voltage reads 402V');
  });

  test('markers added while recording are appended live', () async {
    await controller.start();
    controller.addPhase(MarkerPhase.charge);
    // Marker writes are fire-and-forget; give the real file I/O time to land.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final markersFile = File(controller.markersFilePath!);
    final lines = await markersFile.readAsLines();
    expect(lines, hasLength(1));
    expect(jsonDecode(lines[0])['phase'], 'charge');
  });

  test('a session with no markers has no sidecar file', () async {
    await controller.start();
    await controller.stop();

    expect(controller.markersFilePath, isNull);
    expect(controller.shareableFiles, isNot(contains(contains('.markers.'))));
  });
}
