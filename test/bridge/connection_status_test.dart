import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/bridge/connection_status.dart';

void main() {
  test('connected renders plainly', () {
    expect(describeConnectionStatus(const ConnectionStatus.connected()), 'Connected');
  });

  test('reconnecting renders the local start time and attempt count', () {
    final since = DateTime(2026, 5, 1, 9, 7).toUtc();
    final status = ConnectionStatus.reconnecting(since: since, attempt: 3);

    final text = describeConnectionStatus(status);
    expect(text, startsWith('Reconnecting since '));
    expect(text, contains('(attempt 3)'));
  });

  test('stopped renders the plugin-supplied reason', () {
    final status = ConnectionStatus.stopped('reconnect attempts exhausted');

    expect(
      describeConnectionStatus(status),
      'Stopped: reconnect attempts exhausted',
    );
  });
}
