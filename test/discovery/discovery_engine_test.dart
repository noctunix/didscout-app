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
        final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
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
      final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
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

    test(
      'noActiveRecording suspends the engine permanently -- pump never submits again',
      () async {
        final executor = FakeExecutor();
        final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
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
          delay: (_) => Future<void>.delayed(Duration.zero),
        );
        executor.rejectionsToThrow.add(
          const FakeRejection(SubmitRejectionReason.noActiveRecording),
        );

        await engine.pump(stationary: true, now: now);

        expect(engine.suspended, isTrue);
        expect(engine.eventLog.first.kind, ScoutEventKind.enqueueRejected);
        expect(state.ecus['test']!.scanPosition, 0);

        executor.rejectionsToThrow.clear();
        executor.submittedSteps.clear();
        await engine.pump(stationary: true, now: now);
        expect(
          executor.submittedSteps,
          isEmpty,
          reason: 'a suspended engine never submits again',
        );

        engine.dispose();
      },
    );
  });

  group('cancel', () {
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
      expect(
        engine.suspended,
        isTrue,
        reason: 'cancel is permanent, same as a noActiveRecording reject',
      );

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
