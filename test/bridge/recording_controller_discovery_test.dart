import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` --
// this test needs it anyway, to build a fake in place of the real native
// channel (same pattern as `recording_controller_test.dart`).
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/bridge_read_executor.dart';
import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/discovery/discovery_ui_state.dart';
import 'package:didscout_app/session/session_markers.dart';
import 'package:didscout_app/settings/app_settings.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Records every call made through it, same "everything works" baseline as
/// `recording_controller_test.dart`'s fake, plus a hook for one-shot reads
/// so discovery can be driven deterministically: [respondToOneShot]
/// decides each submitted step's raw reply, delivered back through
/// [BridgeReadExecutor.deliverOneShotResult] once [executorGetter] can
/// resolve the executor the recording actually started (set once
/// `RecordingController.start` has returned).
class _FakeNativeObdApi extends NativeObdApi {
  ObdPermissionStatusMessage permissionStatusResult =
      ObdPermissionStatusMessage.granted;
  List<ObdAdapterMessage> scanResult = [
    ObdAdapterMessage(handle: 'cx', advertisedName: 'OBDLink CX', rssi: -40),
  ];
  ObdLinkStateValueMessage connectResult = ObdLinkStateValueMessage.connected;
  bool startRecordingResult = true;
  ObdLiveStateMessage? liveStateResult;
  ObdRecordingStateMessage? recordingStateResult;
  ObdStartRecordingRequest? lastStartRecordingRequest;

  final List<ObdStepMessage> enqueuedSteps = [];
  BridgeReadExecutor? Function()? executorGetter;
  String? Function(ObdStepMessage step)? respondToOneShot;

  @override
  Future<void> configure(ObdBridgeConfigMessage config) async {}

  @override
  Future<ObdPermissionStatusMessage> permissionStatus() async =>
      permissionStatusResult;

  @override
  Future<ObdPermissionStatusMessage> requestPermissions() async =>
      permissionStatusResult;

  @override
  Future<List<ObdAdapterMessage>> scanAdapters(int durationMs) async =>
      scanResult;

  @override
  Future<ObdLinkStateMessage> connect(String handle) async =>
      ObdLinkStateMessage(state: connectResult, adapterHandle: handle);

  @override
  Future<bool> startRecording(ObdStartRecordingRequest request) async {
    lastStartRecordingRequest = request;
    return startRecordingResult;
  }

  @override
  Future<void> stopRecording(String sessionId) async {}

  @override
  Future<ObdLiveStateMessage> liveState(List<String> signalIds) async {
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

  @override
  Future<ObdOneShotEnqueueResultMessage> enqueueOneShot(
    List<ObdModuleMessage> modules,
    List<ObdStepMessage> steps,
  ) async {
    enqueuedSteps.addAll(steps);
    final respond = respondToOneShot;
    if (respond != null) {
      // Scheduled on the event queue (not a microtask) so it always runs
      // after `BridgeReadExecutor.submit`'s own post-await bookkeeping --
      // real native can never report a result before its own enqueue ack.
      unawaited(
        Future<void>.delayed(Duration.zero, () {
          final executor = executorGetter?.call();
          if (executor == null) return;
          for (final step in steps) {
            executor.deliverOneShotResult(
              ObdSignalExchangeMessage(
                signalId: step.signalId,
                transport: ObdTransportStatusMessage.ok,
                rawResponseText: respond(step) ?? 'NO DATA',
              ),
            );
          }
        }),
      );
    }
    return ObdOneShotEnqueueResultMessage.accepted;
  }
}

/// A 29-bit live-state exchange reporting speed [speedKmh] via `22F40D` --
/// enough for `RecordingController`'s own decoder to report a non-null
/// speed, so discovery's `stationary` flag reflects it.
ObdLiveStateMessage _liveStateWithSpeed(int speedKmh) {
  final speedHex = speedKmh.toRadixString(16).toUpperCase().padLeft(2, '0');
  return ObdLiveStateMessage(
    link: ObdLinkStateMessage(state: ObdLinkStateValueMessage.connected),
    timebaseId: 't1',
    exchanges: [
      ObdSignalExchangeMessage(
        signalId: 'module7_22f40d',
        transport: ObdTransportStatusMessage.ok,
        rawResponseText: '18DAF104 04 62 F4 0D $speedHex',
        // The engine's stationary check requires a fresh speed reading
        // (see `AppSettings.speedFreshnessWindow`) -- "now" keeps every
        // fixture built from this helper fresh regardless of test timing.
        receivedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      ),
    ],
  );
}

void main() {
  // `RecordingController.start` wires `ObdEventsApi` (for discovery
  // results) through a real `BasicMessageChannel`, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeNativeObdApi fakeNative;
  late DiscoveryState? persistedState;
  late List<DiscoveryState> savedStates;

  Future<DiscoveryState> loadState() async =>
      persistedState ?? DiscoveryState();
  Future<void> saveState(DiscoveryState state) async {
    savedStates.add(state);
    persistedState = state;
  }

  RecordingController makeController({
    AppSettings settings = const AppSettings.defaultValues(),
    DateTime Function()? clock,
  }) {
    final controller = RecordingController(
      requestRuntimePermissions: (List<ph.Permission> _) async {},
      bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
      recordingsDirectory: () async => tempDir,
      sessionIdFactory: () => 'fixed-session-id',
      tickInterval: const Duration(milliseconds: 500),
      discoveryPumpInterval: const Duration(milliseconds: 5),
      loadSettings: () async => settings,
      loadDiscoveryState: loadState,
      saveDiscoveryState: saveState,
      clock: clock,
    );
    fakeNative.executorGetter = () => controller.discoveryExecutorForTesting;
    return controller;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('didscout_discovery_');
    fakeNative = _FakeNativeObdApi();
    persistedState = null;
    savedStates = [];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test(
    'scoutWhileRecording off never starts discovery or reads one-shot steps',
    () async {
      final controller = makeController(
        settings: const AppSettings.defaultValues().copyWith(
          scoutWhileRecording: false,
        ),
      );

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.discoveryUiState, isNull);
      expect(fakeNative.enqueuedSteps, isEmpty);

      await controller.stop();
    },
  );

  test(
    'a hit while recording is persisted and reported in discoveryUiState',
    () async {
      fakeNative.respondToOneShot = (step) {
        if (step.signalId == 'gateway_22f180') {
          // header 77A (gateway's own responder), single-frame positive
          // reply to `22F180`: `62 F1 80 AB`.
          return '77A 04 62 F1 80 AB';
        }
        return null;
      };
      final controller = makeController();

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await controller.stop();

      final engine = controller.discoveryEngineForTesting;
      expect(engine, isNull); // torn down by stop()
      expect(savedStates, isNotEmpty);
      final discovered = savedStates.last.ecus['gateway']?.discovered;
      expect(discovered, contains('F180'));
    },
  );

  test(
    'a discovered DID is part of the plan from the next recording on',
    () async {
      fakeNative.respondToOneShot = (step) {
        if (step.signalId == 'gateway_22f180') {
          return '77A 04 62 F1 80 AB';
        }
        return null;
      };
      final first = makeController();
      await first.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await first.stop();
      expect(persistedState!.ecus['gateway']?.discovered, contains('F180'));

      // A fresh recording picks up the persisted discovery state --
      // 'gateway' shares `module6`'s header (710/77A), so the discovered
      // DID is folded into `module6`, not a separate module.
      fakeNative.respondToOneShot = null;
      final second = makeController();
      await second.start();

      final plan = fakeNative.lastStartRecordingRequest!.plan;
      expect(
        plan.steps.any((s) => s.moduleId == 'module6' && s.command == '22F180'),
        isTrue,
      );
      expect(plan.modules.where((m) => m.moduleId == 'module6'), hasLength(1));

      await second.stop();
    },
  );

  test(
    'moving with scoutWhileDriving off never submits a one-shot read',
    () async {
      // No `liveStateResult` configured -- speed stays unknown, which this
      // app treats as moving, never as stationary.
      final controller = makeController(
        settings: const AppSettings.defaultValues().copyWith(
          scoutWhileDriving: false,
        ),
      );

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fakeNative.enqueuedSteps, isEmpty);
      expect(
        controller.discoveryUiState?.activity,
        DiscoveryActivity.waitingMoving,
      );

      await controller.stop();
    },
  );

  test(
    'stationary (speed 0) runs discovery even with scoutWhileDriving off',
    () async {
      fakeNative.liveStateResult = _liveStateWithSpeed(0);
      fakeNative.respondToOneShot = (_) => null;
      final controller = makeController(
        settings: const AppSettings.defaultValues().copyWith(
          scoutWhileDriving: false,
        ),
      );

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(fakeNative.enqueuedSteps, isNotEmpty);

      await controller.stop();
    },
  );

  test('a stale speed=0 reading outside the freshness window is treated as '
      'moving, not stationary', () async {
    fakeNative.liveStateResult = _liveStateWithSpeed(0);
    fakeNative.respondToOneShot = (_) => null;
    // The default speedPollIntervalS (20s) gives a 50s freshness window;
    // a clock running 5 minutes ahead of the fixture's real-time
    // `receivedAtEpochMs` makes every speed reading look stale.
    final controller = makeController(
      settings: const AppSettings.defaultValues().copyWith(
        scoutWhileDriving: false,
      ),
      clock: () => DateTime.now().add(const Duration(minutes: 5)),
    );

    await controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(fakeNative.enqueuedSteps, isEmpty);
    expect(
      controller.discoveryUiState?.activity,
      DiscoveryActivity.waitingMoving,
    );

    await controller.stop();
  });

  test('stop cancels an in-flight discovery batch instead of waiting out its '
      'deadline', () async {
    // Never set up: every enqueued one-shot step is simply never
    // answered, same as a result the plugin dropped mid-recording.
    fakeNative.respondToOneShot = null;
    final controller = makeController();

    await controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fakeNative.enqueuedSteps, isNotEmpty);

    final stopwatch = Stopwatch()..start();
    await controller.stop();
    stopwatch.stop();

    // The engine's own default batch deadline alone is tens of
    // seconds; completing well under that proves `stop()` cancelled
    // the in-flight batch rather than waiting it out.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(controller.discoveryEngineForTesting, isNull);
  });

  test('addPhase queues conditional retries on the discovery engine', () async {
    fakeNative.respondToOneShot = (step) {
      // Every DID answers "conditions not correct" (NRC 22) -- becomes
      // conditional, nothing discovered yet.
      return '77A 03 7F22 22';
    };
    final controller = makeController();
    await controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final engine = controller.discoveryEngineForTesting!;
    final gateway = engine.state.ecus['gateway']!;
    expect(gateway.conditional, isNotEmpty);
    expect(gateway.retryQueue, isEmpty);

    controller.addPhase(MarkerPhase.drive);

    expect(gateway.retryQueue, isNotEmpty);

    await controller.stop();
  });
}
