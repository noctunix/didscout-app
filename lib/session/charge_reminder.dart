import 'session_markers.dart';

/// Decides when the charging-round reminder ("ask for SoC and battery
/// temp") is due, independent of any real [Timer] — so tests can drive it
/// with a fake clock instead of waiting on wall-clock time. The owning
/// controller is expected to call [checkDue] on its own short, regular tick
/// and show a reminder exactly when it returns true.
class ChargeReminderScheduler {
  ChargeReminderScheduler({
    this.interval = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration interval;
  final DateTime Function() _clock;

  bool _active = false;
  DateTime? _lastReminderAt;

  /// Whether the charging round is currently active (phase == charge).
  bool get active => _active;

  /// Tells the scheduler the session's phase changed. Entering [MarkerPhase]
  /// charge arms the reminder, starting its first interval from now; leaving
  /// it disarms the reminder until charge is entered again.
  void phaseChanged(MarkerPhase phase) {
    if (phase == MarkerPhase.charge) {
      _active = true;
      _lastReminderAt = _clock();
    } else {
      _active = false;
      _lastReminderAt = null;
    }
  }

  /// Checks whether a reminder is due right now. Returns true at most once
  /// per [interval] while [active]; false while inactive, or before the
  /// interval has elapsed since the last reminder (or since charge was
  /// entered, for the first one).
  bool checkDue() {
    if (!_active || _lastReminderAt == null) return false;
    final now = _clock();
    if (!now.isBefore(_lastReminderAt!.add(interval))) {
      _lastReminderAt = now;
      return true;
    }
    return false;
  }
}
