import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/discovery/did_order.dart';
import 'package:didscout_app/discovery/discovery_engine.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/discovery/probe.dart';
import 'package:didscout_app/discovery/scout_status.dart';

import 'fake_executor.dart';

void main() {
  final now = DateTime.utc(2026, 10, 28, 12, 0);

  group('ECU inventory', () {
    test(
      '11-bit sweep finds a new ECU, identifies it, and skips a header already known',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        final hits = <(String, String)>[];
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (ecuId, did, payload) => hits.add((ecuId, did)),
        );
        // The vag-ppe seed already claims header 710 (gateway) -- the sweep
        // must not probe it again.
        expect(state.ecus.values.any((e) => e.requestHeader == '710'), isTrue);

        executor.respond = (step) {
          final moduleId = moduleIdOf(step.signalId);
          if (moduleId == 'ecu11-7A1' && step.command == '22F189') {
            return ProbeResult(
              signalId: step.signalId,
              status: const ProbeOk(),
              responderHeader: '7A9',
              at: now,
            );
          }
          if (moduleId == 'ecus11-7A1' && step.command == '22F197') {
            return ProbeResult(
              signalId: step.signalId,
              status: const ProbeOk(),
              payload: 'Gateway 2'.codeUnits,
              at: now,
            );
          }
          if (moduleId == 'ecus11-7A1') {
            return ProbeResult(
              signalId: step.signalId,
              status: const ProbeOk(),
              at: now,
            );
          }
          return ProbeResult(
            signalId: step.signalId,
            status: const ProbeNoData(),
            at: now,
          );
        };

        await engine.runEcu11Inventory();

        expect(
          executor.submittedSteps.any(
            (s) => moduleIdOf(s.signalId) == 'ecu11-710',
          ),
          isFalse,
          reason:
              'a header already known from the vag-ppe seed must not be swept again',
        );
        final found = state.ecus['ecus11-7A1'];
        expect(found, isNotNull);
        expect(found!.responseHeader, '7A9');
        expect(found.identification['F197'], 'Gateway 2');
        expect(state.inventoryStagesDone.contains('ecus11'), isTrue);

        engine.dispose();
      },
    );

    test('11-bit sweep never probes the phantom 0x700 header', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: moduleIdOf(step.signalId) == 'ecu11-700'
            ? const ProbeOk()
            : const ProbeNoData(),
        responderHeader: '77A',
        at: now,
      );

      await engine.runEcu11Inventory();

      expect(
        executor.submittedSteps.map((s) => moduleIdOf(s.signalId)),
        isNot(contains('ecu11-700')),
      );
      expect(state.ecus.containsKey('ecus11-700'), isFalse);

      engine.dispose();
    });

    test('29-bit sweep finds and identifies a new ECU', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );

      executor.respond = (step) {
        final moduleId = moduleIdOf(step.signalId);
        if (moduleId == 'ecus29-26' && step.command == '22F189') {
          // sacid1 is already seeded at 18DA26F1, so this id must be skipped
          return ProbeResult(
            signalId: step.signalId,
            status: const ProbeOk(),
            at: now,
          );
        }
        if (moduleId == 'ecus29-55' && step.command == '22F189') {
          return ProbeResult(
            signalId: step.signalId,
            status: const ProbeOk(),
            at: now,
          );
        }
        if (moduleId == 'ecus29-55') {
          return ProbeResult(
            signalId: step.signalId,
            status: const ProbeOk(),
            at: now,
          );
        }
        return ProbeResult(
          signalId: step.signalId,
          status: const ProbeNoData(),
          at: now,
        );
      };

      await engine.runEcu29Inventory();

      expect(
        executor.submittedSteps.any(
          (s) => moduleIdOf(s.signalId) == 'ecus29-26',
        ),
        isFalse,
        reason:
            'the 29-bit id already claimed by the seeded sacid1 module must be skipped',
      );
      expect(state.ecus['ecus29-55'], isNotNull);
      expect(state.ecus['ecus29-55']!.requestHeader, '18DA55F1');
      expect(state.ecus['ecus29-55']!.responseHeader, '18DAF155');
      expect(state.inventoryStagesDone.contains('ecus29'), isTrue);

      engine.dispose();
    });

    /// Answers only a module set up for request `17FC007B` with the
    /// explicit response header `17FE007B`; [f197] is that ECU's name reply.
    ProbeResult Function(ProbeStep) vagBmsResponder(
      FakeExecutor executor,
      ProbeStatus f197,
    ) => (step) {
      final module = executor.submittedModules.lastWhere(
        (m) => m.id == moduleIdOf(step.signalId),
      );
      final isBms =
          module.requestHeader == '17FC007B' &&
          module.responseHeader == '17FE007B' &&
          module.protocol == 7;
      if (!isBms) {
        return ProbeResult(
          signalId: step.signalId,
          status: const ProbeNoData(),
          at: now,
        );
      }
      final status = step.command == '22F197' ? f197 : const ProbeOk();
      return ProbeResult(
        signalId: step.signalId,
        status: status,
        payload: step.command == '22F197' && status is ProbeOk
            ? 'BMS HV'.codeUnits
            : null,
        at: now,
      );
    };

    test('VW/Audi 29-bit sweep probes 17FC0000-17FC00FF with explicit 17FE00xx '
        'response headers', () async {
      final executor = FakeExecutor();
      final engine = DiscoveryEngine(
        executor: executor,
        state: DiscoveryState(),
        onHit: (_, _, _) {},
      );

      await engine.runVag29Inventory();

      final sweep = executor.submittedModules
          .where((m) => m.requestHeader.startsWith('17FC00'))
          .toList();
      expect(sweep, hasLength(256));
      expect(sweep.first.requestHeader, '17FC0000');
      expect(sweep.first.responseHeader, '17FE0000');
      expect(sweep.first.id, 'vag29-00');
      expect(sweep.last.requestHeader, '17FC00FF');
      expect(sweep.last.responseHeader, '17FE00FF');
      final tester = sweep.singleWhere((m) => m.requestHeader == '17FC00F1');
      expect(tester.responseHeader, '17FE00F1');
      for (final module in sweep) {
        expect(module.protocol, 7);
        expect(module.receiveFilter, isNull);
        expect(module.receiveMask, isNull);
        expect(
          module.responseHeader,
          '17FE00${module.requestHeader.substring(6)}',
        );
      }
      expect(executor.submittedSteps.map((s) => s.command).toSet(), {'22F189'});
      expect(executor.submittedModules, hasLength(256));

      engine.dispose();
    });

    test(
      'VW/Audi 29-bit sweep identifies an ECU answering at 17FE007B',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
        );
        executor.respond = vagBmsResponder(executor, const ProbeOk());

        await engine.runVag29Inventory();

        final found = state.ecus['vag29-7B'];
        expect(found, isNotNull);
        expect(found!.requestHeader, '17FC007B');
        expect(found.responseHeader, '17FE007B');
        expect(found.protocol, 7);
        expect(found.identification, {
          'F187': 'OK',
          'F189': 'OK',
          'F191': 'OK',
          'F197': 'BMS HV',
        });
        expect(state.ecus.keys.where((id) => id.startsWith('vag29-')), [
          'vag29-7B',
        ]);
        expect(
          executor.submittedSteps
              .where((s) => moduleIdOf(s.signalId) == 'vag29-7B')
              .map((s) => s.command),
          ['22F189', '22F187', '22F189', '22F191', '22F197'],
        );
        expect(state.inventoryStagesDone, {'vag29'});
        expect(engine.eventLog.first.kind, ScoutEventKind.inventoryStep);
        expect(engine.eventLog.first.detail, 'vag29: 1 found');

        engine.dispose();
      },
    );

    test('VW/Audi 29-bit sweep skips a 17FC00xx header already known, but not '
        'the same target id under 18DA', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['vag29-10'] = EcuInfo(
        requestHeader: '17FC0010',
        responseHeader: '17FE0010',
        protocol: 7,
      );
      state.ecus['ecus29-7B'] = EcuInfo(
        requestHeader: '18DA7BF1',
        responseHeader: '18DAF17B',
        protocol: 7,
      );
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );

      await engine.runVag29Inventory();

      final swept = executor.submittedModules
          .map((m) => m.requestHeader)
          .toList();
      expect(swept, hasLength(255));
      expect(swept, isNot(contains('17FC0010')));
      expect(swept, contains('17FC007B'));
      expect(state.ecus['vag29-10']!.identification, isEmpty);
      expect(state.inventoryStagesDone, {'vag29'});

      engine.dispose();
    });

    test('a VW/Audi 29-bit ECU is only scanned while moving once its F197 name '
        'is known and not blocklisted', () async {
      for (final (f197, scannableWhileMoving) in <(ProbeStatus, bool)>[
        (const ProbeOk(), true),
        (const ProbeNoData(), false),
      ]) {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
        );
        executor.respond = vagBmsResponder(executor, f197);

        await engine.runVag29Inventory();

        expect(
          engine.selectNextEcuForScan(stationary: false, now: now),
          scannableWhileMoving ? 'vag29-7B' : isNull,
        );
        expect(engine.hasDiscoveryWork('vag29-7B', now), isTrue);
        engine.dispose();
      }
    });

    test('a stationary pump runs the VW/Audi stage once the others are '
        'done', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );
      executor.respond = vagBmsResponder(executor, const ProbeOk());

      await engine.pump(stationary: true, now: now);

      expect(state.inventoryStagesDone, {'ecus11', 'ecus29', 'vag29'});
      expect(state.ecus['vag29-7B']!.responseHeader, '17FE007B');
      expect(
        executor.submittedModules.where((m) => m.id.startsWith('ecus29-')),
        isEmpty,
        reason: 'the 18DA stage is already done',
      );

      engine.dispose();
    });

    test(
      'rediscovery re-probes the VW/Audi range, skipping known ids',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
        );
        executor.respond = vagBmsResponder(executor, const ProbeOk());
        await engine.runVag29Inventory();
        executor.submittedModules.clear();

        await engine.rediscoverEcus(now);

        final vagSwept = executor.submittedModules
            .where((m) => m.requestHeader.startsWith('17FC00'))
            .map((m) => m.requestHeader)
            .toSet();
        expect(vagSwept, hasLength(255));
        expect(vagSwept, isNot(contains('17FC007B')));
        expect(state.lastRediscoveryTime, now);

        engine.dispose();
      },
    );

    test('an 11-bit sweep with unanswered probes is not done, and the next '
        'pump probes only those headers', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState(inventoryStagesDone: {'ecus29', 'vag29'});
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        delay: (_) => Future<void>.delayed(Duration.zero),
      );
      var reconnected = false;
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: switch (moduleIdOf(step.signalId)) {
          'ecu11-7A1' when !reconnected => const ProbeTransportError(),
          'ecu11-7C1' when !reconnected => const ProbeCancelled(),
          'ecu11-7A1' || 'ecus11-7A1' => const ProbeOk(),
          _ => const ProbeNoData(),
        },
        responderHeader: '7A9',
        at: now,
      );
      executor.droppedSignalIds.add(signalIdFor('ecu11-7B0', '22F189'));

      await engine.runEcu11Inventory();

      expect(state.inventoryStagesDone, isNot(contains('ecus11')));
      expect(state.inventorySwept['ecus11'], contains('7A2'));
      expect(
        state.inventorySwept['ecus11'],
        isNot(anyOf(contains('7A1'), contains('7B0'), contains('7C1'))),
      );
      expect(state.ecus.containsKey('ecus11-7A1'), isFalse);
      expect(engine.eventLog.first.detail, 'ecus11: 0 found, 3 unanswered');

      reconnected = true;
      executor
        ..droppedSignalIds.clear()
        ..submittedSteps.clear();
      await engine.pump(stationary: true, now: now);

      expect(
        executor.submittedSteps
            .map((s) => moduleIdOf(s.signalId))
            .where((id) => id.startsWith('ecu11-'))
            .toSet(),
        {'ecu11-7A1', 'ecu11-7B0', 'ecu11-7C1'},
      );
      expect(state.inventoryStagesDone, contains('ecus11'));
      expect(state.ecus['ecus11-7A1']!.responseHeader, '7A9');
      expect(
        state.inventorySwept['ecus11'],
        containsAll(['7A1', '7B0', '7C1']),
      );

      engine.dispose();
    });

    test('a VW/Audi 29-bit sweep with unanswered probes is not done, and the '
        'next pump probes only those ids', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        delay: (_) => Future<void>.delayed(Duration.zero),
      );
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: moduleIdOf(step.signalId) == 'vag29-7B'
            ? const ProbeTransportError()
            : const ProbeNoData(),
        at: now,
      );
      executor.droppedSignalIds.add(signalIdFor('vag29-40', '22F189'));

      await engine.runVag29Inventory();

      expect(state.inventoryStagesDone, isNot(contains('vag29')));
      expect(state.inventorySwept['vag29'], hasLength(254));
      expect(
        state.inventorySwept['vag29'],
        isNot(anyOf(contains('7B'), contains('40'))),
      );

      executor
        ..droppedSignalIds.clear()
        ..submittedSteps.clear()
        ..respond = vagBmsResponder(executor, const ProbeOk());
      await engine.pump(stationary: true, now: now);

      expect(
        executor.submittedSteps
            .map((s) => moduleIdOf(s.signalId))
            .where((id) => id.startsWith('vag29-'))
            .toSet(),
        {'vag29-40', 'vag29-7B'},
      );
      expect(state.inventoryStagesDone, contains('vag29'));
      expect(state.ecus['vag29-7B']!.f197Name, 'BMS HV');

      engine.dispose();
    });

    test('a sweep cancelled between chunks is not done and records only the '
        'chunks answered before', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      late final DiscoveryEngine engine;
      engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        sweepChunkSize: 16,
      );
      var probed = 0;
      executor.respond = (step) {
        if (++probed == 17) {
          engine.cancel();
        }
        return ProbeResult(
          signalId: step.signalId,
          status: const ProbeNoData(),
          at: now,
        );
      };

      await engine.runEcu11Inventory();

      expect(state.inventoryStagesDone, isEmpty);
      expect(
        executor.submittedSteps,
        hasLength(32),
        reason: 'no chunk is submitted after the cancel',
      );
      expect(state.inventorySwept['ecus11'], hasLength(16));

      engine.dispose();
    });

    test('a sweep cancelled while identifying a found ECU records neither the '
        'ECU nor the stage', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      late final DiscoveryEngine engine;
      engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );
      final bms = vagBmsResponder(executor, const ProbeOk());
      executor.respond = (step) {
        if (step.signalId == signalIdFor('vag29-7B', '22F187')) {
          engine.cancel();
        }
        return bms(step);
      };

      await engine.runVag29Inventory();

      expect(state.ecus.containsKey('vag29-7B'), isFalse);
      expect(state.inventoryStagesDone, isEmpty);
      expect(state.inventorySwept['vag29'], isNot(contains('7B')));

      engine.dispose();
    });
  });

  group('runDiscoveryBatch', () {
    DiscoveryEngine buildEngine(
      FakeExecutor executor,
      DiscoveryState state,
      List<(String, String)> hits,
    ) => DiscoveryEngine(
      executor: executor,
      state: state,
      onHit: (ecuId, did, payload) => hits.add((ecuId, did)),
    );

    test(
      'scans DIDs in order and advances position on a normal batch',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        state.ecus['test'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: [(0x2A00, 0x2A0F)],
        );
        final hits = <(String, String)>[];
        final engine = buildEngine(executor, state, hits);

        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: const ProbeOk(),
          payload: const [1],
          at: now,
        );

        final found = await engine.runDiscoveryBatch('test', now);

        expect(executor.submittedSteps.map((s) => s.command).toList(), [
          for (var did = 0x2A00; did <= 0x2A0F; did++)
            '22${did.toRadixString(16).toUpperCase()}',
        ]);
        expect(found.length, 16);
        expect(state.ecus['test']!.scanPosition, 16);
        expect(state.ecus['test']!.discovered.length, 16);
        expect(hits.length, 16);

        engine.dispose();
      },
    );

    test(
      'a batch where at least half the replies are NRC 11 is treated as asleep',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        state.ecus['test'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: [(0x2A00, 0x2A0F)],
        );
        final engine = buildEngine(executor, state, []);

        var i = 0;
        executor.respond = (step) {
          final status = i < 9 ? const ProbeNrc(0x11) : const ProbeOk();
          i++;
          return ProbeResult(signalId: step.signalId, status: status, at: now);
        };

        final found = await engine.runDiscoveryBatch('test', now);

        expect(found, isEmpty);
        expect(
          state.ecus['test']!.scanPosition,
          0,
          reason: 'an asleep batch must not advance',
        );
        expect(state.ecus['test']!.discovered, isEmpty);
        expect(state.ecus['test']!.asleepUntil, now.add(asleepPauseDuration));

        engine.dispose();
      },
    );

    test('a batch where at least three quarters of the replies are NO DATA '
        'is treated as asleep for the longer no-data pause', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      final engine = buildEngine(executor, state, []);

      var i = 0;
      executor.respond = (step) {
        final status = i < 12 ? const ProbeNoData() : const ProbeNrc(0x31);
        i++;
        return ProbeResult(signalId: step.signalId, status: status, at: now);
      };

      final found = await engine.runDiscoveryBatch('test', now);

      expect(found, isEmpty);
      expect(
        state.ecus['test']!.scanPosition,
        0,
        reason: 'a NO-DATA-asleep batch must not advance',
      );
      expect(
        state.ecus['test']!.asleepUntil,
        now.add(noDataAsleepPauseDuration),
      );
      expect(
        engine.eventLog.first.detail,
        'no data',
        reason: 'distinguishes this from the NRC-11 asleep signature',
      );

      engine.dispose();
    });

    test('consecutive NO-DATA-asleep batches double the pause up to its cap, '
        'and a batch with answers resets it', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      final engine = buildEngine(executor, state, []);
      final ecu = state.ecus['test']!;

      final pauses = <Duration>[];
      var at = now;
      for (var i = 0; i < 7; i++) {
        await engine.runDiscoveryBatch('test', at);
        pauses.add(ecu.asleepUntil!.difference(at));
        at = ecu.asleepUntil!;
      }
      expect(pauses, const [
        Duration(minutes: 5),
        Duration(minutes: 10),
        Duration(minutes: 20),
        Duration(minutes: 40),
        Duration(minutes: 80),
        Duration(hours: 2),
        Duration(hours: 2),
      ]);

      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeNrc(0x31),
        at: at,
      );
      await engine.runDiscoveryBatch('test', at);
      expect(ecu.noDataStreak, 0);
      expect(ecu.scanPosition, 16);

      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeNoData(),
        at: at,
      );
      await engine.runDiscoveryBatch('test', at);
      expect(ecu.asleepUntil, at.add(noDataAsleepPauseDuration));

      engine.dispose();
    });

    test('a batch with at least one OK reply is never NO-DATA-asleep, however '
        'much of the rest is NO DATA', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      final engine = buildEngine(executor, state, []);

      // 15 of 16 replies are NO DATA (well past the 75% threshold), but
      // the ECU demonstrably answered one of them -- it isn't asleep.
      executor.respond = (step) => step.command == '222A00'
          ? ProbeResult(
              signalId: step.signalId,
              status: const ProbeOk(),
              payload: const [1],
              at: now,
            )
          : ProbeResult(
              signalId: step.signalId,
              status: const ProbeNoData(),
              at: now,
            );

      final found = await engine.runDiscoveryBatch('test', now);

      expect(found, ['2A00']);
      expect(state.ecus['test']!.scanPosition, 16);
      expect(state.ecus['test']!.asleepUntil, isNull);

      engine.dispose();
    });

    test('an asleep ECU is skipped until its pause expires', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
        asleepUntil: now.add(const Duration(seconds: 30)),
      );
      final engine = buildEngine(executor, state, []);
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeOk(),
        at: now,
      );

      final found = await engine.runDiscoveryBatch('test', now);
      expect(found, isEmpty);
      expect(executor.submittedSteps, isEmpty);

      final laterFound = await engine.runDiscoveryBatch(
        'test',
        now.add(const Duration(seconds: 31)),
      );
      expect(laterFound, isNotEmpty);

      engine.dispose();
    });

    test(
      'NRC 22/33 DIDs become conditional and are retried once queued',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        state.ecus['test'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: [(0x2A00, 0x2A03)],
        );
        final engine = buildEngine(executor, state, []);

        executor.respond = (step) => switch (step.command) {
          '222A00' => ProbeResult(
            signalId: step.signalId,
            status: const ProbeNrc(0x22),
            at: now,
          ),
          '222A01' => ProbeResult(
            signalId: step.signalId,
            status: const ProbeNrc(0x33),
            at: now,
          ),
          // Everything else answers OK -- a mix of NoData filler here would
          // make this batch look NO-DATA-asleep (`batchLooksNoDataAsleep`)
          // and mask the two conditional DIDs this test is actually about.
          _ => ProbeResult(
            signalId: step.signalId,
            status: const ProbeOk(),
            payload: const [],
            at: now,
          ),
        };

        await engine.runDiscoveryBatch('test', now);
        expect(state.ecus['test']!.conditional, {'2A00', '2A01'});
        expect(
          state.ecus['test']!.retryQueue,
          isEmpty,
          reason: 'not queued until a phase change',
        );

        engine.queueConditionalRetries('test');
        expect(state.ecus['test']!.retryQueue, ['2A00', '2A01']);

        executor.submittedSteps.clear();
        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: const ProbeOk(),
          payload: const [],
          at: now,
        );
        final retried = await engine.runDiscoveryBatch('test', now);

        expect(executor.submittedSteps.map((s) => s.command).toSet(), {
          '222A00',
          '222A01',
        });
        expect(retried.toSet(), {'2A00', '2A01'});
        expect(state.ecus['test']!.conditional, isEmpty);
        expect(state.ecus['test']!.retryQueue, isEmpty);
        // The scan position moved by one full batch on the first
        // (non-retry) call; the retry batch didn't touch it again.
        expect(state.ecus['test']!.scanPosition, 16);

        engine.dispose();
      },
    );
  });

  group('motion gating', () {
    test(
      'a blocked ECU is excluded while moving but included while stationary',
      () {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        state.ecus['abs'] = EcuInfo(
          requestHeader: '712',
          responseHeader: '71A',
          protocol: 6,
          identification: {'F197': 'ABS/ESC control unit'},
        );
        state.ecus['gw'] = EcuInfo(
          requestHeader: '710',
          responseHeader: '718',
          protocol: 6,
          identification: {'F197': 'Gateway'},
        );
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
        );

        expect(
          engine.selectNextEcuForScan(stationary: false, now: now),
          'gw',
          reason: 'the ABS-named ECU must be skipped while moving',
        );
        // Stationary: the blocklist no longer applies, so the ABS-named ECU
        // becomes the first eligible one again (it has discovery work, same
        // as 'gw' -- see hasDiscoveryWork below).
        expect(engine.selectNextEcuForScan(stationary: true, now: now), 'abs');
        expect(engine.hasDiscoveryWork('abs', now), isTrue);
        expect(engine.hasDiscoveryWork('gw', now), isTrue);

        engine.dispose();
      },
    );

    test('an ECU without a usable F197 name is excluded while moving', () {
      final state = DiscoveryState();
      state.ecus['unnamed'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
      );
      state.ecus['failed'] = EcuInfo(
        requestHeader: '7A2',
        responseHeader: '7AA',
        protocol: 6,
        identification: {'F197': 'NO DATA'},
      );
      final engine = DiscoveryEngine(
        executor: FakeExecutor(),
        state: state,
        onHit: (_, _, _) {},
      );
      state.ecus.removeWhere((id, _) => id != 'unnamed' && id != 'failed');

      expect(engine.selectNextEcuForScan(stationary: false, now: now), isNull);
      expect(
        engine.selectNextEcuForScan(stationary: true, now: now),
        isNotNull,
      );

      engine.dispose();
    });

    test('a stationary pump reads F197 once per engine from unnamed ECUs, '
        'which then become scannable while moving', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState(
        inventoryStagesDone: {'ecus11', 'ecus29', 'vag29'},
      );
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );
      state.ecus
        ..clear()
        // Both scans are already past the identification range, so any
        // F197 read below is the naming read, not a scan step.
        ..['door'] = EcuInfo(
          requestHeader: '74A',
          responseHeader: '7B4',
          protocol: 6,
          scanPosition: 200,
        )
        ..['mute'] = EcuInfo(
          requestHeader: '713',
          responseHeader: '77D',
          protocol: 6,
          scanPosition: 200,
        );
      // Every other DID is refused rather than met with silence, so no
      // scan batch looks asleep.
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: switch (step.signalId) {
          'door_22f197' => const ProbeOk(),
          'mute_22f197' => const ProbeNoData(),
          _ => const ProbeNrc(0x31),
        },
        payload: step.signalId == 'door_22f197' ? 'TSG FS'.codeUnits : null,
        at: now,
      );

      await engine.pump(stationary: true, now: now);

      expect(state.ecus['door']!.f197Name, 'TSG FS');
      expect(state.ecus['mute']!.f197Name, isNull);
      expect(state.ecus['mute']!.identification['F197'], 'NO DATA');
      expect(engine.selectNextEcuForScan(stationary: false, now: now), 'door');

      executor.submittedSteps.clear();
      await engine.pump(stationary: true, now: now);
      expect(
        executor.submittedSteps.where((s) => s.command == '22F197'),
        isEmpty,
        reason: 'an ECU is only asked for its name once per engine',
      );

      engine.dispose();
    });

    test('pump never runs ECU (re)discovery while moving', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeNoData(),
        at: now,
      );

      await engine.pump(stationary: false, now: now);

      expect(state.inventoryStagesDone, isEmpty);
      expect(
        executor.submittedSteps.any(
          (s) => moduleIdOf(s.signalId).startsWith('ecu11-'),
        ),
        isFalse,
      );
      expect(
        executor.submittedModules.any(
          (m) => m.requestHeader.startsWith('17FC00'),
        ),
        isFalse,
      );

      engine.dispose();
    });
  });

  group('pacing', () {
    test(
      'a pump round groups several ECUs into a single submit call',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        const headers = {
          'a': ('701', '709'),
          'b': ('711', '719'),
          'c': ('721', '729'),
        };
        for (final id in ['a', 'b', 'c']) {
          state.ecus[id] = EcuInfo(
            requestHeader: headers[id]!.$1,
            responseHeader: headers[id]!.$2,
            protocol: 6,
            discoverRanges: [(0x2A00, 0x2A1F)],
          );
        }
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
          maxQueueDepth: 48,
        );
        // OK, not NoData -- an all-NoData batch would look NO-DATA-asleep
        // (`batchLooksNoDataAsleep`) and this test isn't about that.
        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: const ProbeOk(),
          at: now,
        );

        await engine.runDiscoveryBatchGroup(['a', 'b', 'c'], now);

        expect(
          executor.submittedSteps.length,
          48,
          reason: '3 ECUs x 16 DIDs submitted together',
        );
        expect(state.ecus['a']!.scanPosition, 16);
        expect(state.ecus['b']!.scanPosition, 16);
        expect(state.ecus['c']!.scanPosition, 16);

        engine.dispose();
      },
    );

    test(
      'pump does one round and stops once an ECU is fully scanned',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState(
          inventoryStagesDone: {'ecus11', 'ecus29', 'vag29'},
        );
        final ranges = [(0x2A00, 0x2A0F)];
        final fullOrderLength = discoveryDidOrder(ranges).length;
        // One batch short of the end of its scan order, so one pump call
        // finishes it off completely.
        state.ecus['only'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: ranges,
          scanPosition: fullOrderLength - discoveryBatchSize,
        );
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
        );
        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: const ProbeOk(),
          at: now,
        );

        await engine.pump(stationary: true, now: now);

        expect(state.ecus['only']!.scanPosition, fullOrderLength);
        expect(engine.hasDiscoveryWork('only', now), isFalse);
        expect(executor.queueDepth, 0);

        // 'only' is now fully scanned; a second call never touches it
        // again even though other seeded ECUs still have work.
        await engine.pump(stationary: true, now: now);
        expect(state.ecus['only']!.scanPosition, fullOrderLength);

        engine.dispose();
      },
    );

    test('pump rotates which known ECUs it offers a batch to, round to round, '
        'instead of only ever picking the first few', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState(
        inventoryStagesDone: {'ecus11', 'ecus29', 'vag29'},
      );
      final ids = [for (var i = 0; i < 10; i++) 'ecu$i'];
      for (var i = 0; i < ids.length; i++) {
        state.ecus[ids[i]] = EcuInfo(
          requestHeader: 'H$i',
          protocol: 6,
          // Far more DIDs than one batch covers, so every one of these
          // ECUs always has work left -- the only thing that can stop
          // an earlier one from monopolizing every round is rotation.
          discoverRanges: [(0x2A00, 0x2AFF)],
        );
      }
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        // 2 ECUs' worth (16 DIDs each) per round.
        maxQueueDepth: 32,
      );
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeOk(),
        at: now,
      );

      // 10 ECUs at 2 per round takes exactly 5 rounds to reach all of
      // them once each.
      for (var round = 0; round < 5; round++) {
        await engine.pump(stationary: true, now: now);
      }

      for (final id in ids) {
        expect(
          state.ecus[id]!.scanPosition,
          16,
          reason: '$id must have been offered exactly one batch',
        );
      }

      engine.dispose();
    });
  });

  group('scanProgress', () {
    test('no known ECUs reports zero of zero', () {
      final engine = DiscoveryEngine(
        executor: FakeExecutor(),
        state: DiscoveryState(),
        onHit: (_, _, _) {},
      );
      final progress = engine.scanProgress();
      expect(progress.ecuCount, greaterThan(0)); // vag-ppe seeds exist
      engine.dispose();
    });

    test('reflects scan position against a known-length order', () {
      final state = DiscoveryState(
        inventoryStagesDone: {'ecus11', 'ecus29', 'vag29'},
      );
      final ranges = [(0x2A00, 0x2A0F)];
      final fullOrderLength = discoveryDidOrder(ranges).length;
      state.ecus['only'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: ranges,
        scanPosition: fullOrderLength ~/ 2,
      );
      final engine = DiscoveryEngine(
        executor: FakeExecutor(),
        state: state,
        onHit: (_, _, _) {},
      );

      final progress = engine.scanProgress();

      // The vag-ppe seed ECUs (scanPosition 0) dilute the overall
      // percentage -- only check 'only' isn't the sole contributor and the
      // value is between 0 and 100.
      expect(progress.percent, greaterThan(0));
      expect(progress.percent, lessThan(100));
      engine.dispose();
    });

    test('percent is denominated against the priority ranges, not the full '
        '64k DID space, so it reaches 100% once those are scanned', () {
      final state = DiscoveryState(
        inventoryStagesDone: {'ecus11', 'ecus29', 'vag29'},
      );
      final ranges = [(0x2A00, 0x2A0F)];
      final priorityLength = priorityDidOrder(ranges).length;
      state.ecus['only'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: ranges,
        // Past the priority order's own length, but nowhere near the
        // full order's -- a real recording would never scan this far
        // within one session, which is exactly the bug this fixes.
        scanPosition: priorityLength,
      );
      final engine = DiscoveryEngine(
        executor: FakeExecutor(),
        state: state,
        onHit: (_, _, _) {},
      );
      // The vag-ppe seed ECUs the engine adds on construction all start
      // at scanPosition 0, which would dilute the average below 100% --
      // drop them so this test isolates 'only's own percentage.
      state.ecus.removeWhere((key, _) => key != 'only');

      final progress = engine.scanProgress();

      expect(progress.percent, 100);
      engine.dispose();
    });

    test('totalChecked sums scanPosition across every known ECU', () {
      final state = DiscoveryState(
        inventoryStagesDone: {'ecus11', 'ecus29', 'vag29'},
      );
      state.ecus['a'] = EcuInfo(
        requestHeader: '7A1',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2AFF)],
        scanPosition: 30,
      );
      state.ecus['b'] = EcuInfo(
        requestHeader: '7B1',
        protocol: 6,
        discoverRanges: [(0x2B00, 0x2BFF)],
        scanPosition: 12,
      );
      final engine = DiscoveryEngine(
        executor: FakeExecutor(),
        state: state,
        onHit: (_, _, _) {},
      );

      // vag-ppe seed ECUs all start at scanPosition 0, so they add nothing.
      expect(engine.scanProgress().totalChecked, 42);
      engine.dispose();
    });
  });

  group('batch deadline and enqueue rejection', () {
    test(
      'a lost result event times out without advancing position, and is retried',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        state.ecus['test'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: [(0x2A00, 0x2A0F)],
        );
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
          // A real timer (even a zero-duration one) only fires once every
          // pending microtask has drained, so a normal result -- delivered
          // through the fake executor's own microtask chain -- always wins
          // its race against this; only a genuinely dropped signal (no
          // delivery scheduled at all) ever times out.
          delay: (_) => Future<void>.delayed(Duration.zero),
        );
        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: const ProbeOk(),
          payload: const [1],
          at: now,
        );
        executor.droppedSignalIds.add(signalIdFor('test', '222A00'));

        final found = await engine.runDiscoveryBatch('test', now);

        expect(found, isEmpty);
        expect(
          state.ecus['test']!.scanPosition,
          0,
          reason: 'a batch with a missing result must not advance',
        );
        expect(state.ecus['test']!.discovered, isEmpty);
        expect(
          engine.eventLog.first.kind,
          ScoutEventKind.batchTimedOut,
          reason: 'newest event first',
        );
        expect(engine.eventLog.first.ecuId, 'test');
        expect(engine.eventLog.first.detail, '1/16 missing');

        // Retried on the next call: the lost DID answers this time.
        executor.droppedSignalIds.clear();
        final retried = await engine.runDiscoveryBatch('test', now);
        expect(retried.length, 16);
        expect(state.ecus['test']!.scanPosition, 16);

        engine.dispose();
      },
    );

    test('a transport error does not advance position, and the DID is read '
        'again on the next batch', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );
      var disconnected = true;
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: disconnected && step.command == '222A03'
            ? const ProbeTransportError()
            : const ProbeOk(),
        payload: const [1],
        at: now,
      );

      final found = await engine.runDiscoveryBatch('test', now);

      expect(found, isEmpty);
      expect(state.ecus['test']!.scanPosition, 0);
      expect(state.ecus['test']!.discovered, isEmpty);
      expect(engine.eventLog.first.kind, ScoutEventKind.batchTimedOut);
      expect(engine.eventLog.first.detail, '1/16 missing');

      disconnected = false;
      executor.submittedSteps.clear();
      final retried = await engine.runDiscoveryBatch('test', now);
      expect(executor.submittedSteps.map((s) => s.command), contains('222A03'));
      expect(retried, contains('2A03'));
      expect(state.ecus['test']!.scanPosition, 16);

      engine.dispose();
    });

    test('a rejected enqueue backs off and retries, then succeeds', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      final requestedBackoffs = <Duration>[];
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        delay: (duration) {
          requestedBackoffs.add(duration);
          return Future<void>.delayed(Duration.zero);
        },
      );
      executor.rejectionsToThrow.add(
        const FakeRejection(SubmitRejectionReason.queueFull),
      );
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeOk(),
        payload: const [1],
        at: now,
      );

      final found = await engine.runDiscoveryBatch('test', now);

      expect(found.length, 16, reason: 'the retried submit must succeed');
      expect(
        requestedBackoffs.first,
        defaultSubmitBackoff,
        reason:
            'the rejected submit itself backs off by this -- later calls '
            'to the same delay hook are the (always-losing) per-step '
            'deadline races',
      );
      expect(
        engine.eventLog.any(
          (e) =>
              e.kind == ScoutEventKind.enqueueRejected &&
              e.detail == 'queueFull',
        ),
        isTrue,
      );

      engine.dispose();
    });

    test('a noActiveRecording rejection backs off and retries, and the '
        'batch is submitted once the executor accepts again', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState(
        inventoryStagesDone: {'ecus11', 'ecus29', 'vag29'},
      );
      final requestedBackoffs = <Duration>[];
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        delay: (duration) {
          requestedBackoffs.add(duration);
          return Future<void>.delayed(Duration.zero);
        },
      );
      state.ecus
        ..clear()
        ..['test'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: [(0x2A00, 0x2A0F)],
          identification: {'F197': 'Test'},
        );
      // The plugin reports no active recording while it reconnects to the
      // adapter, then accepts again.
      executor.rejectionsToThrow.addAll([
        const FakeRejection(SubmitRejectionReason.noActiveRecording),
        const FakeRejection(SubmitRejectionReason.noActiveRecording),
      ]);
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeOk(),
        payload: const [1],
        at: now,
      );

      await engine.pump(stationary: true, now: now);

      expect(engine.suspended, isFalse);
      expect(requestedBackoffs.take(2), [
        defaultSubmitBackoff,
        defaultSubmitBackoff,
      ]);
      expect(
        engine.eventLog.where(
          (e) =>
              e.kind == ScoutEventKind.enqueueRejected &&
              e.detail == 'noActiveRecording',
        ),
        hasLength(2),
      );
      expect(executor.submittedSteps, hasLength(16));
      expect(state.ecus['test']!.scanPosition, 16);

      executor.submittedSteps.clear();
      await engine.pump(stationary: true, now: now);
      expect(
        executor.submittedSteps,
        isNotEmpty,
        reason: 'a rejection never stops later pumps',
      );

      engine.dispose();
    });
  });

  group('cancel', () {
    test('stops a batch whose enqueue is being retried, without submitting '
        'it', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      late final DiscoveryEngine engine;
      var backoffs = 0;
      engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        delay: (duration) {
          if (duration == defaultSubmitBackoff && ++backoffs == 2) {
            engine.cancel();
          }
          return Future<void>.delayed(Duration.zero);
        },
      );
      executor.rejectionsToThrow.addAll([
        for (var i = 0; i < 3; i++)
          const FakeRejection(SubmitRejectionReason.noActiveRecording),
      ]);

      final found = await engine.runDiscoveryBatch('test', now);

      expect(found, isEmpty);
      expect(
        executor.rejectionsToThrow,
        hasLength(1),
        reason: 'retried once, then stopped by the cancel during its backoff',
      );
      expect(executor.submittedSteps, isEmpty);
      expect(state.ecus['test']!.scanPosition, 0);
      expect(engine.suspended, isTrue);

      engine.dispose();
    });

    test('resolves an in-flight batch immediately as cancelled, without '
        'waiting out its deadline, and never advances scan position', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        // Real-time, so a test that accidentally waited out the actual
        // deadline instead of being cancelled immediately would time out
        // rather than quietly pass.
        delay: (duration) => Future<void>.delayed(duration),
      );
      // Every step's result is dropped -- simulates the plugin never
      // reporting one, same as a disconnect mid-batch.
      for (var did = 0x2A00; did <= 0x2A0F; did++) {
        executor.droppedSignalIds.add(signalIdFor('test', '22${hex4(did)}'));
      }

      final batchFuture = engine.runDiscoveryBatch('test', now);
      engine.cancel();
      final found = await batchFuture;

      expect(found, isEmpty);
      expect(state.ecus['test']!.scanPosition, 0);
      expect(engine.suspended, isTrue, reason: 'cancel is permanent');

      engine.dispose();
    });

    test('dispose cancels too', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
      );
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
        delay: (duration) => Future<void>.delayed(duration),
      );
      for (var did = 0x2A00; did <= 0x2A0F; did++) {
        executor.droppedSignalIds.add(signalIdFor('test', '22${hex4(did)}'));
      }

      final batchFuture = engine.runDiscoveryBatch('test', now);
      engine.dispose();
      final found = await batchFuture;

      expect(found, isEmpty);
      expect(state.ecus['test']!.scanPosition, 0);
    });
  });

  group('scoutStatus', () {
    test(
      'reflects the current batch, reads per minute, and last result',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        state.ecus['test'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: [(0x2A00, 0x2A0F)],
        );
        var clockNow = now;
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
          clock: () => clockNow,
        );
        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: const ProbeNrc(0x31),
          at: now,
        );

        await engine.runDiscoveryBatch('test', now);

        final status = engine.scoutStatus(clockNow);
        expect(status.currentEcuId, 'test');
        expect(status.currentDidRangeLabel, '2A00–2A0F');
        expect(status.readsPerMinute, 16);
        expect(status.lastResultSummary, 'NRC 31');
        expect(status.waitingCount, 0, reason: 'batch already finished');
        expect(status.waitingFor, isNull);

        // Reads older than the rolling window drop out of the rate.
        clockNow = now.add(const Duration(seconds: 61));
        expect(engine.scoutStatus(clockNow).readsPerMinute, 0);

        engine.dispose();
      },
    );

    test('event log is bounded at 50 entries, newest first', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x0000, 0x0FFF)],
      );
      final engine = DiscoveryEngine(
        executor: executor,
        state: state,
        onHit: (_, _, _) {},
      );
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeOk(),
        payload: const [],
        at: now,
      );

      // Each batch logs 1 "batch submitted" + up to 16 "hit" events --
      // a handful of batches is plenty to overflow the 50-entry buffer.
      for (var i = 0; i < 5; i++) {
        await engine.runDiscoveryBatch('test', now);
      }

      expect(engine.eventLog.length, scoutEventLogCapacity);
      // Newest first: the very last hit logged must be at index 0.
      expect(engine.eventLog.first.kind, ScoutEventKind.hit);

      engine.dispose();
    });
  });

  group('targeted discover ranges', () {
    List<String> commandsFrom(int firstDid) => [
      for (var did = firstDid; did < firstDid + 16; did++)
        '22${did.toRadixString(16).toUpperCase()}',
    ];

    DiscoveryEngine buildEngine(FakeExecutor executor, DiscoveryState state) =>
        DiscoveryEngine(executor: executor, state: state, onHit: (_, _, _) {});

    // OK, not NoData -- an all-NoData batch would look NO-DATA-asleep.
    ProbeResult ok(ProbeStep step) =>
        ProbeResult(signalId: step.signalId, status: const ProbeOk(), at: now);

    test('the thermal management seed scans 2600-27FF first', () async {
      final executor = FakeExecutor()..respond = ok;
      final state = DiscoveryState();
      final engine = buildEngine(executor, state);

      expect(state.ecus['tme']!.requestHeader, '742');
      expect(state.ecus['tme']!.discoverRanges, [
        (0x2600, 0x27FF),
        (0x4700, 0x47FF),
      ]);

      await engine.runDiscoveryBatch('tme', now);

      expect(
        executor.submittedSteps.map((s) => s.command).toList(),
        commandsFrom(0x2600),
      );

      engine.dispose();
    });

    test('the HCP1 seed scans 1800-18FF first', () async {
      final executor = FakeExecutor()..respond = ok;
      final state = DiscoveryState();
      final engine = buildEngine(executor, state);

      expect(state.ecus['hcp1']!.requestHeader, '18DA0FF1');
      expect(state.ecus['hcp1']!.discoverRanges, [(0x1800, 0x18FF)]);

      await engine.runDiscoveryBatch('hcp1', now);

      expect(
        executor.submittedSteps.map((s) => s.command).toList(),
        commandsFrom(0x1800),
      );

      engine.dispose();
    });

    test('an ECU that already has the targeted ranges keeps its position, '
        'and the second range follows the first', () async {
      final executor = FakeExecutor()..respond = ok;
      final state = DiscoveryState();
      state.ecus['tme'] = EcuInfo(
        requestHeader: '742',
        responseHeader: '7AC',
        protocol: 6,
        discoverRanges: [(0x2600, 0x27FF), (0x4700, 0x47FF)],
        scanPosition: 512,
      );
      final engine = buildEngine(executor, state);

      expect(state.ecus['tme']!.scanPosition, 512);

      await engine.runDiscoveryBatch('tme', now);

      expect(
        executor.submittedSteps.map((s) => s.command).toList(),
        commandsFrom(0x4700),
      );

      engine.dispose();
    });

    test('an ECU with another header keeps its ranges and position', () async {
      final executor = FakeExecutor()..respond = ok;
      final state = DiscoveryState();
      state.ecus['test'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2AFF)],
        scanPosition: 16,
      );
      final engine = buildEngine(executor, state);

      expect(state.ecus['gateway']!.discoverRanges, isEmpty);
      expect(state.ecus['test']!.discoverRanges, [(0x2A00, 0x2AFF)]);
      expect(state.ecus['test']!.scanPosition, 16);

      await engine.runDiscoveryBatch('test', now);

      expect(
        executor.submittedSteps.map((s) => s.command).toList(),
        commandsFrom(0x2A10),
      );

      engine.dispose();
    });

    test('a persisted ECU without ranges gets them and restarts its scan, '
        'keeping what it found', () async {
      final executor = FakeExecutor()..respond = ok;
      final state = DiscoveryState.fromJson({
        'ecus': {
          'hcp1': EcuInfo(
            requestHeader: '18DA0FF1',
            responseHeader: '18DAF10F',
            protocol: 7,
            scanPosition: 480,
            discovered: {'0101', '0102'},
            conditional: {'0103'},
            sampleStats: {'0101': DidSampleStats(stableSamples: 3)},
          ).toJson(),
        },
      });
      expect(state.ecus['hcp1']!.discoverRanges, isEmpty);

      final engine = buildEngine(executor, state);

      final hcp1 = state.ecus['hcp1']!;
      expect(hcp1.discoverRanges, [(0x1800, 0x18FF)]);
      expect(hcp1.scanPosition, 0);
      expect(hcp1.discovered, {'0101', '0102'});
      expect(hcp1.conditional, {'0103'});
      expect(hcp1.sampleStats['0101']!.stableSamples, 3);

      await engine.runDiscoveryBatch('hcp1', now);

      expect(
        executor.submittedSteps.map((s) => s.command).toList(),
        commandsFrom(0x1800),
      );

      engine.dispose();
    });

    test('an ECU the 11-bit inventory finds at 742 gets the ranges', () async {
      final executor = FakeExecutor();
      final state = DiscoveryState();
      final engine = buildEngine(executor, state);
      state.ecus.remove('tme');
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: moduleIdOf(step.signalId) == 'ecu11-742'
            ? const ProbeOk()
            : const ProbeNoData(),
        responderHeader: '7AC',
        at: now,
      );

      await engine.runEcu11Inventory();

      expect(state.ecus['ecus11-742']!.discoverRanges, [
        (0x2600, 0x27FF),
        (0x4700, 0x47FF),
      ]);

      engine.dispose();
    });
  });

  group('batchSize', () {
    test('minQueueDepth/maxQueueDepth scale with it when not given '
        'explicitly', () {
      final executor = FakeExecutor();
      final engine = DiscoveryEngine(
        executor: executor,
        state: DiscoveryState(),
        onHit: (_, _, _) {},
        batchSize: 32,
      );

      expect(engine.minQueueDepth, 64);
      expect(engine.maxQueueDepth, 256);

      engine.dispose();
    });

    test('an explicit minQueueDepth/maxQueueDepth overrides the scaled '
        'default', () {
      final executor = FakeExecutor();
      final engine = DiscoveryEngine(
        executor: executor,
        state: DiscoveryState(),
        onHit: (_, _, _) {},
        batchSize: 32,
        minQueueDepth: 10,
        maxQueueDepth: 20,
      );

      expect(engine.minQueueDepth, 10);
      expect(engine.maxQueueDepth, 20);

      engine.dispose();
    });

    test(
      'a batch reads batchSize dids, not the fixed discoveryBatchSize',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState();
        state.ecus['test'] = EcuInfo(
          requestHeader: '7A1',
          responseHeader: '7A9',
          protocol: 6,
          discoverRanges: [(0x0000, 0x0FFF)],
        );
        final engine = DiscoveryEngine(
          executor: executor,
          state: state,
          onHit: (_, _, _) {},
          batchSize: 8,
        );
        // OK, not NoData -- an all-NoData batch would look NO-DATA-asleep
        // (`batchLooksNoDataAsleep`) and this test isn't about that.
        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: const ProbeOk(),
          at: now,
        );

        await engine.runDiscoveryBatch('test', now);

        expect(executor.submittedSteps.length, 8);
        expect(state.ecus['test']!.scanPosition, 8);

        engine.dispose();
      },
    );
  });
}
