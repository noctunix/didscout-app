import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/capture/readings.dart';
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
      expect(log.markers[0], isA<PhaseMarker>());
      expect((log.markers[0] as PhaseMarker).phase, MarkerPhase.drive);
      expect(log.markers[1], isA<NoteMarker>());
      expect((log.markers[1] as NoteMarker).text, 'battery at 80%');
      expect((log.markers[2] as PhaseMarker).phase, MarkerPhase.charge);
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

    test('addEvent records an event marker', () {
      final log = SessionMarkerLog(clock: () => DateTime.utc(2026, 1, 1));
      log.addEvent('climate on');

      expect(log.markers.single, isA<EventMarker>());
      expect((log.markers.single as EventMarker).label, 'climate on');
    });

    test('addReading records read_at separately from saved_at', () {
      final savedAt = DateTime.utc(2026, 1, 1, 10, 5);
      final readAt = DateTime.utc(2026, 1, 1, 10, 0);
      final log = SessionMarkerLog(clock: () => savedAt);

      log.addReading(
        quantity: ReadingQuantity.soc,
        value: 80,
        unit: '%',
        readAt: readAt,
        source: ReadingSource.typed,
      );

      final marker = log.markers.single as ReadingMarker;
      expect(marker.readAt, readAt);
      expect(marker.savedAt, savedAt);
      expect(marker.timestamp, readAt);
    });

    test('lastValueFor returns the most recent reading for that quantity', () {
      final log = SessionMarkerLog(clock: () => DateTime.utc(2026, 1, 1));

      expect(log.lastValueFor(ReadingQuantity.soc), isNull);

      log.addReading(
        quantity: ReadingQuantity.soc,
        value: 70,
        unit: '%',
        readAt: DateTime.utc(2026, 1, 1),
        source: ReadingSource.typed,
      );
      log.addReading(
        quantity: ReadingQuantity.range,
        value: 150,
        unit: 'km',
        readAt: DateTime.utc(2026, 1, 1),
        source: ReadingSource.confirmed,
      );
      log.addReading(
        quantity: ReadingQuantity.soc,
        value: 75,
        unit: '%',
        readAt: DateTime.utc(2026, 1, 1),
        source: ReadingSource.stepped,
      );

      expect(log.lastValueFor(ReadingQuantity.soc), 75);
      expect(log.lastValueFor(ReadingQuantity.range), 150);
      expect(log.lastValueFor(ReadingQuantity.batteryTemp), isNull);
    });

    test('lastValueFor with maxAge ignores a reading older than that', () {
      final now = DateTime.utc(2026, 1, 1, 12);
      final log = SessionMarkerLog(clock: () => now);
      log.addReading(
        quantity: ReadingQuantity.batteryTemp,
        value: 13,
        unit: '°C',
        readAt: now.subtract(const Duration(minutes: 20)),
        source: ReadingSource.typed,
      );
      log.addReading(
        quantity: ReadingQuantity.outsideTemp,
        value: 8,
        unit: '°C',
        readAt: now.subtract(const Duration(minutes: 21)),
        source: ReadingSource.typed,
      );

      const maxAge = Duration(minutes: 20);
      expect(log.lastValueFor(ReadingQuantity.batteryTemp, maxAge: maxAge), 13);
      expect(
        log.lastValueFor(ReadingQuantity.outsideTemp, maxAge: maxAge),
        isNull,
      );
      expect(log.lastValueFor(ReadingQuantity.outsideTemp), 8);
    });
  });

  group('marker sidecar JSON', () {
    test('phase marker', () {
      final marker = PhaseMarker(
        at: DateTime.utc(2026, 1, 1, 10, 0),
        phase: MarkerPhase.drive,
      );
      expect(marker.toJson(), {
        'type': 'phase',
        'phase': 'drive',
        'at': '2026-01-01T10:00:00.000Z',
      });
    });

    test('note marker', () {
      final marker = NoteMarker(
        at: DateTime.utc(2026, 1, 1, 10, 0),
        text: 'voltage reads 402V',
      );
      expect(marker.toJson(), {
        'type': 'note',
        'text': 'voltage reads 402V',
        'at': '2026-01-01T10:00:00.000Z',
      });
    });

    test('event marker', () {
      final marker = EventMarker(
        at: DateTime.utc(2026, 1, 1, 10, 0),
        label: 'climate on',
      );
      expect(marker.toJson(), {
        'type': 'event',
        'label': 'climate on',
        'at': '2026-01-01T10:00:00.000Z',
      });
    });

    test('reading marker, every field present', () {
      final marker = ReadingMarker(
        quantity: ReadingQuantity.outsideTemp,
        value: 12,
        unit: '°C',
        readAt: DateTime.utc(2026, 1, 1, 10, 0),
        savedAt: DateTime.utc(2026, 1, 1, 10, 0, 3),
        source: ReadingSource.confirmed,
        prefill: 10,
        liveValue: 12,
        speedKmh: 0,
      );
      expect(marker.toJson(), {
        'type': 'reading',
        'quantity': 'outside_temp',
        'value': 12,
        'unit': '°C',
        'read_at': '2026-01-01T10:00:00.000Z',
        'saved_at': '2026-01-01T10:00:03.000Z',
        'source': 'confirmed',
        'prefill': 10,
        'live_value': 12,
        'speed_kmh': 0,
      });
    });

    test('reading marker, optional fields null', () {
      final marker = ReadingMarker(
        quantity: ReadingQuantity.soc,
        value: 80,
        unit: '%',
        readAt: DateTime.utc(2026, 1, 1, 10, 0),
        savedAt: DateTime.utc(2026, 1, 1, 10, 0),
        source: ReadingSource.typed,
      );
      expect(marker.toJson(), {
        'type': 'reading',
        'quantity': 'soc',
        'value': 80,
        'unit': '%',
        'read_at': '2026-01-01T10:00:00.000Z',
        'saved_at': '2026-01-01T10:00:00.000Z',
        'source': 'typed',
        'prefill': null,
        'live_value': null,
        'speed_kmh': null,
      });
    });
  });
}
