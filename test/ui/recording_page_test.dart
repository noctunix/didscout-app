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

  /// Same as [outsideTempResponse], for the `221E10` (battery temp.) step.
  String? batteryTempResponse;

  /// Same as [outsideTempResponse], for the `220311` (charging power) step.
  String? chargePowerResponse;

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
  Future<void> disconnect() async {}

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
          if (batteryTempResponse != null)
            ObdSignalExchangeMessage(
              signalId: 'vag29-7B_221e10',
              transport: ObdTransportStatusMessage.ok,
              rawResponseText: batteryTempResponse,
              receivedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
            ),
          if (chargePowerResponse != null)
            ObdSignalExchangeMessage(
              signalId: 'module6_220311',
              transport: ObdTransportStatusMessage.ok,
              rawResponseText: chargePowerResponse,
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

/// Claims to be recording without ever connecting.
class _RecordingStubController extends RecordingController {
  _RecordingStubController()
    : super(
        bridge: ObdBridge(DidscoutPolicy(), nativeApi: _FakeNativeObdApi()),
        recordingsDirectory: () async => Directory.systemTemp,
        requestRuntimePermissions: (_) async {},
        loadDiscoveryState: () async => DiscoveryState(),
        saveDiscoveryState: (_) async {},
      );

  @override
  RecordingPhase get phase => RecordingPhase.recording;
}

/// Shows and dismisses the charging-round reminder as a test says.
class _ReminderController extends _RecordingStubController {
  bool reminder = false;

  void showReminder() {
    reminder = true;
    notifyListeners();
  }

  @override
  bool get chargeReminderVisible => reminder;

  @override
  void dismissChargeReminder() {
    reminder = false;
    notifyListeners();
  }
}

/// Reports [experimentRun] and [experimentSuggestions] as a test sets them,
/// while recording, and records the experiment calls the card makes
/// instead of running them.
class _ExperimentCardController extends _RecordingStubController {
  ExperimentRun? run;
  List<Experiment> suggestions = const [];
  bool stationary = true;
  final List<String> calls = [];

  void show(ExperimentRun? next) {
    run = next;
    notifyListeners();
  }

  @override
  ExperimentRun? get experimentRun => run;

  @override
  List<Experiment> get experimentSuggestions => suggestions;

  @override
  bool get isStationary => stationary;

  @override
  String? ecuName(String requestHeader) =>
      const {'74A': 'Door FL', '767': 'Climate'}[requestHeader];

  @override
  void startExperiment(String id) => calls.add('start $id');

  @override
  void confirmExperimentAction() => calls.add('confirm');

  @override
  void confirmExperimentUndo() => calls.add('confirm undo');

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
    Future<void> Function()? onReminderVibration,
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
          onReminderVibration: onReminderVibration ?? () async {},
        ),
      ),
    );
  }

  Future<void> openTile(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  bool labelled(WidgetTester tester, String label) => tester
      .widgetList<Semantics>(find.byType(Semantics))
      .any((widget) => widget.properties.label == label);

  Color? valueColor(WidgetTester tester, String text) =>
      (tester.widget<Text>(find.text(text)).textSpan! as TextSpan)
          .children!
          .first
          .style!
          .color;

  ColorScheme colorsOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(RecordingPage))).colorScheme;

  testWidgets('start recording button is enabled while idle', (tester) async {
    await pumpPage(tester);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start recording'),
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

  testWidgets('Stop asks first, hides sharing while recording, and the '
      'share button is enabled once finished', (tester) async {
    final controller = _fakeController();
    await pumpPage(tester, controller: controller);

    await _startRecording(tester, controller);

    expect(controller.phase, RecordingPhase.recording);
    expect(find.text('Share recording'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(find.text('Stop recording?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(controller.phase, RecordingPhase.recording);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Stop recording'));
    await tester.pumpAndSettle();

    expect(controller.phase, RecordingPhase.finished);
    final shareButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Share recording'),
    );
    expect(shareButton.onPressed, isNotNull);
  });

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

    expect(
      tester.getSemantics(find.widgetWithText(FilledButton, 'Charge')),
      isSemantics(
        label: 'Charge',
        isButton: true,
        isSelected: true,
        isInMutuallyExclusiveGroup: true,
      ),
    );
    expect(
      tester.getSemantics(find.widgetWithText(FilledButton, 'Drive')),
      isSemantics(label: 'Drive', isSelected: false),
    );
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
      await tester.enterText(find.byType(TextField), '150');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.chargePowerMax);
    });

    testWidgets('while charging, the charging power tile takes the max. '
        "tile's place and shows the vehicle's value", (tester) async {
      final controller = _fakeController(
        fakeNative: _FakeNativeObdApi()
          // 62 0311, then 0x0CCB = (3275 - 500) / 10 = 277.5 kW.
          ..chargePowerResponse = '77A066203110CCB038B',
        tickInterval: const Duration(milliseconds: 1),
      );
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Max. charging power'), findsOneWidget);
      expect(find.text('Charging power (now)'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Charge'));
      await tester.pumpAndSettle();

      expect(find.text('Max. charging power'), findsNothing);
      expect(find.text('Charging power (now)'), findsOneWidget);
      expect(find.text('278 kW'), findsOneWidget);

      await controller.stop();
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

      await tester.enterText(find.byType(TextField), '64');
      await tester.pump();
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

    FilledButton sheetButton(WidgetTester tester, String label) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

    IconButton stepper(WidgetTester tester, IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

    void addSoc(RecordingController controller, num value) {
      controller.addReading(
        quantity: ReadingQuantity.soc,
        value: value,
        readAt: DateTime.now(),
        source: ReadingSource.typed,
      );
    }

    testWidgets('a tile shows the last entry with its age', (tester) async {
      final controller = _fakeController();
      addSoc(controller, 63);
      controller
        ..addReading(
          quantity: ReadingQuantity.batteryTemp,
          value: 13,
          readAt: DateTime.now().subtract(const Duration(minutes: 12)),
          source: ReadingSource.typed,
        )
        ..addReading(
          quantity: ReadingQuantity.odometer,
          value: 12345.6,
          readAt: DateTime.now().subtract(const Duration(hours: 2)),
          source: ReadingSource.typed,
        );
      await pumpPage(tester, controller: controller);

      expect(find.text('63 %'), findsOneWidget);
      expect(find.text('Just now'), findsOneWidget);
      expect(
        labelled(tester, 'State of charge, 63 percent, entered just now'),
        isTrue,
      );
      expect(find.text('13 °C'), findsOneWidget);
      expect(find.text('12 min ago'), findsOneWidget);
      expect(valueColor(tester, '13 °C'), colorsOf(tester).onSurface);
      expect(find.text('12345 km'), findsOneWidget);
      expect(find.text('2 h ago'), findsOneWidget);

      await openTile(tester, 'State of charge');
      expect(find.text('Your last entry, just now'), findsOneWidget);
    });

    testWidgets('a tile without a value says it was not read', (tester) async {
      await pumpPage(tester);

      // Seven tiles: only one of the two charging power tiles at a time.
      expect(find.text('Not read'), findsNWidgets(7));
      expect(labelled(tester, 'Odometer, not read'), isTrue);

      await openTile(tester, 'Inside temp.');
      expect(find.text("Read the value off the car's display"), findsOneWidget);
    });

    testWidgets('the last entry prefills the sheet and, saved unchanged, '
        'is recorded as confirmed', (tester) async {
      final controller = _fakeController();
      addSoc(controller, 42);
      await pumpPage(tester, controller: controller);

      await openTile(tester, 'State of charge');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '42',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Matches display'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.last as ReadingMarker;
      expect(marker.value, 42);
      expect(marker.source, ReadingSource.confirmed);
      expect(marker.prefill, 42);
      expect(marker.prefillOrigin, PrefillOrigin.entry);
    });

    testWidgets('the +1 stepper records source stepped', (tester) async {
      final controller = _fakeController();
      addSoc(controller, 42);
      await pumpPage(tester, controller: controller);

      await openTile(tester, 'State of charge');
      await tester.tap(find.byTooltip('Increase by 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.last as ReadingMarker;
      expect(marker.source, ReadingSource.stepped);
      expect(marker.value, 43);
      expect(marker.prefill, 42);
      expect(marker.prefillOrigin, PrefillOrigin.entry);
    });

    testWidgets('without a value to prefill, the sheet opens empty and '
        'Save and the steppers stay disabled until a number is typed', (
      tester,
    ) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await openTile(tester, 'Inside temp.');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(sheetButton(tester, 'Save').onPressed, isNull);
      expect(stepper(tester, Icons.add_circle_outline).onPressed, isNull);
      expect(stepper(tester, Icons.remove_circle_outline).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '21');
      await tester.pump();
      expect(stepper(tester, Icons.add_circle_outline).onPressed, isNotNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.value, 21);
      expect(marker.source, ReadingSource.typed);
      expect(marker.prefill, isNull);
      expect(marker.prefillOrigin, isNull);
    });

    testWidgets('a comma is accepted as the decimal separator', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await openTile(tester, 'Inside temp.');
      await tester.enterText(find.byType(TextField), '12,5');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.value, 12.5);
    });

    testWidgets('temperatures take a minus sign; anything not a number is '
        'an error that keeps Save disabled', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await openTile(tester, 'Outside temp.');
      expect(
        tester.widget<TextField>(find.byType(TextField)).keyboardType,
        const TextInputType.numberWithOptions(decimal: true, signed: true),
      );
      await tester.enterText(find.byType(TextField), '3-');
      await tester.pump();
      expect(find.text('Enter a number'), findsOneWidget);
      expect(sheetButton(tester, 'Save').onPressed, isNull);

      await tester.enterText(find.byType(TextField), '-3');
      await tester.pump();
      expect(find.text('Enter a number'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.value, -3);
    });

    testWidgets('typing a value records source typed', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);

      await tester.tap(find.text('State of charge'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '55');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.source, ReadingSource.typed);
      expect(marker.value, 55);
    });
  });

  group('live values', () {
    Future<void> startAndPoll(
      WidgetTester tester,
      RecordingController controller,
    ) async {
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);
      // The tick timer was armed inside `runAsync` (see `_startRecording`),
      // so it runs on the real clock now, not the fake one `tester.pump`
      // advances — wait in real time for the live-state poll to land.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }

    /// A controller whose vehicle reports [rawTemp] for outside temp.:
    /// single-frame ISO-TP 04 (SF, 4 bytes) 62 (positive 22) F446 (DID),
    /// then the raw byte, minus the 40 degC UDS offset.
    RecordingController outsideTempController(String rawTemp) =>
        _fakeController(
          fakeNative: _FakeNativeObdApi()
            ..outsideTempResponse = '${_module7ResponseHeader}0462F446$rawTemp',
          tickInterval: const Duration(milliseconds: 1),
        );

    testWidgets('the live value shows on its tile and prefills the sheet '
        'ahead of the last entry; changed, it is recorded as typed', (
      tester,
    ) async {
      // 0x3C = 60 -> 20 degC.
      final controller = outsideTempController('3C');
      controller.addReading(
        quantity: ReadingQuantity.outsideTemp,
        value: 18,
        readAt: DateTime.now(),
        source: ReadingSource.typed,
      );
      await startAndPoll(tester, controller);

      expect(find.text('20 °C'), findsOneWidget);
      expect(find.text('Vehicle'), findsOneWidget);
      expect(
        labelled(tester, 'Outside temp., 20 degrees Celsius, from the vehicle'),
        isTrue,
      );

      await openTile(tester, 'Outside temp.');
      expect(find.text('Vehicle reads 20 °C'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '20',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Matches display'));
      await tester.pumpAndSettle();

      final confirmed = controller.markers.markers.last as ReadingMarker;
      expect(confirmed.value, 20);
      expect(confirmed.source, ReadingSource.confirmed);
      expect(confirmed.prefill, 20);
      expect(confirmed.prefillOrigin, PrefillOrigin.live);
      expect(confirmed.liveValue, 20);

      await openTile(tester, 'Outside temp.');
      await tester.enterText(find.byType(TextField), '21');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final typed = controller.markers.markers.last as ReadingMarker;
      expect(typed.value, 21);
      expect(typed.source, ReadingSource.typed);
      expect(typed.prefill, 20);
      expect(typed.prefillOrigin, PrefillOrigin.live);
      expect(typed.liveValue, 20);

      await controller.stop();
    });

    testWidgets('a negative temperature is spoken with minus', (tester) async {
      // 0x25 = 37 -> -3 degC.
      final controller = outsideTempController('25');
      await startAndPoll(tester, controller);

      expect(find.text('-3 °C'), findsOneWidget);
      expect(
        labelled(
          tester,
          'Outside temp., minus 3 degrees Celsius, from the vehicle',
        ),
        isTrue,
      );

      await controller.stop();
    });

    RecordingController storedEnergyController() => _fakeController(
      fakeNative: _FakeNativeObdApi()
        // Single-frame ISO-TP: 07 (SF, 7 bytes) 62 2AB8, then stored energy
        // at offset 2: 0x098B = 2443 * 25 Wh = 61075 Wh.
        ..storedEnergyResponse = '77A07622AB80000098B',
      tickInterval: const Duration(milliseconds: 1),
    );

    void addBatteryTemp(RecordingController controller, Duration age) {
      controller.addReading(
        quantity: ReadingQuantity.batteryTemp,
        value: 13,
        readAt: DateTime.now().subtract(age),
        source: ReadingSource.typed,
      );
    }

    testWidgets('the SoC tile shows the estimate from stored energy, which '
        'the sheet explains and records as confirmed', (tester) async {
      final controller = storedEnergyController();
      await startAndPoll(tester, controller);

      // 61075 * 0.00107967 + 4.7633 = 70.704
      expect(find.text('≈ 71 %'), findsOneWidget);
      expect(find.text('Estimate'), findsOneWidget);
      expect(
        labelled(
          tester,
          'State of charge, approximately 71 percent, '
          'estimated from the vehicle',
        ),
        isTrue,
      );

      await openTile(tester, 'State of charge');
      expect(
        find.text(
          'Vehicle estimate ≈ 71 % '
          '(61\u202F075 Wh, no battery temp., up to ±5 pp)',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Matches display'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.soc);
      expect(marker.source, ReadingSource.confirmed);
      expect(marker.value, 71);
      expect(marker.prefill, 71);
      expect(marker.prefillOrigin, PrefillOrigin.live);
      expect(marker.liveValue, 71);

      await controller.stop();
    });

    testWidgets('a recent battery temp. reading feeds the SoC estimate', (
      tester,
    ) async {
      final controller = storedEnergyController();
      addBatteryTemp(controller, const Duration(minutes: 5));
      await startAndPoll(tester, controller);

      // 61075 * 0.00109775 + 1.4812 + (33 - 13) * 0.301022 = 74.546
      expect(find.text('≈ 75 %'), findsOneWidget);

      await openTile(tester, 'State of charge');
      expect(
        find.text(
          'Vehicle estimate ≈ 75 % (61\u202F075 Wh, battery 13 °C, ±1.5 pp)',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Matches display'));
      await tester.pumpAndSettle();

      final entered = controller.markers.markers.last as ReadingMarker;
      expect(entered.quantity, ReadingQuantity.soc);
      expect(entered.value, 75);
      expect(entered.liveValue, 75);

      await controller.stop();
    });

    testWidgets('a battery temp. reading older than 20 min is ignored and '
        'shown as stale', (tester) async {
      final controller = storedEnergyController();
      addBatteryTemp(controller, const Duration(minutes: 21));
      await startAndPoll(tester, controller);

      // 61075 * 0.00107967 + 4.7633 = 70.704 -- the energy-only fit.
      expect(find.text('≈ 71 %'), findsOneWidget);
      expect(find.text('21 min ago'), findsOneWidget);
      expect(valueColor(tester, '13 °C'), colorsOf(tester).onSurfaceVariant);

      await openTile(tester, 'State of charge');
      expect(find.textContaining('no battery temp.'), findsOneWidget);

      await controller.stop();
    });

    testWidgets("the vehicle's battery temp. shows on its tile and feeds the "
        'SoC estimate ahead of an entry', (tester) async {
      final controller = _fakeController(
        fakeNative: _FakeNativeObdApi()
          ..storedEnergyResponse = '77A07622AB80000098B'
          // 62 1E10, then 0x01A4 = 420 / 8 - 40 = 12.5 degC.
          ..batteryTempResponse = '17FE007B05621E1001A4',
        tickInterval: const Duration(milliseconds: 1),
      );
      controller.addReading(
        quantity: ReadingQuantity.batteryTemp,
        value: 30,
        readAt: DateTime.now().subtract(const Duration(minutes: 5)),
        source: ReadingSource.typed,
      );
      await startAndPoll(tester, controller);

      expect(find.text('13 °C'), findsOneWidget);
      // 61075 * 0.00109775 + 1.4812 + (33 - 12.5) * 0.301022 = 74.697;
      // the 30 degC entry would give 69.
      expect(find.text('≈ 75 %'), findsOneWidget);

      await controller.stop();
    });
  });

  group('experiments card', () {
    testWidgets('hidden while not recording', (tester) async {
      await pumpPage(tester);

      expect(find.text('Experiments'), findsNothing);
    });

    testWidgets('shown while recording in a standing phase; starts once '
        'the vehicle stands', (tester) async {
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
      expect(find.text('Experiments'), findsOneWidget);
      expect(find.text('Starts when the vehicle stands still'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
            .onPressed,
        isNull,
      );

      fakeNative.speedResponse = '${_module7ResponseHeader}0462F40D00';
      await poll();
      expect(find.text('Experiments'), findsOneWidget);
      expect(find.text('Driver door'), findsOneWidget);
      expect(find.text('Reads Door FL'), findsOneWidget);

      await controller.stop();
      await tester.pumpAndSettle();
      expect(find.text('Experiments'), findsNothing);
    });

    testWidgets('hidden while driving unless a run is in progress', (
      tester,
    ) async {
      final controller = _ExperimentCardController()
        ..suggestions = [_experiment('door-driver')]
        ..addPhase(MarkerPhase.drive);
      await pumpPage(tester, controller: controller);
      expect(find.text('Experiments'), findsNothing);

      controller.show(
        ExperimentCapturing(
          _experiment('door-driver'),
          stage: ExperimentCaptureStage.before,
          answered: 0,
          total: 3,
        ),
      );
      await tester.pump();
      expect(find.text('Experiments'), findsOneWidget);
    });

    testWidgets('says when no experiment fits the ECUs found', (tester) async {
      final controller = _ExperimentCardController()
        ..addPhase(MarkerPhase.park);
      await pumpPage(tester, controller: controller);

      expect(
        find.text('No experiment for the ECUs found so far'),
        findsOneWidget,
      );
    });

    testWidgets('walks through the steps of a run', (tester) async {
      final controller = _ExperimentCardController()
        ..suggestions = [
          _experiment('door-driver'),
          _experiment('climate-setpoint'),
        ]
        ..addPhase(MarkerPhase.stand);
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
        ExperimentCapturing(
          doorDriver,
          stage: ExperimentCaptureStage.before,
          answered: 1,
          total: 3,
        ),
      );
      await tester.pump();
      expect(find.text('Reading before…'), findsOneWidget);
      expect(find.text('1 of 3 reads'), findsOneWidget);
      await tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(controller.calls.last, 'cancel');

      controller.show(ExperimentAwaitingAction(doorDriver));
      await tester.pump();
      expect(
        find.text('Open the driver door and leave it open.'),
        findsOneWidget,
      );
      await tap(find.widgetWithText(FilledButton, 'Done'));
      expect(controller.calls.last, 'confirm');

      controller.show(
        ExperimentCapturing(
          doorDriver,
          stage: ExperimentCaptureStage.after,
          answered: 0,
          total: 3,
        ),
      );
      await tester.pump();
      expect(find.text('Reading after…'), findsOneWidget);

      controller.show(ExperimentAwaitingUndo(doorDriver));
      await tester.pump();
      expect(find.text('Close the driver door.'), findsOneWidget);
      await tap(find.widgetWithText(FilledButton, 'Done'));
      expect(controller.calls.last, 'confirm undo');
      await tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(controller.calls.last, 'cancel');

      controller.show(
        ExperimentCapturing(
          doorDriver,
          stage: ExperimentCaptureStage.undone,
          answered: 2,
          total: 3,
        ),
      );
      await tester.pump();
      expect(find.text('Reading after undo…'), findsOneWidget);
      expect(find.text('2 of 3 reads'), findsOneWidget);

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

      final followUp = find.widgetWithText(FilledButton, 'Enter Inside temp.');
      await tester.ensureVisible(followUp);
      await tester.pumpAndSettle();
      await tester.tap(followUp);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '21');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final marker = controller.markers.markers.single as ReadingMarker;
      expect(marker.quantity, ReadingQuantity.insideTemp);
    });
  });

  group('experiments card result', () {
    testWidgets('lists at most 6 changed DIDs and the rest on demand', (
      tester,
    ) async {
      final controller = _ExperimentCardController();
      await pumpPage(tester, controller: controller);
      final diffs = [
        for (var i = 0; i < 8; i++)
          DidDiff(
            module: '767',
            did: '2A0$i',
            before: Uint8List.fromList([0x00]),
            after: Uint8List.fromList([0x01]),
            changes: const [ByteDiff(position: 0, before: 0x00, after: 0x01)],
          ),
      ];
      controller.show(
        ExperimentDone(
          _experiment('climate-setpoint'),
          changes: {'767': diffs},
        ),
      );
      await tester.pump();

      expect(find.text('2A05  byte 0: 00 → 01'), findsOneWidget);
      expect(find.text('2A06  byte 0: 00 → 01'), findsNothing);
      final showAll = find.widgetWithText(TextButton, 'Show all (8)');
      await tester.ensureVisible(showAll);
      await tester.pumpAndSettle();
      await tester.tap(showAll);
      await tester.pumpAndSettle();

      expect(find.text('2A06  byte 0: 00 → 01'), findsOneWidget);
      expect(find.text('2A07  byte 0: 00 → 01'), findsOneWidget);
    });

    testWidgets('lists DIDs that also change on their own last, marked', (
      tester,
    ) async {
      final controller = _ExperimentCardController();
      await pumpPage(tester, controller: controller);
      DidDiff diff(String did) => DidDiff(
        module: '767',
        did: did,
        before: Uint8List.fromList([0x00]),
        after: Uint8List.fromList([0x01]),
        changes: const [ByteDiff(position: 0, before: 0x00, after: 0x01)],
      );
      controller.show(
        ExperimentDone(
          _experiment('climate-setpoint'),
          changes: {
            '767': [diff('2A00'), diff('2A01')],
          },
          movingOnTheirOwn: const {(header: '767', did: '2A00')},
        ),
      );
      await tester.pump();

      final moving = find.text('2A00  byte 0: 00 → 01  (moves on its own)');
      final quiet = find.text('2A01  byte 0: 00 → 01');
      expect(moving, findsOneWidget);
      expect(quiet, findsOneWidget);
      expect(
        tester.getTopLeft(quiet).dy,
        lessThan(tester.getTopLeft(moving).dy),
      );
    });

    DidDiff flip(String header, String did) => DidDiff(
      module: header,
      did: did,
      before: Uint8List.fromList([0x00]),
      after: Uint8List.fromList([0x01]),
      changes: const [ByteDiff(position: 0, before: 0x00, after: 0x01)],
    );

    testWidgets('lists the changes that returned after the undo first and '
        'marks the others, the ECU with a returned change first', (
      tester,
    ) async {
      final controller = _ExperimentCardController();
      await pumpPage(tester, controller: controller);
      controller.show(
        ExperimentDone(
          _experiment('lock'),
          changes: {
            '74A': [flip('74A', '2A00')],
            '767': [
              flip('767', '3000'),
              flip('767', '3001'),
              flip('767', '3002'),
            ],
          },
          notReturned: const {
            (header: '74A', did: '2A00'),
            (header: '767', did: '3000'),
          },
          movingOnTheirOwn: const {
            (header: '767', did: '3000'),
            (header: '767', did: '3001'),
          },
        ),
      );
      await tester.pump();

      final rows = [
        find.text('Climate'),
        find.text('3002  byte 0: 00 → 01'),
        find.text('3001  byte 0: 00 → 01  (moves on its own)'),
        find.text('3000  byte 0: 00 → 01  (did not return, moves on its own)'),
        find.text('Door FL'),
        find.text('2A00  byte 0: 00 → 01  (did not return)'),
      ];
      for (final row in rows) {
        expect(row, findsOneWidget);
      }
      final tops = [for (final row in rows) tester.getTopLeft(row).dy];
      expect(tops, [...tops]..sort());
    });

    testWidgets('a change that returned is listed even behind more that did '
        'not than fit', (tester) async {
      final controller = _ExperimentCardController();
      await pumpPage(tester, controller: controller);
      final door = [for (var i = 0; i < 6; i++) flip('74A', '2A0$i')];
      controller.show(
        ExperimentDone(
          _experiment('lock'),
          changes: {
            '74A': door,
            '767': [flip('767', '3000')],
          },
          notReturned: {
            for (final diff in door) (header: '74A', did: diff.did),
          },
        ),
      );
      await tester.pump();

      expect(find.text('3000  byte 0: 00 → 01'), findsOneWidget);
      expect(
        find.text('2A04  byte 0: 00 → 01  (did not return)'),
        findsOneWidget,
      );
      expect(find.textContaining('2A05'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Show all (7)'), findsOneWidget);
    });
  });

  group('reading prompts', () {
    testWidgets('none while not recording', (tester) async {
      await pumpPage(tester);

      expect(find.text('Readings'), findsOneWidget);
      expect(find.text('Nothing due right now'), findsNothing);
      expect(find.textContaining('Read now'), findsNothing);
      expect(labelled(tester, 'Battery temp., not read'), isTrue);
    });

    testWidgets('list what to read off and highlight those tiles until '
        'read', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);
      controller.addPhase(MarkerPhase.charge);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Read now: Battery temp., Charging power (now), State of charge',
        ),
        findsOneWidget,
      );
      expect(labelled(tester, 'Battery temp., not read, reading due'), isTrue);
      expect(labelled(tester, 'Odometer, not read'), isTrue);

      await tester.ensureVisible(find.text('Battery temp.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Battery temp.'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '20');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.text('Read now: Charging power (now), State of charge'),
        findsOneWidget,
      );
      expect(
        labelled(tester, 'Battery temp., 20 degrees Celsius, entered just now'),
        isTrue,
      );

      await controller.stop();
    });

    testWidgets('never ask for what the vehicle reports itself', (
      tester,
    ) async {
      final controller = _fakeController(
        fakeNative: _FakeNativeObdApi()
          ..batteryTempResponse = '17FE007B05621E1001A4'
          ..chargePowerResponse = '77A066203110CCB038B',
        tickInterval: const Duration(milliseconds: 1),
      );
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      controller.addPhase(MarkerPhase.charge);
      await tester.pumpAndSettle();

      expect(find.text('Read now: State of charge'), findsOneWidget);

      await controller.stop();
    });

    testWidgets('say so when nothing is due', (tester) async {
      final controller = _RecordingStubController()
        ..addReading(
          quantity: ReadingQuantity.batteryTemp,
          value: 20,
          readAt: DateTime.now(),
          source: ReadingSource.typed,
        );
      await pumpPage(tester, controller: controller);

      expect(find.text('Nothing due right now'), findsOneWidget);
    });

    testWidgets('the charging-round reminder takes the due line\'s place '
        'until dismissed, vibrating once', (tester) async {
      var vibrations = 0;
      final controller = _ReminderController();
      await pumpPage(
        tester,
        controller: controller,
        onReminderVibration: () async => vibrations++,
      );
      expect(find.text('Read now: Battery temp.'), findsOneWidget);

      controller.showReminder();
      await tester.pumpAndSettle();
      expect(
        find.text('Charging round: check SoC and battery temp.'),
        findsOneWidget,
      );
      expect(find.text('Read now: Battery temp.'), findsNothing);
      expect(vibrations, 1);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(
        find.text('Charging round: check SoC and battery temp.'),
        findsNothing,
      );
      expect(find.text('Read now: Battery temp.'), findsOneWidget);
      expect(vibrations, 1);
    });
  });
}
