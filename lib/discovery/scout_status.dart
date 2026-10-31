/// Live scouting activity for display: a snapshot of what the discovery
/// engine is doing right now, plus a bounded log of recent events -- kept
/// separate from [DiscoveryEngine] itself only in the sense that these
/// types carry no behavior, just data the engine fills in.
library;

/// One notable thing the discovery engine did, for the scouting event log.
enum ScoutEventKind {
  /// A DID batch was submitted to the executor.
  batchSubmitted,

  /// A DID answered OK and was recorded as discovered.
  hit,

  /// A DID came back NRC 22/33 and was queued for retry on the next phase
  /// change.
  conditional,

  /// A batch looked asleep (see `batchIsAsleep`); the ECU pauses.
  asleep,

  /// A batch's deadline passed with at least one step still missing a
  /// result; the ECU's scan position does not advance.
  batchTimedOut,

  /// [ReadExecutor.submit] rejected a batch outright (queue full, or no
  /// active recording).
  enqueueRejected,

  /// One ECU (re)discovery inventory sweep finished.
  inventoryStep,
}

/// One entry in the scouting event log.
class ScoutEvent {
  const ScoutEvent({
    required this.kind,
    required this.at,
    this.ecuId,
    this.detail,
  });

  final ScoutEventKind kind;
  final DateTime at;

  /// The ECU this event concerns, when it concerns one in particular.
  final String? ecuId;

  /// Free-form extra detail (a DID, a missing count, a rejection reason, …).
  final String? detail;
}

/// A snapshot of the discovery engine's current scouting activity, for the
/// recording page's compact status line.
class ScoutStatus {
  const ScoutStatus({
    required this.currentEcuId,
    required this.currentEcuName,
    required this.currentDidRangeLabel,
    required this.readsPerMinute,
    required this.lastResultSummary,
    required this.queueDepth,
    required this.waitingCount,
    required this.waitingFor,
    required this.suspended,
  });

  /// The ECU the most recently submitted batch addressed, if any.
  final String? currentEcuId;

  /// That ECU's identified F197 name, when known.
  final String? currentEcuName;

  /// The current batch's DID range, formatted e.g. `1A40–1A4F`.
  final String? currentDidRangeLabel;

  /// Completed reads (any status) in the last rolling 60 seconds.
  final int readsPerMinute;

  /// The most recently completed read's outcome, e.g. `OK`, `NRC 31`.
  final String? lastResultSummary;

  /// The executor's own queue depth right now.
  final int queueDepth;

  /// Results still outstanding for the batch currently in flight, if any.
  final int waitingCount;

  /// How long the current batch has been waiting on [waitingCount] results,
  /// null when nothing is in flight.
  final Duration? waitingFor;

  /// Once true (the engine was cancelled), the engine never submits again
  /// for its lifetime.
  final bool suspended;
}
