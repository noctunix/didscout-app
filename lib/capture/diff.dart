import 'dart:typed_data';

import 'capture_entry.dart';
import 'isotp.dart';
import 'markers.dart';

/// One byte position whose value differs between the "before" and "after"
/// payload of a [DidDiff].
class ByteDiff {
  final int position;
  final int before;
  final int after;

  const ByteDiff({
    required this.position,
    required this.before,
    required this.after,
  });
}

/// The change observed in one (module, DID) pair between the "before" and
/// "after" windows, with the specific byte positions that differ.
class DidDiff {
  final String? module;
  final String did;
  final Uint8List before;
  final Uint8List after;
  final List<ByteDiff> changes;

  const DidDiff({
    required this.module,
    required this.did,
    required this.before,
    required this.after,
    required this.changes,
  });
}

class _Sample {
  final DateTime timestamp;
  final Uint8List payload;
  const _Sample(this.timestamp, this.payload);
}

/// Compares every (module, DID) pair that has a positive ReadDataByIdentifier
/// payload both shortly before [beforeTimestamp] and shortly after
/// [afterTimestamp], and reports the byte positions whose value changed.
///
/// For each pair, the comparison takes the payload closest to
/// [beforeTimestamp] from the `window`-long interval ending at it, and the
/// payload closest to [afterTimestamp] from the `window`-long interval
/// starting at it. A pair is dropped if its payload also changed in the
/// `controlWindow`-long interval immediately preceding the "before" window
/// (the noise filter) — such a DID was already drifting before the interval
/// under test and isn't specific to it.
///
/// Results are sorted by number of changed bytes, ascending, so small,
/// specific changes come first.
List<DidDiff> computeDiff({
  required List<CaptureEntry> entries,
  required DateTime beforeTimestamp,
  required DateTime afterTimestamp,
  Duration window = const Duration(seconds: 30),
  Duration controlWindow = const Duration(seconds: 30),
}) {
  final samplesByKey = _collectPositiveSamples(entries);

  final beforeWindowStart = beforeTimestamp.subtract(window);
  final controlWindowStart = beforeWindowStart.subtract(controlWindow);
  final afterWindowEnd = afterTimestamp.add(window);

  final results = <DidDiff>[];
  for (final entry in samplesByKey.entries) {
    final (module, did) = entry.key;
    final samples = entry.value;

    final beforeSample = _closestWithin(
      samples,
      beforeWindowStart,
      beforeTimestamp,
      toEnd: true,
    );
    final afterSample = _closestWithin(
      samples,
      afterTimestamp,
      afterWindowEnd,
      toEnd: false,
    );
    if (beforeSample == null || afterSample == null) continue;

    final controlSamples = samples.where(
      (s) =>
          !s.timestamp.isBefore(controlWindowStart) &&
          s.timestamp.isBefore(beforeWindowStart),
    );
    final isNoisy = controlSamples.any(
      (s) => !_bytesEqual(s.payload, beforeSample.payload),
    );
    if (isNoisy) continue;

    final changes = _diffBytes(beforeSample.payload, afterSample.payload);
    if (changes.isEmpty) continue;

    results.add(
      DidDiff(
        module: module,
        did: did,
        before: beforeSample.payload,
        after: afterSample.payload,
        changes: changes,
      ),
    );
  }

  results.sort((a, b) => a.changes.length.compareTo(b.changes.length));
  return results;
}

/// Convenience wrapper over [computeDiff] taking two [Marker]s instead of
/// raw timestamps.
List<DidDiff> computeDiffBetweenMarkers({
  required List<CaptureEntry> entries,
  required Marker before,
  required Marker after,
  Duration window = const Duration(seconds: 30),
  Duration controlWindow = const Duration(seconds: 30),
}) {
  return computeDiff(
    entries: entries,
    beforeTimestamp: before.timestamp,
    afterTimestamp: after.timestamp,
    window: window,
    controlWindow: controlWindow,
  );
}

/// Decodes every positive ReadDataByIdentifier exchange in [entries] into
/// its (module, DID) -> time-ordered samples.
Map<(String?, String), List<_Sample>> _collectPositiveSamples(
  List<CaptureEntry> entries,
) {
  final samplesByKey = <(String?, String), List<_Sample>>{};
  for (final entry in entries) {
    if (entry.isNote) continue;
    final command = entry.command.toUpperCase();
    if (!command.startsWith('22') || command.length < 6) continue;
    final did = command.substring(2);
    final payload = decodePositivePayload(command, entry.response, null);
    if (payload == null) continue;
    samplesByKey
        .putIfAbsent((entry.module, did), () => [])
        .add(_Sample(entry.startedUtc, payload));
  }
  for (final samples in samplesByKey.values) {
    samples.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }
  return samplesByKey;
}

/// Among [samples] falling in `[start, end]`, returns the one closest to
/// [toEnd] ? `end` : `start`.
_Sample? _closestWithin(
  List<_Sample> samples,
  DateTime start,
  DateTime end, {
  required bool toEnd,
}) {
  _Sample? best;
  for (final sample in samples) {
    if (sample.timestamp.isBefore(start) || sample.timestamp.isAfter(end)) {
      continue;
    }
    if (best == null) {
      best = sample;
    } else if (toEnd && sample.timestamp.isAfter(best.timestamp)) {
      best = sample;
    } else if (!toEnd && sample.timestamp.isBefore(best.timestamp)) {
      best = sample;
    }
  }
  return best;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<ByteDiff> _diffBytes(Uint8List before, Uint8List after) {
  final changes = <ByteDiff>[];
  final length = before.length < after.length ? before.length : after.length;
  for (var i = 0; i < length; i++) {
    if (before[i] != after[i]) {
      changes.add(ByteDiff(position: i, before: before[i], after: after[i]));
    }
  }
  return changes;
}
