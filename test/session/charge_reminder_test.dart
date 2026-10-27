import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/session/charge_reminder.dart';
import 'package:didscout_app/session/session_markers.dart';

void main() {
  group('ChargeReminderScheduler', () {
    test('inactive outside the charge phase', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final scheduler = ChargeReminderScheduler(clock: () => now);

      scheduler.phaseChanged(MarkerPhase.drive);
      now = now.add(const Duration(minutes: 10));

      expect(scheduler.active, isFalse);
      expect(scheduler.checkDue(), isFalse);
    });

    test('fires every 5 minutes while charging, not before', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final scheduler = ChargeReminderScheduler(clock: () => now);

      scheduler.phaseChanged(MarkerPhase.charge);
      expect(scheduler.active, isTrue);

      now = now.add(const Duration(minutes: 4));
      expect(scheduler.checkDue(), isFalse);

      now = now.add(const Duration(minutes: 1));
      expect(scheduler.checkDue(), isTrue);

      // Immediately after firing, not due again.
      expect(scheduler.checkDue(), isFalse);

      now = now.add(const Duration(minutes: 5));
      expect(scheduler.checkDue(), isTrue);
    });

    test('leaving the charge phase disarms the reminder', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final scheduler = ChargeReminderScheduler(clock: () => now);

      scheduler.phaseChanged(MarkerPhase.charge);
      now = now.add(const Duration(minutes: 5));
      scheduler.phaseChanged(MarkerPhase.drive);

      expect(scheduler.active, isFalse);
      expect(scheduler.checkDue(), isFalse);
    });

    test('re-entering charge restarts the 5-minute window', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final scheduler = ChargeReminderScheduler(clock: () => now);

      scheduler.phaseChanged(MarkerPhase.charge);
      now = now.add(const Duration(minutes: 3));
      scheduler.phaseChanged(MarkerPhase.stand);
      now = now.add(const Duration(minutes: 1));
      scheduler.phaseChanged(MarkerPhase.charge);

      now = now.add(const Duration(minutes: 4));
      expect(scheduler.checkDue(), isFalse);
      now = now.add(const Duration(minutes: 1));
      expect(scheduler.checkDue(), isTrue);
    });
  });
}
