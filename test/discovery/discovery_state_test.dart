import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/discovery/discovery_state.dart';

void main() {
  group('DiscoveryState persistence', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('discovery_state_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('loading a missing file yields a fresh empty state', () async {
      final state = await DiscoveryState.loadFromFile(
        File('${tempDir.path}/no-such-file.json'),
      );
      expect(state.ecus, isEmpty);
      expect(state.inventoryStagesDone, isEmpty);
      expect(state.lastRediscoveryTime, isNull);
    });

    test(
      'loading a corrupt file yields a fresh empty state rather than throwing',
      () async {
        final file = File('${tempDir.path}/corrupt.json')
          ..writeAsStringSync('not json');
        final state = await DiscoveryState.loadFromFile(file);
        expect(state.ecus, isEmpty);
      },
    );

    test('a full round trip preserves every field', () async {
      final original = DiscoveryState(
        inventoryStagesDone: {'ecus11', 'ecus29'},
        lastRediscoveryTime: DateTime.utc(2026, 10, 28, 9, 30),
      );
      original.ecus['ecus11-700'] = EcuInfo(
        requestHeader: '700',
        responseHeader: '708',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2AFF)],
        identification: {'F187': 'OK', 'F197': 'Gateway'},
        scanPosition: 48,
        discovered: {'2A04', '2A15'},
        conditional: {'2A26'},
        retryQueue: ['2A26'],
        asleepUntil: DateTime.utc(2026, 10, 28, 9, 31),
      );
      original.ecus['ecus29-04'] = EcuInfo(
        requestHeader: '18DA04F1',
        responseHeader: '18DAF104',
        protocol: 7,
      );

      final file = File('${tempDir.path}/vehicle-a6.json');
      await original.saveToFile(file);
      final loaded = await DiscoveryState.loadFromFile(file);

      expect(loaded.inventoryStagesDone, original.inventoryStagesDone);
      expect(loaded.lastRediscoveryTime, original.lastRediscoveryTime);
      expect(loaded.ecus.keys.toSet(), original.ecus.keys.toSet());

      final gateway = loaded.ecus['ecus11-700']!;
      expect(gateway.requestHeader, '700');
      expect(gateway.responseHeader, '708');
      expect(gateway.protocol, 6);
      expect(gateway.discoverRanges, [(0x2A00, 0x2AFF)]);
      expect(gateway.identification, {'F187': 'OK', 'F197': 'Gateway'});
      expect(gateway.scanPosition, 48);
      expect(gateway.discovered, {'2A04', '2A15'});
      expect(gateway.conditional, {'2A26'});
      expect(gateway.retryQueue, ['2A26']);
      expect(gateway.asleepUntil, DateTime.utc(2026, 10, 28, 9, 31));
      expect(gateway.f197Name, 'Gateway');

      final other = loaded.ecus['ecus29-04']!;
      expect(other.responseHeader, '18DAF104');
      expect(other.asleepUntil, isNull);
    });
  });
}
