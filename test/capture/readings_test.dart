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

  group('decodeBatteryTempC', () {
    test('uint16 big-endian, 1/8 degC, minus 40 degC', () {
      // 0x0204 = 516 -> 516 / 8 - 40 = 24.5 degC.
      expect(decodeBatteryTempC(Uint8List.fromList([0x02, 0x04])), 24.5);
      // 0x0140 = 320 -> 0 degC; 0x00A0 = 160 -> -20 degC.
      expect(decodeBatteryTempC(Uint8List.fromList([0x01, 0x40])), 0);
      expect(decodeBatteryTempC(Uint8List.fromList([0x00, 0xA0])), -20);
    });

    test('too short is null', () {
      expect(decodeBatteryTempC(Uint8List.fromList([0x02])), isNull);
    });
  });

  group('decodeChargePowerKw', () {
    test('first uint16 big-endian, 0.1 kW, minus 50 kW', () {
      // 0x0CCB = 3275 -> (3275 - 500) / 10 = 277.5 kW.
      expect(
        decodeChargePowerKw(Uint8List.fromList([0x0C, 0xCB, 0x03, 0x8B])),
        277.5,
      );
      // 0x01F4 = 500 is what it reads while not charging.
      expect(decodeChargePowerKw(Uint8List.fromList([0x01, 0xF4])), 0);
    });

    test('too short is null', () {
      expect(decodeChargePowerKw(Uint8List.fromList([0x0C])), isNull);
    });
  });

  group('estimateSocPercent', () {
    // Energy, battery temperature and the display value of real readings.
    test('with battery temp., matches the display', () {
      // 59322 Wh at 50.1 degC, display 67 %.
      expect(estimateSocPercent(59322, batteryTempC: 50.1), 67);
      // 37310 Wh at 9 degC, display 50 %.
      expect(estimateSocPercent(37310, batteryTempC: 9), 50);
      // 82635 Wh at 30.2 degC, display 93 %.
      expect(estimateSocPercent(82635, batteryTempC: 30.2), 93);
    });

    test('the same energy reads higher with a cold battery only', () {
      // 37310 * 0.00109775 + 1.4812 = 42.438; below 33 degC plus
      // 0.301022 per K: 24 K -> 49.663.
      expect(estimateSocPercent(37310, batteryTempC: 40), 42);
      expect(estimateSocPercent(37310, batteryTempC: 33), 42);
      expect(estimateSocPercent(37310, batteryTempC: 9), 50);
    });

    test('without battery temp., uses the energy-only fit', () {
      // 61075 * 0.00107967 + 4.7633 = 70.704
      expect(estimateSocPercent(61075), 71);
    });

    test('is clamped to 100 %', () {
      expect(estimateSocPercent(200000), 100);
      expect(estimateSocPercent(200000, batteryTempC: 20), 100);
    });

    test('is what LiveVehicleInfo reports, and null without energy', () {
      const info = LiveVehicleInfo(storedEnergyWh: 37310);
      expect(info.socEstimatePercent(), 45);
      expect(info.socEstimatePercent(batteryTempC: 9), 50);
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
    expect(ReadingQuantity.chargePowerMax.wireName, 'charge_power_max');
    expect(ReadingQuantity.odometer.wireName, 'odometer');
  });

  test('spokenUnit spells out each unit', () {
    for (final quantity in ReadingQuantity.values) {
      expect(quantity.spokenUnit, switch (quantity.unit) {
        '%' => 'percent',
        '°C' => 'degrees Celsius',
        'km' => 'kilometres',
        'kW' => 'kilowatts',
        _ => fail('unexpected unit ${quantity.unit}'),
      });
    }
  });
}
