import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/capture/recording_summary.dart';
import 'package:didscout_app/ui/recordings_page.dart';

RecordingSummary _summary(
  String sessionId, {
  Duration? duration = const Duration(minutes: 5),
}) => RecordingSummary(
  sessionId: sessionId,
  bufferPath: '/recordings/$sessionId.jsonl',
  markersPath: '/recordings/$sessionId.jsonl.markers.jsonl',
  startedAt: DateTime.utc(2026, 1, 1, 12),
  duration: duration,
  sizeBytes: 2048,
  readingCount: 10,
  markerCount: 3,
);

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required List<RecordingSummary> recordings,
    String? currentBufferPath,
    List<List<String>>? sharedCalls,
    List<RecordingSummary>? deletedCalls,
    Future<String?> Function()? exportProfileDraft,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsPage(
          recordingsDirectory: () async => Directory.systemTemp,
          currentBufferPath: currentBufferPath,
          listRecordings: (_) async => recordings,
          deleteRecording: (summary) async {
            deletedCalls?.add(summary);
            recordings.removeWhere((r) => r.sessionId == summary.sessionId);
          },
          onShare: (paths) async {
            sharedCalls?.add(paths);
          },
          exportProfileDraft: exportProfileDraft,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists recordings and shows an empty state with none', (
    tester,
  ) async {
    await pumpPage(tester, recordings: []);

    expect(find.text('No recordings yet.'), findsOneWidget);
  });

  testWidgets('shows start time and duration/size/counts for each recording', (
    tester,
  ) async {
    await pumpPage(tester, recordings: [_summary('s1')]);

    expect(find.textContaining('2026-01-01'), findsOneWidget);
    expect(find.textContaining('5m'), findsOneWidget);
    expect(find.textContaining('10 readings, 3 markers'), findsOneWidget);
  });

  testWidgets('marks the currently running recording and disables delete', (
    tester,
  ) async {
    await pumpPage(
      tester,
      recordings: [_summary('running')],
      currentBufferPath: '/recordings/running.jsonl',
    );

    expect(find.text('Recording…'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('sharing one recording hands both its files to onShare', (
    tester,
  ) async {
    final shared = <List<String>>[];
    await pumpPage(tester, recordings: [_summary('s1')], sharedCalls: shared);

    await tester.tap(find.byIcon(Icons.share_outlined));
    await tester.pumpAndSettle();

    expect(shared, [
      ['/recordings/s1.jsonl', '/recordings/s1.jsonl.markers.jsonl'],
    ]);
  });

  testWidgets('deleting a recording asks for confirmation first', (
    tester,
  ) async {
    final recordings = [_summary('s1')];
    final deleted = <RecordingSummary>[];
    await pumpPage(tester, recordings: recordings, deletedCalls: deleted);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete recording?'), findsOneWidget);
    expect(deleted, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, hasLength(1));
    expect(find.text('No recordings yet.'), findsOneWidget);
  });

  testWidgets('cancelling the delete confirmation keeps the recording', (
    tester,
  ) async {
    final deleted = <RecordingSummary>[];
    await pumpPage(tester, recordings: [_summary('s1')], deletedCalls: deleted);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(deleted, isEmpty);
    expect(find.text('No recordings yet.'), findsNothing);
  });

  testWidgets('long-pressing enters multi-select and allows sharing/deleting '
      'several at once', (tester) async {
    final shared = <List<String>>[];
    final deleted = <RecordingSummary>[];
    await pumpPage(
      tester,
      recordings: [_summary('s1'), _summary('s2')],
      sharedCalls: shared,
      deletedCalls: deleted,
    );

    await tester.longPress(find.textContaining('2026-01-01').first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.textContaining('2026-01-01').last);
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.share_outlined));
    await tester.pumpAndSettle();
    expect(shared, hasLength(1));
    expect(shared.single, hasLength(4)); // 2 recordings * 2 files each

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, hasLength(2));
    expect(find.text('No recordings yet.'), findsOneWidget);
  });

  group('profile draft', () {
    testWidgets('no export action without exportProfileDraft', (tester) async {
      await pumpPage(tester, recordings: []);

      expect(find.byTooltip('Share profile draft'), findsNothing);
    });

    testWidgets('tapping the export action shares the written file', (
      tester,
    ) async {
      final shared = <List<String>>[];
      await pumpPage(
        tester,
        recordings: [],
        sharedCalls: shared,
        exportProfileDraft: () async => '/tmp/profile-draft.toml',
      );

      await tester.tap(find.byTooltip('Share profile draft'));
      await tester.pumpAndSettle();

      expect(shared, [
        ['/tmp/profile-draft.toml'],
      ]);
    });
  });
}
