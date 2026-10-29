/// The discovery engine: drives manufacturer ECU inventory and per-ECU
/// DID scanning against a [ReadExecutor], ported from didscout's
/// `run_discovery_batch`/`_batch_is_asleep`/`_select_discovery_module`/
/// `_inventory_ecus11`/`_inventory_ecus29` and the rediscovery logic.
library;

import 'dart:async';

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
/// to wake up again within a minute.
const Duration noDataAsleepPauseDuration = Duration(minutes: 5);

/// Default per-step addition to a batch's result-wait deadline (see
/// [DiscoveryEngine.batchDeadlinePerStep]).
const Duration defaultBatchDeadlinePerStep = Duration(seconds: 2);

/// Default fixed floor of a batch's result-wait deadline (see
/// [DiscoveryEngine.batchDeadlineBase]).
const Duration defaultBatchDeadlineBase = Duration(seconds: 30);

/// Default pause before retrying a batch [ReadExecutor.submit] rejected
/// with [SubmitRejectionReason.queueFull].
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
  ProbeTransportError() => 'TRANSPORT_ERROR',
  ProbeCancelled() => 'CANCELLED',
};

String hex3(int value) => value.toRadixString(16).toUpperCase().padLeft(3, '0');
String hex4(int value) => value.toRadixString(16).toUpperCase().padLeft(4, '0');

/// Reported once a DID scan confirms an ECU answers a given DID -- lets
/// the caller add it to its own recurring reads.
typedef DiscoveryHit =
    void Function(String ecuId, String did, List<int> payload);

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

  /// Added to [batchDeadlineBase] once per queued step to get the deadline
  /// a batch's results have to arrive by (see [_submitAndAwait]) -- a
  /// step without a result by then is treated as missing rather than
  /// awaited forever, since the plugin documents that a one-shot result
  /// event may simply never arrive (engine paused, app backgrounded).
  final Duration batchDeadlinePerStep;

  /// Fixed floor of a batch's result-wait deadline, see
  /// [batchDeadlinePerStep].
  final Duration batchDeadlineBase;

  /// How long [_submitAndAwait] waits before retrying a batch
  /// [ReadExecutor.submit] rejected with [SubmitRejectionReason.queueFull].
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
  late final StreamSubscription<ProbeResult> _subscription;

  /// Index into `state.ecus.keys` [pump] starts its next round from -- see
  /// [pump]'s doc comment on why this rotates instead of always starting
  /// at the first key.
  int _roundRobinCursor = 0;

  /// ECUs [nameUnnamedEcus] already tried during this engine's lifetime.
  final Set<String> _namingAttempted = {};

  /// Once true (a batch was rejected with
  /// [SubmitRejectionReason.noActiveRecording]), [pump] never submits
  /// anything again for the rest of this engine's lifetime -- the caller
  /// is expected to start a fresh engine for the next recording.
  bool _suspended = false;

  /// Whether [pump] has permanently stopped submitting for this engine
  /// instance (see [_suspended]).
  bool get suspended => _suspended;

  String? _lastResultSummary;
  final List<DateTime> _recentReads = [];
  final List<ScoutEvent> _events = [];

  String? _currentEcuId;
  (String, String)? _currentDidRange;
  int _waitingCount = 0;
  DateTime? _waitingSince;

  /// The last [scoutEventLogCapacity] scouting events, newest first.
  List<ScoutEvent> get eventLog => List.unmodifiable(_events);

  /// A snapshot of current scouting activity for the recording page's
  /// compact status line -- [now] is used only to report [ScoutStatus.
  /// waitingFor] and to window [ScoutStatus.readsPerMinute]; business
  /// logic (asleep timers, scan position) is unaffected by it.
  ScoutStatus scoutStatus(DateTime now) {
    _recentReads.removeWhere((at) => now.difference(at) > readsPerMinuteWindow);
    final ecuId = _currentEcuId;
    return ScoutStatus(
      currentEcuId: ecuId,
      currentEcuName: ecuId == null ? null : state.ecus[ecuId]?.f197Name,
      currentDidRangeLabel: _currentDidRange == null
          ? null
          : '${_currentDidRange!.$1}–${_currentDidRange!.$2}',
      readsPerMinute: _recentReads.length,
      lastResultSummary: _lastResultSummary,
      queueDepth: executor.queueDepth,
      waitingCount: _waitingCount,
      waitingFor: _waitingSince == null ? null : now.difference(_waitingSince!),
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

  /// Abandons whatever batch is currently in flight, if any: every
  /// outstanding completer resolves right now with [ProbeCancelled]
  /// instead of waiting out its deadline, and (like [_suspended]) this
  /// engine never submits again -- a fresh engine is expected for the
  /// next recording. Called when the recording this engine serves is
  /// stopping, so a pump call already awaiting results doesn't keep
  /// running in the background for minutes after the caller walked away;
  /// its own `await` simply resolves promptly once this runs, without the
  /// caller needing to await it itself.
  void cancel() {
    _suspended = true;
    final pending = _pending.entries.toList();
    _pending.clear();
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
    _pending.remove(result.signalId)?.complete(result);
  }

  /// Marks a new batch of [dids] against [ecuIds] (the first entry is the
  /// one shown as "current" -- the rest matter only for [ScoutStatus.
  /// waitingCount]) as submitted, for [scoutStatus] and the event log.
  void _beginBatch(List<String> ecuIds, List<String> dids, int totalSteps) {
    final primary = ecuIds.isEmpty ? null : ecuIds.first;
    _currentEcuId = primary;
    _currentDidRange = dids.isEmpty ? null : (dids.first, dids.last);
    _waitingCount = totalSteps;
    _waitingSince = _clock();
    if (primary != null) {
      _logEvent(
        ScoutEventKind.batchSubmitted,
        ecuId: primary,
        detail: '${dids.length} dids',
      );
    }
  }

  void _endWaiting() {
    _waitingCount = 0;
    _waitingSince = null;
  }

  /// Submits [steps] against [modules], retrying on
  /// [SubmitRejectionReason.queueFull] after [submitBackoff] and giving up
  /// permanently (see [_suspended]) on [SubmitRejectionReason.
  /// noActiveRecording] -- either rejection is logged. Once accepted,
  /// awaits every step's result up to a deadline of [batchDeadlineBase]
  /// plus [batchDeadlinePerStep] per step; a step with no result by then
  /// reports null rather than hanging forever (the plugin documents that a
  /// one-shot result event may simply be lost), and is dropped from
  /// [_pending] so a late result for it is ignored safely rather than
  /// completing an already-abandoned wait.
  Future<List<ProbeResult?>> _submitAndAwait(
    List<ProbeModule> modules,
    List<ProbeStep> steps,
  ) async {
    if (_suspended) {
      // Already cancelled or permanently rejected -- an abandoned sweep
      // loop (inventory, identification) that hasn't noticed yet must not
      // keep submitting against an executor the caller may already have
      // torn down.
      return [for (final _ in steps) null];
    }
    final completers = <String, Completer<ProbeResult>>{};
    for (final step in steps) {
      completers[step.signalId] = Completer<ProbeResult>();
    }
    _pending.addAll(completers);

    while (true) {
      try {
        await executor.submit(modules, steps);
        break;
      } on ReadExecutorRejection catch (rejection) {
        _logEvent(
          ScoutEventKind.enqueueRejected,
          detail: rejection.reason.name,
        );
        if (rejection.reason == SubmitRejectionReason.noActiveRecording) {
          _suspended = true;
          for (final id in completers.keys) {
            _pending.remove(id);
          }
          return [for (final _ in steps) null];
        }
        await _delay(submitBackoff);
      }
    }

    final deadline = batchDeadlineBase + batchDeadlinePerStep * steps.length;
    return Future.wait([
      for (final step in steps)
        _awaitStepOrDeadline(
          step.signalId,
          completers[step.signalId]!,
          deadline,
        ),
    ]);
  }

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

  List<int> _orderFor(String ecuId, List<(int, int)> ranges) =>
      _orderCache.putIfAbsent(ecuId, () => discoveryDidOrder(ranges));

  List<int> _priorityOrderFor(String ecuId, List<(int, int)> ranges) =>
      _priorityOrderCache.putIfAbsent(ecuId, () => priorityDidOrder(ranges));

  /// Sweeps the 11-bit manufacturer-ECU request range for any header not
  /// already known in [state], identifies each newly found ECU, and
  /// records the result. Safe to call repeatedly -- a header already
  /// known is skipped, so a later call only probes what's still unknown
  /// (used for both initial inventory and rediscovery).
  Future<void> runEcu11Inventory() async {
    final knownHeaders = {
      for (final ecu in state.ecus.values)
        if (ecu.protocol == 6 && ecu.requestHeader.length == 3)
          ecu.requestHeader,
    };
    final candidates = ecu11RequestIds
        .where((id) => !knownHeaders.contains(hex3(id)))
        .toList();

    final found = <String, String>{};
    for (var i = 0; i < candidates.length; i += sweepChunkSize) {
      final chunk = candidates.sublist(
        i,
        i + sweepChunkSize > candidates.length
            ? candidates.length
            : i + sweepChunkSize,
      );
      final probes = chunk.map(ecu11SweepProbe).toList();
      final results = await _submitAndAwait(
        [for (final probe in probes) probe.$1],
        [for (final probe in probes) probe.$2],
      );
      for (var j = 0; j < chunk.length; j++) {
        final result = results[j];
        if (result != null && result.status is ProbeOk) {
          final requestHex = hex3(chunk[j]);
          found[requestHex] = result.responderHeader ?? requestHex;
        }
      }
    }

    for (final entry in found.entries) {
      final ecuId = ecu11EcuId(entry.key);
      final identification = await _identify(
        moduleId: ecuId,
        requestHeader: entry.key,
        responseHeader: entry.value,
        protocol: 6,
      );
      state.ecus[ecuId] = EcuInfo(
        requestHeader: entry.key,
        responseHeader: entry.value,
        protocol: 6,
        identification: identification,
      );
    }
    state.inventoryStagesDone.add('ecus11');
    _logEvent(
      ScoutEventKind.inventoryStep,
      detail: 'ecus11: ${found.length} found',
    );
  }

  /// Sweeps the 29-bit normal-fixed-addressing target range for any id
  /// not already known in [state]; see [runEcu11Inventory].
  Future<void> runEcu29Inventory() async {
    final knownIds = {
      for (final ecu in state.ecus.values)
        if (ecu.protocol == 7 &&
            RegExp(r'^18DA([0-9A-F]{2})F1$').hasMatch(ecu.requestHeader))
          RegExp(
            r'^18DA([0-9A-F]{2})F1$',
          ).firstMatch(ecu.requestHeader)!.group(1)!,
    };
    final candidates = ecu29Ids.where((id) => !knownIds.contains(id)).toList();

    final found = <String>{};
    for (var i = 0; i < candidates.length; i += sweepChunkSize) {
      final chunk = candidates.sublist(
        i,
        i + sweepChunkSize > candidates.length
            ? candidates.length
            : i + sweepChunkSize,
      );
      final probes = chunk.map(ecu29SweepProbe).toList();
      final results = await _submitAndAwait(
        [for (final probe in probes) probe.$1],
        [for (final probe in probes) probe.$2],
      );
      for (var j = 0; j < chunk.length; j++) {
        final result = results[j];
        if (result != null && result.status is ProbeOk) {
          found.add(chunk[j]);
        }
      }
    }

    for (final id in found) {
      final ecuId = ecu29EcuId(id);
      final requestHeader = '18DA${id}F1';
      final responseHeader = '18DAF1$id';
      final identification = await _identify(
        moduleId: ecuId,
        requestHeader: requestHeader,
        responseHeader: responseHeader,
        protocol: 7,
      );
      state.ecus[ecuId] = EcuInfo(
        requestHeader: requestHeader,
        responseHeader: responseHeader,
        protocol: 7,
        identification: identification,
      );
    }
    state.inventoryStagesDone.add('ecus29');
    _logEvent(
      ScoutEventKind.inventoryStep,
      detail: 'ecus29: ${found.length} found',
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

  /// Re-probes for ECUs that only wake in some vehicle states -- ecus11
  /// and ecus29, skipping anything already known -- and records when it
  /// ran.
  Future<void> rediscoverEcus(DateTime now) async {
    await runEcu11Inventory();
    await runEcu29Inventory();
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

  /// Whether [ecuId] still has pending discovery work: a queued retry, or
  /// more of its scan order left, and it isn't currently paused asleep.
  bool hasDiscoveryWork(String ecuId, DateTime now) {
    final ecu = state.ecus[ecuId];
    if (ecu == null) {
      return false;
    }
    if (ecu.asleepUntil != null && now.isBefore(ecu.asleepUntil!)) {
      return false;
    }
    if (ecu.retryQueue.isNotEmpty) {
      return true;
    }
    return ecu.scanPosition < _orderFor(ecuId, ecu.discoverRanges).length;
  }

  /// The next ECU [pump]'s discovery scan should run a batch on: honors a
  /// sleeping-ECU pause and, while moving, only offers an ECU whose F197
  /// name is known and doesn't match [movingDiscoveryBlocked] -- ECU (re)discovery
  /// itself never runs while moving (the caller gates that separately).
  String? selectNextEcuForScan({
    required bool stationary,
    required DateTime now,
  }) {
    for (final entry in state.ecus.entries) {
      if (!stationary && movingDiscoveryBlocked(entry.value.f197Name)) {
        continue;
      }
      if (hasDiscoveryWork(entry.key, now)) {
        return entry.key;
      }
    }
    return null;
  }

  /// The next batch of DIDs [ecuId] would read -- its pending conditional
  /// retries first, else the next slice of its scan order -- without
  /// submitting or mutating anything. Null once there is nothing left.
  ({List<String> dids, bool fromRetry})? _nextBatchFor(String ecuId) {
    final ecu = state.ecus[ecuId];
    if (ecu == null) {
      return null;
    }
    final fromRetry = ecu.retryQueue.isNotEmpty;
    final dids = fromRetry
        ? ecu.retryQueue.take(batchSize).toList()
        : _orderFor(
            ecuId,
            ecu.discoverRanges,
          ).skip(ecu.scanPosition).take(batchSize).map(hex4).toList();
    return dids.isEmpty ? null : (dids: dids, fromRetry: fromRetry);
  }

  /// Applies one completed batch's [results] (in the same order as
  /// [dids]) to [ecuId]: missing-result and asleep detection,
  /// position/retry-queue advancement, discovered/conditional bookkeeping,
  /// and [onHit] reporting. Returns the DIDs found OK.
  ///
  /// A batch with any missing (null) or [ProbeCancelled] result -- its
  /// deadline passed before the plugin reported one, or the request was
  /// cancelled -- advances nothing: it is logged and left exactly as
  /// queued, so the same slice is simply retried on a later batch instead
  /// of being silently treated as answered.
  List<String> _finalizeBatch(
    String ecuId,
    List<String> dids,
    bool fromRetry,
    List<ProbeResult?> results,
    DateTime now,
  ) {
    final ecu = state.ecus[ecuId]!;
    final missing = results
        .where((r) => r == null || r.status is ProbeCancelled)
        .length;
    if (missing > 0) {
      _logEvent(
        ScoutEventKind.batchTimedOut,
        ecuId: ecuId,
        detail: '$missing/${dids.length} missing',
      );
      return [];
    }
    final okResults = results.cast<ProbeResult>();

    final statusCounts = <String, int>{};
    for (final result in okResults) {
      final bucket = _statusBucket(result.status);
      statusCounts[bucket] = (statusCounts[bucket] ?? 0) + 1;
    }

    if (batchIsAsleep(statusCounts, dids.length)) {
      ecu.asleepUntil = now.add(asleepPauseDuration);
      _logEvent(ScoutEventKind.asleep, ecuId: ecuId);
      return [];
    }
    if (batchLooksNoDataAsleep(statusCounts, dids.length)) {
      ecu.asleepUntil = now.add(noDataAsleepPauseDuration);
      _logEvent(ScoutEventKind.asleep, ecuId: ecuId, detail: 'no data');
      return [];
    }

    if (fromRetry) {
      ecu.retryQueue = ecu.retryQueue.sublist(dids.length);
    } else {
      ecu.scanPosition += dids.length;
    }

    final newlyFound = <String>[];
    for (var i = 0; i < dids.length; i++) {
      final did = dids[i];
      final result = okResults[i];
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
        default:
          ecu.conditional.remove(did);
      }
    }
    return newlyFound;
  }

  /// Reads one batch ([batchSize] DIDs) of [ecuId]'s discovery
  /// work. If the batch looks asleep ([batchIsAsleep]), progress does not
  /// advance and the ECU pauses for [asleepPauseDuration]; otherwise
  /// updates position/discovered/conditional, reports every newly found
  /// DID via [onHit], and returns the DIDs found OK.
  Future<List<String>> runDiscoveryBatch(String ecuId, DateTime now) async {
    final ecu = state.ecus[ecuId];
    if (ecu == null ||
        (ecu.asleepUntil != null && now.isBefore(ecu.asleepUntil!))) {
      return [];
    }
    final next = _nextBatchFor(ecuId);
    if (next == null) {
      return [];
    }
    final module = ProbeModule(
      id: ecuId,
      requestHeader: ecu.requestHeader,
      responseHeader: ecu.responseHeader,
      protocol: ecu.protocol,
    );
    final steps = [
      for (final did in next.dids)
        ProbeStep(signalId: signalIdFor(ecuId, '22$did'), command: '22$did'),
    ];
    _beginBatch([ecuId], next.dids, steps.length);
    final results = await _submitAndAwait([module], steps);
    _endWaiting();
    if (_suspended) {
      // The rejection itself is already logged; nothing to finalize -- a
      // suspended engine never gets another chance to retry this batch.
      return [];
    }
    return _finalizeBatch(ecuId, next.dids, next.fromRetry, results, now);
  }

  /// Submits one batch for each of [ecuIds] in a single
  /// [ReadExecutor.submit] call -- so the queue is topped up by several
  /// ECUs' work at once instead of one DID at a time -- then finalizes
  /// each ECU's own slice of the results independently.
  Future<void> runDiscoveryBatchGroup(List<String> ecuIds, DateTime now) async {
    final prepared = <String, ({List<String> dids, bool fromRetry})>{};
    for (final ecuId in ecuIds) {
      final next = _nextBatchFor(ecuId);
      if (next != null) {
        prepared[ecuId] = next;
      }
    }
    if (prepared.isEmpty) {
      return;
    }

    final modules = <ProbeModule>[];
    final steps = <ProbeStep>[];
    for (final entry in prepared.entries) {
      final ecu = state.ecus[entry.key]!;
      modules.add(
        ProbeModule(
          id: entry.key,
          requestHeader: ecu.requestHeader,
          responseHeader: ecu.responseHeader,
          protocol: ecu.protocol,
        ),
      );
      for (final did in entry.value.dids) {
        steps.add(
          ProbeStep(
            signalId: signalIdFor(entry.key, '22$did'),
            command: '22$did',
          ),
        );
      }
    }
    _beginBatch(
      prepared.keys.toList(),
      prepared.values.first.dids,
      steps.length,
    );
    final results = await _submitAndAwait(modules, steps);
    _endWaiting();
    if (_suspended) {
      // The rejection itself is already logged; nothing to finalize -- a
      // suspended engine never gets another chance to retry this batch.
      return;
    }

    var offset = 0;
    for (final entry in prepared.entries) {
      final count = entry.value.dids.length;
      _finalizeBatch(
        entry.key,
        entry.value.dids,
        entry.value.fromRetry,
        results.sublist(offset, offset + count),
        now,
      );
      offset += count;
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
  /// (re)discovery and names unnamed ECUs ([nameUnnamedEcus]); then groups one batch from every currently eligible
  /// ECU into a single submission -- so the executor's queue is topped
  /// up by several ECUs at once, bounded by [maxQueueDepth] -- and
  /// returns. The caller invokes this repeatedly (e.g. once per
  /// scheduler iteration) rather than draining all discovery work in one
  /// call, keeping the queue in the [minQueueDepth]-[maxQueueDepth] band
  /// over time instead of flooding it. A no-op once [suspended] -- a
  /// batch was rejected with [SubmitRejectionReason.noActiveRecording],
  /// which only a fresh engine for the next recording can recover from.
  ///
  /// Each round starts scanning known ECUs from just after wherever the
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
      if (!state.inventoryStagesDone.contains('ecus29')) {
        await runEcu29Inventory();
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
    var lastIndexConsidered = _roundRobinCursor % keys.length;
    for (var step = 0; step < keys.length; step++) {
      final index = (_roundRobinCursor + step) % keys.length;
      final ecuId = keys[index];
      lastIndexConsidered = index;
      if (!stationary && movingDiscoveryBlocked(state.ecus[ecuId]!.f197Name)) {
        continue;
      }
      if (!hasDiscoveryWork(ecuId, now)) {
        continue;
      }
      round.add(ecuId);
      if (round.length * batchSize >= maxQueueDepth) {
        break;
      }
    }
    _roundRobinCursor = (lastIndexConsidered + 1) % keys.length;
    if (round.isEmpty) {
      return;
    }
    await runDiscoveryBatchGroup(round, now);
  }
}
