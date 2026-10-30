import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/capture/readings.dart';

void main() {
  group('decodeSpeedKmh', () {
    test('byte 0 is km/h', () {
      expect(decodeSpeedKmh(Uint8List.fromList([42])), 42);
    });

    test('empty payload is null', () {
      expect(decodeSpeedKmh(Uint8List.fromList([])), isNull);
    });
  });

  group('decodeOdometerKm', () {
    test('uint32 big-endian, tenths of a km', () {
      // 123456 (0x0001E240) tenths of a km -> 12345.6 km.
      expect(
        decodeOdometerKm(Uint8List.fromList([0x00, 0x01, 0xE2, 0x40])),
        12345.6,
      );
    });

    test('too short is null', () {
      expect(decodeOdometerKm(Uint8List.fromList([0x00, 0x01, 0xE2])), isNull);
    });
  });

  group('decodeOutsideTempC', () {
    test('byte 0 minus the 40 degC UDS offset', () {
      expect(decodeOutsideTempC(Uint8List.fromList([60])), 20);
      expect(decodeOutsideTempC(Uint8List.fromList([30])), -10);
    });
  });

  group('decodeRangeKm', () {
    test('first uint16 big-endian, km', () {
      expect(decodeRangeKm(Uint8List.fromList([0x01, 0x2C, 0xFF])), 300);
    });

    test('too short is null', () {
      expect(decodeRangeKm(Uint8List.fromList([0x01])), isNull);
    });
  });

  group('decodeStoredEnergyWh', () {
    test('uint16 big-endian at offset 2, times 25 Wh', () {
      // offset 2..3 = 0x00C8 = 200 -> 200 * 25 = 5000 Wh.
      expect(
        decodeStoredEnergyWh(Uint8List.fromList([0, 0, 0x00, 0xC8])),
        5000,
      );
    });

    test('too short is null', () {
      expect(decodeStoredEnergyWh(Uint8List.fromList([0, 0, 0])), isNull);
    });
  });

  group('estimateSocPercent', () {
    test('maps stored energy onto the displayed SoC, rounded', () {
      // 2443 * 25 Wh, read while the display showed 73 %.
      expect(estimateSocPercent(61075), 73);
      // 1230 * 25 Wh, read while the display showed 39 %.
      expect(estimateSocPercent(30750), 39);
    });

    test('never exceeds 100 %', () {
      expect(estimateSocPercent(200000), 100);
    });

    test('is what LiveVehicleInfo reports, and null without energy', () {
      expect(
        const LiveVehicleInfo(storedEnergyWh: 61075).socEstimatePercent,
        73,
      );
      expect(LiveVehicleInfo.empty.socEstimatePercent, isNull);
    });
  });

  test('wireName matches the fixed sidecar spelling', () {
    expect(ReadingQuantity.soc.wireName, 'soc');
    expect(ReadingQuantity.batteryTemp.wireName, 'battery_temp');
    expect(ReadingQuantity.outsideTemp.wireName, 'outside_temp');
    expect(ReadingQuantity.range.wireName, 'range');
    expect(ReadingQuantity.chargePower.wireName, 'charge_power');
    expect(ReadingQuantity.odometer.wireName, 'odometer');
  });
}
