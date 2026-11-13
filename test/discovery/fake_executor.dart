import 'dart:async';

import 'package:didscout_app/discovery/probe.dart';

/// A [ReadExecutorRejection] test double -- an unconditional rejection with
/// whatever [reason] a test wants [FakeExecutor.submit] to throw.
class FakeRejection implements ReadExecutorRejection {
  const FakeRejection(this.reason);

  @override
  final SubmitRejectionReason reason;
}

/// A [ReadExecutor] double for discovery engine tests: delivers results
/// through [respond] (by default [ProbeNoData], so an un-stubbed step
/// doesn't hang a test) and tracks every submitted module/step for
/// assertions on ordering and module setup.
class FakeExecutor implements ReadExecutor {
  final List<ProbeModule> submittedModules = [];
  final List<ProbeStep> submittedSteps = [];

  /// Called for every submitted step; override per test to control the
  /// result. Results are delivered on a microtask so `submit()`'s caller
  /// can still register its completers first.
  ProbeResult Function(ProbeStep step) respond = (step) => ProbeResult(
    signalId: step.signalId,
    status: const ProbeNoData(),
    at: DateTime.now(),
  );

  /// Signal ids whose result is deliberately never delivered, simulating a
  /// one-shot result event the plugin lost.
  final Set<String> droppedSignalIds = {};

  /// Rejections `submit` throws instead of queuing, one per call, oldest
  /// first -- empty once a test wants submits to succeed again.
  final List<ReadExecutorRejection> rejectionsToThrow = [];

  final StreamController<ProbeResult> _controller =
      StreamController<ProbeResult>.broadcast();
  int _queueDepth = 0;

  @override
  Stream<ProbeResult> get results => _controller.stream;

  @override
  int get queueDepth => _queueDepth;

  @override
  Future<void> submit(List<ProbeModule> modules, List<ProbeStep> steps) async {
    if (rejectionsToThrow.isNotEmpty) {
      throw rejectionsToThrow.removeAt(0);
    }
    submittedModules.addAll(modules);
    submittedSteps.addAll(steps);
    for (final step in steps) {
      _queueDepth += 1;
      if (droppedSignalIds.contains(step.signalId)) {
        continue;
      }
      final result = respond(step);
      scheduleMicrotask(() {
        _queueDepth -= 1;
        _controller.add(result);
      });
    }
  }

  /// Delivers [result] as if the plugin reported it, independently of
  /// any submitted step -- e.g. a reply that arrives after its batch's
  /// deadline.
  void deliver(ProbeResult result) => _controller.add(result);

  Future<void> close() => _controller.close();
}

/// Flushes every pending microtask -- a pipelined `DiscoveryEngine.pump`
/// round finalizes each ECU's slice in the background, across the
/// `FakeExecutor.submit`/stream/completer microtask chain, after `pump`
/// itself has already returned; a test that wants to see a round's
/// results applied awaits this once before inspecting state.
Future<void> settleDiscovery() => Future<void>.delayed(Duration.zero);

/// How [simulatedEcu] answers a ReadDataByIdentifier of several DIDs.
enum MultiDidBehavior {
  /// Omits unsupported DIDs, NRC 31 only if none is supported.
  compliant,

  /// NRC 31 as soon as any requested DID is unsupported.
  rejectsAnyUnsupported,

  /// NRC 13 to any request carrying more than one DID.
  rejectsMultiple,
}

/// The DIDs a `22` [command] reads.
List<String> didsOf(String command) => [
  for (var i = 2; i < command.length; i += 4) command.substring(i, i + 4),
];

/// A [FakeExecutor.respond] for one ECU that supports exactly the DIDs in
/// [records] (DID to data record), shaped like [BridgeReadExecutor]'s
/// parsed results: a single-DID payload is the data record alone, a
/// multi-DID payload every DID echo and record after the response SID.
ProbeResult Function(ProbeStep step) simulatedEcu(
  Map<String, List<int>> records, {
  required DateTime at,
  MultiDidBehavior behavior = MultiDidBehavior.compliant,
}) => (step) {
  final dids = didsOf(step.command);
  final supported = dids.where(records.containsKey).toList();
  ProbeResult result(ProbeStatus status, [List<int>? payload]) => ProbeResult(
    signalId: step.signalId,
    status: status,
    payload: payload,
    at: at,
  );
  if (dids.length == 1) {
    return supported.isEmpty
        ? result(const ProbeNrc(0x31))
        : result(const ProbeOk(), records[dids.single]);
  }
  switch (behavior) {
    case MultiDidBehavior.rejectsMultiple:
      return result(const ProbeNrc(0x13));
    case MultiDidBehavior.rejectsAnyUnsupported
        when supported.length < dids.length:
      return result(const ProbeNrc(0x31));
    case _:
      if (supported.isEmpty) {
        return result(const ProbeNrc(0x31));
      }
      return result(const ProbeOk(), [
        for (final did in supported) ...[
          int.parse(did.substring(0, 2), radix: 16),
          int.parse(did.substring(2), radix: 16),
          ...records[did]!,
        ],
      ]);
  }
};
