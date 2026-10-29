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
        learnedRecordings: {'session-a'},
      );
      original.ecus['ecus11-7A1'] = EcuInfo(
        requestHeader: '7A1',
        responseHeader: '7A9',
        protocol: 6,
        discoverRanges: [(0x2A00, 0x2AFF)],
        identification: {'F187': 'OK', 'F197': 'Gateway'},
        scanPosition: 48,
        discovered: {'2A04', '2A15'},
        conditional: {'2A26'},
        retryQueue: ['2A26'],
        asleepUntil: DateTime.utc(2026, 10, 28, 9, 31),
        noDataStreak: 3,
        sampleStats: {
          '2A04': DidSampleStats(
            lastPayloadHash: 0xDEADBEEF,
            stableSamples: 12,
            stableRecordings: 3,
            everChanged: true,
          ),
        },
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

      final gateway = loaded.ecus['ecus11-7A1']!;
      expect(gateway.requestHeader, '7A1');
      expect(gateway.responseHeader, '7A9');
      expect(gateway.protocol, 6);
      expect(gateway.discoverRanges, [(0x2A00, 0x2AFF)]);
      expect(gateway.identification, {'F187': 'OK', 'F197': 'Gateway'});
      expect(gateway.scanPosition, 48);
      expect(gateway.discovered, {'2A04', '2A15'});
      expect(gateway.conditional, {'2A26'});
      expect(gateway.retryQueue, ['2A26']);
      expect(gateway.asleepUntil, DateTime.utc(2026, 10, 28, 9, 31));
      expect(gateway.noDataStreak, 3);
      final stats = gateway.sampleStats['2A04']!;
      expect(stats.lastPayloadHash, 0xDEADBEEF);
      expect(stats.stableSamples, 12);
      expect(stats.stableRecordings, 3);
      expect(stats.everChanged, isTrue);
      expect(loaded.learnedRecordings, {'session-a'});
      expect(gateway.f197Name, 'Gateway');

      final other = loaded.ecus['ecus29-04']!;
      expect(other.responseHeader, '18DAF104');
      expect(other.asleepUntil, isNull);
    });

    test('a persisted phantom 0x700 ECU is dropped on load', () async {
      final original = DiscoveryState(inventoryStagesDone: {'ecus11'});
      original.ecus['ecus11-700'] = EcuInfo(
        requestHeader: '700',
        responseHeader: '77A',
        protocol: 6,
        scanPosition: 645,
        discovered: {'2A04'},
      );
      original.ecus['gateway'] = EcuInfo(
        requestHeader: '710',
        responseHeader: '77A',
        protocol: 6,
      );

      final file = File('${tempDir.path}/vehicle-a6.json');
      await original.saveToFile(file);
      final loaded = await DiscoveryState.loadFromFile(file);

      expect(loaded.ecus.keys, ['gateway']);
      expect(loaded.inventoryStagesDone, {'ecus11'});
    });
  });

  group('merging ECUs that share a request header', () {
    Map<String, dynamic> ecuJson({
      required String request,
      String? response,
      int protocol = 6,
      int scanPosition = 0,
      List<String> discovered = const [],
      List<String> conditional = const [],
      Map<String, String> identification = const {},
    }) => EcuInfo(
      requestHeader: request,
      responseHeader: response,
      protocol: protocol,
      scanPosition: scanPosition,
      discovered: discovered.toSet(),
      conditional: conditional.toSet(),
      identification: Map.of(identification),
    ).toJson();

    test('an inventory duplicate of a vag-ppe seed is folded into the seed '
        'id', () {
      final state = DiscoveryState.fromJson({
        'ecus': {
          'bcm1': ecuJson(
            request: '70E',
            response: '778',
            scanPosition: 160,
            discovered: ['F187', 'F189'],
            conditional: ['0100'],
          ),
          'ecus11-70E': ecuJson(
            request: '70E',
            response: '778',
            scanPosition: 320,
            discovered: ['F189', '0100', '0200'],
            conditional: ['0300'],
            identification: {'F187': 'OK', 'F197': 'BCM1 E3 1.2'},
          ),
          'gateway': ecuJson(request: '710', response: '77A'),
        },
      });

      expect(state.ecus.keys, ['bcm1', 'gateway']);
      final bcm = state.ecus['bcm1']!;
      expect(bcm.discovered, {'F187', 'F189', '0100', '0200'});
      expect(bcm.conditional, {'0300'});
      expect(bcm.scanPosition, 320);
      expect(bcm.f197Name, 'BCM1 E3 1.2');
    });

    test('an inventory entry alone is renamed to the seed id for its '
        'header', () {
      final state = DiscoveryState.fromJson({
        'ecus': {
          'ecus29-06': ecuJson(
            request: '18DA06F1',
            response: '18DAF106',
            protocol: 7,
            discovered: ['0100'],
          ),
        },
      });

      expect(state.ecus.keys, ['motor-rear']);
      expect(state.ecus['motor-rear']!.discovered, {'0100'});
    });

    test('a name replaces a failed identification status', () {
      final state = DiscoveryState.fromJson({
        'ecus': {
          'parking-lock': ecuJson(
            request: '18DA28F1',
            protocol: 7,
            identification: {'F197': 'CANCELLED'},
          ),
          'ecus29-28': ecuJson(
            request: '18DA28F1',
            protocol: 7,
            identification: {'F197': 'PARKSP. HIGH'},
          ),
        },
      });

      expect(state.ecus['parking-lock']!.f197Name, 'PARKSP. HIGH');
    });

    test('the same header on another protocol stays a separate ECU', () {
      final state = DiscoveryState.fromJson({
        'ecus': {
          'a': ecuJson(request: '7A1', protocol: 6),
          'b': ecuJson(request: '7A1', protocol: 7),
        },
      });

      expect(state.ecus.keys, ['a', 'b']);
    });
  });
}
