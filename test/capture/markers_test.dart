import 'package:didscout_app/capture/capture_entry.dart';
import 'package:didscout_app/capture/markers.dart';
import 'package:flutter_test/flutter_test.dart';

CaptureEntry _note(String text, DateTime at) => CaptureEntry(
  stage: 'notes',
  command: 'NOTE',
  response: text,
  status: 'NOTE',
  startedUtc: at,
);

CaptureEntry _poll(DateTime at) => CaptureEntry(
  stage: 'sweep',
  command: '22F40C',
  response: '7E8 04 62 F4 0C 2A',
  status: 'OK',
  startedUtc: at,
);

void main() {
  group('markersFromNotes', () {
    test('turns NOTE entries into markers and skips polled exchanges', () {
      final t0 = DateTime.utc(2026, 1, 1, 10, 0, 0);
      final entries = [
        _note('drive', t0),
        _poll(t0.add(const Duration(seconds: 1))),
      ];

      final markers = markersFromNotes(entries);

      expect(markers, hasLength(1));
      expect(markers.single.label, 'drive');
      expect(markers.single.timestamp, t0);
      expect(markers.single.isKnownPhase, isTrue);
    });

    test('a free-form action label is not a known phase', () {
      final markers = markersFromNotes([
        _note('pedal to the floor', DateTime.utc(2026)),
      ]);

      expect(markers.single.isKnownPhase, isFalse);
    });
  });

  group('mergeMarkers', () {
    test(
      'merges note markers with caller-supplied markers, sorted by time',
      () {
        final t0 = DateTime.utc(2026, 1, 1, 10, 0, 0);
        final entries = [_note('charge', t0.add(const Duration(seconds: 10)))];
        final external = [Marker(t0, 'drive')];

        final markers = mergeMarkers(entries, external);

        expect(markers.map((m) => m.label), ['drive', 'charge']);
      },
    );
  });
}
