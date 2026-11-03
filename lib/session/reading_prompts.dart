import 'package:flutter/foundation.dart';

import '../capture/readings.dart';
import 'session_markers.dart';

/// How old the last battery temperature reading may get before the owner
/// is asked again, in any phase.
const Duration batteryTempPromptInterval = Duration(minutes: 15);

/// How old the last charging power and state of charge readings may get
/// while charging before the owner is asked again.
const Duration chargingPromptInterval = Duration(minutes: 5);

/// How old the last predicted maximum charging power reading may get
/// while stationary and not charging before the owner is asked again.
const Duration chargePowerMaxPromptInterval = Duration(minutes: 60);

/// A display value the owner should read off now, and why.
@immutable
class ReadingPrompt {
  const ReadingPrompt({required this.quantity, required this.reason});

  final ReadingQuantity quantity;

  /// A short English explanation for the owner.
  final String reason;
}

/// The display values the owner should read off now, in this order:
///
/// 1. [ReadingQuantity.batteryTemp], in any phase, when it was never read
///    or last read more than [batteryTempPromptInterval] ago.
/// 2. [ReadingQuantity.chargePower], then [ReadingQuantity.soc], in the
///    charge phase, each when never read or last read more than
///    [chargingPromptInterval] ago.
/// 3. [ReadingQuantity.chargePowerMax], when [stationary] and not in the
///    charge phase, when never read or last read more than
///    [chargePowerMaxPromptInterval] ago.
///
/// Values the vehicle reports itself (odometer, range, outside
/// temperature, and whatever is in [reportedByVehicle]) are never prompted
/// for, and the inside temperature only as an experiment's follow-up. Apart from rule 3, motion is not
/// considered: the caller decides how to show prompts while driving.
///
/// - [phase]: the session's current phase, or null if none was chosen.
/// - [stationary]: whether the vehicle is standing still.
/// - [now]: the current time, compared against [lastReadAt].
/// - [lastReadAt]: when each quantity was last read; a missing quantity
///   was never read.
/// - [reportedByVehicle]: the quantities the vehicle currently reports a
///   decoded value for; an estimate does not count.
///
/// Returns the due prompts, or an empty list.
List<ReadingPrompt> readingPrompts({
  required MarkerPhase? phase,
  required bool stationary,
  required DateTime now,
  required Map<ReadingQuantity, DateTime> lastReadAt,
  Set<ReadingQuantity> reportedByVehicle = const {},
}) {
  ReadingPrompt? due(ReadingQuantity quantity, Duration interval) {
    if (reportedByVehicle.contains(quantity)) return null;
    final last = lastReadAt[quantity];
    if (last == null) {
      return ReadingPrompt(quantity: quantity, reason: 'Not read yet');
    }
    if (now.difference(last) > interval) {
      return ReadingPrompt(
        quantity: quantity,
        reason: 'Last read over ${interval.inMinutes} min ago',
      );
    }
    return null;
  }

  final charging = phase == MarkerPhase.charge;
  return [
    ?due(ReadingQuantity.batteryTemp, batteryTempPromptInterval),
    if (charging) ...[
      ?due(ReadingQuantity.chargePower, chargingPromptInterval),
      ?due(ReadingQuantity.soc, chargingPromptInterval),
    ],
    if (stationary && !charging)
      ?due(ReadingQuantity.chargePowerMax, chargePowerMaxPromptInterval),
  ];
}

/// How long a reading of [quantity] stays current in [phase]: as long as
/// [readingPrompts] waits before asking for it again, and
/// [batteryTempPromptInterval] for everything it does not ask for.
Duration readingStaleAfter(ReadingQuantity quantity, MarkerPhase? phase) =>
    switch (quantity) {
      ReadingQuantity.chargePower || ReadingQuantity.soc
          when phase == MarkerPhase.charge =>
        chargingPromptInterval,
      ReadingQuantity.chargePowerMax => chargePowerMaxPromptInterval,
      _ => batteryTempPromptInterval,
    };
