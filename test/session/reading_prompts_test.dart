import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/capture/readings.dart';
import 'package:didscout_app/session/reading_prompts.dart';
import 'package:didscout_app/session/session_markers.dart';

final DateTime _now = DateTime.utc(2026, 1, 1, 12);

DateTime _minutesAgo(int minutes) => _now.subtract(Duration(minutes: minutes));

List<ReadingQuantity> _prompted({
  MarkerPhase? phase,
  bool stationary = false,
  Map<ReadingQuantity, DateTime> lastReadAt = const {},
}) => [
  for (final prompt in readingPrompts(
    phase: phase,
    stationary: stationary,
    now: _now,
    lastReadAt: lastReadAt,
  ))
    prompt.quantity,
];

void main() {
  test('everything read recently prompts nothing', () {
    for (final phase in [null, ...MarkerPhase.values]) {
      for (final stationary in [false, true]) {
        expect(
          _prompted(
            phase: phase,
            stationary: stationary,
            lastReadAt: {
              ReadingQuantity.batteryTemp: _minutesAgo(1),
              ReadingQuantity.chargePower: _minutesAgo(1),
              ReadingQuantity.soc: _minutesAgo(1),
              ReadingQuantity.chargePowerMax: _minutesAgo(1),
            },
          ),
          isEmpty,
        );
      }
    }
  });

  group('battery temp.', () {
    test('is prompted in any phase when never read', () {
      for (final phase in [null, ...MarkerPhase.values]) {
        expect(_prompted(phase: phase), contains(ReadingQuantity.batteryTemp));
      }
    });

    test('is prompted only once the last reading is over 15 min old', () {
      expect(
        _prompted(
          phase: MarkerPhase.drive,
          lastReadAt: {ReadingQuantity.batteryTemp: _minutesAgo(15)},
        ),
        isEmpty,
      );
      expect(
        _prompted(
          phase: MarkerPhase.drive,
          lastReadAt: {ReadingQuantity.batteryTemp: _minutesAgo(16)},
        ),
        [ReadingQuantity.batteryTemp],
      );
    });

    test('gives the reason the owner is asked', () {
      final never = readingPrompts(
        phase: MarkerPhase.drive,
        stationary: false,
        now: _now,
        lastReadAt: const {},
      ).single;
      final stale = readingPrompts(
        phase: MarkerPhase.drive,
        stationary: false,
        now: _now,
        lastReadAt: {ReadingQuantity.batteryTemp: _minutesAgo(16)},
      ).single;

      expect(never.reason, 'Not read yet');
      expect(stale.reason, 'Last read over 15 min ago');
    });
  });

  group('charge phase', () {
    final batteryTempFresh = {ReadingQuantity.batteryTemp: _minutesAgo(1)};

    test('prompts charging power and SoC when never read', () {
      expect(
        _prompted(phase: MarkerPhase.charge, lastReadAt: batteryTempFresh),
        [ReadingQuantity.chargePower, ReadingQuantity.soc],
      );
    });

    test('prompts each only once its last reading is over 5 min old', () {
      expect(
        _prompted(
          phase: MarkerPhase.charge,
          lastReadAt: {
            ...batteryTempFresh,
            ReadingQuantity.chargePower: _minutesAgo(5),
            ReadingQuantity.soc: _minutesAgo(6),
          },
        ),
        [ReadingQuantity.soc],
      );
    });

    test('never prompts the max. charging power, even when stationary', () {
      expect(
        _prompted(
          phase: MarkerPhase.charge,
          stationary: true,
          lastReadAt: batteryTempFresh,
        ),
        isNot(contains(ReadingQuantity.chargePowerMax)),
      );
    });
  });

  test('charging power and SoC are not prompted outside the charge phase', () {
    for (final phase in [null, MarkerPhase.drive, MarkerPhase.stand]) {
      final prompted = _prompted(phase: phase, stationary: true);
      expect(prompted, isNot(contains(ReadingQuantity.chargePower)));
      expect(prompted, isNot(contains(ReadingQuantity.soc)));
    }
  });

  group('max. charging power', () {
    final batteryTempFresh = {ReadingQuantity.batteryTemp: _minutesAgo(1)};

    test('is prompted when stationary outside the charge phase', () {
      for (final phase in [null, MarkerPhase.stand, MarkerPhase.park]) {
        expect(
          _prompted(
            phase: phase,
            stationary: true,
            lastReadAt: batteryTempFresh,
          ),
          [ReadingQuantity.chargePowerMax],
        );
      }
    });

    test('is not prompted while moving', () {
      expect(
        _prompted(phase: MarkerPhase.park, lastReadAt: batteryTempFresh),
        isEmpty,
      );
    });

    test('is prompted only once the last reading is over 60 min old', () {
      expect(
        _prompted(
          phase: MarkerPhase.park,
          stationary: true,
          lastReadAt: {
            ...batteryTempFresh,
            ReadingQuantity.chargePowerMax: _minutesAgo(60),
          },
        ),
        isEmpty,
      );
      expect(
        _prompted(
          phase: MarkerPhase.park,
          stationary: true,
          lastReadAt: {
            ...batteryTempFresh,
            ReadingQuantity.chargePowerMax: _minutesAgo(61),
          },
        ),
        [ReadingQuantity.chargePowerMax],
      );
    });
  });

  test('never prompts values the vehicle reports or experiment follow-ups', () {
    for (final phase in [null, ...MarkerPhase.values]) {
      for (final stationary in [false, true]) {
        expect(
          _prompted(phase: phase, stationary: stationary),
          everyElement(
            isNot(
              anyOf(
                ReadingQuantity.odometer,
                ReadingQuantity.range,
                ReadingQuantity.outsideTemp,
                ReadingQuantity.insideTemp,
              ),
            ),
          ),
        );
      }
    }
  });

  test('lists prompts in rule order', () {
    expect(_prompted(phase: MarkerPhase.charge), [
      ReadingQuantity.batteryTemp,
      ReadingQuantity.chargePower,
      ReadingQuantity.soc,
    ]);
    expect(_prompted(phase: MarkerPhase.stand, stationary: true), [
      ReadingQuantity.batteryTemp,
      ReadingQuantity.chargePowerMax,
    ]);
  });
}
