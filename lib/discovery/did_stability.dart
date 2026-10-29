/// Learns from finished recordings which discovered DIDs never change
/// value, so the recurring plan can sample those rarely and leave the
/// adapter's read budget to discovery: the recurring plan always runs
/// before any queued discovery read.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../capture/isotp.dart';
import '../capture/recording_summary.dart';
import 'discovery_state.dart';
import 'probe.dart';

/// Identical samples in a row after which a DID counts as stable, if they
/// span at least [stableRecordingCount] recordings -- one parked recording
/// alone says little about a value that only moves while driving.
const int stableSampleCount = 10;

/// See [stableSampleCount].
const int stableRecordingCount = 2;

/// The ISO 14229-1 identification DIDs (part numbers, software and
/// hardware versions, ...), assumed stable until a change is observed.
const (int, int) identificationDidRange = (0xF180, 0xF1FF);

/// Recurring interval for a stable DID: still sampled, so a change is
/// noticed and the DID goes back to the normal survey interval.
const int stableDidIntervalMs = 30 * 60 * 1000;

/// Whether [did] (4 hex digits) has, per [stats], kept one value long
/// enough to be sampled at [stableDidIntervalMs] only.
bool didLooksStable(String did, DidSampleStats? stats) {
  if (stats != null &&
      stats.stableSamples >= stableSampleCount &&
      stats.stableRecordings >= stableRecordingCount) {
    return true;
  }
  final value = int.parse(did, radix: 16);
  return value >= identificationDidRange.$1 &&
      value <= identificationDidRange.$2 &&
      !(stats?.everChanged ?? false);
}

/// One positive recurring read found in a recording.
typedef RecordedSample = ({
  int protocol,
  String requestHeader,
  String did,
  int payloadHash,
});

/// Folds every recording in [directory] that [state] hasn't learned from
/// yet into its ECUs' [EcuInfo.sampleStats], oldest first, and marks it
/// learned. Returns whether any recording was new.
///
/// Throws a [FileSystemException] if a recording can't be read.
Future<bool> learnFromRecordings(
  DiscoveryState state,
  Directory directory,
) async {
  final pending = [
    for (final buffer in await listRecordingBuffers(directory))
      if (!state.learnedRecordings.contains(sessionIdOfBuffer(buffer.path)))
        buffer.path,
  ];
  if (pending.isEmpty) {
    return false;
  }
  final recordings = [
    for (final path in pending)
      await Isolate.run(() => readRecordedSamples(path)),
  ]..sort((a, b) => a.createdUtcMs.compareTo(b.createdUtcMs));
  for (final recording in recordings) {
    applyRecordedSamples(state, recording.samples);
    state.learnedRecordings.add(recording.sessionId);
  }
  return true;
}

/// Reads every positive, recurring (not discovery) `22xxxx` read from the
/// buffer at [bufferPath], in file order, resolving each step's module to
/// its request header through the plan line of the buffer's marker
/// sidecar. A buffer without a sidecar plan yields no samples.
///
/// Throws a [FileSystemException] if the buffer can't be read.
({String sessionId, int createdUtcMs, List<RecordedSample> samples})
readRecordedSamples(String bufferPath) {
  final headers = _planModuleHeaders(File('$bufferPath.markers.jsonl'));
  var createdUtcMs = 0;
  final samples = <RecordedSample>[];
  for (final line in File(bufferPath).readAsLinesSync()) {
    final row = _decodeObject(line);
    if (row == null) {
      continue;
    }
    if (row['createdUtcMs'] case final int created) {
      createdUtcMs = created;
      continue;
    }
    if (row['oneShot'] == true || row['transport'] != 'ok') {
      continue;
    }
    final (signalId, raw) = (row['signalId'], row['raw']);
    if (signalId is! String || raw is! String || !signalId.contains('_')) {
      continue;
    }
    final header = headers[moduleIdOf(signalId)];
    final command = commandOf(signalId);
    final response = _asciiFromHex(raw);
    if (header == null ||
        response == null ||
        command.length != 6 ||
        !command.startsWith('22')) {
      continue;
    }
    final payload = decodePositivePayload(command, response, null);
    if (payload == null) {
      continue;
    }
    samples.add((
      protocol: header.protocol,
      requestHeader: header.request,
      did: command.substring(2),
      payloadHash: _fnv1a32(payload),
    ));
  }
  return (
    sessionId: sessionIdOfBuffer(bufferPath),
    createdUtcMs: createdUtcMs,
    samples: samples,
  );
}

/// Records [samples] (one recording's, in order) into the
/// [EcuInfo.sampleStats] of whichever ECU in [state] has the sample's
/// header and has discovered its DID; anything else is ignored.
void applyRecordedSamples(
  DiscoveryState state,
  Iterable<RecordedSample> samples,
) {
  final ecus = {
    for (final ecu in state.ecus.values) (ecu.protocol, ecu.requestHeader): ecu,
  };
  final sampledThisRecording = <DidSampleStats>{};
  for (final sample in samples) {
    final ecu = ecus[(sample.protocol, sample.requestHeader)];
    if (ecu == null || !ecu.discovered.contains(sample.did)) {
      continue;
    }
    final stats = ecu.sampleStats.putIfAbsent(sample.did, DidSampleStats.new);
    stats.record(
      sample.payloadHash,
      firstInRecording: sampledThisRecording.add(stats),
    );
  }
}

Map<String, ({int protocol, String request})> _planModuleHeaders(File sidecar) {
  if (!sidecar.existsSync()) {
    return {};
  }
  for (final line in sidecar.readAsLinesSync()) {
    final marker = _decodeObject(line);
    if (marker?['type'] != 'plan' || marker!['modules'] is! List) {
      continue;
    }
    return {
      for (final module in marker['modules'] as List<dynamic>)
        if (module case {
          'id': final String id,
          'request': final String request,
          'protocol': final String protocol,
        })
          if (int.tryParse(protocol) case final int parsed)
            id: (protocol: parsed, request: request),
    };
  }
  return {};
}

Map<String, dynamic>? _decodeObject(String line) {
  try {
    final decoded = jsonDecode(line);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String? _asciiFromHex(String hex) {
  if (hex.length.isOdd) {
    return null;
  }
  final codes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    final code = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (code == null) {
      return null;
    }
    codes.add(code);
  }
  return String.fromCharCodes(codes);
}

/// 32-bit FNV-1a: a stable hash, unlike [Object.hashCode].
int _fnv1a32(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}
