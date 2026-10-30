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
  });

  static const empty = LiveVehicleInfo();

  final int? speedKmh;
  final double? odometerKm;
  final int? outsideTempC;
  final int? rangeKm;
  final int? storedEnergyWh;

  /// [estimateSocPercent] of [storedEnergyWh], when known.
  int? get socEstimatePercent =>
      storedEnergyWh == null ? null : estimateSocPercent(storedEnergyWh!);

  bool get hasAnyValue =>
      speedKmh != null ||
      odometerKm != null ||
      outsideTempC != null ||
      rangeKm != null ||
      storedEnergyWh != null;
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

/// Estimates the state of charge the vehicle displays from
/// [storedEnergyWh] (`222AB8`), clamped to 0-100 %. Not a decoded DID: a
/// linear fit of the owner's typed SoC readings against stored energy on
/// the one vehicle recorded so far. It stays within about 3 percentage
/// points of the display, which drifts from stored energy with battery
/// temperature.
int estimateSocPercent(int storedEnergyWh) =>
    (storedEnergyWh * 0.0011077 + 5.38).round().clamp(0, 100);
