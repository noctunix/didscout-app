import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` — this
// test needs it anyway, to build a fake in place of the real native channel.
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/connection_status.dart';
import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/bridge/vag_ppe_plan_data.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/session/session_markers.dart';
import 'package:didscout_app/settings/app_settings.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

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
    ObdAdapterMessage(handle: 'strong', advertisedName: 'strong CX', rssi: -40),
  ];
  ObdLinkStateValueMessage connectResult = ObdLinkStateValueMessage.connected;
  bool startRecordingResult = true;

  /// Overridden by tests that exercise [RecordingController]'s connection
  /// status polling; left null makes [liveState] throw, same as a real
  /// channel would with nothing mocked.
  ObdLiveStateMessage? liveStateResult;

  /// Overridden by tests that exercise connection-status/native-stop
  /// polling; left null makes [recordingState] throw.
  ObdRecordingStateMessage? recordingStateResult;

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

  /// When set, [liveState] waits for it before answering -- holds a poll in
  /// flight for as long as a test needs.
  Completer<void>? liveStateGate;

  @override
  Future<ObdLiveStateMessage> liveState(List<String> signalIds) async {
    await liveStateGate?.future;
    final result = liveStateResult;
    if (result == null) throw StateError('no liveState result set');
    return result;
  }

  @override
  Future<ObdRecordingStateMessage> recordingState() async {
    final result = recordingStateResult;
    if (result == null) throw StateError('no recordingState result set');
    return result;
  }
}

ObdLiveStateMessage _liveStateWithLink(ObdLinkStateValueMessage link) =>
    ObdLiveStateMessage(
      link: ObdLinkStateMessage(state: link),
      timebaseId: 't1',
      exchanges: const [],
    );

void main() {
  // `RecordingController.start` wires `ObdEventsApi` (for discovery
  // results) through a real `BasicMessageChannel`, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeNativeObdApi fakeNative;
  late RecordingController controller;
  late List<List<ph.Permission>> requestedPermissions;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('didscout_test_');
    fakeNative = _FakeNativeObdApi();
    requestedPermissions = [];
    controller = RecordingController(
      requestRuntimePermissions: (permissions) async =>
          requestedPermissions.add(permissions),
      bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
      recordingsDirectory: () async => tempDir,
      sessionIdFactory: () => 'fixed-session-id',
      clock: () => DateTime.utc(2026, 1, 1, 12),
    );
  });

  tearDown(() async {
    // Disposes whatever discovery timer `start()` may have armed -- a test
    // that never calls `stop()` would otherwise leave it running past this
    // test, free to fire against a later test's unmocked `enqueueOneShot`
    // channel.
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  test(
    'a live-state poll that finishes after dispose notifies nobody',
    () async {
      final gate = Completer<void>();
      fakeNative
        ..liveStateGate = gate
        ..liveStateResult = _liveStateWithLink(
          ObdLinkStateValueMessage.connected,
        );
      final disposed = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'disposed-session-id',
        tickInterval: const Duration(milliseconds: 1),
        loadDiscoveryState: () async => DiscoveryState(),
        saveDiscoveryState: (_) async {},
      );
      await disposed.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      disposed.dispose();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
  );

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
    expect(config.smallIconResourceName, 'ic_stat_didscout');
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

    expect(fakeNative.lastStartRecordingRequest!.options.holdWakeLock, isTrue);
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
    expect(requestedPermissions, [
      [
        ph.Permission.bluetoothScan,
        ph.Permission.bluetoothConnect,
        ph.Permission.notification,
      ],
      [ph.Permission.locationWhenInUse],
    ]);
  });

  test(
    'granting nearby devices at the prompt lets the recording start',
    () async {
      fakeNative.permissionStatusResult = ObdPermissionStatusMessage.denied;
      fakeNative.requestPermissionsResult = ObdPermissionStatusMessage.granted;

      await controller.start();

      expect(requestedPermissions, hasLength(1));
      expect(controller.phase, isNot(RecordingPhase.permissionDenied));
    },
  );

  test('already granted permissions show no prompt', () async {
    await controller.start();

    expect(requestedPermissions, isEmpty);
  });

  test('a connect failure leaves the controller startable again', () async {
    fakeNative.connectResult = ObdLinkStateValueMessage.failed;

    await controller.start();

    expect(controller.phase, RecordingPhase.error);
    expect(controller.canStart, isTrue);
  });

  test(
    'markers added before a session starts are flushed after the plan line',
    () async {
      controller.addPhase(MarkerPhase.drive);
      controller.addNote('voltage reads 402V');

      await controller.start();

      final markersFile = File(controller.markersFilePath!);
      final lines = await markersFile.readAsLines();
      expect(lines, hasLength(3));
      expect(jsonDecode(lines[0])['type'], 'plan');
      expect(jsonDecode(lines[1])['type'], 'phase');
      expect(jsonDecode(lines[1])['phase'], 'drive');
      expect(jsonDecode(lines[2])['type'], 'note');
      expect(jsonDecode(lines[2])['text'], 'voltage reads 402V');
    },
  );

  test(
    "a second recording's sidecar gets only markers no earlier sidecar has",
    () async {
      var sessionCount = 0;
      final twoSessions = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'session-${++sessionCount}',
        clock: () => DateTime.utc(2026, 1, 1, 12),
      );
      addTearDown(twoSessions.dispose);

      await twoSessions.start();
      twoSessions.addNote('first recording');
      await twoSessions.stop();
      twoSessions.addNote('after first stop');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final firstSidecar = twoSessions.markersFilePath!;

      await twoSessions.start();
      await twoSessions.stop();
      final secondSidecar = twoSessions.markersFilePath!;
      expect(secondSidecar, isNot(firstSidecar));

      final first = (await File(firstSidecar).readAsLines())
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(first.map((line) => line['text']), [
        null,
        'first recording',
        'after first stop',
      ]);
      expect(first[2]['recording_active'], isFalse);

      final second = await File(secondSidecar).readAsLines();
      expect(second, hasLength(1));
      expect(jsonDecode(second[0])['type'], 'plan');
      expect(twoSessions.markers.markers, hasLength(2));
    },
  );

  test(
    'markers added after a failed start are flushed into the next recording',
    () async {
      var sessionCount = 0;
      final retried = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'session-${++sessionCount}',
        clock: () => DateTime.utc(2026, 1, 1, 12),
      );
      addTearDown(retried.dispose);

      await retried.start();
      retried.addNote('first recording');
      await retried.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      fakeNative.startRecordingResult = false;
      await retried.start();
      expect(retried.phase, RecordingPhase.error);
      retried.addNote('before second recording');

      fakeNative.startRecordingResult = true;
      await retried.start();

      final lines = await File(retried.markersFilePath!).readAsLines();
      expect(lines, hasLength(2));
      expect(jsonDecode(lines[1])['text'], 'before second recording');
      expect(jsonDecode(lines[1]).containsKey('recording_active'), isFalse);
    },
  );

  test('markers added while recording are appended live', () async {
    await controller.start();
    controller.addPhase(MarkerPhase.charge);
    // Marker writes are fire-and-forget; give the real file I/O time to land.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final markersFile = File(controller.markersFilePath!);
    final lines = await markersFile.readAsLines();
    expect(lines, hasLength(2));
    expect(jsonDecode(lines[1])['phase'], 'charge');
  });

  test(
    'a session with no markers still has a sidecar, with just the plan line',
    () async {
      await controller.start();
      await controller.stop();

      expect(controller.markersFilePath, isNotNull);
      expect(controller.shareableFiles, contains(contains('.markers.')));
      final lines = await File(controller.markersFilePath!).readAsLines();
      expect(lines, hasLength(1));
      expect(jsonDecode(lines[0])['type'], 'plan');
    },
  );

  group('marker sidecar plan line', () {
    test('matches the plan actually sent, headers included', () async {
      await controller.start();

      final lines = await File(controller.markersFilePath!).readAsLines();
      final planLine = jsonDecode(lines[0]) as Map<String, dynamic>;
      final sentPlan = fakeNative.lastStartRecordingRequest!.plan;

      expect(planLine['type'], 'plan');
      expect(planLine['planId'], sentPlan.planId);
      expect(planLine['planVersion'], sentPlan.planVersion);
      expect(planLine['at'], isA<String>());
      expect(DateTime.tryParse(planLine['at'] as String), isNotNull);

      final modules = planLine['modules'] as List<dynamic>;
      expect(modules, hasLength(sentPlan.modules.length));
      for (var i = 0; i < modules.length; i++) {
        final module = modules[i] as Map<String, dynamic>;
        final sentModule = sentPlan.modules[i];
        expect(module['id'], sentModule.moduleId);
        expect(module['protocol'], sentModule.protocol.toString());
      }
      // Fixed-plan headers, matching recording_controller.dart's own
      // constants.
      expect(modules[0]['request'], '18DA04F1');
      expect(modules[0]['response'], '18DAF104');
      expect(modules[1]['request'], '18DA06F1');
      expect(modules[1]['response'], '18DAF106');
      expect(modules[2]['request'], '710');
      expect(modules[2]['response'], '77A');
      expect(modules[0]['protocol'], '7');
      expect(modules[2]['protocol'], '6');
    });
  });

  group('reconnect limits', () {
    test('favor a long, interruption-tolerant session', () async {
      await controller.start();

      final limits = fakeNative.lastStartRecordingRequest!.plan.limits;
      expect(limits.maxReconnectAttemptsPerGap, 100000);
      expect(limits.reconnectBackoffMinMs, 2000);
      expect(limits.reconnectBackoffMaxMs, 60000);
      expect(limits.idleVehicleStopAfterMs, 1800000);
      // 0 means "no cap" — already past the 72h floor.
      expect(limits.maxRecordingMs, 0);
    });
  });

  group('connection status', () {
    test('connected link while recording reports connected', () async {
      fakeNative.liveStateResult = _liveStateWithLink(
        ObdLinkStateValueMessage.connected,
      );
      fakeNative.recordingStateResult = ObdRecordingStateMessage(
        state: ObdRecordingStateValueMessage.recording,
        lastFlushedSequence: 0,
        bufferBytes: 0,
        gapCount: 0,
        resumedAfterRestart: false,
        oneShotQueueDepth: 0,
      );
      controller = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'fixed-session-id',
        tickInterval: const Duration(milliseconds: 1),
      );

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.connectionStatus, isNotNull);
      expect(
        controller.connectionStatus!.state,
        RecordingConnectionState.connected,
      );

      await controller.stop();
    });

    test('a lost link while recording reports reconnecting, with an '
        'increasing attempt count', () async {
      fakeNative.liveStateResult = _liveStateWithLink(
        ObdLinkStateValueMessage.disconnected,
      );
      fakeNative.recordingStateResult = ObdRecordingStateMessage(
        state: ObdRecordingStateValueMessage.recording,
        lastFlushedSequence: 0,
        bufferBytes: 0,
        gapCount: 1,
        resumedAfterRestart: false,
        oneShotQueueDepth: 0,
      );
      controller = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'fixed-session-id',
        tickInterval: const Duration(milliseconds: 1),
      );

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final status = controller.connectionStatus!;
      expect(status.state, RecordingConnectionState.reconnecting);
      expect(status.reconnectingSince, isNotNull);
      expect(status.reconnectAttempt, greaterThan(1));

      await controller.stop();
    });
  });

  group('recording ended by native', () {
    test('switches out of recording immediately, with a banner, and keeps the '
        'buffer shareable', () async {
      fakeNative.liveStateResult = _liveStateWithLink(
        ObdLinkStateValueMessage.connected,
      );
      fakeNative.recordingStateResult = ObdRecordingStateMessage(
        state: ObdRecordingStateValueMessage.interrupted,
        lastFlushedSequence: 12,
        bufferBytes: 1000,
        gapCount: 3,
        writeError: 'reconnect attempts exhausted',
        resumedAfterRestart: false,
        oneShotQueueDepth: 0,
      );
      controller = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'fixed-session-id',
        tickInterval: const Duration(milliseconds: 1),
      );

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.phase, RecordingPhase.finished);
      expect(controller.canStart, isTrue);
      expect(controller.canShare, isTrue);
      expect(controller.nativeStopBanner, isNotNull);
      expect(
        controller.nativeStopBanner,
        contains('reconnect attempts exhausted'),
      );
      expect(
        controller.connectionStatus!.state,
        RecordingConnectionState.stopped,
      );
    });

    test('readings entered after native stopped the recording are flagged '
        'recording_active: false', () async {
      fakeNative.liveStateResult = _liveStateWithLink(
        ObdLinkStateValueMessage.connected,
      );
      fakeNative.recordingStateResult = ObdRecordingStateMessage(
        state: ObdRecordingStateValueMessage.interrupted,
        lastFlushedSequence: 0,
        bufferBytes: 0,
        gapCount: 1,
        writeError: 'reconnect attempts exhausted',
        resumedAfterRestart: false,
        oneShotQueueDepth: 0,
      );
      controller = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'fixed-session-id',
        tickInterval: const Duration(milliseconds: 1),
      );

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.phase, RecordingPhase.finished);

      controller.addNote('typed after the fact');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final lines = await File(controller.markersFilePath!).readAsLines();
      final noteLine = lines
          .map(jsonDecode)
          .whereType<Map<String, dynamic>>()
          .firstWhere((m) => m['type'] == 'note');
      expect(noteLine['recording_active'], isFalse);
    });
  });

  group('settings applied at start', () {
    const customSettings = AppSettings(
      readTimeoutMs: 3000,
      reconnectBackoffMinS: 5,
      reconnectBackoffMaxS: 90,
      neverGiveUpReconnecting: false,
      reconnectAttempts: 7,
      stopAfterNoVehicleDataMinutes: 10,
      maxReadsPerSecond: 4,
      surveyIntervalMinutes: 8,
      chargeReminderIntervalMinutes: 2,
      autoStartOnPower: false,
      recordOnlyWhilePoweredOn: false,
      scoutWhileRecording: false,
      scoutWhileDriving: false,
      recordingMode: RecordingMode.scoutAndRecordKnown,
      keepSamplingFoundDids: true,
      speedPollIntervalS: 20,
      discoveryBatchSize: 32,
    );

    RecordingController controllerWithSettings(AppSettings settings) =>
        RecordingController(
          requestRuntimePermissions: (permissions) async =>
              requestedPermissions.add(permissions),
          bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
          recordingsDirectory: () async => tempDir,
          sessionIdFactory: () => 'fixed-session-id',
          loadSettings: () async => settings,
        );

    test('applies the loaded settings to the plan limits', () async {
      controller = controllerWithSettings(customSettings);

      await controller.start();

      final limits = fakeNative.lastStartRecordingRequest!.plan.limits;
      expect(limits.adapterStepDeadlineMs, 3000);
      expect(limits.vehicleReadDeadlineMs, 3000);
      expect(limits.reconnectBackoffMinMs, 5000);
      expect(limits.reconnectBackoffMaxMs, 90000);
      expect(limits.maxReconnectAttemptsPerGap, 7);
      expect(limits.idleVehicleStopAfterMs, 10 * 60000);
      expect(limits.maxReadsPerSecond, 4);
      final speedStep = fakeNative.lastStartRecordingRequest!.plan.steps
          .firstWhere((s) => s.signalId == 'module7_22f40d');
      expect(speedStep.intervalMs, 20000);
    });

    test(
      'applies the loaded discovery batch size to the discovery engine',
      () async {
        controller = controllerWithSettings(
          customSettings.copyWith(scoutWhileRecording: true),
        );

        await controller.start();

        expect(controller.discoveryEngineForTesting!.batchSize, 32);
        expect(controller.discoveryEngineForTesting!.minQueueDepth, 64);
        expect(controller.discoveryEngineForTesting!.maxQueueDepth, 256);
      },
    );

    test('overrides only the DID steps generated at the survey interval, '
        'leaving watch/once DIDs at their generated interval', () async {
      controller = controllerWithSettings(customSettings);

      await controller.start();

      final steps = fakeNative.lastStartRecordingRequest!.plan.steps;
      // gateway/F189 is generated at 600000ms (a "once" DID) and must stay
      // untouched by the survey-interval setting.
      final onceStep = steps.firstWhere((s) => s.signalId == 'module6_22f189');
      expect(onceStep.intervalMs, 600000);
      // gateway/2A04 is generated at the survey default (180000ms) and
      // must take the configured 8-minute interval instead.
      final surveyStep = steps.firstWhere(
        (s) => s.signalId == 'module6_222a04',
      );
      expect(surveyStep.intervalMs, customSettings.surveyIntervalMs);
      expect(surveyStep.intervalMs, 8 * 60000);
    });

    test('an unavailable settings store falls back to defaults instead of '
        'failing the start', () async {
      controller = RecordingController(
        requestRuntimePermissions: (_) async {},
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
        recordingsDirectory: () async => tempDir,
        sessionIdFactory: () => 'fixed-session-id',
        loadSettings: () async => throw StateError('store unavailable'),
      );

      await controller.start();

      expect(controller.phase, RecordingPhase.recording);
      final limits = fakeNative.lastStartRecordingRequest!.plan.limits;
      expect(limits.maxReconnectAttemptsPerGap, 100000);
    });
  });

  test('buildPlanForTesting honors an explicit settings override', () {
    final plan = RecordingController.buildPlanForTesting(
      settings: const AppSettings.defaultValues().copyWith(
        maxReadsPerSecond: 8,
        surveyIntervalMinutes: 1,
        recordingMode: RecordingMode.scoutAndRecordKnown,
      ),
    );

    expect(plan.limits.maxReadsPerSecond, 8);
    final surveyStep = plan.steps.firstWhere(
      (s) => s.signalId == 'module6_222a04',
    );
    expect(surveyStep.intervalMs, 60000);
    // Sanity check the fixture DID used above is really generated at the
    // survey default, matching vag_ppe_plan_data.dart.
    final gateway = vagPpeModules.firstWhere((m) => m.id == 'gateway');
    final spec = gateway.dids.firstWhere((d) => d.did == '2A04');
    expect(spec.intervalMs, 180000);
  });
}
