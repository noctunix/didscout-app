import 'capture_entry.dart';

/// The well-known phase labels a recording session's phase buttons produce.
/// A marker's label is not restricted to these — a free-form action label
/// (e.g. "plugged in", "pedal to the floor") is just as valid a marker.
const Set<String> knownPhases = {'drive', 'charge', 'stand', 'park'};

/// A timestamped label on the capture timeline: either a vehicle phase
/// change or a free-form action, used to bound the "before" and "after"
/// windows that [computeDiff] compares.
class Marker {
  final DateTime timestamp;
  final String label;

  const Marker(this.timestamp, this.label);

  bool get isKnownPhase => knownPhases.contains(label);

  @override
  String toString() => 'Marker($timestamp, $label)';
}

/// Turns every `NOTE` entry in [entries] into a [Marker], using the note's
/// typed text as the label and its `started_utc` as the timestamp.
List<Marker> markersFromNotes(List<CaptureEntry> entries) {
  return entries
      .where((e) => e.isNote)
      .map((e) => Marker(e.startedUtc, e.response))
      .toList();
}

/// Merges the markers found in [entries]' `NOTE` lines with [external]
/// markers supplied by the caller (e.g. phase-button presses recorded
/// outside the capture log), sorted by timestamp.
List<Marker> mergeMarkers(List<CaptureEntry> entries, List<Marker> external) {
  final merged = [...markersFromNotes(entries), ...external];
  merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return merged;
}
