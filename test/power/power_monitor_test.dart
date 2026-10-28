import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/power/power_monitor.dart';

void main() {
  Future<List<PowerConnection>> collect(List<BatteryState> states) {
    final monitor = PowerMonitor(
      batteryStateStream: Stream.fromIterable(states),
    );
    return monitor.connectionChanges.toList();
  }

  test('charging and full both map to connected', () async {
    final connections = await collect([
      BatteryState.charging,
      BatteryState.unknown,
      BatteryState.full,
    ]);
    expect(connections, [
      PowerConnection.connected,
      PowerConnection.disconnected,
      PowerConnection.connected,
    ]);
  });

  test('connectedNotCharging counts as connected too', () async {
    final connections = await collect([BatteryState.connectedNotCharging]);
    expect(connections, [PowerConnection.connected]);
  });

  test('discharging and unknown both map to disconnected', () async {
    final connections = await collect([
      BatteryState.discharging,
      BatteryState.unknown,
    ]);
    expect(connections, [PowerConnection.disconnected]);
  });

  test('consecutive equal states are deduplicated', () async {
    final connections = await collect([
      BatteryState.charging,
      BatteryState.full,
      BatteryState.discharging,
    ]);
    expect(connections, [
      PowerConnection.connected,
      PowerConnection.disconnected,
    ]);
  });
}
