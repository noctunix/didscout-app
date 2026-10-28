/// Signal plumbing between the discovery engine and whatever executes
/// OBD/UDS reads on-device. [ReadExecutor] has no notion of discovery,
/// DIDs, or ECUs -- it only queues probe steps and reports results back.
/// A real implementation will later queue one-shot reads through
/// obdbridge; nothing here is wired to it yet.
library;

/// Outcome of one queued read.
sealed class ProbeStatus {
  const ProbeStatus();
}

/// A positive response was received.
class ProbeOk extends ProbeStatus {
  const ProbeOk();
}

/// The responder replied with "NO DATA" -- nothing answered the request.
class ProbeNoData extends ProbeStatus {
  const ProbeNoData();
}

/// The responder replied with negative response code [code] (e.g. `0x11`
/// serviceNotSupported, `0x22` conditionsNotCorrect, `0x33`
/// securityAccessDenied).
class ProbeNrc extends ProbeStatus {
  const ProbeNrc(this.code);
  final int code;
}

/// No reply arrived before the adapter/transport timed out.
class ProbeTimeout extends ProbeStatus {
  const ProbeTimeout();
}

/// The transport itself failed (e.g. a BLE disconnect) before a reply
/// could be collected.
class ProbeTransportError extends ProbeStatus {
  const ProbeTransportError();
}

/// A CAN module an executor must set up (header/filter/flow-control)
/// before steps addressed to it can run.
class ProbeModule {
  const ProbeModule({
    required this.id,
    required this.requestHeader,
    this.responseHeader,
    required this.protocol,
    this.receiveFilter,
    this.receiveMask,
  });

  /// Stable identifier for this module. Never contains an underscore --
  /// see the `<moduleId>_<command>` scheme on [ProbeStep.signalId].
  final String id;

  /// 11-bit (3 hex digits) or 29-bit (8 hex digits) request header.
  final String requestHeader;

  /// Expected responder header, when known. Null means only single-frame
  /// replies are usable (no flow control can be addressed back), which is
  /// the case while sweeping for an ECU whose response header isn't known
  /// yet.
  final String? responseHeader;

  /// Wire protocol: 6 (11-bit CAN) or 7 (29-bit CAN).
  final int protocol;

  /// Optional CAN receive filter (the value an `ATCFxxx` command would
  /// carry, without the `ATCF` prefix), for a module that must accept
  /// replies from more than one header.
  final String? receiveFilter;

  /// Optional CAN receive mask (the value an `ATCMxxx` command would
  /// carry), paired with [receiveFilter].
  final String? receiveMask;
}

/// One queued read against an already set-up module.
class ProbeStep {
  const ProbeStep({required this.signalId, required this.command});

  /// `<moduleId>_<command lowercase>`. Module ids never contain an
  /// underscore, so the module id can always be recovered by splitting on
  /// the first `_` -- see [moduleIdOf].
  final String signalId;

  /// The raw mode-01/UDS command hex string, e.g. `22F189`.
  final String command;
}

/// Recovers the module id a [ProbeStep.signalId]/[ProbeResult.signalId]
/// was built from.
String moduleIdOf(String signalId) =>
    signalId.substring(0, signalId.indexOf('_'));

/// Builds the signal id for [moduleId]/[command] per the
/// `<moduleId>_<command lowercase>` scheme.
String signalIdFor(String moduleId, String command) {
  assert(
    !moduleId.contains('_'),
    'module id must not contain an underscore: $moduleId',
  );
  return '${moduleId}_${command.toLowerCase()}';
}

/// One reported result for a previously submitted [ProbeStep].
class ProbeResult {
  const ProbeResult({
    required this.signalId,
    required this.status,
    this.payload,
    this.responderHeader,
    required this.at,
  });

  final String signalId;
  final ProbeStatus status;

  /// The positive response payload, when [status] is [ProbeOk].
  final List<int>? payload;

  /// The header that actually answered, when [status] is [ProbeOk] and the
  /// step's module accepted replies from more than one header (see
  /// [ProbeModule.receiveFilter]) -- null when the module only ever
  /// expects its own fixed [ProbeModule.responseHeader].
  final String? responderHeader;

  final DateTime at;
}

/// Executes queued probe steps against whatever transport/adapter backs
/// an implementation; results are reported asynchronously and may arrive
/// in any order relative to submission.
abstract class ReadExecutor {
  /// Queues [steps] for execution, setting up any module in [modules] not
  /// already set up. Returns once the steps are queued, not once they
  /// have run.
  Future<void> submit(List<ProbeModule> modules, List<ProbeStep> steps);

  /// Reports one [ProbeResult] per completed step.
  Stream<ProbeResult> get results;

  /// Number of steps queued but not yet reported on [results].
  int get queueDepth;
}
