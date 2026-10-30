import 'dart:math' as math;
import 'dart:typed_data';

/// One of the tile quantities the recording page lets the owner enter or
/// confirm. [wireName] is this quantity's spelling in the marker sidecar's
/// `reading` lines — fixed, another component parses it.
enum ReadingQuantity {
  soc,
  batteryTemp,
  outsideTemp,
  range,
  chargePower,
  odometer,
}

extension ReadingQuantityWire on ReadingQuantity {
  String get wireName => switch (this) {
    ReadingQuantity.soc => 'soc',
    ReadingQuantity.batteryTemp => 'battery_temp',
    ReadingQuantity.outsideTemp => 'outside_temp',
    ReadingQuantity.range => 'range',
    ReadingQuantity.chargePower => 'charge_power',
    ReadingQuantity.odometer => 'odometer',
  };

  String get label => switch (this) {
    ReadingQuantity.soc => 'State of charge',
    ReadingQuantity.batteryTemp => 'Battery temp.',
    ReadingQuantity.outsideTemp => 'Outside temp.',
    ReadingQuantity.range => 'Range',
    ReadingQuantity.chargePower => 'Charging power',
    ReadingQuantity.odometer => 'Odometer',
  };

  String get unit => switch (this) {
    ReadingQuantity.soc => '%',
    ReadingQuantity.batteryTemp => '°C',
    ReadingQuantity.outsideTemp => '°C',
    ReadingQuantity.range => 'km',
    ReadingQuantity.chargePower => 'kW',
    ReadingQuantity.odometer => 'km',
  };
}

/// Where a [ReadingMarker]'s value came from: the numeric keypad, the ±1
/// steppers, or a one-tap confirmation of a live value already shown.
enum ReadingSource { typed, stepped, confirmed }

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
    this.batteryTempMinC,
    this.batteryTempMaxC,
  });

  static const empty = LiveVehicleInfo();

  final int? speedKmh;
  final double? odometerKm;
  final int? outsideTempC;
  final int? rangeKm;
  final int? storedEnergyWh;

  /// Lowest and highest populated sensor of the unverified HV battery
  /// temperature candidate, see [decodeBatteryTempRangeC].
  final double? batteryTempMinC;
  final double? batteryTempMaxC;

  /// [estimateSocPercent] of [storedEnergyWh] at [batteryTempC] (°C, if
  /// known), or null while [storedEnergyWh] is unknown.
  int? socEstimatePercent({num? batteryTempC}) => storedEnergyWh == null
      ? null
      : estimateSocPercent(storedEnergyWh!, batteryTempC: batteryTempC);

  bool get hasAnyValue =>
      speedKmh != null ||
      odometerKm != null ||
      outsideTempC != null ||
      rangeKm != null ||
      storedEnergyWh != null ||
      batteryTempMinC != null ||
      batteryTempMaxC != null;
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

/// Decodes a `222A2D` positive payload from module `hcp1` into the lowest
/// and highest populated sensor temperature, in °C, or returns null when
/// [payload] has no populated sensor slot. Byte 0 is a format/count byte;
/// every following byte is one sensor slot, raw / 2 - 64 °C, and a slot at
/// or below 0x31 (-39.5 °C) is unpopulated. An unverified candidate for
/// the HV battery temperature: its minimum has matched the vehicle's
/// displayed battery temperature at a single data point only.
({double min, double max})? decodeBatteryTempRangeC(Uint8List payload) {
  final temps = [
    for (final raw in payload.skip(1))
      if (raw > 0x31) raw / 2 - 64,
  ];
  if (temps.isEmpty) return null;
  return (min: temps.reduce(math.min), max: temps.reduce(math.max));
}

/// Estimates the state of charge the vehicle displays from
/// [storedEnergyWh] (`222AB8`) and returns it in percent, clamped to 0-100.
/// Not a decoded DID: a linear fit of the owner's typed SoC readings on the
/// one vehicle recorded so far. Stored energy reads lower with a cold
/// battery while the display does not, so [batteryTempC] (°C), when given,
/// is part of the fit and keeps the estimate within about 1.3 percentage
/// points of the display; without it, the error reaches about 3.
int estimateSocPercent(int storedEnergyWh, {num? batteryTempC}) {
  final soc = batteryTempC == null
      ? storedEnergyWh * 0.0011077 + 5.38
      : storedEnergyWh * 0.00109229 - batteryTempC * 0.191163 + 9.8163;
  return soc.round().clamp(0, 100);
}
