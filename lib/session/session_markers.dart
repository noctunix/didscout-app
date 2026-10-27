import 'package:flutter/foundation.dart';

import '../capture/readings.dart';

/// The driving/charging phase a [PhaseMarker] records.
enum MarkerPhase { drive, charge, stand, park }

/// A single, immutable entry in a session's marker log, and the exact JSON
/// shape ([toJson]) the marker sidecar file (`<buffer>.markers.jsonl`)
/// records it as — one object per line, parsed by another component, so
/// keys and spellings here are fixed, not just documentation.
@immutable
sealed class SessionMarker {
  const SessionMarker();

  /// The time this marker sorts and displays by: the phase/note/event
  /// timestamp, or a reading's [ReadingMarker.readAt] — the moment the tile
  /// was tapped, not when it was saved.
  DateTime get timestamp;

  Map<String, dynamic> toJson();
}

class PhaseMarker extends SessionMarker {
  const PhaseMarker({required this.at, required this.phase});

  final DateTime at;
  final MarkerPhase phase;

  @override
  DateTime get timestamp => at;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'phase',
    'phase': phase.name,
    'at': at.toIso8601String(),
  };
}

class NoteMarker extends SessionMarker {
  const NoteMarker({required this.at, required this.text});

  final DateTime at;
  final String text;

  @override
  DateTime get timestamp => at;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'note',
    'text': text,
    'at': at.toIso8601String(),
  };
}

class EventMarker extends SessionMarker {
  const EventMarker({required this.at, required this.label});

  final DateTime at;
  final String label;

  @override
  DateTime get timestamp => at;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'event',
    'label': label,
    'at': at.toIso8601String(),
  };
}

class ReadingMarker extends SessionMarker {
  const ReadingMarker({
    required this.quantity,
    required this.value,
    required this.unit,
    required this.readAt,
    required this.savedAt,
    required this.source,
    this.prefill,
    this.liveValue,
    this.speedKmh,
  });

  final ReadingQuantity quantity;
  final num value;
  final String unit;

  /// The moment the tile was tapped — this marker's [timestamp].
  final DateTime readAt;

  /// The moment Save was tapped.
  final DateTime savedAt;

  final ReadingSource source;

  /// The value the entry sheet was prefilled with (the quantity's last
  /// entry), or null if there was none yet.
  final num? prefill;

  /// The vehicle's own live value for this quantity at read time, if any.
  final num? liveValue;

  /// The vehicle's live speed at read time, if any.
  final num? speedKmh;

  @override
  DateTime get timestamp => readAt;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'reading',
    'quantity': quantity.wireName,
    'value': value,
    'unit': unit,
    'read_at': readAt.toIso8601String(),
    'saved_at': savedAt.toIso8601String(),
    'source': source.name,
    'prefill': prefill,
    'live_value': liveValue,
    'speed_kmh': speedKmh,
  };
}

/// An in-memory, append-only, time-ordered log of markers for the current
/// recording session. Notifies listeners whenever a marker is added.
class SessionMarkerLog extends ChangeNotifier {
  SessionMarkerLog({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<SessionMarker> _markers = [];

  /// Markers in the order they were added (oldest first).
  List<SessionMarker> get markers => List.unmodifiable(_markers);

  /// The most recently added phase marker's phase, or null if none yet.
  MarkerPhase? get currentPhase {
    for (final marker in _markers.reversed) {
      if (marker is PhaseMarker) {
        return marker.phase;
      }
    }
    return null;
  }

  /// The most recently added reading for [quantity], or null if none yet —
  /// used to prefill a tile's entry sheet.
  num? lastValueFor(ReadingQuantity quantity) {
    for (final marker in _markers.reversed) {
      if (marker is ReadingMarker && marker.quantity == quantity) {
        return marker.value;
      }
    }
    return null;
  }

  void addPhase(MarkerPhase phase) {
    _markers.add(PhaseMarker(at: _clock().toUtc(), phase: phase));
    notifyListeners();
  }

  void addNote(String text) {
    _markers.add(NoteMarker(at: _clock().toUtc(), text: text));
    notifyListeners();
  }

  void addEvent(String label) {
    _markers.add(EventMarker(at: _clock().toUtc(), label: label));
    notifyListeners();
  }

  void addReading({
    required ReadingQuantity quantity,
    required num value,
    required String unit,
    required DateTime readAt,
    required ReadingSource source,
    num? prefill,
    num? liveValue,
    num? speedKmh,
  }) {
    _markers.add(
      ReadingMarker(
        quantity: quantity,
        value: value,
        unit: unit,
        readAt: readAt.toUtc(),
        savedAt: _clock().toUtc(),
        source: source,
        prefill: prefill,
        liveValue: liveValue,
        speedKmh: speedKmh,
      ),
    );
    notifyListeners();
  }
}
