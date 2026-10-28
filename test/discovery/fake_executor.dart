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

  Future<void> close() => _controller.close();
}
