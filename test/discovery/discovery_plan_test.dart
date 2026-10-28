import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/discovery/discovery_plan.dart';
import 'package:didscout_app/discovery/discovery_state.dart';

void main() {
  test('an ECU with no discovered DIDs contributes nothing', () {
    final state = DiscoveryState();
    state.ecus['new-ecu'] = EcuInfo(
      requestHeader: '7B0',
      responseHeader: '7B8',
      protocol: 6,
    );

    expect(discoveredPlanAdditions(state), isEmpty);
  });

  test('an ECU with no identified responder is skipped entirely', () {
    final state = DiscoveryState();
    final ecu = EcuInfo(requestHeader: '7B0', protocol: 6)
      ..discovered.add('2A00');
    state.ecus['new-ecu'] = ecu;

    expect(discoveredPlanAdditions(state), isEmpty);
  });

  test('an ECU unknown to vag-ppe is added whole', () {
    final state = DiscoveryState();
    final ecu = EcuInfo(
      requestHeader: '7B0',
      responseHeader: '7B8',
      protocol: 6,
    )..discovered.addAll(['2A00', '2A01']);
    state.ecus['ecus11-7B0'] = ecu;

    final additions = discoveredPlanAdditions(state);

    expect(additions, hasLength(1));
    expect(additions.single.moduleId, 'ecus11-7B0');
    expect(additions.single.requestHeader, '7B0');
    expect(additions.single.responseHeader, '7B8');
    expect(additions.single.protocol, 6);
    expect(additions.single.dids, ['2A00', '2A01']);
  });

  test('a vag-ppe-seeded ECU only contributes DIDs vag-ppe does not already '
      'poll', () {
    final state = DiscoveryState();
    // 'gateway' is a real vag-ppe module id (710/77A); 2AF7 is already in
    // its generated DID list, 9999 is new.
    final ecu = EcuInfo(
      requestHeader: '710',
      responseHeader: '77A',
      protocol: 6,
    )..discovered.addAll(['2AF7', '9999']);
    state.ecus['gateway'] = ecu;

    final additions = discoveredPlanAdditions(state);

    expect(additions, hasLength(1));
    expect(additions.single.moduleId, 'gateway');
    expect(additions.single.dids, ['9999']);
  });

  test('a vag-ppe-seeded ECU with nothing new contributes nothing', () {
    final state = DiscoveryState();
    final ecu = EcuInfo(
      requestHeader: '710',
      responseHeader: '77A',
      protocol: 6,
    )..discovered.add('2AF7');
    state.ecus['gateway'] = ecu;

    expect(discoveredPlanAdditions(state), isEmpty);
  });

  test('results are sorted by module id, each module\'s DIDs sorted', () {
    final state = DiscoveryState();
    state.ecus['ecus11-7C0'] = EcuInfo(
      requestHeader: '7C0',
      responseHeader: '7C8',
      protocol: 6,
    )..discovered.addAll(['2A02', '2A01']);
    state.ecus['ecus11-7B0'] = EcuInfo(
      requestHeader: '7B0',
      responseHeader: '7B8',
      protocol: 6,
    )..discovered.add('2A00');

    final additions = discoveredPlanAdditions(state);

    expect(additions.map((a) => a.moduleId), ['ecus11-7B0', 'ecus11-7C0']);
    expect(additions.firstWhere((a) => a.moduleId == 'ecus11-7C0').dids, [
      '2A01',
      '2A02',
    ]);
  });
}
