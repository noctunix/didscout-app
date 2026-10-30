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

  group('decodeBatteryTempRangeC', () {
    test('min and max of the populated slots, raw / 2 - 64 degC', () {
      // Byte 0 is skipped. 0xB0 = 176 -> 24.0, 0xB3 = 179 -> 25.5,
      // 0xB7 = 183 -> 27.5; 0x30 (-40.0) and 0x31 (-39.5) are unpopulated.
      final range = decodeBatteryTempRangeC(
        Uint8List.fromList([0x01, 0xB3, 0xB0, 0xB7, 0x30, 0x31, 0x30]),
      );
      expect(range?.min, 24.0);
      expect(range?.max, 27.5);
    });

    test('0x32 (-39.0 degC) is the lowest populated slot', () {
      final range = decodeBatteryTempRangeC(
        Uint8List.fromList([0x01, 0x32, 0x31]),
      );
      expect(range?.min, -39.0);
      expect(range?.max, -39.0);
    });

    test('only unpopulated slots is null', () {
      expect(
        decodeBatteryTempRangeC(Uint8List.fromList([0x01, 0x30, 0x31, 0x00])),
        isNull,
      );
    });

    test('a payload without any slot is null', () {
      expect(decodeBatteryTempRangeC(Uint8List.fromList([0x01])), isNull);
      expect(decodeBatteryTempRangeC(Uint8List.fromList([])), isNull);
    });
  });

  test('a battery temp. candidate alone counts as a live value', () {
    expect(LiveVehicleInfo.empty.hasAnyValue, isFalse);
    expect(
      const LiveVehicleInfo(
        batteryTempMinC: 24,
        batteryTempMaxC: 27.5,
      ).hasAnyValue,
      isTrue,
    );
  });

  group('estimateSocPercent', () {
    test('without battery temp., uses the energy-only fit', () {
      // 61075 * 0.0011077 + 5.38 = 73.033
      expect(estimateSocPercent(61075), 73);
      // 1230 * 25 Wh, read while the display showed 39 %:
      // 30750 * 0.0011077 + 5.38 = 39.442
      expect(estimateSocPercent(30750), 39);
    });

    test('with battery temp., the same energy reads higher when cold', () {
      // 61075 * 0.00109229 - 13 * 0.191163 + 9.8163 = 74.043
      expect(estimateSocPercent(61075, batteryTempC: 13), 74);
      // 61075 * 0.00109229 - 31 * 0.191163 + 9.8163 = 70.602
      expect(estimateSocPercent(61075, batteryTempC: 31), 71);
      // 58175 * 0.00109229 - 31 * 0.191163 + 9.8163 = 67.434
      expect(estimateSocPercent(58175, batteryTempC: 31.0), 67);
    });

    test('is clamped to 0-100 %', () {
      expect(estimateSocPercent(200000), 100);
      expect(estimateSocPercent(200000, batteryTempC: 20), 100);
      // 0 * 0.00109229 - 60 * 0.191163 + 9.8163 = -1.653
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
    expect(ReadingQuantity.range.wireName, 'range');
    expect(ReadingQuantity.chargePower.wireName, 'charge_power');
    expect(ReadingQuantity.odometer.wireName, 'odometer');
  });
}
