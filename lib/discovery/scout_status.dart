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
  /// result; those DIDs are queued to be read again rather than lost.
  batchTimedOut,

  /// A DID's discovery read timed out; it is now quarantined and never
  /// requested by discovery again.
  slowDid,

  /// A DID's reply exceeded the adapter's response limit; it is now
  /// quarantined and never read again.
  oversizedDid,

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

  /// Results still outstanding, summed across every ECU slice currently
  /// in flight (zero or more at once -- the engine pipelines rounds
  /// rather than scanning one ECU at a time).
  final int waitingCount;

  /// How long the oldest of those in-flight slices has been waiting,
  /// null when none is in flight.
  final Duration? waitingFor;

  /// Once true (the engine was cancelled), the engine never submits again
  /// for its lifetime.
  final bool suspended;
}
