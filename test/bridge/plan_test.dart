import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/bridge/vag_ppe_plan_data.dart';

void main() {
  final plan = RecordingController.buildPlanForTesting();
  final filter = GuardedCommandFilter(DidscoutPolicy());

  test('every known profile DID is read, plus the base signals', () {
    final known = vagPpeModules.fold<int>(0, (n, m) => n + m.dids.length);
    expect(plan.steps.length, known + 7);
  });

  test('signal ids are unique and name a planned module', () {
    final ids = plan.steps.map((s) => s.signalId).toList();
    expect(ids.toSet().length, ids.length);
    final modules = plan.modules.map((m) => m.moduleId).toSet();
    expect(modules.length, plan.modules.length);
    for (final step in plan.steps) {
      expect(modules, contains(step.moduleId));
      expect(step.moduleId.contains('_'), isFalse);
      expect(step.signalId, startsWith('${step.moduleId}_'));
    }
  });

  test('every command passes the hard guard and the app policy', () {
    final commands = [
      ...plan.init,
      ...plan.resync,
      for (final m in plan.modules) ...m.setup,
      for (final s in plan.steps) s.command,
    ];
    for (final command in commands) {
      expect(filter.check(command), isA<GuardAllowed>(), reason: command);
    }
  });

  test('the planned read rate stays well below the adapter limit', () {
    final readsPerSecond = plan.steps.fold<double>(
      0,
      (sum, s) => sum + 1000 / s.intervalMs,
    );
    expect(readsPerSecond, lessThan(plan.limits.maxReadsPerSecond * 0.7));
  });
}
