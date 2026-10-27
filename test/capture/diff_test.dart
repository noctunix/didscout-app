import 'package:didscout_app/capture/capture_entry.dart';
import 'package:didscout_app/capture/diff.dart';
import 'package:flutter_test/flutter_test.dart';

CaptureEntry _reading({
  required String did,
  required int value,
  required DateTime at,
  String module = 'm1',
}) {
  return CaptureEntry(
    stage: 'sweep',
    command: '22$did',
    response:
        '7E8 04 62 ${did.substring(0, 2)} ${did.substring(2, 4)} '
        '${value.toRadixString(16).padLeft(2, '0')}',
    status: 'OK',
    startedUtc: at,
    module: module,
  );
}

void main() {
  test(
    'reports a DID that changes exactly at the marker boundary and filters a noisy one',
    () {
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final marker1 = t0.add(const Duration(seconds: 100));
      final marker2 = t0.add(const Duration(seconds: 140));

      final entries = [
        // AAAA: stable before, changes exactly between the two markers.
        _reading(
          did: 'AAAA',
          value: 0x01,
          at: t0.add(const Duration(seconds: 90)),
        ),
        _reading(
          did: 'AAAA',
          value: 0x02,
          at: t0.add(const Duration(seconds: 145)),
        ),
        // BBBB: already drifting in the control window right before the
        // before-window - should be filtered out as noise.
        _reading(
          did: 'BBBB',
          value: 0x10,
          at: t0.add(const Duration(seconds: 50)),
        ),
        _reading(
          did: 'BBBB',
          value: 0x11,
          at: t0.add(const Duration(seconds: 95)),
        ),
        _reading(
          did: 'BBBB',
          value: 0x22,
          at: t0.add(const Duration(seconds: 145)),
        ),
      ];

      final diffs = computeDiff(
        entries: entries,
        beforeTimestamp: marker1,
        afterTimestamp: marker2,
      );

      expect(diffs, hasLength(1));
      final diff = diffs.single;
      expect(diff.did, 'AAAA');
      expect(diff.module, 'm1');
      expect(diff.changes, hasLength(1));
      expect(diff.changes.single.position, 0);
      expect(diff.changes.single.before, 0x01);
      expect(diff.changes.single.after, 0x02);
    },
  );

  test('ignores a DID with no change between the windows', () {
    final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
    final marker1 = t0.add(const Duration(seconds: 100));
    final marker2 = t0.add(const Duration(seconds: 140));

    final entries = [
      _reading(
        did: 'CCCC',
        value: 0x05,
        at: t0.add(const Duration(seconds: 90)),
      ),
      _reading(
        did: 'CCCC',
        value: 0x05,
        at: t0.add(const Duration(seconds: 145)),
      ),
    ];

    final diffs = computeDiff(
      entries: entries,
      beforeTimestamp: marker1,
      afterTimestamp: marker2,
    );

    expect(diffs, isEmpty);
  });

  test('sorts results by number of changed bytes ascending', () {
    final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
    final marker1 = t0.add(const Duration(seconds: 100));
    final marker2 = t0.add(const Duration(seconds: 140));

    CaptureEntry multiByteReading(String did, List<int> bytes, DateTime at) {
      final hexBytes = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      return CaptureEntry(
        stage: 'sweep',
        command: '22$did',
        response:
            '7E8 ${(bytes.length + 3).toRadixString(16).padLeft(2, '0')} '
            '62 ${did.substring(0, 2)} ${did.substring(2, 4)} $hexBytes',
        status: 'OK',
        startedUtc: at,
        module: 'm1',
      );
    }

    final entries = [
      // DDDD: two bytes change.
      multiByteReading('DDDD', [
        0x01,
        0x01,
      ], t0.add(const Duration(seconds: 90))),
      multiByteReading('DDDD', [
        0x02,
        0x02,
      ], t0.add(const Duration(seconds: 145))),
      // EEEE: one byte changes.
      multiByteReading('EEEE', [
        0x01,
        0x09,
      ], t0.add(const Duration(seconds: 90))),
      multiByteReading('EEEE', [
        0x02,
        0x09,
      ], t0.add(const Duration(seconds: 145))),
    ];

    final diffs = computeDiff(
      entries: entries,
      beforeTimestamp: marker1,
      afterTimestamp: marker2,
    );

    expect(diffs.map((d) => d.did), ['EEEE', 'DDDD']);
  });
}
