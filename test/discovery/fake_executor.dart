import 'dart:async';

import 'package:didscout_app/discovery/probe.dart';

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

  final StreamController<ProbeResult> _controller =
      StreamController<ProbeResult>.broadcast();
  int _queueDepth = 0;

  @override
  Stream<ProbeResult> get results => _controller.stream;

  @override
  int get queueDepth => _queueDepth;

  @override
  Future<void> submit(List<ProbeModule> modules, List<ProbeStep> steps) async {
    submittedModules.addAll(modules);
    submittedSteps.addAll(steps);
    _queueDepth += steps.length;
    for (final step in steps) {
      final result = respond(step);
      scheduleMicrotask(() {
        _queueDepth -= 1;
        _controller.add(result);
      });
    }
  }

  Future<void> close() => _controller.close();
}
