import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/bridge/recording_controller.dart';
import 'package:didscout_app/bridge/vag_ppe_plan_data.dart';
import 'package:didscout_app/discovery/did_stability.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/settings/app_settings.dart';

void main() {
  final plan = RecordingController.buildPlanForTesting(
    settings: const AppSettings.defaultValues().copyWith(
      recordingMode: RecordingMode.scoutAndRecordKnown,
    ),
  );
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

  test('a failure burst resyncs and keeps recording', () {
    expect(
      plan.limits.onConsecutiveFailures,
      ObdConsecutiveFailuresPolicyMessage.resyncAndContinue,
    );
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

  group('RecordingMode.scoutOnly (the default)', () {
    final scoutOnlyPlan = RecordingController.buildPlanForTesting();

    const baseSignalIds = [
      'module7_22f40d',
      'module6_222ab8',
      'module6_222ab6',
      'module8_22f4a6',
    ];

    test('reads only speed, energy, range and odometer', () {
      expect(scoutOnlyPlan.steps.map((s) => s.signalId), baseSignalIds);
      final intervals = {
        for (final s in scoutOnlyPlan.steps) s.signalId: s.intervalMs,
      };
      expect(intervals['module6_222ab8'], 15000);
      expect(intervals['module6_222ab6'], 60000);
      expect(intervals['module8_22f4a6'], 60000);
    });

    test('a discovered gateway DID matching a base signal is planned once', () {
      final state = DiscoveryState();
      state.ecus['gateway'] = EcuInfo(
        requestHeader: '710',
        responseHeader: '77A',
        protocol: 6,
      )..discovered.addAll({'2AB8', '2A00'});

      final withDiscovery = RecordingController.buildPlanForTesting(
        discoveryState: state,
      );

      final ids = withDiscovery.steps.map((s) => s.signalId).toList();
      expect(ids.where((id) => id == 'module6_222ab8'), hasLength(1));
      expect(ids, contains('module6_222a00'));
      expect(ids.toSet().length, ids.length);
    });

    test('omits the generated vag-ppe DID modules', () {
      final moduleIds = scoutOnlyPlan.modules.map((m) => m.moduleId).toSet();
      expect(moduleIds, {'module7', 'module8', 'module6'});
    });

    test('adds discovered DIDs when keepSamplingFoundDids is on', () {
      final state = DiscoveryState();
      state.ecus['ecus11-7B0'] = EcuInfo(
        requestHeader: '7B0',
        responseHeader: '7B8',
        protocol: 6,
      )..discovered.add('2A00');

      final withDiscovery = RecordingController.buildPlanForTesting(
        discoveryState: state,
      );

      expect(
        withDiscovery.steps.map((s) => s.signalId),
        containsAll(['module7_22f40d', 'ecus11-7B0_222a00']),
      );
    });

    test('a discovered DID that kept one value is sampled at the stable '
        'interval', () {
      final state = DiscoveryState();
      state.ecus['ecus11-7B0'] =
          EcuInfo(requestHeader: '7B0', responseHeader: '7B8', protocol: 6)
            ..discovered.addAll(['2A00', '2A01', 'F187'])
            ..sampleStats['2A00'] = DidSampleStats(
              lastPayloadHash: 1,
              stableSamples: stableSampleCount,
              stableRecordings: stableRecordingCount,
            );

      final withDiscovery = RecordingController.buildPlanForTesting(
        discoveryState: state,
      );

      final intervals = {
        for (final s in withDiscovery.steps) s.signalId: s.intervalMs,
      };
      expect(intervals['ecus11-7B0_222a00'], stableDidIntervalMs);
      expect(intervals['ecus11-7B0_22f187'], stableDidIntervalMs);
      expect(
        intervals['ecus11-7B0_222a01'],
        const AppSettings.defaultValues().surveyIntervalMs,
      );
    });

    test('omits discovered DIDs when keepSamplingFoundDids is off', () {
      final state = DiscoveryState();
      state.ecus['ecus11-7B0'] = EcuInfo(
        requestHeader: '7B0',
        responseHeader: '7B8',
        protocol: 6,
      )..discovered.add('2A00');

      final withoutDiscovery = RecordingController.buildPlanForTesting(
        settings: const AppSettings.defaultValues().copyWith(
          keepSamplingFoundDids: false,
        ),
        discoveryState: state,
      );

      expect(withoutDiscovery.steps.map((s) => s.signalId), baseSignalIds);
    });
  });

  group('scout speed settings', () {
    test('the speed step interval follows speedPollIntervalS', () {
      final customPlan = RecordingController.buildPlanForTesting(
        settings: const AppSettings.defaultValues().copyWith(
          speedPollIntervalS: 25,
        ),
      );

      final speedStep = customPlan.steps.firstWhere(
        (s) => s.signalId == 'module7_22f40d',
      );
      expect(speedStep.intervalMs, 25000);
    });

    test('no ATST command is sent by default', () {
      final defaultPlan = RecordingController.buildPlanForTesting();

      expect(defaultPlan.init.any((c) => c.startsWith('ATST')), isFalse);
      expect(defaultPlan.resync.any((c) => c.startsWith('ATST')), isFalse);
    });

    test('an ATST command is appended to init and resync after the existing '
        'formatting commands when set', () {
      final customPlan = RecordingController.buildPlanForTesting(
        settings: const AppSettings.defaultValues().copyWith(
          adapterResponseTimeoutMs: 100,
        ),
      );

      expect(customPlan.init.last, 'ATST19');
      expect(customPlan.resync.last, 'ATST19');
      expect(customPlan.init.length, greaterThan(1));
    });
  });

  group('RecordingMode.scoutAndRecordKnown', () {
    test('omits discovered DIDs when keepSamplingFoundDids is off', () {
      final state = DiscoveryState();
      state.ecus['ecus11-7B0'] = EcuInfo(
        requestHeader: '7B0',
        responseHeader: '7B8',
        protocol: 6,
      )..discovered.add('2A00');

      final withoutDiscovery = RecordingController.buildPlanForTesting(
        settings: const AppSettings.defaultValues().copyWith(
          recordingMode: RecordingMode.scoutAndRecordKnown,
          keepSamplingFoundDids: false,
        ),
        discoveryState: state,
      );

      final known = vagPpeModules.fold<int>(0, (n, m) => n + m.dids.length);
      expect(withoutDiscovery.steps, hasLength(known + 7));
      expect(
        withoutDiscovery.steps.map((s) => s.signalId),
        isNot(contains('ecus11-7B0_222a00')),
      );
    });
  });
}
