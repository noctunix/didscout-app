/// [ReadExecutor] backed by obdbridge's queued one-shot reads
/// (`ObdBridge.enqueueOneShot`), for the discovery engine to run against a
/// recording that's already in progress.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:obdbridge/obdbridge.dart';

import '../capture/isotp.dart';
import '../discovery/probe.dart';

/// Thrown when [ObdBridge.enqueueOneShot] could not queue a whole batch --
/// the native one-shot queue is full, or no recording is currently
/// running. Either way none of the batch was queued.
class BridgeReadExecutorException implements ReadExecutorRejection {
  BridgeReadExecutorException(this.result);

  final ObdOneShotEnqueueResultMessage result;

  @override
  SubmitRejectionReason get reason => switch (result) {
    ObdOneShotEnqueueResultMessage.queueFull => SubmitRejectionReason.queueFull,
    ObdOneShotEnqueueResultMessage.noActiveRecording =>
      SubmitRejectionReason.noActiveRecording,
    ObdOneShotEnqueueResultMessage.accepted => throw StateError(
      'BridgeReadExecutorException must never carry an accepted result',
    ),
  };

  @override
  String toString() => 'BridgeReadExecutorException: ${result.name}';
}

/// ELM-level markers that mean nothing answered the request, beyond the
/// literal "NO DATA" -- ported from didscout's `classify`.
const List<String> _noAnswerMarkers = [
  'NO DATA',
  'CAN ERROR',
  'BUS INIT',
  'UNABLE TO CONNECT',
  'BUFFER FULL',
  'STOPPED',
  '?',
];

/// Drives the discovery engine's probes through [bridge]'s one-shot queue
/// instead of a recording's own recurring plan, and parses each reply with
/// the app's own ISO-TP parser ([parseIsotp]) rather than trusting any
/// classification obdbridge itself might do.
///
/// Doesn't wire itself to [ObdEventsApi] -- call [deliverOneShotResult] with
/// every [ObdEventsApi.onOneShotResult] event for the recording this
/// executor serves; that keeps this class usable in a plain unit test
/// without touching a real platform channel.
class BridgeReadExecutor implements ReadExecutor {
  /// [onAccepted], if given, is called with a batch's modules once
  /// [ObdBridge.enqueueOneShot] has accepted it. [claimResult], if given,
  /// is offered every parsed result first: a result it claims (returns
  /// true for) belongs to reads queued on behalf of someone other than the
  /// [results] listener, and is left out of [results].
  BridgeReadExecutor(this._bridge, {this._onAccepted, this._claimResult});

  final ObdBridge _bridge;
  final void Function(List<ProbeModule> modules)? _onAccepted;
  final bool Function(ProbeResult result)? _claimResult;
  final StreamController<ProbeResult> _results =
      StreamController<ProbeResult>.broadcast();
  int _queueDepth = 0;

  @override
  Stream<ProbeResult> get results => _results.stream;

  @override
  int get queueDepth => _queueDepth;

  /// Corrects [queueDepth] from the recording's own authoritative count --
  /// call with `ObdRecordingStateMessage.oneShotQueueDepth` whenever the
  /// caller polls `ObdBridge.recordingState()`, so the locally kept count
  /// (optimistic between [submit] and [deliverOneShotResult]) can't drift.
  void applyRecordingState(int oneShotQueueDepth) {
    _queueDepth = oneShotQueueDepth;
  }

  @override
  Future<void> submit(List<ProbeModule> modules, List<ProbeStep> steps) async {
    if (steps.isEmpty) return;
    final result = await _bridge.enqueueOneShot(
      [for (final module in modules) _toBridgeModule(module)],
      [for (final step in steps) _toBridgeStep(step)],
    );
    if (result != ObdOneShotEnqueueResultMessage.accepted) {
      throw BridgeReadExecutorException(result);
    }
    _queueDepth += steps.length;
    _onAccepted?.call(modules);
  }

  /// Feeds one [ObdEventsApi.onOneShotResult] event into [results], parsed
  /// into a [ProbeResult], unless the constructor's `claimResult` claims
  /// it. The caller is responsible for wiring this to the actual event
  /// channel.
  void deliverOneShotResult(ObdSignalExchangeMessage result) {
    if (_queueDepth > 0) _queueDepth -= 1;
    final parsed = _toProbeResult(result);
    if (_claimResult?.call(parsed) ?? false) return;
    _results.add(parsed);
  }

  void dispose() => unawaited(_results.close());

  static ObdModuleMessage _toBridgeModule(ProbeModule module) {
    final protocol = ObdProtocol.fromWireValue(module.protocol);
    if (protocol == null) {
      throw ArgumentError.value(
        module.protocol,
        'protocol',
        'not a known wire protocol (6 or 7)',
      );
    }
    return ObdModuleMessage(
      moduleId: module.id,
      protocol: module.protocol,
      setup: _moduleSetupCommands(module, protocol),
    );
  }

  /// Builds a module's adapter setup sequence. A module with a known
  /// [ProbeModule.responseHeader] gets the usual fixed-responder setup
  /// (flow control included); one without it (an inventory sweep) instead
  /// sets up [ProbeModule.receiveFilter]/[ProbeModule.receiveMask] to
  /// accept a reply from any header they admit, with no flow control --
  /// such a module only ever expects a single-frame reply (see
  /// [ProbeModule.responseHeader]'s doc comment), so there's no
  /// consecutive-frame request to address back.
  static List<String> _moduleSetupCommands(
    ProbeModule module,
    ObdProtocol protocol,
  ) {
    final responseHeader = module.responseHeader;
    if (responseHeader != null) {
      return buildModuleSetupCommands(
        protocol: protocol,
        requestHeader: module.requestHeader,
        responseHeader: responseHeader,
      );
    }
    return [
      protocol.protocolSelectCommand,
      'ATSH${module.requestHeader}',
      if (module.receiveFilter != null) 'ATCF${module.receiveFilter}',
      if (module.receiveMask != null) 'ATCM${module.receiveMask}',
    ];
  }

  /// The responder header carried here is metadata only -- obdbridge's own
  /// poller never validates against it (this app's own ISO-TP parser does
  /// that, in [_toProbeResult]) -- so a step whose module's responder isn't
  /// known yet (an inventory sweep) can safely leave it blank.
  static ObdStepMessage _toBridgeStep(ProbeStep step) => ObdStepMessage(
    signalId: step.signalId,
    moduleId: moduleIdOf(step.signalId),
    command: step.command,
    responseHeader: '',
    intervalMs: 0,
  );
}

/// Parses one [ObdSignalExchangeMessage] into a [ProbeResult], ported from
/// didscout's `classify`: an actual timeout maps to [ProbeTimeout], a
/// cancelled transport to [ProbeCancelled], an oversized reply to
/// [ProbeOverflow], any other non-ok transport
/// outcome to [ProbeTransportError], a reply
/// containing an ELM-level no-answer marker ([_noAnswerMarkers]) to
/// [ProbeNoData], a reassembled negative response (`7F <SID> <code>`) to
/// [ProbeNrc], a reassembled positive response (`<SID+0x40> ...`) to
/// [ProbeOk] with its payload and responder header, and anything else
/// (malformed framing, or no recognisable reply at all) to [ProbeNoData].
ProbeResult _toProbeResult(ObdSignalExchangeMessage result) {
  final at = result.receivedAtEpochMs != null
      ? DateTime.fromMillisecondsSinceEpoch(
          result.receivedAtEpochMs!,
          isUtc: true,
        )
      : DateTime.now().toUtc();

  if (result.transport == ObdTransportStatusMessage.timeout) {
    return ProbeResult(
      signalId: result.signalId,
      status: const ProbeTimeout(),
      at: at,
    );
  }
  if (result.transport == ObdTransportStatusMessage.cancelled) {
    return ProbeResult(
      signalId: result.signalId,
      status: const ProbeCancelled(),
      at: at,
    );
  }
  if (result.transport == ObdTransportStatusMessage.overflow) {
    return ProbeResult(
      signalId: result.signalId,
      status: const ProbeOverflow(),
      at: at,
    );
  }
  if (result.transport != ObdTransportStatusMessage.ok) {
    return ProbeResult(
      signalId: result.signalId,
      status: const ProbeTransportError(),
      at: at,
    );
  }
  final rawResponseText = result.rawResponseText;
  if (rawResponseText == null) {
    return ProbeResult(
      signalId: result.signalId,
      status: const ProbeTransportError(),
      at: at,
    );
  }
  final upper = rawResponseText.toUpperCase();
  if (_noAnswerMarkers.any(upper.contains)) {
    return ProbeResult(
      signalId: result.signalId,
      status: const ProbeNoData(),
      at: at,
    );
  }

  final command = commandOf(result.signalId);
  final parsed = parseIsotp(command, rawResponseText);
  final expectedSid = int.parse(command.substring(0, 2), radix: 16);
  final positivePayloadOf = _positivePayloadReader(expectedSid, command);

  int? nrcCode;
  String? nrcHeader;
  Uint8List? positivePayload;
  String? positiveHeader;
  for (final message in parsed.messages) {
    final data = message.data;
    if (nrcCode == null &&
        data.length == 3 &&
        data[0] == 0x7F &&
        data[1] == expectedSid) {
      nrcCode = data[2];
      nrcHeader = message.header;
      continue;
    }
    if (positivePayload == null) {
      positivePayload = positivePayloadOf(data);
      if (positivePayload != null) positiveHeader = message.header;
    }
  }
  if (nrcCode != null) {
    return ProbeResult(
      signalId: result.signalId,
      status: ProbeNrc(nrcCode),
      responderHeader: nrcHeader,
      at: at,
    );
  }
  if (positivePayload != null) {
    return ProbeResult(
      signalId: result.signalId,
      status: const ProbeOk(),
      payload: positivePayload,
      responderHeader: positiveHeader,
      at: at,
    );
  }
  return ProbeResult(
    signalId: result.signalId,
    status: const ProbeNoData(),
    at: at,
  );
}

/// Returns a function that extracts the payload of a positive reply to
/// [command] (service [sid]) from one reassembled message, or null if the
/// message is no such reply. For a single DID or any other service that is
/// everything after the echoed request; for a ReadDataByIdentifier of
/// several DIDs it is everything after the response SID, DID echoes
/// included, and the reply must start with one of the requested DIDs.
Uint8List? Function(Uint8List data) _positivePayloadReader(
  int sid,
  String command,
) {
  final request = _hexToBytes(command.substring(2));
  if (sid == 0x22 && request.length > 2) {
    // ISO 14229-1:2013 §10.2: the positive response carries one
    // <DID><dataRecord> pair per supported DID, in request order, with no
    // length fields, so only the first DID echo can be checked here.
    final dids = [
      for (var i = 0; i + 1 < request.length; i += 2)
        (request[i], request[i + 1]),
    ];
    return (data) =>
        data.length >= 3 &&
            data[0] == sid + 0x40 &&
            dids.contains((data[1], data[2]))
        ? Uint8List.fromList(data.sublist(1))
        : null;
  }
  final prefix = [sid + 0x40, ...request];
  return (data) => _startsWith(data, prefix)
      ? Uint8List.fromList(data.sublist(prefix.length))
      : null;
}

List<int> _hexToBytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

bool _startsWith(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}
