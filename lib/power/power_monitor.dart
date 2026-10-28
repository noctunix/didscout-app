import 'package:battery_plus/battery_plus.dart';

/// Whether the device is currently plugged into external power, collapsed
/// from `battery_plus`'s finer-grained [BatteryState].
enum PowerConnection { connected, disconnected }

/// Wraps `battery_plus`'s battery-state stream and maps it to
/// [PowerConnection]. [batteryStateStream] is overridable so tests can drive
/// it with a fake battery source instead of the real platform channel.
class PowerMonitor {
  PowerMonitor({Stream<BatteryState>? batteryStateStream, Battery? battery})
    : _batteryStateStream =
          batteryStateStream ?? (battery ?? Battery()).onBatteryStateChanged;

  final Stream<BatteryState> _batteryStateStream;

  Stream<PowerConnection> get connectionChanges =>
      _batteryStateStream.map(_toConnection).distinct();

  /// [BatteryState.connectedNotCharging] still means plugged in (a charge
  /// limit or an underpowered source can hold charging off indefinitely) —
  /// it counts as connected, same as [BatteryState.charging]/[BatteryState.full].
  static PowerConnection _toConnection(BatteryState state) => switch (state) {
    BatteryState.charging ||
    BatteryState.full ||
    BatteryState.connectedNotCharging => PowerConnection.connected,
    BatteryState.discharging ||
    BatteryState.unknown => PowerConnection.disconnected,
  };
}
