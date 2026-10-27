import 'dart:convert';

/// One exchange recorded in a `capture.jsonl` log, as written by the
/// `didscout` CLI's recorder: a stage name, the command sent, the raw
/// response text, a status classification, and the UTC time the exchange
/// started. A manually typed note lands in the same log as an entry with
/// `command == 'NOTE'` and the typed text as its response.
class CaptureEntry {
  final String stage;
  final String command;
  final String response;
  final String status;
  final DateTime startedUtc;
  final String? module;

  const CaptureEntry({
    required this.stage,
    required this.command,
    required this.response,
    required this.status,
    required this.startedUtc,
    this.module,
  });

  /// Whether this entry is a typed note rather than a polled exchange.
  bool get isNote => command == 'NOTE';

  @override
  String toString() =>
      'CaptureEntry(stage: $stage, command: $command, status: $status, '
      'startedUtc: $startedUtc, module: $module)';
}

/// One line of a `capture.jsonl` file that could not be turned into a
/// [CaptureEntry], with the 1-based line number and a human-readable reason.
class MalformedCaptureLine {
  final int lineNumber;
  final String rawLine;
  final String reason;

  const MalformedCaptureLine({
    required this.lineNumber,
    required this.rawLine,
    required this.reason,
  });

  @override
  String toString() => 'line $lineNumber: $reason';
}

/// The result of reading a `capture.jsonl` file: the entries that parsed
/// successfully, in file order, plus every line that didn't.
class CaptureReadResult {
  final List<CaptureEntry> entries;
  final List<MalformedCaptureLine> malformedLines;

  const CaptureReadResult({
    required this.entries,
    required this.malformedLines,
  });
}

/// Tolerantly parses the lines of a `capture.jsonl` file. Unknown JSON keys
/// are ignored, blank lines are skipped, and a line that is not valid JSON,
/// is not a JSON object, or is missing/mistyping a required field is
/// reported in [CaptureReadResult.malformedLines] rather than throwing.
CaptureReadResult readCaptureJsonl(String contents) {
  final entries = <CaptureEntry>[];
  final malformed = <MalformedCaptureLine>[];
  final lines = contents.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final rawLine = lines[i];
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final lineNumber = i + 1;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (error) {
      malformed.add(
        MalformedCaptureLine(
          lineNumber: lineNumber,
          rawLine: rawLine,
          reason: 'invalid JSON: $error',
        ),
      );
      continue;
    }
    if (decoded is! Map) {
      malformed.add(
        MalformedCaptureLine(
          lineNumber: lineNumber,
          rawLine: rawLine,
          reason: 'not a JSON object',
        ),
      );
      continue;
    }
    final map = decoded;
    final entry = _tryParseEntry(map);
    if (entry == null) {
      malformed.add(
        MalformedCaptureLine(
          lineNumber: lineNumber,
          rawLine: rawLine,
          reason: 'missing or malformed required field',
        ),
      );
      continue;
    }
    entries.add(entry);
  }
  return CaptureReadResult(entries: entries, malformedLines: malformed);
}

CaptureEntry? _tryParseEntry(Map<dynamic, dynamic> map) {
  final stage = map['stage'];
  final command = map['command'];
  final response = map['response'];
  final status = map['status'];
  final startedUtcRaw = map['started_utc'];
  final module = map['module'];
  if (stage is! String ||
      command is! String ||
      response is! String ||
      status is! String) {
    return null;
  }
  if (startedUtcRaw is! String) return null;
  final startedUtc = DateTime.tryParse(startedUtcRaw);
  if (startedUtc == null) return null;
  if (module != null && module is! String) return null;
  return CaptureEntry(
    stage: stage,
    command: command,
    response: response,
    status: status,
    startedUtc: startedUtc,
    module: module as String?,
  );
}
