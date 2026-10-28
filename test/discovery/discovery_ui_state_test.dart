import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/discovery/discovery_engine.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/discovery/discovery_ui_state.dart';

import 'fake_executor.dart';

void main() {
  final now = DateTime.utc(2026, 10, 28, 12, 0);

  test('stationary with incomplete inventory reports inventory activity', () {
    final engine = DiscoveryEngine(
      executor: FakeExecutor(),
      state: DiscoveryState(),
      onHit: (_, _, _) {},
    );

    final uiState = buildDiscoveryUiState(
      engine: engine,
      stationary: true,
      now: now,
      sessionHits: 0,
    );

    expect(uiState.activity, DiscoveryActivity.inventory);
    engine.dispose();
  });

  test('an eligible ECU with pending work reports scanning with its name', () {
    final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
    state.ecus['ecu1'] = EcuInfo(
      requestHeader: '7B0',
      responseHeader: '7B8',
      protocol: 6,
      discoverRanges: [(0x2A00, 0x2A0F)],
      identification: {'F197': 'Climate control'},
    );
    final engine = DiscoveryEngine(
      executor: FakeExecutor(),
      state: state,
      onHit: (_, _, _) {},
    );

    final uiState = buildDiscoveryUiState(
      engine: engine,
      stationary: true,
      now: now,
      sessionHits: 0,
    );

    expect(uiState.activity, DiscoveryActivity.scanning);
    expect(uiState.scanningEcuName, 'Climate control');
    engine.dispose();
  });

  test(
    'moving with only a safety-blocklisted ECU left reports waiting: moving',
    () {
      final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
      state.ecus['abs'] = EcuInfo(
        requestHeader: '7B0',
        responseHeader: '7B8',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2A0F)],
        identification: {'F197': 'ABS controller'},
      );
      final engine = DiscoveryEngine(
        executor: FakeExecutor(),
        state: state,
        onHit: (_, _, _) {},
      );
      // Exhaust the vag-ppe seed ECUs so only 'abs' has pending work.
      for (final id in state.ecus.keys.toList()) {
        if (id != 'abs') state.ecus[id]!.scanPosition = 1 << 20;
      }

      final uiState = buildDiscoveryUiState(
        engine: engine,
        stationary: false,
        now: now,
        sessionHits: 0,
      );

      expect(uiState.activity, DiscoveryActivity.waitingMoving);
      engine.dispose();
    },
  );

  test('an asleep ECU with nothing else pending reports waiting: asleep', () {
    final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
    state.ecus['ecu1'] = EcuInfo(
      requestHeader: '7B0',
      responseHeader: '7B8',
      protocol: 6,
      discoverRanges: const [],
      asleepUntil: now.add(const Duration(seconds: 30)),
    );
    final engine = DiscoveryEngine(
      executor: FakeExecutor(),
      state: state,
      onHit: (_, _, _) {},
    );
    // Exhaust the vag-ppe seed ECUs so only 'ecu1' (asleep) has pending work.
    for (final id in state.ecus.keys.toList()) {
      if (id != 'ecu1') state.ecus[id]!.scanPosition = 1 << 20;
    }

    final uiState = buildDiscoveryUiState(
      engine: engine,
      stationary: true,
      now: now,
      sessionHits: 0,
    );

    expect(uiState.activity, DiscoveryActivity.waitingAsleep);
    engine.dispose();
  });

  test('nothing left anywhere reports idle', () {
    final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
    final engine = DiscoveryEngine(
      executor: FakeExecutor(),
      state: state,
      onHit: (_, _, _) {},
    );
    // Exhaust every seeded ECU's scan order up front.
    for (final ecu in state.ecus.values) {
      ecu.scanPosition = 1 << 20;
    }

    final uiState = buildDiscoveryUiState(
      engine: engine,
      stationary: true,
      now: now,
      sessionHits: 0,
    );

    expect(uiState.activity, DiscoveryActivity.idle);
    engine.dispose();
  });

  test('allowedToRun: false short-circuits to waiting: moving even with '
      'eligible, non-blocklisted work', () {
    final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
    final engine = DiscoveryEngine(
      executor: FakeExecutor(),
      state: state,
      onHit: (_, _, _) {},
    );
    // The seeded vag-ppe ECUs have pending work and no F197 name, so
    // they're not safety-blocklisted -- `selectNextEcuForScan` alone
    // would report `scanning`.
    expect(engine.selectNextEcuForScan(stationary: false, now: now), isNotNull);

    final uiState = buildDiscoveryUiState(
      engine: engine,
      stationary: false,
      now: now,
      sessionHits: 0,
      allowedToRun: false,
    );

    expect(uiState.activity, DiscoveryActivity.waitingMoving);
    engine.dispose();
  });

  test('totalHits and sessionHits are reported independently', () {
    final state = DiscoveryState(inventoryStagesDone: {'ecus11', 'ecus29'});
    state.ecus['ecu1'] = EcuInfo(requestHeader: '7B0', protocol: 6)
      ..discovered.addAll(['2A00', '2A01']);
    final engine = DiscoveryEngine(
      executor: FakeExecutor(),
      state: state,
      onHit: (_, _, _) {},
    );
    for (final ecu in state.ecus.values) {
      ecu.scanPosition = 1 << 20;
    }

    final uiState = buildDiscoveryUiState(
      engine: engine,
      stationary: true,
      now: now,
      sessionHits: 3,
    );

    expect(uiState.totalHits, 2);
    expect(uiState.sessionHits, 3);
    engine.dispose();
  });
}
