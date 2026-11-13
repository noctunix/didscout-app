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
    // Speed, energy, range, odometer, outside temp., charging power,
    // battery temp., the BMS's 06C7/06C8 and 22F449/22F442; none of them
    // is also a profile DID.
    expect(plan.steps.length, known + 11);
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

  test('the outside temp. is planned once, every 60 s', () {
    final steps = plan.steps.where((s) => s.signalId == 'module7_22f446');
    expect(steps, hasLength(1));
    expect(steps.single.intervalMs, 60000);
  });

  test('a discovered hcp1 DID adds neither a second hcp1 module nor a '
      'second step for a planned DID', () {
    final state = DiscoveryState();
    state.ecus['hcp1'] = EcuInfo(
      requestHeader: '18DA0FF1',
      responseHeader: '18DAF10F',
      protocol: 7,
    )..discovered.addAll({'1801', '2A2D', '2A00'});

    final withDiscovery = RecordingController.buildPlanForTesting(
      settings: const AppSettings.defaultValues().copyWith(
        recordingMode: RecordingMode.scoutAndRecordKnown,
      ),
      discoveryState: state,
    );

    final ids = withDiscovery.steps.map((s) => s.signalId).toList();
    expect(ids.where((id) => id == 'hcp1_221801'), hasLength(1));
    expect(ids.where((id) => id == 'hcp1_222a2d'), hasLength(1));
    expect(ids, contains('hcp1_222a00'));
    expect(ids.toSet().length, ids.length);
    final moduleIds = withDiscovery.modules.map((m) => m.moduleId).toList();
    expect(moduleIds.toSet().length, moduleIds.length);
  });

  test('a module that keeps answering NO DATA is held back', () {
    expect(plan.limits.quietModuleBackoffMs, quietModuleBackoffMs);
    expect(
      quietModuleBackoffMs,
      lessThan(const AppSettings.defaultValues().surveyIntervalMs),
    );
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
      'module7_22f446',
      'module6_220311',
      'vag29-7B_221e10',
      'vag29-7B_2206c7',
      'vag29-7B_2206c8',
    ];

    test('reads only speed, energy, range, odometer, outside temp., '
        'charging power, battery temp. and the BMS curve-fit DIDs', () {
      expect(scoutOnlyPlan.steps.map((s) => s.signalId), baseSignalIds);
      final intervals = {
        for (final s in scoutOnlyPlan.steps) s.signalId: s.intervalMs,
      };
      expect(intervals['module6_222ab8'], 15000);
      expect(intervals['module6_222ab6'], 60000);
      expect(intervals['module8_22f4a6'], 60000);
      expect(intervals['module7_22f446'], 60000);
      expect(intervals['module6_220311'], 10000);
      expect(intervals['vag29-7B_221e10'], 30000);
      expect(intervals['vag29-7B_2206c7'], 30000);
      expect(intervals['vag29-7B_2206c8'], 30000);
    });

    test('every command passes the hard guard and the app policy', () {
      final commands = [
        for (final m in scoutOnlyPlan.modules) ...m.setup,
        for (final s in scoutOnlyPlan.steps) s.command,
      ];
      expect(commands, contains('22F446'));
      for (final command in commands) {
        expect(filter.check(command), isA<GuardAllowed>(), reason: command);
      }
    });

    test('discovered hcp1 and tme DIDs are planned once, on one module '
        'each', () {
      final state = DiscoveryState();
      state.ecus['hcp1'] = EcuInfo(
        requestHeader: '18DA0FF1',
        responseHeader: '18DAF10F',
        protocol: 7,
      )..discovered.addAll({'1801', '2A00'});
      state.ecus['tme'] = EcuInfo(
        requestHeader: '742',
        responseHeader: '7AC',
        protocol: 6,
      )..discovered.addAll({'2609', '2A00'});

      final withDiscovery = RecordingController.buildPlanForTesting(
        discoveryState: state,
      );

      final ids = withDiscovery.steps.map((s) => s.signalId).toList();
      expect(ids.where((id) => id == 'hcp1_221801'), hasLength(1));
      expect(ids.where((id) => id == 'tme_222609'), hasLength(1));
      expect(ids, containsAll(['hcp1_222a00', 'tme_222a00']));
      expect(ids.toSet().length, ids.length);
      final moduleIds = withDiscovery.modules.map((m) => m.moduleId).toList();
      expect(moduleIds.where((id) => id == 'hcp1'), hasLength(1));
      expect(moduleIds.where((id) => id == 'tme'), hasLength(1));
      expect(moduleIds.toSet().length, moduleIds.length);
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

    test('a discovered battery management DID matching the battery temp. '
        'is planned once, on the fixed module', () {
      final state = DiscoveryState();
      state.ecus['vag29-7B'] = EcuInfo(
        requestHeader: '17FC007B',
        responseHeader: '17FE007B',
        protocol: 7,
      )..discovered.addAll({'1E10', '1E17'});

      final withDiscovery = RecordingController.buildPlanForTesting(
        discoveryState: state,
      );

      final ids = withDiscovery.steps.map((s) => s.signalId).toList();
      expect(ids.where((id) => id == 'vag29-7B_221e10'), hasLength(1));
      expect(ids, contains('vag29-7B_221e17'));
      final moduleIds = withDiscovery.modules.map((m) => m.moduleId).toList();
      expect(moduleIds.where((id) => id == 'vag29-7B'), hasLength(1));
    });

    test("a fixed step's DID found under another ECU id is not read twice", () {
      EcuInfo ecu(
        String request,
        String response,
        int protocol,
        Set<String> dids,
      ) => EcuInfo(
        requestHeader: request,
        responseHeader: response,
        protocol: protocol,
      )..discovered.addAll(dids);
      final state = DiscoveryState()
        ..ecus['ecus29-04'] = ecu('18DA04F1', '18DAF104', 7, {'F40D', 'F446'})
        ..ecus['motor-rear'] = ecu('18DA06F1', '18DAF106', 7, {'F4A6'})
        ..ecus['ecus11-710'] = ecu('710', '77A', 6, {'2AB6', '2AB8', '0311'})
        ..ecus['ecus29-7B'] = ecu('17FC007B', '17FE007B', 7, {'1E10'});

      final withDiscovery = RecordingController.buildPlanForTesting(
        discoveryState: state,
      );

      expect(withDiscovery.steps.map((s) => s.signalId), baseSignalIds);
    });

    test('plans only the fixed modules', () {
      final moduleIds = scoutOnlyPlan.modules.map((m) => m.moduleId).toSet();
      expect(moduleIds, {'module7', 'module8', 'module6', 'vag29-7B'});
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

  group('survey load budget', () {
    List<String> didsFrom(int first, int count) => [
      for (var did = first; did < first + count; did++)
        did.toRadixString(16).toUpperCase().padLeft(4, '0'),
    ];

    Map<String, int> intervalsOf(ObdPlanMessage plan) => {
      for (final s in plan.steps) s.signalId: s.intervalMs,
    };

    DiscoveryState stateWith(List<String> dids) => DiscoveryState()
      ..ecus['ecus11-7B0'] = (EcuInfo(
        requestHeader: '7B0',
        responseHeader: '7B8',
        protocol: 6,
      )..discovered.addAll(dids));

    test('a plan with many survey reads stretches the survey interval, '
        'leaving fixed and stable reads alone', () {
      // F187 is an identification DID and so stable: it does not count.
      final state = stateWith([...didsFrom(0x2000, 1000), 'F187']);

      final stretched = intervalsOf(
        RecordingController.buildPlanForTesting(discoveryState: state),
      );

      // 1000 reads x 150 ms (one BLE read; 8 reads/s would allow 125 ms)
      // may take 40 % of the read time.
      const expectedSurveyMs = 375000;
      expect(stretched['ecus11-7B0_222000'], expectedSurveyMs);
      expect(stretched['ecus11-7B0_2223e7'], expectedSurveyMs);
      expect(stretched['ecus11-7B0_22f187'], stableDidIntervalMs);
      final fixed = intervalsOf(RecordingController.buildPlanForTesting());
      for (final MapEntry(key: signalId, value: intervalMs) in fixed.entries) {
        expect(stretched[signalId], intervalMs, reason: signalId);
      }
    });

    test('a slower read cap stretches by its own read spacing', () {
      final plan = RecordingController.buildPlanForTesting(
        settings: const AppSettings.defaultValues().copyWith(
          maxReadsPerSecond: 2,
        ),
        discoveryState: stateWith(didsFrom(0x2000, 1000)),
      );

      // 1000 reads x 500 ms / 0.4.
      expect(intervalsOf(plan)['ecus11-7B0_222000'], 1250000);
    });

    test('a stable DID never drops below the stable interval, and follows '
        'a survey interval stretched beyond it', () {
      final plan = RecordingController.buildPlanForTesting(
        discoveryState: stateWith([...didsFrom(0x2000, 5000), 'F187']),
      );

      // 5000 reads x 150 ms / 0.4, past the stable interval's 30 min.
      expect(intervalsOf(plan)['ecus11-7B0_222000'], 1875000);
      expect(intervalsOf(plan)['ecus11-7B0_22f187'], 1875000);
    });

    test('a plan with few survey reads keeps the configured interval', () {
      final intervals = intervalsOf(
        RecordingController.buildPlanForTesting(
          settings: const AppSettings.defaultValues().copyWith(
            recordingMode: RecordingMode.scoutAndRecordKnown,
          ),
          discoveryState: stateWith(didsFrom(0x2000, 10)),
        ),
      );

      expect(
        intervals['module6_222a04'],
        const AppSettings.defaultValues().surveyIntervalMs,
      );
      expect(
        intervals['ecus11-7B0_222000'],
        const AppSettings.defaultValues().surveyIntervalMs,
      );
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
      expect(withoutDiscovery.steps, hasLength(known + 11));
      expect(
        withoutDiscovery.steps.map((s) => s.signalId),
        isNot(contains('ecus11-7B0_222a00')),
      );
    });
  });
}
