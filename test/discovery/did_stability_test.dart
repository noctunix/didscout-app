import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/discovery/did_stability.dart';
import 'package:didscout_app/discovery/discovery_state.dart';

String _hex(String text) => text.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

/// Writes a synthetic recording [sessionId] into [dir]: a buffer whose
/// rows are `(signalId, responseText)` pairs (null text: a cancelled
/// transport), plus a sidecar plan naming [modules] (id -> request
/// header, 11-bit).
void _writeRecording(
  Directory dir,
  String sessionId, {
  required int createdUtcMs,
  required Map<String, String> modules,
  required List<(String, String?)> rows,
  Set<int> oneShotRows = const {},
}) {
  final buffer = File('${dir.path}/$sessionId.jsonl');
  final lines = [
    jsonEncode({
      'format': 'didscout-buffer',
      'sessionId': sessionId,
      'createdUtcMs': createdUtcMs,
    }),
    for (var i = 0; i < rows.length; i++)
      jsonEncode({
        'sequence': i + 1,
        'signalId': rows[i].$1,
        'raw': _hex(rows[i].$2 ?? ''),
        'transport': rows[i].$2 == null ? 'cancelled' : 'ok',
        if (oneShotRows.contains(i)) 'oneShot': true,
      }),
  ];
  buffer.writeAsStringSync('${lines.join('\n')}\n');
  final plan = {
    'type': 'plan',
    'modules': [
      for (final MapEntry(:key, :value) in modules.entries)
        {'id': key, 'request': value, 'response': '7B8', 'protocol': '6'},
    ],
  };
  File(
    '${buffer.path}.markers.jsonl',
  ).writeAsStringSync('${jsonEncode(plan)}\n');
}

void main() {
  group('didLooksStable', () {
    test('an identification DID is stable until a change is seen', () {
      expect(didLooksStable('F187', null), isTrue);
      expect(didLooksStable('F1FF', DidSampleStats()), isTrue);
      expect(
        didLooksStable(
          'F186',
          DidSampleStats(lastPayloadHash: 1, stableSamples: 1)
            ..everChanged = true,
        ),
        isFalse,
      );
    });

    test('any other DID needs enough identical samples over enough '
        'recordings', () {
      expect(didLooksStable('2A00', null), isFalse);
      expect(
        didLooksStable(
          '2A00',
          DidSampleStats(
            lastPayloadHash: 1,
            stableSamples: stableSampleCount,
            stableRecordings: stableRecordingCount - 1,
          ),
        ),
        isFalse,
      );
      expect(
        didLooksStable(
          '2A00',
          DidSampleStats(
            lastPayloadHash: 1,
            stableSamples: stableSampleCount - 1,
            stableRecordings: stableRecordingCount,
          ),
        ),
        isFalse,
      );
      expect(
        didLooksStable(
          '2A00',
          DidSampleStats(
            lastPayloadHash: 1,
            stableSamples: stableSampleCount,
            stableRecordings: stableRecordingCount,
          ),
        ),
        isTrue,
      );
    });

    test('a changed identification DID can become stable again', () {
      expect(
        didLooksStable(
          'F186',
          DidSampleStats(
            lastPayloadHash: 1,
            stableSamples: stableSampleCount,
            stableRecordings: stableRecordingCount,
            everChanged: true,
          ),
        ),
        isTrue,
      );
    });
  });

  group('DidSampleStats.record', () {
    test('counts identical samples and the recordings they span, and '
        'restarts on a change', () {
      final stats = DidSampleStats()
        ..record(7, firstInRecording: true)
        ..record(7, firstInRecording: false)
        ..record(7, firstInRecording: true);
      expect(stats.stableSamples, 3);
      expect(stats.stableRecordings, 2);
      expect(stats.everChanged, isFalse);

      stats.record(8, firstInRecording: false);
      expect(stats.lastPayloadHash, 8);
      expect(stats.stableSamples, 1);
      expect(stats.stableRecordings, 1);
      expect(stats.everChanged, isTrue);
    });
  });

  group('readRecordedSamples', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('did_stability_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('keeps only positive recurring reads of planned modules, hashing '
        'equal payloads equally', () {
      _writeRecording(
        dir,
        's1',
        createdUtcMs: 1000,
        modules: {'door': '74A'},
        rows: [
          ('door_222a00', '7B8 05 62 2A 00 01 02'),
          ('door_222a00', '7B8 05 62 2A 00 01 02'),
          ('door_222a00', '7B8 05 62 2A 00 01 03'),
          ('door_222a01', 'NO DATA'),
          ('door_222a02', '7B8 03 7F 22 31'),
          ('door_222a03', null),
          ('door_222a04', '7B8 05 62 2A 04 01 02'),
          ('ghost_222a00', '7C8 05 62 2A 00 01 02'),
        ],
        oneShotRows: {6},
      );

      final recording = readRecordedSamples('${dir.path}/s1.jsonl');

      expect(recording.sessionId, 's1');
      expect(recording.createdUtcMs, 1000);
      expect(recording.samples.map((s) => (s.requestHeader, s.did)), [
        ('74A', '2A00'),
        ('74A', '2A00'),
        ('74A', '2A00'),
      ]);
      final hashes = recording.samples.map((s) => s.payloadHash).toList();
      expect(hashes[0], hashes[1]);
      expect(hashes[1], isNot(hashes[2]));
    });

    test('a buffer without a sidecar plan yields no samples', () {
      _writeRecording(
        dir,
        's1',
        createdUtcMs: 1000,
        modules: {'door': '74A'},
        rows: [('door_222a00', '7B8 05 62 2A 00 01 02')],
      );
      File('${dir.path}/s1.jsonl.markers.jsonl').deleteSync();

      expect(readRecordedSamples('${dir.path}/s1.jsonl').samples, isEmpty);
    });
  });

  group('learnFromRecordings', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('did_stability_'));
    tearDown(() => dir.deleteSync(recursive: true));

    DiscoveryState doorState() => DiscoveryState(
      ecus: {
        'door': EcuInfo(
          requestHeader: '74A',
          responseHeader: '7B4',
          protocol: 6,
          discovered: {'2A00'},
        ),
      },
    );

    test('learns each recording once, oldest first, and only for '
        'discovered DIDs', () async {
      // Named so directory order and age disagree: the older recording
      // ends on the value the newer one starts with.
      _writeRecording(
        dir,
        'b-newer',
        createdUtcMs: 2000,
        modules: {'door': '74A'},
        rows: [
          ('door_222a00', '7B8 04 62 2A 00 02'),
          ('door_222a00', '7B8 04 62 2A 00 02'),
        ],
      );
      _writeRecording(
        dir,
        'a-older',
        createdUtcMs: 1000,
        modules: {'door': '74A'},
        rows: [
          ('door_222a00', '7B8 04 62 2A 00 01'),
          ('door_222a00', '7B8 04 62 2A 00 02'),
          ('door_222a01', '7B8 04 62 2A 01 09'),
        ],
      );
      final state = doorState();

      expect(await learnFromRecordings(state, dir), isTrue);

      final stats = state.ecus['door']!.sampleStats;
      expect(stats.keys, ['2A00']);
      expect(stats['2A00']!.stableSamples, 3);
      expect(stats['2A00']!.stableRecordings, 2);
      expect(stats['2A00']!.everChanged, isTrue);
      expect(state.learnedRecordings, {'a-older', 'b-newer'});

      expect(await learnFromRecordings(state, dir), isFalse);
      expect(stats['2A00']!.stableSamples, 3);
    });

    test('a missing directory teaches nothing', () async {
      final state = doorState();

      expect(
        await learnFromRecordings(state, Directory('${dir.path}/missing')),
        isFalse,
      );
    });
  });
}
