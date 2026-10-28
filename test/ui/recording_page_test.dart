import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` — this
// test needs it anyway, to build a fake in place of the real native channel.
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/capture/readings.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
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
  Future<ObdLiveStateMessage> liveState(List<String> signalIds) async {
    final response = outsideTempResponse;
    if (response == null) {
      return ObdLiveStateMessage(
        link: ObdLinkStateMessage(
          state: ObdLinkStateValueMessage.connected,
          adapterHandle: 'cx',
        ),
        timebaseId: 't1',
        exchanges: [],
      );
    }
    return ObdLiveStateMessage(
      link: ObdLinkStateMessage(
        state: ObdLinkStateValueMessage.connected,
        adapterHandle: 'cx',
      ),
      timebaseId: 't1',
      exchanges: [
        ObdSignalExchangeMessage(
          signalId: 'module7_22f446',
          transport: ObdTransportStatusMessage.ok,
          rawResponseText: response,
        ),
      ],
    );
  }
}

RecordingController _fakeController({
  _FakeNativeObdApi? fakeNative,
  Duration tickInterval = const Duration(hours: 1),
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
  loadDiscoveryState: () async => DiscoveryState(),
  saveDiscoveryState: (_) async {},
);

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

    testWidgets('share profile draft button is tappable with nothing '
        'discovered yet (writeProfileDraft returns null, no share sheet '
        'opens)', (tester) async {
      final controller = _fakeController();
      await pumpPage(tester, controller: controller);
      await _startRecording(tester, controller);

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
  });
}
