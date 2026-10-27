import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/session/session_markers.dart';

void main() {
  group('SessionMarkerLog', () {
    test('keeps markers in the order they were added', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0, 0);
      final log = SessionMarkerLog(clock: () => now);

      log.addPhase(MarkerPhase.drive);
      now = now.add(const Duration(minutes: 5));
      log.addNote('battery at 80%');
      now = now.add(const Duration(minutes: 1));
      log.addPhase(MarkerPhase.charge);

      expect(log.markers, hasLength(3));
      expect(log.markers[0].kind, MarkerKind.phase);
      expect(log.markers[0].phase, MarkerPhase.drive);
      expect(log.markers[1].kind, MarkerKind.note);
      expect(log.markers[1].text, 'battery at 80%');
      expect(log.markers[2].phase, MarkerPhase.charge);
      expect(
        log.markers[0].timestamp.isBefore(log.markers[1].timestamp),
        isTrue,
      );
      expect(
        log.markers[1].timestamp.isBefore(log.markers[2].timestamp),
        isTrue,
      );
    });

    test('exposes the most recent phase as currentPhase', () {
      final log = SessionMarkerLog(clock: () => DateTime.utc(2026, 1, 1));

      expect(log.currentPhase, isNull);

      log.addPhase(MarkerPhase.drive);
      expect(log.currentPhase, MarkerPhase.drive);

      log.addNote('irrelevant to phase');
      expect(log.currentPhase, MarkerPhase.drive);

      log.addPhase(MarkerPhase.park);
      expect(log.currentPhase, MarkerPhase.park);
    });

    test('markers list is a snapshot, not a live view', () {
      final log = SessionMarkerLog(clock: () => DateTime.utc(2026, 1, 1));
      log.addPhase(MarkerPhase.drive);

      final snapshot = log.markers;
      log.addPhase(MarkerPhase.park);

      expect(snapshot, hasLength(1));
      expect(log.markers, hasLength(2));
      expect(() => snapshot.add(log.markers.first), throwsUnsupportedError);
    });

    test('notifies listeners when a marker is added', () {
      final log = SessionMarkerLog(clock: () => DateTime.utc(2026, 1, 1));
      var notifications = 0;
      log.addListener(() => notifications++);

      log.addPhase(MarkerPhase.drive);
      log.addNote('hello');

      expect(notifications, 2);
    });

    test('stores timestamps as UTC regardless of clock input', () {
      final local = DateTime(2026, 1, 1, 12, 0, 0);
      final log = SessionMarkerLog(clock: () => local);

      log.addPhase(MarkerPhase.stand);

      expect(log.markers.single.timestamp.isUtc, isTrue);
    });
  });
}
