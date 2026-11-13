import 'dart:math';
import 'dart:typed_data';

/// One of the tile quantities the recording page lets the owner enter or
/// confirm. [wireName] is this quantity's spelling in the marker sidecar's
/// `reading` lines — fixed, another component parses it.
enum ReadingQuantity {
  soc,
  batteryTemp,
  outsideTemp,
  insideTemp,
  range,

  /// The power actually flowing into the battery while charging.
  chargePower,

  /// The maximum charging power the vehicle predicts while not charging;
  /// it falls with state of charge and rises with battery temperature.
  chargePowerMax,

  odometer,
}

extension ReadingQuantityWire on ReadingQuantity {
  String get wireName => switch (this) {
    ReadingQuantity.soc => 'soc',
    ReadingQuantity.batteryTemp => 'battery_temp',
    ReadingQuantity.outsideTemp => 'outside_temp',
    ReadingQuantity.insideTemp => 'inside_temp',
    ReadingQuantity.range => 'range',
    ReadingQuantity.chargePower => 'charge_power',
    ReadingQuantity.chargePowerMax => 'charge_power_max',
    ReadingQuantity.odometer => 'odometer',
  };

  String get label => switch (this) {
    ReadingQuantity.soc => 'State of charge',
    ReadingQuantity.batteryTemp => 'Battery temp.',
    ReadingQuantity.outsideTemp => 'Outside temp.',
    ReadingQuantity.insideTemp => 'Inside temp.',
    ReadingQuantity.range => 'Range',
    ReadingQuantity.chargePower => 'Charging power (now)',
    ReadingQuantity.chargePowerMax => 'Max. charging power',
    ReadingQuantity.odometer => 'Odometer',
  };

  String get unit => switch (this) {
    ReadingQuantity.soc => '%',
    ReadingQuantity.batteryTemp => '°C',
    ReadingQuantity.outsideTemp => '°C',
    ReadingQuantity.insideTemp => '°C',
    ReadingQuantity.range => 'km',
    ReadingQuantity.chargePower => 'kW',
    ReadingQuantity.chargePowerMax => 'kW',
    ReadingQuantity.odometer => 'km',
  };

  /// [unit] spelled out for screen readers.
  String get spokenUnit => switch (this) {
    ReadingQuantity.soc => 'percent',
    ReadingQuantity.batteryTemp ||
    ReadingQuantity.outsideTemp ||
    ReadingQuantity.insideTemp => 'degrees Celsius',
    ReadingQuantity.range || ReadingQuantity.odometer => 'kilometres',
    ReadingQuantity.chargePower ||
    ReadingQuantity.chargePowerMax => 'kilowatts',
  };

  /// The resolution of the vehicle's display for this quantity, which the
  /// entry sheet's steppers move by.
  num get displayStep => switch (this) {
    ReadingQuantity.outsideTemp || ReadingQuantity.insideTemp => 0.5,
    _ => 1,
  };
}

/// Where a [ReadingMarker]'s value came from: the numeric keypad, the
/// steppers, or the entry sheet's prefilled value saved unchanged.
enum ReadingSource { typed, stepped, confirmed }

/// What the entry sheet's prefilled value was: the vehicle's own live
/// value, or the owner's last entry for the same quantity.
enum PrefillOrigin { live, entry }

/// The vehicle's own live values, decoded from the bridge's live-state
/// query. A field is null when its signal hasn't answered yet, or when no
/// live source is available at all (e.g. no live-state API, or not
/// currently recording) — callers show "no live info" in that case rather
/// than treating it as zero.
class LiveVehicleInfo {
  const LiveVehicleInfo({
    this.speedKmh,
    this.odometerKm,
    this.outsideTempC,
    this.rangeKm,
    this.storedEnergyWh,
    this.batteryTempC,
    this.chargePowerKw,
  });

  static const empty = LiveVehicleInfo();

  final int? speedKmh;
  final double? odometerKm;
  final int? outsideTempC;
  final int? rangeKm;
  final int? storedEnergyWh;
  final double? batteryTempC;
  final double? chargePowerKw;

  /// [estimateSocPercent] of [storedEnergyWh] at [batteryTempC] (°C, if
  /// known), or null while [storedEnergyWh] is unknown.
  int? socEstimatePercent({num? batteryTempC}) => storedEnergyWh == null
      ? null
      : estimateSocPercent(storedEnergyWh!, batteryTempC: batteryTempC);
}

/// Decodes a `22F40D` (speed) positive payload: byte 0, km/h.
int? decodeSpeedKmh(Uint8List payload) {
  if (payload.isEmpty) return null;
  return payload[0];
}

/// Decodes a `22F4A6` (odometer) positive payload: uint32 big-endian, tenths
/// of a km.
double? decodeOdometerKm(Uint8List payload) {
  if (payload.length < 4) return null;
  final raw =
      (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
  return raw / 10;
}

/// Decodes a `22F446` (outside temperature) positive payload: byte 0 minus
/// the UDS 40 °C offset.
int? decodeOutsideTempC(Uint8List payload) {
  if (payload.isEmpty) return null;
  return payload[0] - 40;
}

/// Decodes a `222AB6` (range) positive payload: first uint16 big-endian, km.
int? decodeRangeKm(Uint8List payload) {
  if (payload.length < 2) return null;
  return (payload[0] << 8) | payload[1];
}

/// Decodes a `222AB8` (stored energy) positive payload: uint16 big-endian at
/// byte offset 2, in units of 25 Wh.
int? decodeStoredEnergyWh(Uint8List payload) {
  if (payload.length < 4) return null;
  final raw = (payload[2] << 8) | payload[3];
  return raw * 25;
}

/// Decodes a `221E10` (HV battery temperature, battery management
/// `17FC007B`) positive payload: uint16 big-endian, 1/8 °C, offset -40 °C.
double? decodeBatteryTempC(Uint8List payload) {
  if (payload.length < 2) return null;
  return ((payload[0] << 8) | payload[1]) / 8 - 40;
}

/// Decodes a `220311` (charging power, gateway) positive payload: uint16
/// big-endian, 0.1 kW, offset -50 kW; reads 0 while not charging.
double? decodeChargePowerKw(Uint8List payload) {
  if (payload.length < 2) return null;
  return (((payload[0] << 8) | payload[1]) - 500) / 10;
}

/// Estimates the state of charge the vehicle displays from
/// [storedEnergyWh] (`222AB8`) and returns it in percent, clamped to 0-100.
/// Not a decoded DID: a fit of the owner's typed SoC readings on this one
/// vehicle (74 readings, 9-96 %, battery 9-50 °C). Below 33 °C the stored
/// energy reads lower than the display suggests, so [batteryTempC] (°C),
/// when given, keeps the estimate within 1.5 percentage points of the
/// display; without it, the error reaches 5.
int estimateSocPercent(int storedEnergyWh, {num? batteryTempC}) {
  final soc = batteryTempC == null
      ? storedEnergyWh * 0.00107967 + 4.7633
      : storedEnergyWh * 0.00109775 +
            1.4812 -
            0.301022 * min(batteryTempC - 33, 0);
  return soc.round().clamp(0, 100);
}
