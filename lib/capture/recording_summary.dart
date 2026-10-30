import 'dart:convert';
import 'dart:io';

/// Everything the Recordings list shows about one recording, derived by
/// scanning its buffer file (and marker sidecar, if any) rather than
/// keeping a separate index — the buffer/sidecar pair is the only record
/// of a recording that exists.
class RecordingSummary {
  const RecordingSummary({
    required this.sessionId,
    required this.bufferPath,
    required this.markersPath,
    required this.startedAt,
    required this.duration,
    required this.sizeBytes,
    required this.readingCount,
    required this.markerCount,
  });

  /// The `<sessionId>.jsonl` buffer's own session id, read from its file
  /// name.
  final String sessionId;

  final String bufferPath;

  /// Null only for a buffer predating this feature, which never got a
  /// sidecar at all.
  final String? markersPath;

  final DateTime startedAt;

  /// Null when the buffer has too few timestamped exchanges to tell.
  final Duration? duration;

  /// Buffer file size plus the sidecar's, if any.
  final int sizeBytes;

  /// Number of vehicle-read exchanges in the buffer (gap lines excluded).
  final int readingCount;

  /// Number of marker sidecar lines, excluding the `plan` and `modules`
  /// lines, which map module ids to headers rather than mark anything.
  final int markerCount;
}

const Set<String> _moduleHeaderLineTypes = {'plan', 'modules'};

/// Every recording buffer (`<sessionId>.jsonl`, excluding its
/// `.markers.jsonl` sidecar) in [directory], in no particular order. An
/// empty or missing directory yields an empty list.
Future<List<File>> listRecordingBuffers(Directory directory) async {
  if (!await directory.exists()) return [];
  return [
    await for (final entity in directory.list())
      if (entity is File &&
          entity.path.endsWith('.jsonl') &&
          !entity.path.endsWith('.markers.jsonl'))
        entity,
  ];
}

/// Scans [directory] for recording buffers ([listRecordingBuffers]) and
/// summarizes each one, newest first.
Future<List<RecordingSummary>> listRecordings(Directory directory) async {
  final summaries = [
    for (final buffer in await listRecordingBuffers(directory))
      await summarizeRecording(buffer),
  ];
  summaries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return summaries;
}

/// Summarizes one recording from its buffer file, reading the matching
/// `.markers.jsonl` sidecar alongside it if one exists.
Future<RecordingSummary> summarizeRecording(File bufferFile) async {
  final path = bufferFile.path;
  final sessionId = sessionIdOfBuffer(path);
  final markersFile = File('$path.markers.jsonl');
  final hasMarkersFile = await markersFile.exists();

  DateTime? headerCreated;
  DateTime? firstRequested;
  DateTime? lastReceived;
  var readingCount = 0;
  for (final line in await _readJsonLines(bufferFile)) {
    if (line.containsKey('createdUtcMs')) {
      headerCreated = _epochMs(line['createdUtcMs']);
      continue;
    }
    if (line['sequence'] is! int) continue; // a gap line, not an exchange
    readingCount++;
    final requested = _epochMs(line['requestStartedUtcMs']);
    if (requested != null) {
      firstRequested ??= requested;
    }
    final received = _epochMs(line['receivedUtcMs']) ?? requested;
    if (received != null &&
        (lastReceived == null || received.isAfter(lastReceived))) {
      lastReceived = received;
    }
  }

  final bufferStat = await bufferFile.stat();
  final startedAt = headerCreated ?? firstRequested ?? bufferStat.changed;
  final duration = (firstRequested != null && lastReceived != null)
      ? lastReceived.difference(firstRequested)
      : null;

  var sizeBytes = await bufferFile.length();
  var markerCount = 0;
  if (hasMarkersFile) {
    sizeBytes += await markersFile.length();
    for (final line in await _readJsonLines(markersFile)) {
      if (!_moduleHeaderLineTypes.contains(line['type'])) markerCount++;
    }
  }

  return RecordingSummary(
    sessionId: sessionId,
    bufferPath: path,
    markersPath: hasMarkersFile ? markersFile.path : null,
    startedAt: startedAt,
    duration: duration,
    sizeBytes: sizeBytes,
    readingCount: readingCount,
    markerCount: markerCount,
  );
}

/// Deletes [summary]'s buffer and sidecar (if any). A no-op for whichever
/// of them no longer exists.
Future<void> deleteRecording(RecordingSummary summary) async {
  final buffer = File(summary.bufferPath);
  if (await buffer.exists()) await buffer.delete();
  final markersPath = summary.markersPath;
  if (markersPath != null) {
    final markers = File(markersPath);
    if (await markers.exists()) await markers.delete();
  }
}

Future<List<Map<String, dynamic>>> _readJsonLines(File file) async {
  final result = <Map<String, dynamic>>[];
  for (final raw in await file.readAsLines()) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) result.add(decoded);
    } on FormatException {
      continue;
    }
  }
  return result;
}

/// The session id a `<sessionId>.jsonl` buffer at [path] is named after.
String sessionIdOfBuffer(String path) {
  final name = path.split(Platform.pathSeparator).last;
  return name.endsWith('.jsonl')
      ? name.substring(0, name.length - '.jsonl'.length)
      : name;
}

DateTime? _epochMs(Object? value) =>
    value is int ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true) : null;
