import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/discovery/did_order.dart';
import 'package:didscout_app/discovery/probe.dart';
import 'package:didscout_app/discovery/testplan_check.dart';
import 'package:didscout_app/session/session_markers.dart';

import 'fake_executor.dart';

void main() {
  final now = DateTime.utc(2026, 10, 28, 12, 0);

  group('testplan probe catalogue', () {
    final policy = DidscoutPolicy();

    test('reads no VIN or serial-number DID', () {
      for (final probe in testplanProbes()) {
        final did = probe.did;
        if (did == null) continue;
        expect(vinDids, isNot(contains(did)), reason: probe.signalId);
        expect(did, isNot(serialNumberDid), reason: probe.signalId);
      }
    });

    test('every command is mode 01 or UDS ReadDataByIdentifier', () {
      for (final probe in testplanProbes()) {
        expect(
          probe.command.startsWith('01') || probe.command.startsWith('22'),
          isTrue,
          reason: probe.signalId,
        );
      }
    });

    test('every probe and its module setup passes DidscoutPolicy', () {
      for (final probe in testplanProbes()) {
        expect(policy.allows(probe.command), isTrue, reason: probe.signalId);
        expect(
          policy.allows(probe.protocol == 6 ? 'ATSP6' : 'ATSP7'),
          isTrue,
          reason: probe.signalId,
        );
        expect(
          policy.allows('ATSH${probe.requestHeader}'),
          isTrue,
          reason: probe.signalId,
        );
        if (probe.responseHeader case final responseHeader?) {
          expect(
            policy.allows('ATCRA$responseHeader'),
            isTrue,
            reason: probe.signalId,
          );
          expect(
            policy.allows('ATFCSH${probe.requestHeader}'),
            isTrue,
            reason: probe.signalId,
          );
        }
        if (probe.receiveFilter case final receiveFilter?) {
          expect(
            policy.allows('ATCF$receiveFilter'),
            isTrue,
            reason: probe.signalId,
          );
        }
        if (probe.receiveMask case final receiveMask?) {
          expect(
            policy.allows('ATCM$receiveMask'),
            isTrue,
            reason: probe.signalId,
          );
        }
      }
    });

    test(
      'every signal id round-trips through moduleIdOf/commandOf and is unique',
      () {
        final ids = <String>[];
        for (final probe in testplanProbes()) {
          expect(probe.moduleId.contains('_'), isFalse, reason: probe.moduleId);
          expect(moduleIdOf(probe.signalId), probe.moduleId);
          expect(commandOf(probe.signalId), probe.command);
          ids.add(probe.signalId);
        }
        expect(ids.toSet(), hasLength(ids.length));
      },
    );
  });

  group('TestplanCheck', () {
    TestplanProbe probe(String command, {bool countsTowardSurvey = false}) =>
        TestplanProbe(
          group: TestplanGroup.hypotheses,
          moduleId: 'tp',
          requestHeader: '710',
          responseHeader: '77A',
          protocol: 6,
          command: command,
          description: 'test probe',
          countsTowardSurvey: countsTowardSurvey,
        );

    test('runs once per phase, and a cancelled/missing probe is retried on '
        'the next run', () async {
      final executor = FakeExecutor();
      final probeA = probe('222AF7');
      final probeB = probe('222AB2');
      executor.droppedSignalIds.add(probeB.signalId);
      final check = TestplanCheck(
        executor: executor,
        probes: [probeA, probeB],
        delay: (_) => Future<void>.delayed(Duration.zero),
      );

      await check.runForPhase(MarkerPhase.drive);
      expect(
        executor.submittedSteps.where((s) => s.signalId == probeA.signalId),
        hasLength(1),
      );
      expect(
        executor.submittedSteps.where((s) => s.signalId == probeB.signalId),
        hasLength(1),
      );
      expect(check.states[probeA.signalId]!.answered, isTrue);
      expect(check.states[probeB.signalId]!.answered, isFalse);

      // Same phase again -- a no-op even though B is still missing.
      await check.runForPhase(MarkerPhase.drive);
      expect(
        executor.submittedSteps.where((s) => s.signalId == probeB.signalId),
        hasLength(1),
      );

      // A new phase retries B (still missing) but not A (already
      // answered).
      await check.runForPhase(MarkerPhase.charge);
      expect(
        executor.submittedSteps.where((s) => s.signalId == probeA.signalId),
        hasLength(1),
      );
      expect(
        executor.submittedSteps.where((s) => s.signalId == probeB.signalId),
        hasLength(2),
      );
    });

    test(
      'a rejected submit leaves the whole group due for the next run',
      () async {
        final executor = FakeExecutor();
        final probeA = probe('222AF7');
        executor.rejectionsToThrow.add(
          const FakeRejection(SubmitRejectionReason.queueFull),
        );
        final check = TestplanCheck(
          executor: executor,
          probes: [probeA],
          delay: (_) => Future<void>.delayed(Duration.zero),
        );

        await check.runForPhase(MarkerPhase.drive);
        expect(executor.submittedSteps, isEmpty);
        expect(check.states[probeA.signalId]!.answered, isFalse);

        await check.runForPhase(MarkerPhase.charge);
        expect(
          executor.submittedSteps.where((s) => s.signalId == probeA.signalId),
          hasLength(1),
        );
      },
    );

    test('a group\'s deadline grows with the reads already queued ahead of '
        'it', () async {
      final executor = FakeExecutor();
      final queued = [
        for (var i = 0; i < 10; i++)
          ProbeStep(signalId: 'other_22000$i', command: '22000$i'),
      ];
      executor.droppedSignalIds.addAll(queued.map((step) => step.signalId));
      await executor.submit(const [], queued);
      final probeA = probe('222AF7');
      final waits = <Duration>[];
      final check = TestplanCheck(
        executor: executor,
        probes: [probeA],
        delay: (duration) {
          waits.add(duration);
          return Future<void>.delayed(Duration.zero);
        },
      );

      await check.runForPhase(MarkerPhase.drive);

      expect(waits, [testplanDeadlineBase + testplanDeadlinePerStep * 11]);
    });

    test('a timed-out probe is answered and never resent again', () async {
      final executor = FakeExecutor();
      final probeA = probe('222AF7');
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeTimeout(),
        at: now,
      );
      final check = TestplanCheck(
        executor: executor,
        probes: [probeA],
        delay: (_) => Future<void>.delayed(Duration.zero),
      );

      await check.runForPhase(MarkerPhase.drive);
      expect(check.states[probeA.signalId]!.outcome, TestplanOutcome.timeout);

      await check.runForPhase(MarkerPhase.charge);
      expect(
        executor.submittedSteps.where((s) => s.signalId == probeA.signalId),
        hasLength(1),
      );
    });

    test('onResult is called once per completed probe, with its catalogue '
        'entry and result', () async {
      final executor = FakeExecutor();
      final probeA = probe('222AB2', countsTowardSurvey: true);
      executor.respond = (step) => ProbeResult(
        signalId: step.signalId,
        status: const ProbeOk(),
        payload: const [0xAB],
        at: now,
      );
      final results = <(TestplanProbe, ProbeResult)>[];
      final check = TestplanCheck(
        executor: executor,
        probes: [probeA],
        onResult: (probe, result) => results.add((probe, result)),
        delay: (_) => Future<void>.delayed(Duration.zero),
      );

      await check.runForPhase(MarkerPhase.drive);

      expect(results, hasLength(1));
      expect(results.single.$1, same(probeA));
      expect(results.single.$2.payload, [0xAB]);
    });

    test(
      'answeredCount/okCount/lastRunPhase summarize the catalogue',
      () async {
        final executor = FakeExecutor();
        final probeA = probe('222AF7');
        final probeB = probe('222AB2');
        executor.respond = (step) => ProbeResult(
          signalId: step.signalId,
          status: step.signalId == probeA.signalId
              ? const ProbeOk()
              : const ProbeNoData(),
          at: now,
        );
        final check = TestplanCheck(
          executor: executor,
          probes: [probeA, probeB],
          delay: (_) => Future<void>.delayed(Duration.zero),
        );

        await check.runForPhase(MarkerPhase.drive);

        expect(check.totalCount, 2);
        expect(check.answeredCount, 2);
        expect(check.okCount, 1);
        expect(check.lastRunPhase, MarkerPhase.drive);
      },
    );
  });
}
