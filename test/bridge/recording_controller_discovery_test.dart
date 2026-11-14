import 'dart:async';
import 'dart:convert';
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
import 'package:didscout_app/discovery/did_stability.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/discovery/discovery_ui_state.dart';
import 'package:didscout_app/discovery/phase_focus.dart';
import 'package:didscout_app/discovery/probe.dart';
import 'package:didscout_app/session/experiments.dart';
import 'package:didscout_app/session/session_markers.dart';
import 'package:didscout_app/settings/app_settings.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../support/wait_for.dart';

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
  final List<List<ObdStepMessage>> enqueuedBatches = [];
  BridgeReadExecutor? Function()? executorGetter;
  String? Function(ObdStepMessage step)? respondToOneShot;

  /// Signal ids whose one-shot reads never get a result.
  final Set<String> unanswered = {};

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
  Future<void> disconnect() async {}

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
    enqueuedBatches.add(steps);
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
            if (unanswered.contains(step.signalId)) continue;
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

/// Persisted state naming the gateway, so it is scanned while the speed
/// is unknown (treated as moving) -- an unnamed ECU never is.
DiscoveryState _namedGatewayState() => DiscoveryState(
  ecus: {
    'gateway': EcuInfo(
      requestHeader: '710',
      responseHeader: '77A',
      protocol: 6,
      identification: {'F197': 'Gateway'},
    ),
  },
);

/// A named 11-bit ECU as an inventory sweep stores it, with [discovered]
/// DIDs.
EcuInfo _namedEcu(
  String request,
  String response,
  String name,
  Set<String> discovered, {
  Map<String, DidSampleStats>? sampleStats,
}) => EcuInfo(
  requestHeader: request,
  responseHeader: response,
  protocol: 6,
  identification: {'F197': name},
  discovered: discovered,
  sampleStats: sampleStats,
);

/// Settings that keep discovery itself idle while the speed is unknown, so
/// every one-shot read a test sees is a focus read.
final AppSettings _focusOnlySettings = const AppSettings.defaultValues()
    .copyWith(scoutWhileDriving: false);

/// The `modules` entries of every `{"type":"modules",…}` line in the
/// sidecar at [path], one list per line.
List<List<dynamic>> _sidecarModulesLines(String path) => [
  for (final line in File(path).readAsLinesSync())
    if (jsonDecode(line) case {
      'type': 'modules',
      'modules': final List<dynamic> modules,
    })
      modules,
];

void main() {
  // `RecordingController.start` wires `ObdEventsApi` (for discovery
  // results) through a real `BasicMessageChannel`, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeNativeObdApi fakeNative;
  late DiscoveryState? persistedState;
  late List<DiscoveryState> savedStates;

  /// [savedStates] as each was encoded at the moment it was saved.
  late List<String> savedJsons;

  Future<DiscoveryState> loadState() async =>
      persistedState ?? DiscoveryState();
  Future<void> saveState(DiscoveryState state) async {
    savedStates.add(state);
    savedJsons.add(jsonEncode(state.toJson()));
    persistedState = state;
  }

  RecordingController makeController({
    AppSettings settings = const AppSettings.defaultValues(),
    DateTime Function()? clock,
    Duration testplanInitialDelay = const Duration(seconds: 8),
  }) {
    final controller = RecordingController(
      requestRuntimePermissions: (List<ph.Permission> _) async {},
      bridge: ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
      recordingsDirectory: () async => tempDir,
      sessionIdFactory: () => 'fixed-session-id',
      tickInterval: const Duration(milliseconds: 500),
      discoveryPumpInterval: const Duration(milliseconds: 5),
      focusSampleInterval: const Duration(milliseconds: 20),
      testplanInitialDelay: testplanInitialDelay,
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
    savedJsons = [];
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
      persistedState = _namedGatewayState();
      final controller = makeController();

      await controller.start();
      await waitFor(
        () =>
            controller
                .discoveryEngineForTesting
                ?.state
                .ecus['gateway']
                ?.discovered
                .contains('F180') ??
            false,
      );
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
      persistedState = _namedGatewayState();
      final first = makeController();
      await first.start();
      await waitFor(
        () =>
            first.discoveryEngineForTesting?.state.ecus['gateway']?.discovered
                .contains('F180') ??
            false,
      );
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

  test('start learns from finished recordings before planning, even with '
      'scouting off', () async {
    persistedState = DiscoveryState(
      ecus: {
        'door-front-left': EcuInfo(
          requestHeader: '74A',
          responseHeader: '7B4',
          protocol: 6,
          discovered: {'2A00', '2A01'},
        ),
      },
    );
    // Two earlier recordings in which 2A00 never changes and 2A01 does.
    String hexOf(String text) =>
        text.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join();
    for (final (index, sessionId) in ['earlier-1', 'earlier-2'].indexed) {
      final buffer = File('${tempDir.path}/$sessionId.jsonl');
      buffer.writeAsStringSync(
        [
          jsonEncode({'sessionId': sessionId, 'createdUtcMs': index}),
          for (var i = 0; i < 5; i++) ...[
            jsonEncode({
              'signalId': 'door-front-left_222a00',
              'raw': hexOf('7B4 04 62 2A 00 01'),
              'transport': 'ok',
            }),
            jsonEncode({
              'signalId': 'door-front-left_222a01',
              'raw': hexOf('7B4 04 62 2A 01 0$i'),
              'transport': 'ok',
            }),
          ],
        ].join('\n'),
      );
      File('${buffer.path}.markers.jsonl').writeAsStringSync(
        jsonEncode({
          'type': 'plan',
          'modules': [
            {
              'id': 'door-front-left',
              'request': '74A',
              'response': '7B4',
              'protocol': '6',
            },
          ],
        }),
      );
    }
    final controller = makeController(
      settings: const AppSettings.defaultValues().copyWith(
        scoutWhileRecording: false,
      ),
    );

    await controller.start();

    final intervals = {
      for (final step in fakeNative.lastStartRecordingRequest!.plan.steps)
        step.signalId: step.intervalMs,
    };
    expect(intervals['door-front-left_222a00'], stableDidIntervalMs);
    expect(
      intervals['door-front-left_222a01'],
      const AppSettings.defaultValues().surveyIntervalMs,
    );
    expect(persistedState!.learnedRecordings, {'earlier-1', 'earlier-2'});

    await controller.stop();
  });

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
      await waitFor(() => fakeNative.enqueuedSteps.isNotEmpty);

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
    expect(controller.liveInfo.speedKmh, isNull);
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
    persistedState = _namedGatewayState();
    final controller = makeController();

    await controller.start();
    await waitFor(() => fakeNative.enqueuedSteps.isNotEmpty);

    final stopwatch = Stopwatch()..start();
    await controller.stop();
    stopwatch.stop();

    // The engine's own default batch deadline alone is tens of
    // seconds; completing well under that proves `stop()` cancelled
    // the in-flight batch rather than waiting it out.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(controller.discoveryEngineForTesting, isNull);
  });

  test('one-shot modules outside the plan are recorded once per recording '
      'in the sidecar; plan and sweep modules never', () async {
    persistedState = DiscoveryState(
      ecus: {
        'door-front-left': EcuInfo(
          requestHeader: '74A',
          responseHeader: '7B4',
          protocol: 6,
          discovered: {'2A00'},
        ),
      },
    );
    // Unknown speed with scoutWhileDriving off keeps the engine idle, so
    // only the batches submitted below reach the executor.
    final controller = makeController(
      settings: const AppSettings.defaultValues().copyWith(
        scoutWhileDriving: false,
      ),
    );
    const gateway = ProbeModule(
      id: 'gateway',
      requestHeader: '710',
      responseHeader: '77A',
      protocol: 6,
    );
    const cluster = ProbeModule(
      id: 'cluster',
      requestHeader: '714',
      responseHeader: '77E',
      protocol: 6,
    );
    const doorFrontLeft = ProbeModule(
      id: 'door-front-left',
      requestHeader: '74A',
      responseHeader: '7B4',
      protocol: 6,
    );
    const sweep = ProbeModule(
      id: 'ecu11-70C',
      requestHeader: '70C',
      protocol: 6,
      receiveFilter: '700',
      receiveMask: '700',
    );
    Future<void> submit(List<ProbeModule> modules) =>
        controller.discoveryExecutorForTesting!.submit(modules, [
          for (final module in modules)
            ProbeStep(signalId: '${module.id}_22f189', command: '22F189'),
        ]);
    Map<String, String> entry(String id, String request, String response) => {
      'id': id,
      'request': request,
      'response': response,
      'protocol': '6',
    };

    await controller.start();
    final sidecar = controller.markersFilePath!;
    expect(
      fakeNative.lastStartRecordingRequest!.plan.modules.map((m) => m.moduleId),
      contains('door-front-left'),
    );
    await submit([gateway, doorFrontLeft, sweep, gateway]);
    await waitFor(() => _sidecarModulesLines(sidecar).length == 1);
    await submit([gateway, cluster]);
    await waitFor(() => _sidecarModulesLines(sidecar).length == 2);
    await controller.stop();

    final lines = [
      for (final line in File(sidecar).readAsLinesSync())
        jsonDecode(line) as Map<String, dynamic>,
    ];
    expect(lines.first['type'], 'plan');
    final modulesLine = lines.firstWhere((line) => line['type'] == 'modules');
    expect(modulesLine.keys, unorderedEquals(['type', 'at', 'modules']));
    expect(DateTime.parse(modulesLine['at'] as String).isUtc, isTrue);
    expect(_sidecarModulesLines(sidecar), [
      [entry('gateway', '710', '77A')],
      [entry('cluster', '714', '77E')],
    ]);

    await controller.start();
    await submit([gateway]);
    await waitFor(() => _sidecarModulesLines(sidecar).isNotEmpty);
    await controller.stop();

    expect(_sidecarModulesLines(sidecar), [
      [entry('gateway', '710', '77A')],
    ]);
  });

  test('addPhase queues conditional retries on the discovery engine', () async {
    fakeNative.respondToOneShot = (step) {
      // Every DID answers "conditions not correct" (NRC 22) -- becomes
      // conditional, nothing discovered yet.
      return '77A 03 7F22 22';
    };
    persistedState = _namedGatewayState();
    final controller = makeController();
    await controller.start();
    await waitFor(
      () =>
          controller
              .discoveryEngineForTesting
              ?.state
              .ecus['gateway']
              ?.conditional
              .isNotEmpty ??
          false,
    );

    final engine = controller.discoveryEngineForTesting!;
    final gateway = engine.state.ecus['gateway']!;
    expect(gateway.retryQueue, isEmpty);

    controller.addPhase(MarkerPhase.drive);

    expect(gateway.retryQueue, isNotEmpty);

    await controller.stop();
  });

  group('phase focus sampling', () {
    test("reads the current phase's focus ECUs only, under the plan's "
        'signal ids, leaving out stable DIDs', () async {
      fakeNative.respondToOneShot = (_) => null;
      persistedState = DiscoveryState(
        ecus: {
          'ecus11-74A': _namedEcu(
            '74A',
            '7B4',
            'Door FL',
            {'2A00', '2A01', '2A02', 'F187'},
            sampleStats: {
              '2A02': DidSampleStats(
                lastPayloadHash: 1,
                stableSamples: stableSampleCount,
                stableRecordings: stableRecordingCount,
              ),
            },
          ),
          'ecus11-742': _namedEcu('742', '7AC', 'Thermal', {'2600'}),
        },
      );
      final controller = makeController(settings: _focusOnlySettings);

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fakeNative.enqueuedSteps, isEmpty, reason: 'no phase set yet');

      controller.addPhase(MarkerPhase.stand);
      expect(
        controller.discoveryEngineForTesting!.focusRequestHeaders,
        phaseFocusRequestHeaders[MarkerPhase.stand],
      );
      await waitFor(() => fakeNative.enqueuedBatches.isNotEmpty);
      final standBatch = fakeNative.enqueuedBatches.first;
      expect(
        [for (final step in standBatch) step.signalId],
        ['ecus11-74A_222a00', 'ecus11-74A_222a01'],
      );
      expect(
        [for (final step in standBatch) step.command],
        ['222A00', '222A01'],
      );
      final planSignalIds = {
        for (final step in fakeNative.lastStartRecordingRequest!.plan.steps)
          step.signalId,
      };
      expect(planSignalIds, containsAll(standBatch.map((s) => s.signalId)));

      controller.addPhase(MarkerPhase.charge);
      expect(
        controller.discoveryEngineForTesting!.focusRequestHeaders,
        phaseFocusRequestHeaders[MarkerPhase.charge],
      );
      final batchesBefore = fakeNative.enqueuedBatches.length;
      await waitFor(() => fakeNative.enqueuedBatches.length > batchesBefore);
      expect(
        [for (final step in fakeNative.enqueuedBatches.last) step.signalId],
        ['ecus11-742_222600'],
      );
      expect(
        controller.scoutStatus?.lastResultSummary,
        isNull,
        reason: 'focus results never reach the discovery engine',
      );

      await controller.stop();
    });

    test('reads at most maxPhaseFocusReads per sample, rotating through '
        'the rest', () async {
      fakeNative.respondToOneShot = (_) => null;
      final dids = [
        for (var i = 0; i < maxPhaseFocusReads + 10; i++)
          (0x2A00 + i).toRadixString(16).toUpperCase(),
      ];
      persistedState = DiscoveryState(
        ecus: {'ecus11-74A': _namedEcu('74A', '7B4', 'Door FL', dids.toSet())},
      );
      final controller = makeController(settings: _focusOnlySettings);
      controller.addPhase(MarkerPhase.park);

      await controller.start();
      await waitFor(() => fakeNative.enqueuedBatches.length >= 2);
      await controller.stop();

      List<String> commandsOf(List<ObdStepMessage> batch) => [
        for (final step in batch) step.command.substring(2),
      ];
      expect(commandsOf(fakeNative.enqueuedBatches[0]), [
        ...dids.take(maxPhaseFocusReads),
      ]);
      expect(commandsOf(fakeNative.enqueuedBatches[1]), [
        ...dids.skip(maxPhaseFocusReads),
        ...dids.take(maxPhaseFocusReads - 10),
      ]);
    });

    test('reads a DID whose value moved in every sample, ahead of the '
        'rotation', () async {
      final dids = [
        for (var i = 0; i < maxPhaseFocusReads + 10; i++)
          (0x2A00 + i).toRadixString(16).toUpperCase(),
      ];
      final moving = dids.last;
      var counter = 0;
      fakeNative.respondToOneShot = (step) {
        final did = step.command.substring(2);
        final value = did == moving ? (counter++ & 0xFF) : 0;
        return '7B4 04 62 $did ${value.toRadixString(16).padLeft(2, '0')}';
      };
      persistedState = DiscoveryState(
        ecus: {'ecus11-74A': _namedEcu('74A', '7B4', 'Door FL', dids.toSet())},
      );
      final controller = makeController(settings: _focusOnlySettings);
      controller.addPhase(MarkerPhase.park);

      await controller.start();
      await waitFor(() => fakeNative.enqueuedBatches.length >= 6);
      await controller.stop();

      final firsts = [
        for (final batch in fakeNative.enqueuedBatches.take(6))
          batch.first.command.substring(2),
      ];
      // Read once per rotation until two reads differ, then first in
      // every sample.
      expect(firsts.take(3), everyElement(isNot(moving)));
      expect(firsts.skip(3), everyElement(moving));
      expect(
        fakeNative.enqueuedBatches[3].where(
          (step) => step.command == '22$moving',
        ),
        hasLength(1),
      );
    });

    test('skips a sample while the previous one is unanswered', () async {
      // Never set up: no focus read is ever answered.
      fakeNative.respondToOneShot = null;
      persistedState = DiscoveryState(
        ecus: {
          'ecus11-74A': _namedEcu('74A', '7B4', 'Door FL', {'2A00'}),
        },
      );
      final controller = makeController(settings: _focusOnlySettings);
      controller.addPhase(MarkerPhase.stand);

      await controller.start();
      await waitFor(() => fakeNative.enqueuedBatches.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await controller.stop();

      expect(fakeNative.enqueuedBatches, hasLength(1));
    });

    test('never samples after stop', () async {
      fakeNative.respondToOneShot = (_) => null;
      persistedState = DiscoveryState(
        ecus: {
          'ecus11-74A': _namedEcu('74A', '7B4', 'Door FL', {'2A00'}),
        },
      );
      final controller = makeController(settings: _focusOnlySettings);
      controller.addPhase(MarkerPhase.stand);

      await controller.start();
      await waitFor(() => fakeNative.enqueuedBatches.length >= 2);
      await controller.stop();
      final batchesAtStop = fakeNative.enqueuedBatches.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(fakeNative.enqueuedBatches, hasLength(batchesAtStop));
    });

    test(
      'while moving, never reads an ECU the moving blocklist keeps out',
      () async {
        fakeNative.respondToOneShot = (_) => null;
        persistedState = DiscoveryState(
          ecus: {
            'ecus11-74A': _namedEcu('74A', '7B4', 'Door FL', {'2A00'}),
            'ecus11-74B': _namedEcu('74B', '7B5', 'Airbag', {'2A00'}),
            // No F197 name: unknown, so blocked as well.
            'ecus11-73E': EcuInfo(
              requestHeader: '73E',
              responseHeader: '7A8',
              protocol: 6,
              discovered: {'2A00'},
            ),
          },
        );
        final controller = makeController(settings: _focusOnlySettings);
        controller.addPhase(MarkerPhase.stand);

        await controller.start();
        await waitFor(() => fakeNative.enqueuedBatches.length >= 2);
        await controller.stop();

        expect(
          {for (final step in fakeNative.enqueuedSteps) step.signalId},
          {'ecus11-74A_222a00'},
        );
      },
    );

    test('keepSamplingFoundDids off never samples', () async {
      persistedState = DiscoveryState(
        ecus: {
          'ecus11-74A': _namedEcu('74A', '7B4', 'Door FL', {'2A00'}),
        },
      );
      final controller = makeController(
        settings: _focusOnlySettings.copyWith(keepSamplingFoundDids: false),
      );
      controller.addPhase(MarkerPhase.stand);

      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await controller.stop();

      expect(fakeNative.enqueuedSteps, isEmpty);
    });
  });

  group('guided experiments', () {
    const doorSignal = 'door-front-left_22';
    late int doorByte;

    /// The driver door ECU under its vag-ppe seed id, with 2A01 stable.
    DiscoveryState doorState(Set<String> discovered) => DiscoveryState(
      ecus: {
        'door-front-left': _namedEcu(
          '74A',
          '7B4',
          'Door FL',
          discovered,
          sampleStats: {
            '2A01': DidSampleStats(
              lastPayloadHash: 1,
              stableSamples: stableSampleCount,
              stableRecordings: stableRecordingCount,
            ),
          },
        ),
      },
    );

    String? respondAsDoor(ObdStepMessage step) => switch (step.signalId) {
      'door-front-left_222a00' =>
        '7B4 04 62 2A 00 ${doorByte.toRadixString(16).padLeft(2, '0')}',
      'door-front-left_222a01' => '7B4 04 62 2A 01 11',
      // Refused rather than NO DATA, so discovery never pauses the ECU
      // as asleep.
      final id when id.startsWith(doorSignal) => '7B4 03 7F 22 31',
      _ => null,
    };

    List<ExperimentStep> experimentSteps(RecordingController controller) => [
      for (final marker
          in controller.markers.markers.whereType<ExperimentMarker>())
        marker.step,
    ];

    ExperimentFailure? lastReason(RecordingController controller) =>
        controller.markers.markers.whereType<ExperimentMarker>().last.reason;

    List<List<String>> experimentBatches() => [
      for (final batch in fakeNative.enqueuedBatches)
        if (batch.any((step) => step.signalId == '${doorSignal}2a01'))
          [for (final step in batch) step.signalId],
    ];

    Future<RecordingController> startStationary({
      Set<String> discovered = const {'2A00', '2A01', '2A02'},
      DateTime Function()? clock,
    }) async {
      doorByte = 0x00;
      fakeNative
        ..respondToOneShot = respondAsDoor
        ..liveStateResult = _liveStateWithSpeed(0);
      persistedState = doorState(discovered);
      final controller = makeController(clock: clock);
      controller.addPhase(MarkerPhase.park);
      await controller.start();
      await waitFor(() => controller.experimentSuggestions.isNotEmpty);
      return controller;
    }

    test('nothing is suggested before the vehicle is known to stand', () async {
      persistedState = doorState({'2A00'});
      final controller = makeController();
      controller.addPhase(MarkerPhase.park);

      await controller.start();
      expect(controller.experimentSuggestions, isEmpty);

      controller.startExperiment('door-driver');
      expect(controller.experimentRun, isNull);
      expect(experimentSteps(controller), isEmpty);

      await controller.stop();
    });

    test('a run reads all found DIDs before the action, after it and after '
        'its undo, and reports what changed and what returned', () async {
      final controller = await startStationary();
      var latchByte = 0x00;
      fakeNative.respondToOneShot = (step) => switch (step.signalId) {
        'door-front-left_222a02' =>
          '7B4 04 62 2A 02 ${latchByte.toRadixString(16).padLeft(2, '0')}',
        _ => respondAsDoor(step),
      };
      expect(
        [
          for (final experiment in controller.experimentSuggestions)
            experiment.id,
        ],
        ['door-driver', 'window-driver', 'lock'],
      );

      controller.startExperiment('door-driver');
      expect(controller.experimentRun, isA<ExperimentCapturing>());
      expect(experimentSteps(controller), [ExperimentStep.before]);
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);
      expect(experimentSteps(controller), [
        ExperimentStep.before,
        ExperimentStep.action,
      ]);
      controller.confirmExperimentUndo();
      expect(controller.experimentRun, isA<ExperimentAwaitingAction>());
      expect(experimentSteps(controller), hasLength(2));

      doorByte = 0x01;
      latchByte = 0x05;
      controller.confirmExperimentAction();
      expect(
        controller.experimentRun,
        isA<ExperimentCapturing>().having(
          (run) => run.stage,
          'stage',
          ExperimentCaptureStage.after,
        ),
      );
      await waitFor(() => controller.experimentRun is ExperimentAwaitingUndo);
      expect(experimentSteps(controller), [
        ExperimentStep.before,
        ExperimentStep.action,
        ExperimentStep.after,
        ExperimentStep.undo,
      ]);
      expect(persistedState!.experimentCompletions, isEmpty);

      doorByte = 0x00;
      controller.confirmExperimentUndo();
      expect(
        controller.experimentRun,
        isA<ExperimentCapturing>().having(
          (run) => run.stage,
          'stage',
          ExperimentCaptureStage.undone,
        ),
      );
      await waitFor(() => controller.experimentRun is ExperimentDone);
      expect(experimentSteps(controller), [
        ExperimentStep.before,
        ExperimentStep.action,
        ExperimentStep.after,
        ExperimentStep.undo,
        ExperimentStep.undone,
      ]);

      final done = controller.experimentRun! as ExperimentDone;
      expect(done.experiment.id, 'door-driver');
      expect(done.changes.keys, ['74A']);
      final diffs = done.changes['74A']!;
      expect([for (final diff in diffs) diff.did], ['2A00', '2A02']);
      expect(
        [
          for (final change in diffs.first.changes)
            (change.position, change.before, change.after),
        ],
        [(0, 0x00, 0x01)],
      );
      expect(done.notReturned, {(header: '74A', did: '2A02')});
      expect(controller.ecuName('74A'), 'Door FL');

      // The stable 2A01 is read as well, which focus sampling leaves out.
      expect(experimentBatches(), [
        for (var i = 0; i < 3; i++)
          ['${doorSignal}2a00', '${doorSignal}2a01', '${doorSignal}2a02'],
      ]);

      bool completionSaved(String json) => switch (jsonDecode(json)) {
        {'experimentCompletions': {'door-driver': 1}} => true,
        _ => false,
      };
      await waitFor(() => savedJsons.any(completionSaved));
      expect(
        controller.experimentSuggestions.first.id,
        'window-driver',
        reason: 'the completed experiment moves to the back',
      );

      controller.dismissExperiment();
      expect(controller.experimentRun, isNull);
      await controller.stop();
    });

    test('a result names the read DIDs whose value also moved in focus '
        'samples, and the action itself never counts as such', () async {
      final controller = await startStationary();
      var counter = 0;
      fakeNative.respondToOneShot = (step) => switch (step.signalId) {
        'door-front-left_222a02' =>
          '7B4 04 62 2A 02 ${(counter++ & 0xFF).toRadixString(16).padLeft(2, '0')}',
        _ => respondAsDoor(step),
      };
      int focusReadsOf2A02() => fakeNative.enqueuedBatches
          .where(
            (batch) =>
                batch.any((step) => step.signalId == '${doorSignal}2a02') &&
                !batch.any((step) => step.signalId == '${doorSignal}2a01'),
          )
          .length;
      final focusAtStart = focusReadsOf2A02();
      await waitFor(() => focusReadsOf2A02() >= focusAtStart + 3);

      controller.startExperiment('door-driver');
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);
      // Several focus intervals pass before and after the owner's action.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      doorByte = 0x01;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      controller.confirmExperimentAction();
      await waitFor(() => controller.experimentRun is ExperimentAwaitingUndo);
      controller.confirmExperimentUndo();
      await waitFor(() => controller.experimentRun is ExperimentDone);
      final first = controller.experimentRun! as ExperimentDone;
      expect(
        {for (final diff in first.changes['74A']!) diff.did},
        {'2A00', '2A02'},
      );
      expect(first.movingOnTheirOwn, {(header: '74A', did: '2A02')});
      controller.dismissExperiment();

      // Focus samples after the run see 2A00 at its new value; that is
      // the action, not 2A00 moving on its own.
      final focusBefore = focusReadsOf2A02();
      await waitFor(() => focusReadsOf2A02() >= focusBefore + 3);
      controller.startExperiment('door-driver');
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);
      doorByte = 0x00;
      controller.confirmExperimentAction();
      await waitFor(() => controller.experimentRun is ExperimentAwaitingUndo);
      controller.confirmExperimentUndo();
      await waitFor(() => controller.experimentRun is ExperimentDone);
      final second = controller.experimentRun! as ExperimentDone;
      expect(second.movingOnTheirOwn, {(header: '74A', did: '2A02')});

      await controller.stop();
    });

    test('focus sampling leaves the target ECU out until the run ends, '
        'also while the owner undoes the action', () async {
      final controller = await startStationary();
      int focusReadsOfDoor() => fakeNative.enqueuedBatches
          .where(
            (batch) =>
                batch.any((step) => step.signalId == '${doorSignal}2a00') &&
                !batch.any((step) => step.signalId == '${doorSignal}2a01'),
          )
          .length;
      final atStart = focusReadsOfDoor();
      await waitFor(() => focusReadsOfDoor() > atStart);

      controller.startExperiment('door-driver');
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);
      controller.confirmExperimentAction();
      await waitFor(() => controller.experimentRun is ExperimentAwaitingUndo);
      final whileUndoing = focusReadsOfDoor();
      // Five focus intervals.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(focusReadsOfDoor(), whileUndoing);

      controller.confirmExperimentUndo();
      await waitFor(() => controller.experimentRun is ExperimentDone);
      await waitFor(() => focusReadsOfDoor() > whileUndoing);

      await controller.stop();
    });

    test('a capture reads at most maxExperimentReads DIDs', () async {
      final controller = await startStationary(
        discovered: {
          for (var i = 0; i < maxExperimentReads + 20; i++)
            (0x2A00 + i).toRadixString(16).toUpperCase(),
        },
      );

      controller.startExperiment('door-driver');
      await waitFor(() => experimentBatches().isNotEmpty);

      expect(experimentBatches().first, hasLength(maxExperimentReads));
      await controller.stop();
    });

    test('a capture completes at its deadline without the unanswered '
        'reads', () async {
      var offset = Duration.zero;
      fakeNative.unanswered.add('${doorSignal}2a01');
      final controller = await startStationary(
        clock: () => DateTime.now().add(offset),
      );

      controller.startExperiment('door-driver');
      await waitFor(
        () => switch (controller.experimentRun) {
          ExperimentCapturing(:final answered, :final total) =>
            answered == total - 1,
          _ => false,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.experimentRun, isA<ExperimentCapturing>());

      // 30 s plus 2 s per read; still within the speed's freshness window.
      offset = const Duration(seconds: 37);
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);

      await controller.stop();
    });

    test('cancelling records a cancelled marker and drops the run', () async {
      final controller = await startStationary();
      controller.startExperiment('door-driver');
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);

      controller.cancelExperiment();

      expect(
        controller.experimentRun,
        isA<ExperimentFailed>().having(
          (run) => run.failure,
          'failure',
          ExperimentFailure.cancelled,
        ),
      );
      expect(experimentSteps(controller), [
        ExperimentStep.before,
        ExperimentStep.action,
        ExperimentStep.cancelled,
      ]);
      expect(lastReason(controller), ExperimentFailure.cancelled);
      controller
        ..confirmExperimentAction()
        ..confirmExperimentUndo();
      expect(experimentSteps(controller), hasLength(3));
      expect(persistedState!.experimentCompletions, isEmpty);

      await controller.stop();
    });

    test('a run no target ECU answers fails, with the reason in the '
        'sidecar', () async {
      final controller = await startStationary();
      final sidecar = controller.markersFilePath!;
      fakeNative.respondToOneShot = (step) =>
          step.signalId.startsWith(doorSignal) ? '7B4 03 7F 22 31' : null;

      controller.startExperiment('door-driver');
      await waitFor(() => controller.experimentRun is ExperimentFailed);

      expect(
        (controller.experimentRun! as ExperimentFailed).failure,
        ExperimentFailure.noAnswer,
      );
      List<Map<String, dynamic>> experimentLines() => [
        for (final line in File(sidecar).readAsLinesSync())
          if (jsonDecode(line) case final Map<String, dynamic> json
              when json['type'] == 'experiment')
            json..remove('at'),
      ];
      await waitFor(() => experimentLines().length == 2);
      expect(experimentLines(), [
        {'type': 'experiment', 'id': 'door-driver', 'step': 'before'},
        {
          'type': 'experiment',
          'id': 'door-driver',
          'step': 'cancelled',
          'reason': 'noAnswer',
        },
      ]);

      await controller.stop();
    });

    test('the run is cancelled once the vehicle moves', () async {
      final controller = await startStationary();
      controller.startExperiment('door-driver');
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);

      fakeNative.liveStateResult = _liveStateWithSpeed(30);
      await waitFor(() => controller.experimentRun is ExperimentFailed);

      expect(
        (controller.experimentRun! as ExperimentFailed).failure,
        ExperimentFailure.moving,
      );
      expect(experimentSteps(controller).last, ExperimentStep.cancelled);
      expect(lastReason(controller), ExperimentFailure.moving);
      expect(controller.experimentSuggestions, isEmpty);

      await controller.stop();
    });

    test('the run is cancelled once the vehicle moves while the owner '
        'undoes the action', () async {
      final controller = await startStationary();
      controller.startExperiment('door-driver');
      await waitFor(() => controller.experimentRun is ExperimentAwaitingAction);
      controller.confirmExperimentAction();
      await waitFor(() => controller.experimentRun is ExperimentAwaitingUndo);

      fakeNative.liveStateResult = _liveStateWithSpeed(30);
      await waitFor(() => controller.experimentRun is ExperimentFailed);

      expect(
        (controller.experimentRun! as ExperimentFailed).failure,
        ExperimentFailure.moving,
      );
      expect(experimentSteps(controller), [
        ExperimentStep.before,
        ExperimentStep.action,
        ExperimentStep.after,
        ExperimentStep.undo,
        ExperimentStep.cancelled,
      ]);
      expect(persistedState!.experimentCompletions, isEmpty);

      await controller.stop();
    });

    test('stopping the recording cancels the run', () async {
      final controller = await startStationary();
      controller.startExperiment('door-driver');
      expect(controller.experimentRun, isA<ExperimentCapturing>());

      await controller.stop();

      expect(
        (controller.experimentRun! as ExperimentFailed).failure,
        ExperimentFailure.recordingStopped,
      );
      expect(experimentSteps(controller), [
        ExperimentStep.before,
        ExperimentStep.cancelled,
      ]);
      expect(lastReason(controller), ExperimentFailure.recordingStopped);
      expect(controller.experimentSuggestions, isEmpty);
    });
  });

  group('testplan check', () {
    test('a positive reply on a known ECU is folded into discovery state and '
        'reaches onHit', () async {
      fakeNative.respondToOneShot = (step) {
        if (step.signalId == 'testplanGateway_222ab2') {
          return '77A 04 62 2A B2 AB';
        }
        return null;
      };
      persistedState = _namedGatewayState();
      final controller = makeController(
        testplanInitialDelay: const Duration(milliseconds: 5),
      );

      await controller.start();
      await waitFor(
        () =>
            controller
                .discoveryEngineForTesting
                ?.state
                .ecus['gateway']
                ?.discovered
                .contains('2AB2') ??
            false,
      );
      // Read the live state's own object, not the shared `persistedState` --
      // an unrelated test's own dangling save can otherwise land on it
      // after this one's `stop()` (the pre-existing sidecar-save race noted
      // elsewhere in this file).
      final gateway =
          controller.discoveryEngineForTesting!.state.ecus['gateway']!;

      await controller.stop();

      expect(gateway.discovered, contains('2AB2'));
    });

    test('a timed-out probe is quarantined into slow and not resent in the '
        'same recording', () async {
      const targetSignalId = 'testplanGateway_222ab2';
      fakeNative.unanswered.add(targetSignalId);
      fakeNative.respondToOneShot = (_) => null;
      persistedState = _namedGatewayState();
      final controller = makeController(
        testplanInitialDelay: const Duration(milliseconds: 5),
      );

      await controller.start();
      await waitFor(
        () => fakeNative.enqueuedSteps.any((s) => s.signalId == targetSignalId),
      );
      controller.discoveryExecutorForTesting!.deliverOneShotResult(
        ObdSignalExchangeMessage(
          signalId: targetSignalId,
          transport: ObdTransportStatusMessage.timeout,
        ),
      );

      await waitFor(
        () =>
            controller.discoveryEngineForTesting?.state.ecus['gateway']?.slow
                .contains('2AB2') ??
            false,
      );
      final sentBefore = fakeNative.enqueuedSteps
          .where((s) => s.signalId == targetSignalId)
          .length;

      controller.addPhase(MarkerPhase.drive);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        fakeNative.enqueuedSteps
            .where((s) => s.signalId == targetSignalId)
            .length,
        sentBefore,
      );

      await controller.stop();
    });
  });
}
