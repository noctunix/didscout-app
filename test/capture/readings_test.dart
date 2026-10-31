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
    test('without battery temp., uses the energy-only fit', () {
      // 61075 * 0.0010689 + 7.8526 = 73.136
      expect(estimateSocPercent(61075), 73);
      // 1230 * 25 Wh, read while the display showed 39 %, within the
      // energy-only fit's error:
      // 30750 * 0.0010689 + 7.8526 = 40.721
      expect(estimateSocPercent(30750), 41);
    });

    test('with battery temp., the same energy reads higher when cold', () {
      // 61075 * 0.00108695 - 13 * 0.233182 + 10.9764 = 74.331
      expect(estimateSocPercent(61075, batteryTempC: 13), 74);
      // 61075 * 0.00108695 - 31 * 0.233182 + 10.9764 = 70.133
      expect(estimateSocPercent(61075, batteryTempC: 31), 70);
      // 58175 * 0.00108695 - 31 * 0.233182 + 10.9764 = 66.981
      expect(estimateSocPercent(58175, batteryTempC: 31.0), 67);
    });

    test('is clamped to 0-100 %', () {
      expect(estimateSocPercent(200000), 100);
      expect(estimateSocPercent(200000, batteryTempC: 20), 100);
      // 0 * 0.00108695 - 60 * 0.233182 + 10.9764 = -3.015
      expect(estimateSocPercent(0, batteryTempC: 60), 0);
    });

    test('is what LiveVehicleInfo reports, and null without energy', () {
      const info = LiveVehicleInfo(storedEnergyWh: 61075);
      expect(info.socEstimatePercent(), 73);
      expect(info.socEstimatePercent(batteryTempC: 13), 74);
      expect(LiveVehicleInfo.empty.socEstimatePercent(), isNull);
      expect(
        LiveVehicleInfo.empty.socEstimatePercent(batteryTempC: 13),
        isNull,
      );
    });
  });

  test('wireName matches the fixed sidecar spelling', () {
    expect(ReadingQuantity.soc.wireName, 'soc');
    expect(ReadingQuantity.batteryTemp.wireName, 'battery_temp');
    expect(ReadingQuantity.outsideTemp.wireName, 'outside_temp');
    expect(ReadingQuantity.insideTemp.wireName, 'inside_temp');
    expect(ReadingQuantity.range.wireName, 'range');
    expect(ReadingQuantity.chargePower.wireName, 'charge_power');
    expect(ReadingQuantity.odometer.wireName, 'odometer');
  });
}
