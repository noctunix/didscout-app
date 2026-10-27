import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` — this
// test needs it anyway, to build a fake in place of the real native channel.
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/ui/recording_page.dart';

/// A native API that never actually reaches a channel. Every call resolves
/// immediately with the "everything works" result; these widget tests only
/// exercise button enablement, not the controller's own state machine (see
/// `recording_controller_test.dart` for that).
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

RecordingController _fakeController() => RecordingController(
  bridge: ObdBridge(DidscoutPolicy(), nativeApi: _FakeNativeObdApi()),
  recordingsDirectory: () async => Directory.systemTemp,
  sessionIdFactory: () => 'test-session',
);

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    RecordingController? controller,
  }) async {
    // The default 800x600 test surface is too short to fit the status card,
    // phase grid, note input and marker list at once; use a phone-sized
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
        home: RecordingPage(controller: controller ?? _fakeController()),
      ),
    );
  }

  testWidgets('start recording button is enabled while idle', (
    tester,
  ) async {
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

      await tester.tap(find.widgetWithText(ElevatedButton, 'Start recording'));
      await tester.pumpAndSettle();

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

  testWidgets('adding a note shows it in the marker list', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'voltage reads 402V');
    await tester.tap(find.widgetWithText(FilledButton, 'Add note'));
    await tester.pump();

    expect(find.text('voltage reads 402V'), findsOneWidget);
  });
}
