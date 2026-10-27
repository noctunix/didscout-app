import 'package:flutter/foundation.dart';

/// The driving/charging phase a [SessionMarker] records.
enum MarkerPhase { drive, charge, stand, park }

/// The kind of event a [SessionMarker] carries.
enum MarkerKind { phase, note }

/// A single, immutable entry in a session's marker log.
///
/// A marker is either a [MarkerKind.phase] change (with [phase] set) or a
/// free-text [MarkerKind.note] (with [text] set).
@immutable
class SessionMarker {
  const SessionMarker.phase({required this.timestamp, required this.phase})
    : kind = MarkerKind.phase,
      text = null;

  const SessionMarker.note({required this.timestamp, required this.text})
    : kind = MarkerKind.note,
      phase = null;

  /// UTC time the marker was recorded.
  final DateTime timestamp;

  final MarkerKind kind;

  /// Set when [kind] is [MarkerKind.phase], null otherwise.
  final MarkerPhase? phase;

  /// Set when [kind] is [MarkerKind.note], null otherwise.
  final String? text;
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
      if (marker.kind == MarkerKind.phase) {
        return marker.phase;
      }
    }
    return null;
  }

  void addPhase(MarkerPhase phase) {
    _markers.add(
      SessionMarker.phase(timestamp: _clock().toUtc(), phase: phase),
    );
    notifyListeners();
  }

  void addNote(String text) {
    _markers.add(SessionMarker.note(timestamp: _clock().toUtc(), text: text));
    notifyListeners();
  }
}
