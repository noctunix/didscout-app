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

/// Number of DIDs read per discovery batch, matching the proven CLI's
/// `RECORD_DISCOVERY_BATCH`.
const int discoveryBatchSize = 16;

/// How long a module's discovery pauses after a batch where at least half
/// the replies were NRC 11 (serviceNotSupported) -- the ECU has most
/// likely gone to sleep.
const Duration asleepPauseDuration = Duration(seconds: 60);

/// True if at least half of one discovery batch's replies were NRC 11 --
/// the signature of an ECU that stopped answering.
bool batchIsAsleep(Map<String, int> statusCounts, int batchSize) {
  if (batchSize == 0) {
    return false;
  }
  final nrc11 = statusCounts['NRC 11'] ?? 0;
  return nrc11 * 2 >= batchSize;
}

String _statusBucket(ProbeStatus status) => switch (status) {
  ProbeOk() => 'OK',
  ProbeNoData() => 'NO DATA',
  ProbeNrc(code: final code) =>
    'NRC ${code.toRadixString(16).toUpperCase().padLeft(2, '0')}',
  ProbeTimeout() => 'TIMEOUT',
  ProbeTransportError() => 'TRANSPORT_ERROR',
};

String hex3(int value) => value.toRadixString(16).toUpperCase().padLeft(3, '0');
String hex4(int value) => value.toRadixString(16).toUpperCase().padLeft(4, '0');

/// Reported once a DID scan confirms an ECU answers a given DID -- lets
/// the caller add it to its own recurring reads.
typedef DiscoveryHit =
    void Function(String ecuId, String did, List<int> payload);

/// Drives ECU inventory and DID discovery against [executor], persisting
/// progress into [state]. Motion-gates discovery per [didscout's safety
/// blocklist] (see `did_order.dart`): while moving, only scans ECUs whose
/// identified F197 name doesn't match the blocklist, and never runs ECU
/// (re)discovery.
class DiscoveryEngine {
  DiscoveryEngine({
    required this.executor,
    required this.state,
    required this.onHit,
    this.minQueueDepth = 32,
    this.maxQueueDepth = 128,
    this.sweepChunkSize = 64,
  }) {
    _subscription = executor.results.listen(_handleResult);
    _seedVagPpeEcus();
  }

  final ReadExecutor executor;
  final DiscoveryState state;
  final DiscoveryHit onHit;

  /// Lower bound the engine tries to keep the executor's queue filled to
  /// (see [pump]).
  final int minQueueDepth;

  /// Upper bound [pump] never submits past.
  final int maxQueueDepth;

  /// Max probes submitted in one inventory sweep chunk.
  final int sweepChunkSize;

  final Map<String, Completer<ProbeResult>> _pending = {};
  final Map<String, List<int>> _orderCache = {};
  late final StreamSubscription<ProbeResult> _subscription;

  void dispose() => _subscription.cancel();

  void _handleResult(ProbeResult result) {
    _pending.remove(result.signalId)?.complete(result);
  }

  Future<List<ProbeResult>> _submitAndAwait(
    List<ProbeModule> modules,
    List<ProbeStep> steps,
  ) async {
    final completers = <String, Completer<ProbeResult>>{};
    for (final step in steps) {
      completers[step.signalId] = Completer<ProbeResult>();
    }
    _pending.addAll(completers);
    await executor.submit(modules, steps);
    return [for (final step in steps) await completers[step.signalId]!.future];
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
        if (result.status is ProbeOk) {
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
        if (results[j].status is ProbeOk) {
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
      final result = results.single;
      if (did == 'F197' && result.status is ProbeOk && result.payload != null) {
        values[did] = String.fromCharCodes(result.payload!);
      } else {
        values[did] = _statusBucket(result.status);
      }
    }
    return values;
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
  /// name doesn't match [movingDiscoveryBlocked] -- ECU (re)discovery
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
        ? ecu.retryQueue.take(discoveryBatchSize).toList()
        : _orderFor(
            ecuId,
            ecu.discoverRanges,
          ).skip(ecu.scanPosition).take(discoveryBatchSize).map(hex4).toList();
    return dids.isEmpty ? null : (dids: dids, fromRetry: fromRetry);
  }

  /// Applies one completed batch's [results] (in the same order as
  /// [dids]) to [ecuId]: asleep detection, position/retry-queue
  /// advancement, discovered/conditional bookkeeping, and [onHit]
  /// reporting. Returns the DIDs found OK.
  List<String> _finalizeBatch(
    String ecuId,
    List<String> dids,
    bool fromRetry,
    List<ProbeResult> results,
    DateTime now,
  ) {
    final ecu = state.ecus[ecuId]!;
    final statusCounts = <String, int>{};
    for (final result in results) {
      final bucket = _statusBucket(result.status);
      statusCounts[bucket] = (statusCounts[bucket] ?? 0) + 1;
    }

    if (batchIsAsleep(statusCounts, dids.length)) {
      ecu.asleepUntil = now.add(asleepPauseDuration);
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
      final result = results[i];
      switch (result.status) {
        case ProbeOk():
          ecu.discovered.add(did);
          ecu.conditional.remove(did);
          newlyFound.add(did);
          onHit(ecuId, did, result.payload ?? const []);
        case ProbeNrc(code: 0x22) || ProbeNrc(code: 0x33):
          ecu.conditional.add(did);
        default:
          ecu.conditional.remove(did);
      }
    }
    return newlyFound;
  }

  /// Reads one batch ([discoveryBatchSize] DIDs) of [ecuId]'s discovery
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
    final results = await _submitAndAwait([module], steps);
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
    final results = await _submitAndAwait(modules, steps);

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

  /// One scheduler tick: while stationary, tops up any pending ECU
  /// (re)discovery; then groups one batch from every currently eligible
  /// ECU into a single submission -- so the executor's queue is topped
  /// up by several ECUs at once, bounded by [maxQueueDepth] -- and
  /// returns. The caller invokes this repeatedly (e.g. once per
  /// scheduler iteration) rather than draining all discovery work in one
  /// call, keeping the queue in the [minQueueDepth]-[maxQueueDepth] band
  /// over time instead of flooding it.
  Future<void> pump({required bool stationary, required DateTime now}) async {
    if (stationary) {
      if (!state.inventoryStagesDone.contains('ecus11')) {
        await runEcu11Inventory();
      }
      if (!state.inventoryStagesDone.contains('ecus29')) {
        await runEcu29Inventory();
      }
    }
    if (executor.queueDepth >= minQueueDepth) {
      return;
    }
    final round = <String>[];
    for (final ecuId in state.ecus.keys) {
      if (!stationary && movingDiscoveryBlocked(state.ecus[ecuId]!.f197Name)) {
        continue;
      }
      if (!hasDiscoveryWork(ecuId, now)) {
        continue;
      }
      round.add(ecuId);
      if (round.length * discoveryBatchSize >= maxQueueDepth) {
        break;
      }
    }
    if (round.isEmpty) {
      return;
    }
    await runDiscoveryBatchGroup(round, now);
  }
}
