import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` — this
// test needs it anyway, to build a fake in place of the real native channel.
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/capture/diff.dart';
import 'package:didscout_app/capture/readings.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/session/experiments.dart';
import 'package:didscout_app/session/session_markers.dart';
import 'package:didscout_app/ui/recording_page.dart';

/// The 29-bit module header this app's fixed plan uses for outside temp.;
/// matches `recording_controller.dart`'s own private constant.
const String _module7ResponseHeader = '18DAF104';

/// A native API that never actually reaches a channel. Every call resolves
/// immediately with the "everything works" result; these widget tests only
/// exercise button enablement and the entry sheets, not the controller's own
/// state machine (see `recording_controller_test.dart` for that).
class _FakeNativeObdApi extends NativeObdApi {
  /// Set by a test that wants [RecordingController.liveInfo] populated: a
  /// raw adapter response line for the `22F446` (outside temp.) step, as if
  /// the vehicle just answered it.
  String? outsideTempResponse;

  /// Same as [outsideTempResponse], for the `222AB8` (stored energy) step.
  String? storedEnergyResponse;

  /// Same as [outsideTempResponse], for the `22F40D` (speed) step.
  String? speedResponse;

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

  @override
  Future<ObdLiveStateMessage> liveState(List<String> signalIds) async =>
      ObdLiveStateMessage(
        link: ObdLinkStateMessage(
          state: ObdLinkStateValueMessage.connected,
          adapterHandle: 'cx',
        ),
        timebaseId: 't1',
        exchanges: [
          if (outsideTempResponse != null)
            ObdSignalExchangeMessage(
              signalId: 'module7_22f446',
              transport: ObdTransportStatusMessage.ok,
              rawResponseText: outsideTempResponse,
              receivedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
            ),
          if (storedEnergyResponse != null)
            ObdSignalExchangeMessage(
              signalId: 'module6_222ab8',
              transport: ObdTransportStatusMessage.ok,
              rawResponseText: storedEnergyResponse,
              receivedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
            ),
          if (speedResponse != null)
            ObdSignalExchangeMessage(
              signalId: 'module7_22f40d',
              transport: ObdTransportStatusMessage.ok,
              rawResponseText: speedResponse,
              receivedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
            ),
        ],
      );
}

RecordingController _fakeController({
  _FakeNativeObdApi? fakeNative,
  Duration tickInterval = const Duration(hours: 1),
  DiscoveryState? discoveryState,
}) => RecordingController(
  bridge: ObdBridge(
    DidscoutPolicy(),
    nativeApi: fakeNative ?? _FakeNativeObdApi(),
  ),
  recordingsDirectory: () async => Directory.systemTemp,
  sessionIdFactory: () => 'test-session',
  requestRuntimePermissions: (_) async {},
  tickInterval: tickInterval,
  // Same reasoning as `tickInterval` above: a periodic timer never
  // "settles", so it must be far longer than any `pumpAndSettle` call in
  // this file is willing to wait.
  discoveryPumpInterval: const Duration(hours: 1),
  // Discovery isn't what these tests exercise; avoid the real
  // `path_provider`/file I/O `RecordingController.stop` would otherwise
  // await -- real I/O never completes under `pumpAndSettle`'s fake clock
  // outside `tester.runAsync` (see `_startRecording` above).
  loadDiscoveryState: () async => discoveryState ?? DiscoveryState(),
  saveDiscoveryState: (_) async {},
);

Experiment _experiment(String id) =>
    experimentCatalog.firstWhere((experiment) => experiment.id == id);

/// Reports [experimentRun] and [experimentSuggestions] as a test sets them,
/// while recording, and records the experiment calls the card makes
/// instead of running them.
class _ExperimentCardController extends RecordingController {
  _ExperimentCardController()
    : super(
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: _FakeNativeObdApi()),
        recordingsDirectory: () async => Directory.systemTemp,
        requestRuntimePermissions: (_) async {},
        loadDiscoveryState: () async => DiscoveryState(),
        saveDiscoveryState: (_) async {},
      );

  ExperimentRun? run;
  List<Experiment> suggestions = const [];
  final List<String> calls = [];

  void show(ExperimentRun? next) {
    run = next;
    notifyListeners();
  }

  @override
  RecordingPhase get phase => RecordingPhase.recording;

  @override
  ExperimentRun? get experimentRun => run;

  @override
  List<Experiment> get experimentSuggestions => suggestions;

  @override
  String? ecuName(String requestHeader) =>
      const {'74A': 'Door FL', '767': 'Climate'}[requestHeader];

  @override
  void startExperiment(String id) => calls.add('start $id');

  @override
  void confirmExperimentAction() => calls.add('confirm');

  @override
  void cancelExperiment() => calls.add('cancel');

  @override
  void dismissExperiment() => calls.add('dismiss');
}

/// Starts [controller] the same way tapping the "Start recording" button
/// would (its `onPressed` is exactly [RecordingController.start]), via
/// [WidgetTester.runAsync]. [RecordingController.start] does real file I/O
/// (the marker sidecar's plan line) that never actually completes if begun
/// under `testWidgets`' own fake clock — started from a tap, that I/O hangs
/// forever instead of resolving on real time.
Future<void> _startRecording(
  WidgetTester tester,
  RecordingController controller,
) async {
  await tester.runAsync(controller.start);
  await tester.pumpAndSettle();
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    RecordingController? controller,
  }) async {
    // The default 800x600 test surface is too short to fit the status card,
    // phase grid, tile grid and marker list at once; use a phone-sized
    // surface instead so interacting with later widgets doesn't require
    // scrolling the page's ListView into view first.
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: RecordingPage(
          controller: controller ?? _fakeController(),
          onReminderVibration: () async {},
        ),
      ),
    );
  }

  testWidgets('start recording button is enabled while idle', (tester) async {
    await pumpPage(tester);

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start recording'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('share button is disabled before a recording finishes', (
    tester,
  ) async {
    await pumpPage(tester);

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Share recording'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'starting a recording shows Stop and enables the share button once finished',
    (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await _startRecording(tester, controller);

      expect(find.widgetWithText(ElevatedButton, 'Stop'), findsOneWidget);
      expect(controller.phase, RecordingPhase.recording);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Stop'));
      await tester.pumpAndSettle();

      expect(controller.phase, RecordingPhase.finished);
      final shareButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Share recording'),
      );
      expect(shareButton.onPressed, isNotNull);
    },
  );

  group('scouting card', () {
    testWidgets('hidden while idle, shown once recording starts', (
      tester,
    ) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      expect(find.text('Scouting'), findsNothing);

      await _startRecording(tester, controller);

      expect(find.text('Scouting'), findsOneWidget);
    });

    testWidgets('shows a reads/min KPI next to progress and hits', (
      tester,
    ) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await _startRecording(tester, controller);

      expect(find.text('reads/min'), findsOneWidget);
      // Nothing has been read yet right after starting -- the KPI still
      // shows a number, just zero.
      expect(
        find.text('${controller.discoveryUiState!.readsPerMinute}'),
        findsOneWidget,
      );
    });

    testWidgets('share profile draft button is tappable with nothing '
        'discovered yet (writeProfileDraft returns null, no share sheet '
        'opens)', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);

      await tester.scrollUntilVisible(
        find.text('Share profile draft'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Share profile draft'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('tapping a phase button adds and highlights that phase', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Charge'), findsOneWidget);
    await tester.tap(find.text('Charge'));
    await tester.pump();

    // The marker list (newest first) now shows a "Charge" entry in addition
    // to the phase button itself.
    expect(find.text('Charge'), findsNWidgets(2));

    // Button widgets wrap their child in their own (unlabelled) Semantics
    // node, so the closest Semantics ancestor of the text isn't necessarily
    // the labelled one the page sets; search all Semantics nodes instead.
    final chargeSemantics = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where(
          (widget) => widget.properties.label?.contains('Charge') ?? false,
        );
    expect(chargeSemantics, isNotEmpty);
    expect(chargeSemantics.first.properties.label, contains('current phase'));
  });

  testWidgets('adding a note via its sheet shows it in the marker list', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'voltage reads 402V');
    await tester.tap(find.widgetWithText(FilledButton, 'Add note'));
    await tester.pumpAndSettle();

    expect(find.text('voltage reads 402V'), findsOneWidget);
  });

  testWidgets('adding an event via its sheet shows it in the marker list', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Event'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'climate on'));
    await tester.pumpAndSettle();

    expect(find.text('climate on'), findsOneWidget);
  });

  group('reading tiles', () {
    testWidgets('the max. charging power has its own tile', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await tester.ensureVisible(find.text('Max. charging power'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Max. charging power'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.chargePowerMax);
    });

    testWidgets('tile entry stores read_at as the moment the tile was tapped', (
      tester,
    ) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      final beforeTap = DateTime.now();
      await tester.tap(find.text('State of charge'));
      await tester.pumpAndSettle();
      final afterTap = DateTime.now();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.soc);
      expect(
        marker.readAt.isAfter(beforeTap.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        marker.readAt.isBefore(afterTap.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    testWidgets('entry sheet prefills with the quantity\'s last entry', (
      tester,
    ) async {
      final controller = _fakeController();
      controller.addReading(
        quantity: ReadingQuantity.soc,
        value: 42,
        readAt: DateTime.now(),
        source: ReadingSource.typed,
      );
      await pumpPage(tester, controller: controller);

      await tester.tap(find.text('State of charge'));
      await tester.pumpAndSettle();

      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('the +1 stepper records source stepped', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await tester.tap(find.text('State of charge'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Increase by 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.source, ReadingSource.stepped);
      expect(marker.value, 1);
    });

    testWidgets('typing a value records source typed', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await tester.tap(find.text('State of charge'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '55');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.source, ReadingSource.typed);
      expect(marker.value, 55);
    });
  });

  group('live info confirmation', () {
    testWidgets('confirming a live value stores source confirmed with it', (
      tester,
    ) async {
      final fakeNative = _FakeNativeObdApi()
        // Single-frame ISO-TP: 04 (SF, 4 bytes) 62 (positive 22) F446 (DID)
        // 3C (60 decimal, minus the 40 degC UDS offset -> 20 degC).
        ..outsideTempResponse = '${_module7ResponseHeader}0462F4463C'
            .toUpperCase();
      final controller = _fakeController(
        fakeNative: fakeNative,
        tickInterval: const Duration(milliseconds: 1),
      );
      await pumpPage(tester, controller: controller);

      await _startRecording(tester, controller);
      // The tick timer was armed inside `runAsync` (see `_startRecording`),
      // so it runs on the real clock now, not the fake one `tester.pump`
      // advances — wait in real time for the live-state poll to land.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('outside temp.: 20'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Matches display'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.outsideTemp);
      expect(marker.source, ReadingSource.confirmed);
      expect(marker.value, 20);
      expect(marker.liveValue, 20);

      await controller.stop();
    });

    RecordingController storedEnergyController() => _fakeController(
      fakeNative: _FakeNativeObdApi()
        // Single-frame ISO-TP: 07 (SF, 7 bytes) 62 2AB8, then stored energy
        // at offset 2: 0x098B = 2443 * 25 Wh = 61075 Wh.
        ..storedEnergyResponse = '77A07622AB80000098B',
      tickInterval: const Duration(milliseconds: 1),
    );

    Future<void> startAndPoll(
      WidgetTester tester,
      RecordingController controller,
    ) async {
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }

    void addBatteryTemp(RecordingController controller, Duration age) {
      controller.addReading(
        quantity: ReadingQuantity.batteryTemp,
        value: 13,
        readAt: DateTime.now().subtract(age),
        source: ReadingSource.typed,
      );
    }

    testWidgets('the SoC estimate from stored energy can be confirmed', (
      tester,
    ) async {
      final controller = storedEnergyController();
      await startAndPoll(tester, controller);

      // 61075 * 0.0010689 + 7.8526 = 73.136
      expect(
        find.text('Estimated SoC from stored energy: 73 %'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Matches display'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.soc);
      expect(marker.source, ReadingSource.confirmed);
      expect(marker.value, 73);
      expect(marker.liveValue, 73);

      await controller.stop();
    });

    testWidgets('a recent battery temp. reading feeds the SoC estimate', (
      tester,
    ) async {
      final controller = storedEnergyController();
      addBatteryTemp(controller, const Duration(minutes: 5));
      await startAndPoll(tester, controller);

      // 61075 * 0.00108695 - 13 * 0.233182 + 10.9764 = 74.331
      expect(
        find.text('Estimated SoC from stored energy at 13 °C battery: 74 %'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Matches display'));
      await tester.pumpAndSettle();

      final confirmed = controller.markers.markers.last as ReadingMarker;
      expect(confirmed.quantity, ReadingQuantity.soc);
      expect(confirmed.value, 74);
      expect(confirmed.liveValue, 74);

      await tester.tap(find.text('State of charge'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final entered = controller.markers.markers.last as ReadingMarker;
      expect(entered.source, isNot(ReadingSource.confirmed));
      expect(entered.liveValue, 74);

      await controller.stop();
    });

    testWidgets('a battery temp. reading older than 20 min is ignored', (
      tester,
    ) async {
      final controller = storedEnergyController();
      addBatteryTemp(controller, const Duration(minutes: 21));
      await startAndPoll(tester, controller);

      // 61075 * 0.0010689 + 7.8526 = 73.136 -- the energy-only fit.
      expect(
        find.text('Estimated SoC from stored energy: 73 %'),
        findsOneWidget,
      );
      expect(find.textContaining('°C battery'), findsNothing);

      await controller.stop();
    });
  });

  group('experiments card', () {
    testWidgets('hidden while not recording', (tester) async {
      await pumpPage(tester);

      expect(find.text('Experiments'), findsNothing);
    });

    testWidgets('shown while recording only once the vehicle stands', (
      tester,
    ) async {
      final fakeNative = _FakeNativeObdApi()
        ..speedResponse = '${_module7ResponseHeader}0462F40D1E';
      final controller = _fakeController(
        fakeNative: fakeNative,
        tickInterval: const Duration(milliseconds: 1),
        discoveryState: DiscoveryState(
          ecus: {
            'door-front-left': EcuInfo(
              requestHeader: '74A',
              responseHeader: '7B4',
              protocol: 6,
              identification: {'F197': 'Door FL'},
              discovered: {'2A00'},
            ),
          },
        ),
      );
      controller.addPhase(MarkerPhase.stand);
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);
      Future<void> poll() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }

      await poll();
      expect(controller.liveInfo.speedKmh, 30);
      expect(find.text('Experiments'), findsNothing);

      fakeNative.speedResponse = '${_module7ResponseHeader}0462F40D00';
      await poll();
      expect(find.text('Experiments'), findsOneWidget);
      expect(find.text('Driver door'), findsOneWidget);
      expect(find.text('Reads Door FL'), findsOneWidget);

      await controller.stop();
      await tester.pumpAndSettle();
      expect(find.text('Experiments'), findsNothing);
    });

    testWidgets('walks through the steps of a run', (tester) async {
      final controller = _ExperimentCardController()
        ..suggestions = [
          _experiment('door-driver'),
          _experiment('climate-setpoint'),
        ];
      await pumpPage(tester, controller: controller);
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      expect(find.text('Driver door'), findsOneWidget);
      expect(find.text('Reads Door FL'), findsOneWidget);
      await tap(find.widgetWithText(FilledButton, 'Start'));
      expect(controller.calls, ['start door-driver']);

      await tap(find.widgetWithText(TextButton, 'Choose another'));
      await tap(find.text('Cabin temperature'));
      expect(controller.calls.last, 'start climate-setpoint');

      final doorDriver = _experiment('door-driver');
      controller.show(
        ExperimentCapturing(doorDriver, after: false, answered: 1, total: 3),
      );
      await tester.pump();
      expect(find.text('Reading before…'), findsOneWidget);
      expect(find.text('1 of 3 reads'), findsOneWidget);
      await tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(controller.calls.last, 'cancel');

      controller.show(ExperimentAwaitingAction(doorDriver));
      await tester.pump();
      expect(find.text(doorDriver.instruction), findsOneWidget);
      await tap(find.widgetWithText(FilledButton, 'Done'));
      expect(controller.calls.last, 'confirm');

      controller.show(
        ExperimentCapturing(doorDriver, after: true, answered: 0, total: 3),
      );
      await tester.pump();
      expect(find.text('Reading after…'), findsOneWidget);

      controller.show(ExperimentDone(doorDriver, changes: const {}));
      await tester.pump();
      expect(find.text('No change seen'), findsOneWidget);
      expect(find.textContaining('Enter '), findsNothing);
      await tap(find.widgetWithText(TextButton, 'Close'));
      expect(controller.calls.last, 'dismiss');

      controller.show(ExperimentFailed(doorDriver, ExperimentFailure.moving));
      await tester.pump();
      expect(find.textContaining('the vehicle moved'), findsOneWidget);
    });

    testWidgets('a result lists the changed bytes per ECU and offers the '
        'follow-up reading', (tester) async {
      final controller = _ExperimentCardController();
      await pumpPage(tester, controller: controller);
      controller.show(
        ExperimentDone(
          _experiment('climate-setpoint'),
          changes: {
            '767': [
              DidDiff(
                module: '767',
                did: '2A00',
                before: Uint8List.fromList([0x00, 0x11]),
                after: Uint8List.fromList([0x1A, 0x11, 0x22]),
                changes: const [
                  ByteDiff(position: 0, before: 0x00, after: 0x1A),
                ],
              ),
            ],
          },
        ),
      );
      await tester.pump();

      expect(find.text('Climate'), findsOneWidget);
      expect(find.text('2A00  byte 0: 00 → 1A, length 2 → 3'), findsOneWidget);

      final followUp = find.widgetWithText(
        OutlinedButton,
        'Enter Inside temp.',
      );
      await tester.ensureVisible(followUp);
      await tester.pumpAndSettle();
      await tester.tap(followUp);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.insideTemp);
    });
  });

  group('reading prompts', () {
    bool tileLabelled(WidgetTester tester, String label) => tester
        .widgetList<Semantics>(find.byType(Semantics))
        .any((widget) => widget.properties.label == label);

    testWidgets('none while not recording', (tester) async {
      await pumpPage(tester);

      expect(find.text('Read off the display'), findsNothing);
      expect(
        tileLabelled(tester, 'Battery temp., reading due, enter reading'),
        isFalse,
      );
    });

    testWidgets('list what to read off and highlight those tiles until '
        'read', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);
      controller.addPhase(MarkerPhase.charge);
      await tester.pumpAndSettle();

      expect(find.text('Read off the display'), findsOneWidget);
      expect(find.text('Battery temp.: Not read yet'), findsOneWidget);
      expect(find.text('Charging power (now): Not read yet'), findsOneWidget);
      expect(find.text('State of charge: Not read yet'), findsOneWidget);
      expect(
        tileLabelled(tester, 'Battery temp., reading due, enter reading'),
        isTrue,
      );
      expect(tileLabelled(tester, 'Odometer, enter reading'), isTrue);

      await tester.ensureVisible(find.text('Battery temp.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Battery temp.'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Battery temp.: Not read yet'), findsNothing);
      expect(tileLabelled(tester, 'Battery temp., enter reading'), isTrue);
      expect(find.text('State of charge: Not read yet'), findsOneWidget);

      await controller.stop();
    });
  });
}
