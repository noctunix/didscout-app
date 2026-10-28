import 'package:flutter_test/flutter_test.dart';
import 'package:obdbridge/obdbridge.dart';
// `NativeObdApi` is deliberately not re-exported from `obdbridge.dart` --
// this test needs it anyway, to build a fake in place of the real native
// channel (same pattern as `recording_controller_test.dart`).
import 'package:obdbridge/src/obdbridge_api.g.dart' show NativeObdApi;

import 'package:didscout_app/bridge/bridge_read_executor.dart';
import 'package:didscout_app/bridge/didscout_policy.dart';
import 'package:didscout_app/discovery/probe.dart';

class _FakeNativeObdApi extends NativeObdApi {
  List<ObdModuleMessage>? lastModules;
  List<ObdStepMessage>? lastSteps;
  ObdOneShotEnqueueResultMessage enqueueResult =
      ObdOneShotEnqueueResultMessage.accepted;

  @override
  Future<ObdOneShotEnqueueResultMessage> enqueueOneShot(
    List<ObdModuleMessage> modules,
    List<ObdStepMessage> steps,
  ) async {
    lastModules = modules;
    lastSteps = steps;
    return enqueueResult;
  }
}

ObdSignalExchangeMessage _exchange({
  required String signalId,
  ObdTransportStatusMessage transport = ObdTransportStatusMessage.ok,
  String? rawResponseText,
}) => ObdSignalExchangeMessage(
  signalId: signalId,
  transport: transport,
  rawResponseText: rawResponseText,
);

void main() {
  late _FakeNativeObdApi fakeNative;
  late BridgeReadExecutor executor;

  setUp(() {
    fakeNative = _FakeNativeObdApi();
    executor = BridgeReadExecutor(
      ObdBridge(DidscoutPolicy(), nativeApi: fakeNative),
    );
  });

  tearDown(() => executor.dispose());

  group('submit', () {
    test('compiles a known-responder module with flow control', () async {
      await executor.submit(
        [
          ProbeModule(
            id: 'ecu1',
            requestHeader: '710',
            responseHeader: '77A',
            protocol: 6,
          ),
        ],
        [ProbeStep(signalId: 'ecu1_22f189', command: '22F189')],
      );

      final module = fakeNative.lastModules!.single;
      expect(module.moduleId, 'ecu1');
      expect(module.setup, [
        'ATSP6',
        'ATSH710',
        'ATCRA77A',
        'ATFCSH710',
        'ATFCSD300000',
        'ATFCSM1',
      ]);
      final step = fakeNative.lastSteps!.single;
      expect(step.moduleId, 'ecu1');
      expect(step.command, '22F189');
      expect(executor.queueDepth, 1);
    });

    test(
      'compiles a sweep module (no known responder) with a receive filter, no flow control',
      () async {
        await executor.submit(
          [
            ProbeModule(
              id: 'ecu11-700',
              requestHeader: '700',
              protocol: 6,
              receiveFilter: '700',
              receiveMask: '700',
            ),
          ],
          [ProbeStep(signalId: 'ecu11-700_22f189', command: '22F189')],
        );

        final module = fakeNative.lastModules!.single;
        expect(module.setup, ['ATSP6', 'ATSH700', 'ATCF700', 'ATCM700']);
      },
    );

    test('a batch rejected by native throws, queueDepth stays 0', () async {
      fakeNative.enqueueResult = ObdOneShotEnqueueResultMessage.queueFull;
      await expectLater(
        executor.submit(
          [
            ProbeModule(
              id: 'ecu1',
              requestHeader: '710',
              responseHeader: '77A',
              protocol: 6,
            ),
          ],
          [ProbeStep(signalId: 'ecu1_22f189', command: '22F189')],
        ),
        throwsA(isA<BridgeReadExecutorException>()),
      );
      expect(executor.queueDepth, 0);
    });

    test('an empty step list is a no-op', () async {
      await executor.submit([], []);
      expect(fakeNative.lastModules, isNull);
    });

    test('exposes the rejection reason the discovery engine acts on', () async {
      fakeNative.enqueueResult =
          ObdOneShotEnqueueResultMessage.noActiveRecording;
      try {
        await executor.submit(
          [
            ProbeModule(
              id: 'ecu1',
              requestHeader: '710',
              responseHeader: '77A',
              protocol: 6,
            ),
          ],
          [ProbeStep(signalId: 'ecu1_22f189', command: '22F189')],
        );
        fail('expected a rejection');
      } on BridgeReadExecutorException catch (e) {
        expect(e.reason, SubmitRejectionReason.noActiveRecording);
      }
    });
  });

  group('deliverOneShotResult', () {
    test(
      'a positive reply decodes into ProbeOk with its payload and header',
      () async {
        final results = <ProbeResult>[];
        executor.results.listen(results.add);
        await executor.submit(
          [
            ProbeModule(
              id: 'ecu1',
              requestHeader: '710',
              responseHeader: '77A',
              protocol: 6,
            ),
          ],
          [ProbeStep(signalId: 'ecu1_22f189', command: '22F189')],
        );

        executor.deliverOneShotResult(
          _exchange(
            signalId: 'ecu1_22f189',
            rawResponseText: '77A 04 62F189 01',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(results.single.status, isA<ProbeOk>());
        expect(results.single.payload, [0x01]);
        expect(results.single.responderHeader, '77A');
        expect(executor.queueDepth, 0);
      },
    );

    test('a negative reply decodes into ProbeNrc with its code', () async {
      final results = <ProbeResult>[];
      executor.results.listen(results.add);

      executor.deliverOneShotResult(
        _exchange(signalId: 'ecu1_22f189', rawResponseText: '77A 03 7F22 31'),
      );
      await Future<void>.delayed(Duration.zero);

      final status = results.single.status;
      expect(status, isA<ProbeNrc>());
      expect((status as ProbeNrc).code, 0x31);
    });

    test('"NO DATA" decodes into ProbeNoData', () async {
      final results = <ProbeResult>[];
      executor.results.listen(results.add);

      executor.deliverOneShotResult(
        _exchange(signalId: 'ecu1_22f189', rawResponseText: 'NO DATA'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(results.single.status, isA<ProbeNoData>());
    });

    test('a transport timeout decodes into ProbeTimeout', () async {
      final results = <ProbeResult>[];
      executor.results.listen(results.add);

      executor.deliverOneShotResult(
        _exchange(
          signalId: 'ecu1_22f189',
          transport: ObdTransportStatusMessage.timeout,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(results.single.status, isA<ProbeTimeout>());
    });

    test('a cancelled transport decodes into ProbeCancelled', () async {
      final results = <ProbeResult>[];
      executor.results.listen(results.add);

      executor.deliverOneShotResult(
        _exchange(
          signalId: 'ecu1_22f189',
          transport: ObdTransportStatusMessage.cancelled,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(results.single.status, isA<ProbeCancelled>());
    });

    test(
      'any other non-ok transport decodes into ProbeTransportError',
      () async {
        final results = <ProbeResult>[];
        executor.results.listen(results.add);

        executor.deliverOneShotResult(
          _exchange(
            signalId: 'ecu1_22f189',
            transport: ObdTransportStatusMessage.disconnected,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(results.single.status, isA<ProbeTransportError>());
      },
    );

    test(
      'unrecognisable framing falls back to ProbeNoData, not a crash',
      () async {
        final results = <ProbeResult>[];
        executor.results.listen(results.add);

        executor.deliverOneShotResult(
          _exchange(signalId: 'ecu1_22f189', rawResponseText: 'garbage!!'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(results.single.status, isA<ProbeNoData>());
      },
    );
  });

  test(
    'applyRecordingState overrides the locally tracked queue depth',
    () async {
      await executor.submit(
        [
          ProbeModule(
            id: 'ecu1',
            requestHeader: '710',
            responseHeader: '77A',
            protocol: 6,
          ),
        ],
        [ProbeStep(signalId: 'ecu1_22f189', command: '22F189')],
      );
      expect(executor.queueDepth, 1);
      executor.applyRecordingState(42);
      expect(executor.queueDepth, 42);
    },
  );
}
