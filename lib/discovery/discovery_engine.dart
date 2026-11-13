/// The discovery engine: drives manufacturer ECU inventory and per-ECU
/// DID scanning against a [ReadExecutor], ported from didscout's
/// `run_discovery_batch`/`_batch_is_asleep`/`_select_discovery_module`/
/// `_inventory_ecus11`/`_inventory_ecus29` and the rediscovery logic.
library;

import 'dart:async';
import 'dart:math';

import 'did_order.dart';
import 'discovery_state.dart';
import 'inventory.dart';
import 'probe.dart';
import 'scout_status.dart';

/// Number of DIDs read per discovery batch, matching the proven CLI's
/// `RECORD_DISCOVERY_BATCH`.
const int discoveryBatchSize = 16;

/// How long a module's discovery pauses after a batch where at least half
/// the replies were NRC 11 (serviceNotSupported) -- the ECU has most
/// likely gone to sleep.
const Duration asleepPauseDuration = Duration(seconds: 60);

/// How long a module's discovery pauses after a batch where at least
/// three quarters of the replies were "NO DATA" -- a module that doesn't
/// answer at all (e.g. tyre pressure sensors while parked) rather than
/// actively refusing the service, which calls for a longer pause than
/// [asleepPauseDuration]: it's more likely to stay quiet for a while than
/// to wake up again within a minute. Doubles with every further such batch
/// in a row ([EcuInfo.noDataStreak]), up to [maxNoDataAsleepPauseDuration]
/// -- some headers never answer on a given vehicle, and each NO DATA waits
/// out the adapter's full response timeout.
const Duration noDataAsleepPauseDuration = Duration(minutes: 5);

/// Upper bound of the doubling [noDataAsleepPauseDuration].
const Duration maxNoDataAsleepPauseDuration = Duration(hours: 2);

/// The pause after the [streak]th NO-DATA-asleep batch in a row.
Duration noDataAsleepPause(int streak) {
  final pause = noDataAsleepPauseDuration * (1 << (streak - 1).clamp(0, 16));
  return pause < maxNoDataAsleepPauseDuration
      ? pause
      : maxNoDataAsleepPauseDuration;
}

/// Multi-DID calibration reads without a usable answer after which an
/// ECU's [EcuInfo.multiDid] is given up as unsupported.
const int maxMultiDidCalibrationFailures = 3;

/// Default per-step addition to a slice's result-wait deadline (see
/// [DiscoveryEngine.batchDeadlinePerStep]).
const Duration defaultBatchDeadlinePerStep = Duration(seconds: 2);

/// Default fixed floor of a slice's result-wait deadline (see
/// [DiscoveryEngine.batchDeadlineBase]).
const Duration defaultBatchDeadlineBase = Duration(seconds: 30);

/// Default pause before retrying a batch [ReadExecutor.submit] rejected.
const Duration defaultSubmitBackoff = Duration(seconds: 10);

/// Length of the ring buffer [DiscoveryEngine.eventLog] keeps.
const int scoutEventLogCapacity = 50;

/// Window over which [DiscoveryEngine.scoutStatus] reports a reads-per-
/// minute rate.
const Duration readsPerMinuteWindow = Duration(seconds: 60);

DateTime _utcNow() => DateTime.now().toUtc();

/// True if at least half of one discovery batch's replies were NRC 11 --
/// the signature of an ECU that stopped answering.
bool batchIsAsleep(Map<String, int> statusCounts, int batchSize) {
  if (batchSize == 0) {
    return false;
  }
  final nrc11 = statusCounts['NRC 11'] ?? 0;
  return nrc11 * 2 >= batchSize;
}

/// True if at least three quarters of one discovery batch's replies were
/// "NO DATA" and none were OK -- the signature of a module that simply
/// never answers rather than one that actively refuses the service (see
/// [batchIsAsleep]) or one that answered at least one of the batch's DIDs
/// and is therefore demonstrably awake, whatever the rest of the batch's
/// DIDs it doesn't happen to support looks like.
bool batchLooksNoDataAsleep(Map<String, int> statusCounts, int batchSize) {
  if (batchSize == 0 || (statusCounts['OK'] ?? 0) > 0) {
    return false;
  }
  final noData = statusCounts['NO DATA'] ?? 0;
  return noData * 4 >= batchSize * 3;
}

String _statusBucket(ProbeStatus status) => switch (status) {
  ProbeOk() => 'OK',
  ProbeNoData() => 'NO DATA',
  ProbeNrc(code: final code) =>
    'NRC ${code.toRadixString(16).toUpperCase().padLeft(2, '0')}',
  ProbeTimeout() => 'TIMEOUT',
  ProbeOverflow() => 'OVERFLOW',
  ProbeTransportError() => 'TRANSPORT_ERROR',
  ProbeCancelled() => 'CANCELLED',
};

/// Whether [status] is an answer from the vehicle side -- OK, NO DATA, an
/// NRC, an oversized reply or an adapter timeout -- rather than a request cancelled or lost to
/// a transport failure, which says nothing about the request itself.
bool _isAnswer(ProbeStatus status) => switch (status) {
  ProbeOk() ||
  ProbeNoData() ||
  ProbeNrc() ||
  ProbeTimeout() ||
  ProbeOverflow() => true,
  ProbeTransportError() || ProbeCancelled() => false,
};

/// Whether [status] is one of the replies [batchIsAsleep] and
/// [batchLooksNoDataAsleep] read as a sleeping ECU.
bool _isSleepSignature(ProbeStatus status) =>
    status is ProbeNoData || status is ProbeNrc && status.code == 0x11;

String hex3(int value) => value.toRadixString(16).toUpperCase().padLeft(3, '0');
String hex4(int value) => value.toRadixString(16).toUpperCase().padLeft(4, '0');

/// Reported once a DID scan confirms an ECU answers a given DID -- lets
/// the caller add it to its own recurring reads.
typedef DiscoveryHit =
    void Function(String ecuId, String did, List<int> payload);

/// Where one ECU's next batch of DIDs comes from (see
/// [DiscoveryEngine._nextBatchFor]) -- determines what finalizing it
/// advances.
enum _BatchSource {
  /// The next slice of [EcuInfo.discoverRanges]'s scan order.
  scanOrder,

  /// Conditional DIDs (NRC 22/33) queued for retry on a phase change.
  conditionalRetry,

  /// DIDs an earlier batch sent but never got an answer for.
  unansweredRetry,
}

/// One ECU's prepared slice of a round: what [DiscoveryEngine._nextBatchFor]
/// picked, plus how its DIDs are split into steps.
class _Slice {
  _Slice({
    required this.ecuId,
    required this.dids,
    required this.source,
    required this.rawAdvance,
    required this.groups,
    required this.calibration,
  });

  final String ecuId;
  final List<String> dids;
  final _BatchSource source;
  final int rawAdvance;

  /// [dids] split into steps, in order: one DID per step.
  final List<List<String>> groups;

  /// The DIDs of this slice's multi-DID calibration read -- two known
  /// negatives, then the reference DID it must answer first -- or null.
  final List<String>? calibration;

  String signalIdOf(List<String> stepDids) =>
      signalIdFor(ecuId, commandOf(stepDids));

  static String commandOf(List<String> stepDids) => '22${stepDids.join()}';
}

/// What a calibration read says about an ECU's multi-DID support.
enum _CalibrationOutcome {
  supported,
  unsupported,

  /// No usable answer; counts toward [maxMultiDidCalibrationFailures].
  failed,

  /// A sleep signature: counts as [failed] unless the slice itself looked
  /// asleep, in which case it says nothing about multi-DID support.
  failedUnlessAsleep,
}

/// One ECU's batch currently out with [DiscoveryEngine.executor], for
/// [DiscoveryEngine.scoutStatus].
class _InFlightSlice {
  _InFlightSlice({required this.signalIds, required this.submittedAt})
    : remaining = signalIds.toSet();

  final List<String> signalIds;

  /// Signal ids still without a result.
  final Set<String> remaining;

  final DateTime submittedAt;
}

/// Drives ECU inventory and DID discovery against [executor], persisting
/// progress into [state]. Motion-gates discovery per [didscout's safety
/// blocklist] (see `did_order.dart`): while moving, only scans ECUs with
/// an identified F197 name that doesn't match the blocklist, and never
/// runs ECU (re)discovery.
class DiscoveryEngine {
  DiscoveryEngine({
    required this.executor,
    required this.state,
    required this.onHit,
    this.batchSize = discoveryBatchSize,
    int? minQueueDepth,
    int? maxQueueDepth,
    this.sweepChunkSize = 64,
    this.batchDeadlinePerStep = defaultBatchDeadlinePerStep,
    this.batchDeadlineBase = defaultBatchDeadlineBase,
    this.submitBackoff = defaultSubmitBackoff,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  }) : minQueueDepth = minQueueDepth ?? batchSize * 2,
       maxQueueDepth = maxQueueDepth ?? batchSize * 8,
       _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? _utcNow {
    _subscription = executor.results.listen(_handleResult);
    _seedVagPpeEcus();
    state.ecus.forEach(_applyTargetedRanges);
  }

  final ReadExecutor executor;
  final DiscoveryState state;
  final DiscoveryHit onHit;

  /// DIDs read per discovery batch (see [_nextBatchFor]/[pump]). Defaults
  /// to the proven CLI's [discoveryBatchSize]; [minQueueDepth]/
  /// [maxQueueDepth] scale with it unless given explicitly.
  final int batchSize;

  /// Lower bound the engine tries to keep the executor's queue filled to
  /// (see [pump]).
  final int minQueueDepth;

  /// Upper bound [pump] never submits past.
  final int maxQueueDepth;

  /// Max probes submitted in one inventory sweep chunk.
  final int sweepChunkSize;

  /// Added to [batchDeadlineBase] once per step of the submission and once
  /// per step already queued ahead of it, to get the deadline a slice's
  /// results have to arrive by (see [_awaitAndFinalizeSlice]) --
  /// a step without a result by then is treated as missing rather than
  /// awaited forever, since the plugin documents that a one-shot result
  /// event may simply never arrive (engine paused, app backgrounded).
  final Duration batchDeadlinePerStep;

  /// Fixed floor of a slice's result-wait deadline, see
  /// [batchDeadlinePerStep].
  final Duration batchDeadlineBase;

  /// How long [_submitRound] waits before retrying a batch
  /// [ReadExecutor.submit] rejected.
  final Duration submitBackoff;

  final Future<void> Function(Duration) _delay;

  /// Timestamps events are logged with, and reads-per-minute is bucketed
  /// against -- overridable for tests, decoupled from the `now` values
  /// callers pass into [pump]/[runDiscoveryBatch] etc., which drive scan
  /// position/asleep bookkeeping instead.
  final DateTime Function() _clock;

  final Map<String, Completer<ProbeResult>> _pending = {};
  final Map<String, List<int>> _orderCache = {};
  final Map<String, List<int>> _priorityOrderCache = {};
  final Map<String, int> _profileOrderLengthCache = {};
  late final StreamSubscription<ProbeResult> _subscription;

  /// Index into `state.ecus.keys` [pump] starts its next round from -- see
  /// [pump]'s doc comment on why this rotates instead of always starting
  /// at the first key.
  int _roundRobinCursor = 0;

  /// ECUs [nameUnnamedEcus] already tried during this engine's lifetime.
  final Set<String> _namingAttempted = {};

  /// Once true ([cancel] ran), [pump] never submits anything again for
  /// the rest of this engine's lifetime -- the caller is expected to start
  /// a fresh engine for the next recording.
  bool _suspended = false;

  /// Whether [pump] has permanently stopped submitting for this engine
  /// instance (see [_suspended]).
  bool get suspended => _suspended;

  /// Request headers of the ECUs [pump] gives a batch every round, after
  /// those with targeted discover ranges left -- the current vehicle
  /// phase's focus ECUs; empty while no phase is set.
  Set<String> focusRequestHeaders = const {};

  String? _lastResultSummary;
  final List<DateTime> _recentReads = [];
  final List<ScoutEvent> _events = [];

  /// Slices currently out with [executor], keyed by ECU id -- an ECU in
  /// here is not offered another round by [pump] until its own slice is
  /// finalized, however many other ECUs' slices are also still in flight.
  final Map<String, _InFlightSlice> _inFlight = {};

  String? _currentEcuId;
  (String, String)? _currentDidRange;

  /// The last [scoutEventLogCapacity] scouting events, newest first.
  List<ScoutEvent> get eventLog => List.unmodifiable(_events);

  /// A snapshot of current scouting activity for the recording page's
  /// compact status line -- [now] is used only to report [ScoutStatus.
  /// waitingFor] and to window [ScoutStatus.readsPerMinute]; business
  /// logic (asleep timers, scan position) is unaffected by it.
  ScoutStatus scoutStatus(DateTime now) {
    _recentReads.removeWhere((at) => now.difference(at) > readsPerMinuteWindow);
    final ecuId = _currentEcuId;
    var waitingCount = 0;
    DateTime? oldestInFlight;
    for (final slice in _inFlight.values) {
      waitingCount += slice.remaining.length;
      if (oldestInFlight == null ||
          slice.submittedAt.isBefore(oldestInFlight)) {
        oldestInFlight = slice.submittedAt;
      }
    }
    return ScoutStatus(
      currentEcuId: ecuId,
      currentEcuName: ecuId == null ? null : state.ecus[ecuId]?.f197Name,
      currentDidRangeLabel: _currentDidRange == null
          ? null
          : '${_currentDidRange!.$1}–${_currentDidRange!.$2}',
      readsPerMinute: _recentReads.length,
      lastResultSummary: _lastResultSummary,
      queueDepth: executor.queueDepth,
      waitingCount: waitingCount,
      waitingFor: oldestInFlight == null
          ? null
          : now.difference(oldestInFlight),
      suspended: _suspended,
    );
  }

  void _logEvent(ScoutEventKind kind, {String? ecuId, String? detail}) {
    _events.insert(
      0,
      ScoutEvent(kind: kind, at: _clock(), ecuId: ecuId, detail: detail),
    );
    if (_events.length > scoutEventLogCapacity) {
      _events.removeRange(scoutEventLogCapacity, _events.length);
    }
  }

  /// Abandons whatever slices are currently in flight, if any: every
  /// outstanding completer resolves right now with [ProbeCancelled]
  /// instead of waiting out its deadline, a batch whose enqueue is being
  /// retried gives up at its next attempt, and this engine never submits
  /// again ([suspended]) -- a fresh engine is expected for the next
  /// recording. Called when the recording this engine serves is
  /// stopping, so a pump call already awaiting results doesn't keep
  /// running in the background for minutes after the caller walked away;
  /// its own `await` simply resolves promptly once this runs, without the
  /// caller needing to await it itself.
  void cancel() {
    _suspended = true;
    final pending = _pending.entries.toList();
    _pending.clear();
    _inFlight.clear();
    for (final entry in pending) {
      entry.value.complete(
        ProbeResult(
          signalId: entry.key,
          status: const ProbeCancelled(),
          at: _clock(),
        ),
      );
    }
  }

  void dispose() {
    cancel();
    _subscription.cancel();
  }

  void _handleResult(ProbeResult result) {
    _lastResultSummary = _statusBucket(result.status);
    _recentReads.add(_clock());
    final completer = _pending.remove(result.signalId);
    _inFlight[moduleIdOf(result.signalId)]?.remaining.remove(result.signalId);
    if (completer != null) {
      completer.complete(result);
    } else if (result.status is ProbeTimeout) {
      _quarantineLateTimeout(result.signalId);
    }
  }

  /// Quarantines the DID behind a timeout that arrived after its slice's
  /// deadline. A slow adapter queue can still outlast that deadline, and a
  /// timeout ends the session; left unbooked, the same DID would be sent
  /// again after every reconnect and end every session the same way.
  void _quarantineLateTimeout(String signalId) {
    final ecuId = moduleIdOf(signalId);
    final ecu = state.ecus[ecuId];
    final command = commandOf(signalId);
    if (ecu == null || command.length != 6 || !command.startsWith('22')) {
      return;
    }
    final did = command.substring(2);
    ecu.slow.add(did);
    ecu.discovered.remove(did);
    ecu.conditional.remove(did);
    ecu.unanswered.remove(did);
    ecu.retryQueue.remove(did);
    _logEvent(ScoutEventKind.slowDid, ecuId: ecuId, detail: did);
  }

  /// Quarantines the DID behind [signalId] into [EcuInfo.oversized]: its
  /// reply exceeds the adapter's response limit, so every further read,
  /// whoever sends it, only comes back truncated.
  void quarantineOversized(String signalId) {
    final ecuId = moduleIdOf(signalId);
    final ecu = state.ecus[ecuId];
    final command = commandOf(signalId);
    if (ecu == null || command.length != 6 || !command.startsWith('22')) {
      return;
    }
    final did = command.substring(2);
    _quarantineOversizedDid(ecu, ecuId, did);
    ecu.unanswered.remove(did);
    ecu.retryQueue.remove(did);
  }

  void _quarantineOversizedDid(EcuInfo ecu, String ecuId, String did) {
    ecu.oversized.add(did);
    ecu.discovered.remove(did);
    ecu.conditional.remove(did);
    _logEvent(ScoutEventKind.oversizedDid, ecuId: ecuId, detail: did);
  }

  /// Marks a new round as submitted, for [scoutStatus] and the event log --
  /// [dids] is the primary (first) ECU's own slice, the rest matter only
  /// for the log detail.
  void _beginBatch(List<String> ecuIds, List<String> dids) {
    final primary = ecuIds.isEmpty ? null : ecuIds.first;
    _currentEcuId = primary;
    _currentDidRange = dids.isEmpty ? null : (dids.first, dids.last);
    if (primary != null) {
      _logEvent(
        ScoutEventKind.batchSubmitted,
        ecuId: primary,
        detail: '${dids.length} dids',
      );
    }
  }

  /// Submits one batch for each of [ecuIds] that still has one ready, in a
  /// single [ReadExecutor.submit] call -- so the queue is topped up by
  /// several ECUs' work at once instead of one DID at a time -- then
  /// returns one future per prepared ECU that resolves, independently of
  /// every other one, once that ECU's own slice is fully in (or its own
  /// deadline passed) and finalized. Awaits only submission itself (with
  /// the usual reject/backoff retry against [cancel]); a caller that wants
  /// the old all-at-once behavior can simply await the returned futures
  /// (see [runDiscoveryBatch]). Logs every rejection and retries after
  /// [submitBackoff] until the executor accepts the batch or [cancel]
  /// runs; a batch still unaccepted by then resolves to no futures at all.
  /// [SubmitRejectionReason.noActiveRecording] is retried like
  /// [SubmitRejectionReason.queueFull]: the plugin reports it while it
  /// reconnects to the adapter within a recording that is still running,
  /// and the caller cancels this engine once the recording really ends.
  Future<List<Future<List<String>>>> _submitRound(
    List<String> ecuIds,
    DateTime now,
  ) async {
    final prepared = <_Slice>[];
    for (final ecuId in ecuIds) {
      final next = _nextBatchFor(ecuId);
      if (next != null) {
        prepared.add(_planSlice(ecuId, next));
      }
    }
    if (prepared.isEmpty) {
      return const [];
    }

    final modules = <ProbeModule>[];
    final steps = <ProbeStep>[];
    final completers = <String, Completer<ProbeResult>>{};
    for (final slice in prepared) {
      final ecu = state.ecus[slice.ecuId]!;
      modules.add(
        ProbeModule(
          id: slice.ecuId,
          requestHeader: ecu.requestHeader,
          responseHeader: ecu.responseHeader,
          protocol: ecu.protocol,
        ),
      );
      for (final stepDids in [...slice.groups, ?slice.calibration]) {
        final signalId = slice.signalIdOf(stepDids);
        completers[signalId] = Completer<ProbeResult>();
        steps.add(
          ProbeStep(signalId: signalId, command: _Slice.commandOf(stepDids)),
        );
      }
    }
    _pending.addAll(completers);
    _beginBatch([
      for (final slice in prepared) slice.ecuId,
    ], prepared.first.dids);

    var queuedAhead = 0;
    while (true) {
      if (_suspended) {
        // Cancelled -- a retry waiting out a reconnect must not keep
        // submitting against an executor the caller may already have
        // torn down.
        for (final id in completers.keys) {
          _pending.remove(id);
        }
        return const [];
      }
      queuedAhead = executor.queueDepth;
      try {
        await executor.submit(modules, steps);
        break;
      } on ReadExecutorRejection catch (rejection) {
        _logEvent(
          ScoutEventKind.enqueueRejected,
          detail: rejection.reason.name,
        );
        await _delay(submitBackoff);
      }
    }

    final deadline = _deadlineFor(queuedAhead + steps.length);
    return [
      for (final slice in prepared)
        _awaitAndFinalizeSlice(slice, completers, deadline, now),
    ];
  }

  /// Splits [next], [ecuId]'s next batch, into steps, one DID each; a
  /// scan-order slice of an ECU still [MultiDidSupport.unknown] also
  /// carries a calibration read when [_calibrationDids] finds one.
  _Slice _planSlice(
    String ecuId,
    ({List<String> dids, _BatchSource source, int rawAdvance}) next,
  ) {
    final ecu = state.ecus[ecuId]!;
    final scan = next.source == _BatchSource.scanOrder;
    return _Slice(
      ecuId: ecuId,
      dids: next.dids,
      source: next.source,
      rawAdvance: next.rawAdvance,
      groups: [
        for (final did in next.dids) [did],
      ],
      calibration: scan && ecu.multiDid == MultiDidSupport.unknown
          ? _calibrationDids(ecuId, ecu)
          : null,
    );
  }

  /// The DIDs of a multi-DID calibration read for [ecu], in request order:
  /// the two DIDs closest below its scan position that are known negatives
  /// (scanned, and neither discovered, conditional, unanswered, slow nor
  /// oversized), then a discovered reference DID, an identification DID
  /// (F18x/F19x) where there is one. A compliant ECU omits the negatives
  /// from its reply (ISO 14229-1:2013 §10.2), so the reply starts with the
  /// reference DID. Null while [ecu] has no such reference or negatives.
  List<String>? _calibrationDids(String ecuId, EcuInfo ecu) {
    final references =
        ecu.discovered
            .where(
              (did) =>
                  !vinDids.contains(did) &&
                  did != serialNumberDid &&
                  !ecu.slow.contains(did) &&
                  !ecu.oversized.contains(did) &&
                  !ecu.conditional.contains(did),
            )
            .toList()
          ..sort();
    final reference =
        references
            .where((did) => did.startsWith('F18') || did.startsWith('F19'))
            .firstOrNull ??
        references.firstOrNull;
    if (reference == null) {
      return null;
    }
    final order = _orderFor(ecuId, ecu.discoverRanges);
    final negatives = <String>[];
    for (
      var i = min(ecu.scanPosition, order.length) - 1;
      i >= 0 && negatives.length < 2;
      i--
    ) {
      final did = hex4(order[i]);
      if (!ecu.discovered.contains(did) &&
          !ecu.conditional.contains(did) &&
          !ecu.unanswered.contains(did) &&
          !ecu.retryQueue.contains(did) &&
          !ecu.slow.contains(did) &&
          !ecu.oversized.contains(did)) {
        negatives.add(did);
      }
    }
    return negatives.length < 2 ? null : [...negatives.reversed, reference];
  }

  /// Awaits one ECU's own slice of a round up to [deadline] (each slice
  /// on its own, independent of every other ECU's slice in the same
  /// round), then finalizes it. Registers the
  /// slice in [_inFlight] for [scoutStatus] and [pump]'s own in-flight
  /// check, and always removes it again before returning.
  Future<List<String>> _awaitAndFinalizeSlice(
    _Slice slice,
    Map<String, Completer<ProbeResult>> completers,
    Duration deadline,
    DateTime now,
  ) async {
    final calibration = slice.calibration;
    final signalIds = [
      for (final stepDids in [...slice.groups, ?calibration])
        slice.signalIdOf(stepDids),
    ];
    _inFlight[slice.ecuId] = _InFlightSlice(
      signalIds: signalIds,
      submittedAt: _clock(),
    );
    final results = await Future.wait([
      for (final signalId in signalIds)
        _awaitStepOrDeadline(signalId, completers[signalId]!, deadline),
    ]);
    _inFlight.remove(slice.ecuId);
    if (_suspended) {
      // Cancelled: no result is an answer, and this engine never gets
      // another chance to retry this slice -- nothing to finalize.
      return const [];
    }
    return _finalizeSlice(
      slice,
      results.sublist(0, slice.groups.length),
      calibration == null ? null : results.last,
      now,
    );
  }

  Duration _deadlineFor(int queuedSteps) =>
      batchDeadlineBase + batchDeadlinePerStep * queuedSteps;

  Future<ProbeResult?> _awaitStepOrDeadline(
    String signalId,
    Completer<ProbeResult> completer,
    Duration deadline,
  ) async {
    final result = await Future.any<ProbeResult?>([
      completer.future.then<ProbeResult?>((r) => r),
      _delay(deadline).then((_) => null),
    ]);
    if (result == null) {
      // Expired -- drop it from `_pending` so a result that does arrive
      // later for this signal id is ignored rather than mis-delivered to
      // whatever batch happens to reuse it next.
      _pending.remove(signalId);
    }
    return result;
  }

  /// Submits [steps] against [modules] and awaits every result, up to a
  /// deadline of [batchDeadlineBase] plus [batchDeadlinePerStep] per step
  /// queued ahead of or with them;
  /// used by the sequential inventory/identification flows, which (unlike
  /// discovery batches) have no per-DID scan state to finalize and simply
  /// want every step's answer or null. Retries a rejected submit after
  /// [submitBackoff] until the executor accepts or [cancel] runs, same as
  /// [_submitRound].
  Future<List<ProbeResult?>> _submitAndAwait(
    List<ProbeModule> modules,
    List<ProbeStep> steps,
  ) async {
    final completers = <String, Completer<ProbeResult>>{};
    for (final step in steps) {
      completers[step.signalId] = Completer<ProbeResult>();
    }
    _pending.addAll(completers);

    var queuedAhead = 0;
    while (true) {
      if (_suspended) {
        // Cancelled -- an abandoned sweep loop (inventory, identification)
        // or a retry waiting out a reconnect must not keep submitting
        // against an executor the caller may already have torn down.
        for (final id in completers.keys) {
          _pending.remove(id);
        }
        return [for (final _ in steps) null];
      }
      queuedAhead = executor.queueDepth;
      try {
        await executor.submit(modules, steps);
        break;
      } on ReadExecutorRejection catch (rejection) {
        _logEvent(
          ScoutEventKind.enqueueRejected,
          detail: rejection.reason.name,
        );
        await _delay(submitBackoff);
      }
    }

    final deadline = _deadlineFor(queuedAhead + steps.length);
    return Future.wait([
      for (final step in steps)
        _awaitStepOrDeadline(
          step.signalId,
          completers[step.signalId]!,
          deadline,
        ),
    ]);
  }

  /// Seeds [state] with the ECUs the vag-ppe profile already names --
  /// known headers that can be DID-scanned right away without needing
  /// generic discovery to find them first.
  void _seedVagPpeEcus() {
    for (final ecu in vagPpeSeedEcus()) {
      state.ecus.putIfAbsent(
        ecu.id,
        () => EcuInfo(
          requestHeader: ecu.request,
          responseHeader: ecu.response,
          protocol: ecu.protocol,
        ),
      );
    }
  }

  /// Gives [ecu] the [targetedDiscoverRanges] for its request header. A
  /// change restarts its scan, since the stored position indexes the DID
  /// order of the old ranges -- unless ranges were only appended: the old
  /// ranges' DIDs then keep their place, so a position within them stays
  /// valid and one past them resumes at the first appended range.
  void _applyTargetedRanges(String ecuId, EcuInfo ecu) {
    final ranges = targetedDiscoverRanges[ecu.requestHeader];
    final old = ecu.discoverRanges;
    if (ranges == null || sameRanges(old, ranges)) {
      return;
    }
    final appended =
        ranges.length > old.length &&
        sameRanges(old, ranges.sublist(0, old.length));
    ecu
      ..scanPosition = appended
          ? min(ecu.scanPosition, profileDidOrder(old).length)
          : 0
      ..discoverRanges = ranges;
    _orderCache.remove(ecuId);
    _priorityOrderCache.remove(ecuId);
    _profileOrderLengthCache.remove(ecuId);
  }

  List<int> _orderFor(String ecuId, List<(int, int)> ranges) =>
      _orderCache.putIfAbsent(ecuId, () => discoveryDidOrder(ranges));

  List<int> _priorityOrderFor(String ecuId, List<(int, int)> ranges) =>
      _priorityOrderCache.putIfAbsent(ecuId, () => priorityDidOrder(ranges));

  /// Whether [ecuId]'s scan has not yet passed the DIDs of its own
  /// [EcuInfo.discoverRanges].
  bool _hasProfileRangeWork(String ecuId, EcuInfo ecu) =>
      ecu.scanPosition <
      _profileOrderLengthCache.putIfAbsent(
        ecuId,
        () => profileDidOrder(ecu.discoverRanges).length,
      );

  /// Sweeps the 11-bit manufacturer-ECU request range for any header not
  /// already known in [state], identifies each newly found ECU, and
  /// records the result. Safe to call repeatedly -- a header already
  /// known is skipped, so a later call only probes what's still unknown
  /// (used for both initial inventory and rediscovery).
  Future<void> runEcu11Inventory() => _runInventory(
    stage: 'ecus11',
    protocol: 6,
    ids: [for (final id in ecu11RequestIds) hex3(id)],
    requestHeaderOf: (requestHex) => requestHex,
    responseHeaderOf: (requestHex, hit) => hit.responderHeader ?? requestHex,
    ecuIdOf: ecu11EcuId,
    sweepProbe: ecu11SweepProbe,
  );

  /// Sweeps the 29-bit normal-fixed-addressing target range for any id
  /// not already known in [state]; see [runEcu11Inventory].
  Future<void> runEcu29Inventory() => _run29BitInventory(ecu29Scheme);

  /// Sweeps the VW/Audi `17FC00xx`/`17FE00xx` target range for any id not
  /// already known in [state]; see [runEcu11Inventory].
  Future<void> runVag29Inventory() => _run29BitInventory(vag29Scheme);

  Future<void> _run29BitInventory(Ecu29Scheme scheme) => _runInventory(
    stage: scheme.stage,
    protocol: 7,
    ids: scheme.ids,
    requestHeaderOf: scheme.requestHeaderOf,
    responseHeaderOf: (id, _) => scheme.responseHeaderOf(id),
    ecuIdOf: scheme.ecuId,
    sweepProbe: scheme.sweepProbe,
  );

  /// Sweeps [stage]'s target [ids] whose request header no known
  /// [protocol] ECU has -- while [stage] is not done, also skipping the
  /// ids already in [DiscoveryState.inventorySwept] -- then identifies and
  /// records every ECU that answered. An id counts as swept once it got an
  /// answer ([_isAnswer]); one that answered OK only once its ECU is
  /// recorded. [stage] is marked done when every id probed got an answer;
  /// once [cancel] runs, nothing further is recorded.
  Future<void> _runInventory({
    required String stage,
    required int protocol,
    required List<String> ids,
    required String Function(String id) requestHeaderOf,
    required String Function(String id, ProbeResult hit) responseHeaderOf,
    required String Function(String id) ecuIdOf,
    required (ProbeModule, ProbeStep) Function(String id) sweepProbe,
  }) async {
    final knownHeaders = {
      for (final ecu in state.ecus.values)
        if (ecu.protocol == protocol) ecu.requestHeader,
    };
    final swept = state.inventorySwept.putIfAbsent(stage, () => {});
    // A stage already done reruns as rediscovery: an id that answered
    // NO DATA before may belong to an ECU that was asleep then.
    final resuming = !state.inventoryStagesDone.contains(stage);
    final candidates = ids
        .where(
          (id) =>
              !knownHeaders.contains(requestHeaderOf(id)) &&
              !(resuming && swept.contains(id)),
        )
        .toList();

    final hits = <String, ProbeResult>{};
    var unanswered = 0;
    for (var i = 0; i < candidates.length; i += sweepChunkSize) {
      final chunk = candidates.sublist(
        i,
        i + sweepChunkSize > candidates.length
            ? candidates.length
            : i + sweepChunkSize,
      );
      final probes = chunk.map(sweepProbe).toList();
      final results = await _submitAndAwait(
        [for (final probe in probes) probe.$1],
        [for (final probe in probes) probe.$2],
      );
      if (_suspended) {
        return;
      }
      for (var j = 0; j < chunk.length; j++) {
        final result = results[j];
        if (result == null || !_isAnswer(result.status)) {
          unanswered += 1;
        } else if (result.status is ProbeOk) {
          hits[chunk[j]] = result;
        } else {
          swept.add(chunk[j]);
        }
      }
    }

    for (final MapEntry(key: id, value: hit) in hits.entries) {
      final ecuId = ecuIdOf(id);
      final requestHeader = requestHeaderOf(id);
      final responseHeader = responseHeaderOf(id, hit);
      final identification = await _identify(
        moduleId: ecuId,
        requestHeader: requestHeader,
        responseHeader: responseHeader,
        protocol: protocol,
      );
      if (_suspended) {
        return;
      }
      _applyTargetedRanges(
        ecuId,
        state.ecus[ecuId] = EcuInfo(
          requestHeader: requestHeader,
          responseHeader: responseHeader,
          protocol: protocol,
          identification: identification,
        ),
      );
      swept.add(id);
    }
    if (unanswered == 0) {
      state.inventoryStagesDone.add(stage);
    }
    _logEvent(
      ScoutEventKind.inventoryStep,
      detail: unanswered == 0
          ? '$stage: ${hits.length} found'
          : '$stage: ${hits.length} found, $unanswered unanswered',
    );
  }

  Future<Map<String, String>> _identify({
    required String moduleId,
    required String requestHeader,
    required String responseHeader,
    required int protocol,
  }) async {
    final values = <String, String>{};
    for (final did in identificationDids) {
      final probe = identificationProbe(
        moduleId: moduleId,
        requestHeader: requestHeader,
        responseHeader: responseHeader,
        protocol: protocol,
        did: did,
      );
      final results = await _submitAndAwait([probe.$1], [probe.$2]);
      values[did] = _identificationValue(did, results.single);
    }
    return values;
  }

  String _identificationValue(String did, ProbeResult? result) {
    if (result == null) {
      return 'MISSING';
    }
    if (did == 'F197' && result.status is ProbeOk && result.payload != null) {
      return String.fromCharCodes(result.payload!);
    }
    return _statusBucket(result.status);
  }

  /// Reads F197 once per engine from every awake, addressable ECU that has
  /// no system name yet -- a vag-ppe seed, or an ECU whose identification
  /// read failed -- in a single batch. Until it has a name,
  /// [movingDiscoveryBlocked] keeps the ECU out of scanning while moving.
  Future<void> nameUnnamedEcus(DateTime now) async {
    final targets = <String>[];
    final modules = <ProbeModule>[];
    final steps = <ProbeStep>[];
    for (final MapEntry(key: ecuId, value: ecu) in state.ecus.entries) {
      final responseHeader = ecu.responseHeader;
      if (ecu.f197Name != null ||
          responseHeader == null ||
          (ecu.asleepUntil != null && now.isBefore(ecu.asleepUntil!)) ||
          !_namingAttempted.add(ecuId)) {
        continue;
      }
      final probe = identificationProbe(
        moduleId: ecuId,
        requestHeader: ecu.requestHeader,
        responseHeader: responseHeader,
        protocol: ecu.protocol,
        did: 'F197',
      );
      targets.add(ecuId);
      modules.add(probe.$1);
      steps.add(probe.$2);
    }
    if (targets.isEmpty) {
      return;
    }
    final results = await _submitAndAwait(modules, steps);
    if (_suspended) {
      return;
    }
    for (var i = 0; i < targets.length; i++) {
      state.ecus[targets[i]]?.identification['F197'] = _identificationValue(
        'F197',
        results[i],
      );
    }
    _logEvent(
      ScoutEventKind.inventoryStep,
      detail: 'names: ${targets.length} read',
    );
  }

  /// Re-probes for ECUs that only wake in some vehicle states -- ecus11,
  /// ecus29 and vag29, skipping anything already known -- and records when
  /// it ran.
  Future<void> rediscoverEcus(DateTime now) async {
    await runEcu11Inventory();
    await runEcu29Inventory();
    await runVag29Inventory();
    state.lastRediscoveryTime = now;
  }

  /// Queues every currently-conditional DID (NRC 22/33) on [ecuId] for
  /// retry -- called on a phase change, same as the CLI's "retried after
  /// each phase change".
  void queueConditionalRetries(String ecuId) {
    final ecu = state.ecus[ecuId];
    if (ecu == null) {
      return;
    }
    ecu.retryQueue = ecu.conditional.toList()..sort();
  }

  /// Queues conditional retries for every known ECU.
  void handlePhaseChange() {
    for (final ecuId in state.ecus.keys) {
      queueConditionalRetries(ecuId);
    }
  }

  /// Whether [ecuId] still has pending discovery work: a read missing an
  /// answer, a queued retry, or more of its scan order left, and it isn't
  /// currently paused asleep. True regardless of whether a batch for
  /// [ecuId] is currently in flight -- its work only actually shrinks once
  /// that batch is finalized.
  bool hasDiscoveryWork(String ecuId, DateTime now) {
    final ecu = state.ecus[ecuId];
    if (ecu == null) {
      return false;
    }
    if (ecu.asleepUntil != null && now.isBefore(ecu.asleepUntil!)) {
      return false;
    }
    if (ecu.unanswered.isNotEmpty || ecu.retryQueue.isNotEmpty) {
      return true;
    }
    return ecu.scanPosition < _orderFor(ecuId, ecu.discoverRanges).length;
  }

  /// The next ECU [pump]'s discovery scan should run a batch on: honors a
  /// sleeping-ECU pause and, while moving, only offers an ECU whose F197
  /// name is known and doesn't match [movingDiscoveryBlocked] -- ECU (re)discovery
  /// itself never runs while moving (the caller gates that separately). An
  /// ECU with a batch already in flight is still offered here -- it is
  /// still being scanned, just not yet given a second one.
  String? selectNextEcuForScan({
    required bool stationary,
    required DateTime now,
  }) {
    for (final ecuId in state.ecus.keys) {
      if (_scannable(ecuId, stationary: stationary, now: now)) {
        return ecuId;
      }
    }
    return null;
  }

  bool _scannable(
    String ecuId, {
    required bool stationary,
    required DateTime now,
  }) =>
      (stationary || !movingDiscoveryBlocked(state.ecus[ecuId]!.f197Name)) &&
      hasDiscoveryWork(ecuId, now);

  /// What [ecuId]'s next batch would read, without submitting anything:
  /// DIDs an earlier batch sent but never got an answer for first
  /// ([EcuInfo.unanswered]), else pending conditional retries
  /// ([EcuInfo.retryQueue]), else the next slice of the scan order. Null
  /// once there is nothing left to read. [rawAdvance], meaningful only for
  /// a [_BatchSource.scanOrder] result, is how far [EcuInfo.scanPosition]
  /// moves once the batch is read, including any already-[EcuInfo.slow]
  /// DIDs skipped along the way; skipping a run of them all the way to the
  /// end of the scan order needs no probe, so that much of
  /// [EcuInfo.scanPosition] is simply advanced here.
  ({List<String> dids, _BatchSource source, int rawAdvance})? _nextBatchFor(
    String ecuId,
  ) {
    final ecu = state.ecus[ecuId];
    if (ecu == null) {
      return null;
    }
    final unanswered = ecu.unanswered.take(batchSize).toList();
    if (unanswered.isNotEmpty) {
      return (
        dids: unanswered,
        source: _BatchSource.unansweredRetry,
        rawAdvance: 0,
      );
    }
    final retry = ecu.retryQueue.take(batchSize).toList();
    if (retry.isNotEmpty) {
      return (
        dids: retry,
        source: _BatchSource.conditionalRetry,
        rawAdvance: 0,
      );
    }

    final order = _orderFor(ecuId, ecu.discoverRanges);
    final dids = <String>[];
    var cursor = ecu.scanPosition;
    while (dids.length < batchSize && cursor < order.length) {
      final did = hex4(order[cursor]);
      cursor += 1;
      if (!ecu.slow.contains(did) && !ecu.oversized.contains(did)) {
        dids.add(did);
      }
    }
    final rawAdvance = cursor - ecu.scanPosition;
    if (dids.isEmpty) {
      ecu.scanPosition = cursor;
      return null;
    }
    return (dids: dids, source: _BatchSource.scanOrder, rawAdvance: rawAdvance);
  }

  /// Books one DID that got a vehicle-side answer: discovered on
  /// [ProbeOk], queued for retry on NRC 22/33, or quarantined into
  /// [EcuInfo.slow] on a timeout -- a timeout ends the adapter session and
  /// cancels every queued read, so retrying such a DID stalls all
  /// discovery -- or into [EcuInfo.oversized] on a reply too long to read.
  /// Anything else (NO DATA, another NRC) just clears any
  /// stale conditional flag.
  void _finalizeAnsweredDid(
    EcuInfo ecu,
    String ecuId,
    String did,
    ProbeResult result,
    List<String> newlyFound,
  ) {
    switch (result.status) {
      case ProbeOk():
        ecu.discovered.add(did);
        ecu.conditional.remove(did);
        newlyFound.add(did);
        _logEvent(ScoutEventKind.hit, ecuId: ecuId, detail: did);
        onHit(ecuId, did, result.payload ?? const []);
      case ProbeNrc(code: 0x22) || ProbeNrc(code: 0x33):
        ecu.conditional.add(did);
        _logEvent(ScoutEventKind.conditional, ecuId: ecuId, detail: did);
      case ProbeTimeout():
        ecu.slow.add(did);
        ecu.discovered.remove(did);
        ecu.conditional.remove(did);
        _logEvent(ScoutEventKind.slowDid, ecuId: ecuId, detail: did);
      case ProbeOverflow():
        _quarantineOversizedDid(ecu, ecuId, did);
      default:
        ecu.conditional.remove(did);
    }
  }

  /// Applies one ECU's completed [slice] of a round to its state.
  /// [stepResults] holds one entry per [_Slice.groups] step, in order, and
  /// [calibrationResult] the slice's calibration read, if it had one.
  ///
  /// Every DID with a vehicle-side answer ([_isAnswer]) is booked via [_finalizeAnsweredDid]; [_Slice.source]'s
  /// own queue or [EcuInfo.scanPosition] advances. A
  /// [_BatchSource.scanOrder] slice also queues every DID without an
  /// answer into [EcuInfo.unanswered], so it is read again rather than
  /// lost; [_BatchSource.conditionalRetry] and
  /// [_BatchSource.unansweredRetry] simply leave such a DID in its own
  /// queue for the next pull. Asleep/no-data detection ([batchIsAsleep]/
  /// [batchLooksNoDataAsleep]) runs over the answered DIDs only, before
  /// any of this: a slice with none answered changes nothing, and one
  /// that looks asleep is left exactly as queued, to be read again once
  /// the ECU wakes rather than counted as checked while it couldn't
  /// possibly have meant it. The
  /// calibration result is applied either way ([_applyCalibration]).
  /// Returns the DIDs found OK.
  List<String> _finalizeSlice(
    _Slice slice,
    List<ProbeResult?> stepResults,
    ProbeResult? calibrationResult,
    DateTime now,
  ) {
    final ecuId = slice.ecuId;
    final ecu = state.ecus[ecuId]!;
    final calibration = slice.calibration;
    final calibrationOutcome = calibration == null
        ? null
        : _calibrationOutcome(calibration.last, calibrationResult);

    final dids = slice.dids;
    final results = stepResults;
    final answeredDids = <String>[];
    final answeredResults = <ProbeResult>[];
    final missingDids = <String>[];
    for (var i = 0; i < dids.length; i++) {
      final result = results[i];
      if (result != null && _isAnswer(result.status)) {
        answeredDids.add(dids[i]);
        answeredResults.add(result);
      } else {
        missingDids.add(dids[i]);
      }
    }
    // With fewer than half of the batch answered (the rest cancelled by
    // another read's session reset) a NO DATA or NRC 11 cannot be told
    // apart from an ECU going to sleep, so those DIDs are read again
    // instead of being booked or pausing the ECU.
    final representative = answeredResults.length * 2 >= dids.length;
    if (!representative) {
      for (var i = answeredResults.length - 1; i >= 0; i--) {
        if (_isSleepSignature(answeredResults[i].status)) {
          missingDids.add(answeredDids.removeAt(i));
          answeredResults.removeAt(i);
        }
      }
    }
    if (missingDids.isNotEmpty) {
      _logEvent(
        ScoutEventKind.batchTimedOut,
        ecuId: ecuId,
        detail: '${missingDids.length}/${dids.length} missing',
      );
    }
    if (answeredResults.isEmpty) {
      _applyCalibration(ecu, ecuId, calibrationOutcome, sliceAsleep: false);
      return const [];
    }

    final statusCounts = <String, int>{};
    for (final result in answeredResults) {
      final bucket = _statusBucket(result.status);
      statusCounts[bucket] = (statusCounts[bucket] ?? 0) + 1;
    }

    if (representative &&
        batchLooksNoDataAsleep(statusCounts, answeredResults.length)) {
      ecu.noDataStreak += 1;
      ecu.asleepUntil = now.add(noDataAsleepPause(ecu.noDataStreak));
      _logEvent(ScoutEventKind.asleep, ecuId: ecuId, detail: 'no data');
      _applyCalibration(ecu, ecuId, calibrationOutcome, sliceAsleep: true);
      return const [];
    }
    ecu.noDataStreak = 0;
    if (representative && batchIsAsleep(statusCounts, answeredResults.length)) {
      ecu.asleepUntil = now.add(asleepPauseDuration);
      _logEvent(ScoutEventKind.asleep, ecuId: ecuId);
      _applyCalibration(ecu, ecuId, calibrationOutcome, sliceAsleep: true);
      return const [];
    }
    _applyCalibration(ecu, ecuId, calibrationOutcome, sliceAsleep: false);

    switch (slice.source) {
      case _BatchSource.scanOrder:
        ecu.scanPosition += slice.rawAdvance;
        for (final did in missingDids) {
          if (!ecu.unanswered.contains(did)) {
            ecu.unanswered.add(did);
          }
        }
      case _BatchSource.conditionalRetry:
        ecu.retryQueue.removeWhere(answeredDids.contains);
      case _BatchSource.unansweredRetry:
        ecu.unanswered.removeWhere(answeredDids.contains);
    }

    final newlyFound = <String>[];
    for (var i = 0; i < answeredDids.length; i++) {
      _finalizeAnsweredDid(
        ecu,
        ecuId,
        answeredDids[i],
        answeredResults[i],
        newlyFound,
      );
    }
    return newlyFound;
  }

  /// Reads a calibration read's [result] for an ECU whose calibration
  /// asked for [reference] after two known negatives.
  static _CalibrationOutcome _calibrationOutcome(
    String reference,
    ProbeResult? result,
  ) {
    switch (result?.status) {
      case ProbeOk():
        final payload = result!.payload;
        return payload != null &&
                payload.length >= 2 &&
                hex4((payload[0] << 8) | payload[1]) == reference
            ? _CalibrationOutcome.supported
            : _CalibrationOutcome.unsupported;
      case ProbeNoData() || ProbeNrc(code: 0x11):
        return _CalibrationOutcome.failedUnlessAsleep;
      // busyRepeatRequest and responsePending are transient by definition;
      // conditionsNotCorrect may concern the reference DID alone.
      case ProbeNrc(code: 0x21 || 0x22 || 0x78):
        return _CalibrationOutcome.failed;
      case ProbeNrc():
        return _CalibrationOutcome.unsupported;
      default:
        return _CalibrationOutcome.failed;
    }
  }

  /// Applies [outcome], if any, to [ecu]'s [EcuInfo.multiDid];
  /// [sliceAsleep] tells whether the calibration read's slice looked
  /// asleep.
  void _applyCalibration(
    EcuInfo ecu,
    String ecuId,
    _CalibrationOutcome? outcome, {
    required bool sliceAsleep,
  }) {
    switch (outcome) {
      case null:
        return;
      case _CalibrationOutcome.supported:
        _setMultiDid(ecu, ecuId, MultiDidSupport.supported);
      case _CalibrationOutcome.unsupported:
        _setMultiDid(ecu, ecuId, MultiDidSupport.unsupported);
      case _CalibrationOutcome.failedUnlessAsleep when sliceAsleep:
        return;
      case _CalibrationOutcome.failed || _CalibrationOutcome.failedUnlessAsleep:
        ecu.multiDidCalibrationFailures += 1;
        if (ecu.multiDidCalibrationFailures >= maxMultiDidCalibrationFailures) {
          _setMultiDid(ecu, ecuId, MultiDidSupport.unsupported);
        }
    }
  }

  void _setMultiDid(EcuInfo ecu, String ecuId, MultiDidSupport support) {
    if (ecu.multiDid == support) {
      return;
    }
    ecu.multiDid = support;
    _logEvent(ScoutEventKind.multiDid, ecuId: ecuId, detail: support.name);
  }

  /// Reads one batch of [ecuId]'s discovery work and fully awaits its
  /// outcome -- a thin, blocking wrapper around [_submitRound] for
  /// callers (tests, mainly) that want the old one-ECU-at-a-time
  /// behavior; [pump] itself never awaits a slice's results, only its
  /// submission. A no-op (returns empty) while [ecuId] already has a
  /// slice in flight.
  Future<List<String>> runDiscoveryBatch(String ecuId, DateTime now) async {
    final ecu = state.ecus[ecuId];
    if (ecu == null ||
        (ecu.asleepUntil != null && now.isBefore(ecu.asleepUntil!)) ||
        _inFlight.containsKey(ecuId)) {
      return [];
    }
    final futures = await _submitRound([ecuId], now);
    return futures.isEmpty ? [] : await futures.single;
  }

  /// Submits one batch for each of [ecuIds] that still has one ready, in a
  /// single [ReadExecutor.submit] call, and fully awaits every one of
  /// their slices before returning -- an explicit-ECU-list, blocking
  /// counterpart to [pump]'s own round selection, for callers that want
  /// the old all-at-once behavior for a specific group of ECUs.
  Future<void> runDiscoveryBatchGroup(List<String> ecuIds, DateTime now) async {
    for (final future in await _submitRound(ecuIds, now)) {
      await future;
    }
  }

  /// Overall DID scan progress across every known ECU: the ECU count, the
  /// percentage (0-100) of each ECU's own *priority* scan order
  /// ([priorityDidOrder] -- profile ranges plus the standardized
  /// high-value ranges) already visited, averaged by position rather than
  /// per-ECU -- an ECU with a longer priority order counts proportionally
  /// more -- and [totalChecked], the raw DID count read across every
  /// known ECU regardless of range. The percentage is denominated against
  /// [priorityDidOrder] rather than the full 64k-DID [discoveryDidOrder]:
  /// the latter would barely move within one recording and make the
  /// Scouting card look stuck at 0% even after thousands of reads.
  ({int ecuCount, double percent, int totalChecked}) scanProgress() {
    if (state.ecus.isEmpty) {
      return (ecuCount: 0, percent: 0, totalChecked: 0);
    }
    var totalPositions = 0;
    var totalPriorityLength = 0;
    var totalChecked = 0;
    for (final entry in state.ecus.entries) {
      final priorityLength = _priorityOrderFor(
        entry.key,
        entry.value.discoverRanges,
      ).length;
      totalPriorityLength += priorityLength;
      totalPositions += entry.value.scanPosition.clamp(0, priorityLength);
      totalChecked += entry.value.scanPosition;
    }
    return (
      ecuCount: state.ecus.length,
      percent: totalPriorityLength == 0
          ? 0
          : totalPositions / totalPriorityLength * 100,
      totalChecked: totalChecked,
    );
  }

  /// One scheduler tick: while stationary, tops up any pending ECU
  /// (re)discovery and names unnamed ECUs ([nameUnnamedEcus]) -- both
  /// fully awaited, as before; then groups one batch from every currently
  /// eligible, not-already-in-flight ECU into a single submission -- so
  /// the executor's queue is topped up by several ECUs at once, bounded by
  /// [maxQueueDepth] -- and returns without waiting for any of that
  /// round's results: each ECU's own slice is finalized independently,
  /// in the background, as soon as it is fully in or its own deadline
  /// passes (see [_submitRound]). The caller invokes this repeatedly (e.g.
  /// once per scheduler iteration) rather than draining all discovery work
  /// in one call, keeping the queue in the [minQueueDepth]-[maxQueueDepth]
  /// band over time instead of flooding it. A no-op once [suspended];
  /// while the executor rejects batches this call keeps retrying until it
  /// accepts again or [cancel] runs.
  ///
  /// Every eligible, not-in-flight ECU whose scan has not yet passed its
  /// own [EcuInfo.discoverRanges] gets a batch in every round, ahead of
  /// the rest: those ranges are where its useful DIDs are expected, and a
  /// plain rotation over a few dozen ECUs would reach each of them only
  /// once every few rounds. Every such ECU in [focusRequestHeaders]
  /// follows next, also every round, as far as the round has room.
  ///
  /// The remaining room is filled starting from just after wherever the
  /// previous round left off ([_roundRobinCursor]) rather than always from
  /// the first known ECU: an ECU with a long scan order always has more
  /// work left than one near the end of its own, so starting from the
  /// front every time would let the earliest few ECUs monopolize every
  /// round once they fill it to [maxQueueDepth], starving the rest.
  Future<void> pump({required bool stationary, required DateTime now}) async {
    if (_suspended) {
      return;
    }
    if (stationary) {
      if (!state.inventoryStagesDone.contains('ecus11')) {
        await runEcu11Inventory();
      }
      if (!state.inventoryStagesDone.contains(ecu29Scheme.stage)) {
        await runEcu29Inventory();
      }
      if (!state.inventoryStagesDone.contains(vag29Scheme.stage)) {
        await runVag29Inventory();
      }
      await nameUnnamedEcus(now);
    }
    if (_suspended || executor.queueDepth >= minQueueDepth) {
      return;
    }
    final keys = state.ecus.keys.toList();
    if (keys.isEmpty) {
      return;
    }
    final round = <String>[];
    bool roundFull() => round.length * batchSize >= maxQueueDepth;
    bool eligible(String ecuId) =>
        !round.contains(ecuId) &&
        !_inFlight.containsKey(ecuId) &&
        _scannable(ecuId, stationary: stationary, now: now);

    void addPreferred(bool Function(String ecuId, EcuInfo ecu) preferred) {
      for (final ecuId in keys) {
        if (roundFull()) {
          return;
        }
        if (preferred(ecuId, state.ecus[ecuId]!) && eligible(ecuId)) {
          round.add(ecuId);
        }
      }
    }

    addPreferred(_hasProfileRangeWork);
    addPreferred((_, ecu) => focusRequestHeaders.contains(ecu.requestHeader));
    var considered = 0;
    while (considered < keys.length && !roundFull()) {
      final ecuId = keys[(_roundRobinCursor + considered) % keys.length];
      considered += 1;
      if (eligible(ecuId)) {
        round.add(ecuId);
      }
    }
    _roundRobinCursor = (_roundRobinCursor + considered) % keys.length;
    if (round.isEmpty) {
      return;
    }
    for (final future in await _submitRound(round, now)) {
      unawaited(future);
    }
  }
}
