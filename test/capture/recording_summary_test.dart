import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/capture/recording_summary.dart';

String _header({required int createdUtcMs}) =>
    '{"format":"didscout-buffer","formatVersion":1,"sessionId":"s1",'
    '"planId":"didscout-fixed-plan","planVersion":1,"timebaseId":"t1",'
    '"createdUtcMs":$createdUtcMs}';

String _exchange({
  required int sequence,
  required int requestStartedUtcMs,
  required int receivedUtcMs,
}) =>
    '{"sequence":$sequence,"signalId":"module7_22f40d",'
    '"requestStartedUtcMs":$requestStartedUtcMs,'
    '"receivedUtcMs":$receivedUtcMs,"monotonicStartNs":0,"durationNs":100,'
    '"timebaseId":"t1","raw":"aa","transport":"ok"}';

const String _gap = '{"gap":1,"afterSequence":1,"reason":"disconnected"}';

String _planLine() =>
    '{"type":"plan","planId":"didscout-fixed-plan","planVersion":1,'
    '"at":"2026-01-01T12:00:00.000Z","modules":[]}';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('recording_summary_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<File> writeBuffer(String name, List<String> lines) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString('${lines.join('\n')}\n');
    return file;
  }

  group('summarizeRecording', () {
    test('reads start time from the header, duration from the samples', () async {
      final buffer = await writeBuffer('a.jsonl', [
        _header(createdUtcMs: 1700000000000),
        _exchange(
          sequence: 1,
          requestStartedUtcMs: 1700000000000,
          receivedUtcMs: 1700000000500,
        ),
        _gap,
        _exchange(
          sequence: 2,
          requestStartedUtcMs: 1700000010000,
          receivedUtcMs: 1700000010500,
        ),
      ]);

      final summary = await summarizeRecording(buffer);

      expect(summary.sessionId, 'a');
      expect(
        summary.startedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );
      // Last receivedUtcMs - first requestStartedUtcMs.
      expect(summary.duration, const Duration(seconds: 10, milliseconds: 500));
      // The gap line doesn't count as a reading.
      expect(summary.readingCount, 2);
      expect(summary.markersPath, isNull);
      expect(summary.markerCount, 0);
      expect(summary.sizeBytes, await buffer.length());
    });

    test('counts sidecar markers, excluding the plan line', () async {
      final buffer = await writeBuffer('b.jsonl', [
        _header(createdUtcMs: 1700000000000),
        _exchange(
          sequence: 1,
          requestStartedUtcMs: 1700000000000,
          receivedUtcMs: 1700000000500,
        ),
      ]);
      final sidecar = File('${buffer.path}.markers.jsonl');
      await sidecar.writeAsString(
        '${_planLine()}\n'
        '{"type":"phase","phase":"drive","at":"2026-01-01T12:00:00.000Z"}\n'
        '{"type":"note","text":"hi","at":"2026-01-01T12:00:01.000Z"}\n',
      );

      final summary = await summarizeRecording(buffer);

      expect(summary.markersPath, sidecar.path);
      expect(summary.markerCount, 2);
      expect(summary.sizeBytes, await buffer.length() + await sidecar.length());
    });
  });

  group('listRecordings', () {
    test('lists buffers newest first, ignoring sidecar files', () async {
      await writeBuffer('old.jsonl', [_header(createdUtcMs: 1000)]);
      await writeBuffer('new.jsonl', [_header(createdUtcMs: 2000)]);
      await File(
        '${tempDir.path}/old.jsonl.markers.jsonl',
      ).writeAsString('${_planLine()}\n');

      final recordings = await listRecordings(tempDir);

      expect(recordings.map((r) => r.sessionId), ['new', 'old']);
    });

    test('an empty directory yields an empty list', () async {
      final emptyDir = Directory('${tempDir.path}/empty')
        ..createSync();

      expect(await listRecordings(emptyDir), isEmpty);
    });

    test('a missing directory yields an empty list', () async {
      final missing = Directory('${tempDir.path}/does-not-exist');

      expect(await listRecordings(missing), isEmpty);
    });
  });

  group('deleteRecording', () {
    test('removes both the buffer and the sidecar', () async {
      final buffer = await writeBuffer('c.jsonl', [
        _header(createdUtcMs: 1700000000000),
      ]);
      final sidecar = File('${buffer.path}.markers.jsonl');
      await sidecar.writeAsString('${_planLine()}\n');
      final summary = await summarizeRecording(buffer);

      await deleteRecording(summary);

      expect(await buffer.exists(), isFalse);
      expect(await sidecar.exists(), isFalse);
    });

    test('a missing sidecar is a no-op, not an error', () async {
      final buffer = await writeBuffer('d.jsonl', [
        _header(createdUtcMs: 1700000000000),
      ]);
      final summary = await summarizeRecording(buffer);

      await deleteRecording(summary);

      expect(await buffer.exists(), isFalse);
    });
  });
}
