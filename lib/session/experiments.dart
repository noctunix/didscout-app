import 'package:flutter/foundation.dart';

import '../capture/diff.dart';
import '../capture/readings.dart';
import 'session_markers.dart';

/// One guided before/after experiment: a single action the owner takes
/// while the vehicle is stationary, bracketed by reads of the
/// [targetHeaders] ECUs' discovered DIDs.
@immutable
class Experiment {
  const Experiment({
    required this.id,
    required this.title,
    required this.instruction,
    required this.phases,
    required this.targetHeaders,
    this.followUp,
  });

  /// Stable id recorded in [ExperimentMarker.id]; never renamed, another
  /// component matches markers by it.
  final String id;

  final String title;

  /// What the owner is asked to do between the before and after reads.
  final String instruction;

  /// The phases in which this experiment may be suggested.
  final Set<MarkerPhase> phases;

  /// Request headers of the ECUs expected to reflect the action.
  final List<String> targetHeaders;

  /// The display value to ask the owner for once the after reads are in,
  /// if the action changes one.
  final ReadingQuantity? followUp;
}

const Set<MarkerPhase> _stationary = {MarkerPhase.stand, MarkerPhase.park};
const Set<MarkerPhase> _stationaryOrCharging = {
  MarkerPhase.stand,
  MarkerPhase.park,
  MarkerPhase.charge,
};

/// Every experiment the app can suggest, in suggestion order among
/// equally often completed ones.
const List<Experiment> experimentCatalog = [
  Experiment(
    id: 'charge-flap-left',
    title: 'Left charge flap',
    instruction: 'Open the left charge flap, wait 5 s, then close it.',
    phases: _stationaryOrCharging,
    targetHeaders: ['17FC0082'],
  ),
  Experiment(
    id: 'charge-flap-right',
    title: 'Right charge flap',
    instruction: 'Open the right charge flap, wait 5 s, then close it.',
    phases: _stationaryOrCharging,
    targetHeaders: ['17FC0083'],
  ),
  Experiment(
    id: 'door-driver',
    title: 'Driver door',
    instruction: 'Open the driver door, then close it.',
    phases: _stationaryOrCharging,
    targetHeaders: ['74A'],
  ),
  Experiment(
    id: 'door-passenger',
    title: 'Passenger door',
    instruction: 'Open the front passenger door, then close it.',
    phases: _stationaryOrCharging,
    targetHeaders: ['74B'],
  ),
  Experiment(
    id: 'door-rear-left',
    title: 'Rear left door',
    instruction: 'Open the rear left door, then close it.',
    phases: _stationaryOrCharging,
    targetHeaders: ['73E'],
  ),
  Experiment(
    id: 'door-rear-right',
    title: 'Rear right door',
    instruction: 'Open the rear right door, then close it.',
    phases: _stationaryOrCharging,
    targetHeaders: ['73F'],
  ),
  Experiment(
    id: 'window-driver',
    title: 'Driver window',
    instruction: 'Lower the driver window a little.',
    phases: _stationary,
    targetHeaders: ['74A'],
  ),
  Experiment(
    id: 'climate-setpoint',
    title: 'Cabin temperature',
    instruction: 'Raise the cabin temperature setpoint by 3 °C.',
    phases: _stationaryOrCharging,
    targetHeaders: ['767'],
    followUp: ReadingQuantity.insideTemp,
  ),
  Experiment(
    id: 'climate-ac',
    title: 'A/C',
    instruction: 'Switch the A/C off, or on if it is off.',
    phases: _stationaryOrCharging,
    targetHeaders: ['767'],
  ),
  Experiment(
    id: 'climate-fan',
    title: 'Fan',
    instruction: 'Set the fan to maximum.',
    phases: _stationaryOrCharging,
    targetHeaders: ['767'],
  ),
  Experiment(
    id: 'seat-heating',
    title: 'Seat heating',
    instruction: 'Switch the driver seat heating to the highest level.',
    phases: _stationaryOrCharging,
    targetHeaders: ['74C'],
  ),
  Experiment(
    id: 'lights',
    title: 'Low beam',
    instruction: 'Switch the low beam on.',
    phases: _stationaryOrCharging,
    targetHeaders: ['70E'],
  ),
  Experiment(
    id: 'lock',
    title: 'Lock and unlock',
    instruction: 'Lock the car with the key or the app, then unlock it.',
    phases: _stationary,
    targetHeaders: ['70E', '74A', '74B'],
  ),
  Experiment(
    id: 'tailgate',
    title: 'Tailgate',
    instruction: 'Open the tailgate, then close it.',
    phases: _stationary,
    targetHeaders: ['17FC008B', '70E'],
  ),
  Experiment(
    id: 'phone-charger',
    title: 'Wireless phone charger',
    instruction: 'Place a phone on the wireless charging pad.',
    phases: _stationary,
    targetHeaders: ['17FC00A5'],
  ),
  Experiment(
    id: 'charge-limit',
    title: 'Charge limit',
    instruction:
        'Change the charge limit in the vehicle or the app by 10 '
        'percentage points.',
    phases: {MarkerPhase.charge},
    targetHeaders: ['17FC007B', '18DA0FF1', '710'],
    followUp: ReadingQuantity.soc,
  ),
];

/// The experiments worth suggesting to the owner right now, from
/// [experimentCatalog].
///
/// Only experiments allowed in [phase] whose [Experiment.targetHeaders]
/// include at least one of [answeringRequestHeaders] qualify, so the
/// before and after reads have an ECU to come from. They are ordered by
/// how often they were completed, fewest first, then in catalog order.
///
/// - [phase]: the session's current phase; null (no phase chosen yet)
///   suggests nothing.
/// - [stationary]: whether the vehicle is standing still; while it is
///   moving, nothing is suggested.
/// - [answeringRequestHeaders]: request headers of the ECUs that have
///   answered in this session.
/// - [completedCounts]: completed runs per [Experiment.id]; a missing id
///   counts as never completed.
///
/// Returns the qualifying experiments in suggestion order, or an empty
/// list.
List<Experiment> suggestedExperiments({
  required MarkerPhase? phase,
  required bool stationary,
  required Set<String> answeringRequestHeaders,
  required Map<String, int> completedCounts,
}) {
  if (!stationary || phase == null) {
    return const [];
  }
  final candidates = [
    for (final (index, experiment) in experimentCatalog.indexed)
      if (experiment.phases.contains(phase) &&
          experiment.targetHeaders.any(answeringRequestHeaders.contains))
        (index, experiment),
  ];
  int completed(Experiment experiment) => completedCounts[experiment.id] ?? 0;
  candidates.sort((a, b) {
    final byCount = completed(a.$2).compareTo(completed(b.$2));
    return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
  });
  return [for (final (_, experiment) in candidates) experiment];
}

/// One read of a set of ECUs' DIDs: request header -> DID (4 hex digits)
/// -> that DID's positive ReadDataByIdentifier payload.
typedef DidSnapshot = Map<String, Map<String, Uint8List>>;

/// The DIDs whose payload changed between an experiment's [before] and
/// [after] reads, per request header.
///
/// Only DIDs present in both snapshots are compared, over the shorter
/// payload's length (see [diffBytes]). Each [DidDiff.module] is the
/// request header. Headers without a changed DID are left out; each
/// header's DIDs are sorted by DID.
Map<String, List<DidDiff>> experimentChanges({
  required DidSnapshot before,
  required DidSnapshot after,
}) {
  final changes = <String, List<DidDiff>>{};
  for (final MapEntry(key: header, value: beforeDids) in before.entries) {
    final afterDids = after[header];
    if (afterDids == null) {
      continue;
    }
    final changed = [
      for (final MapEntry(key: did, value: beforePayload) in beforeDids.entries)
        if (afterDids[did] case final afterPayload?)
          if (diffBytes(beforePayload, afterPayload) case final bytes
              when bytes.isNotEmpty)
            DidDiff(
              module: header,
              did: did,
              before: beforePayload,
              after: afterPayload,
              changes: bytes,
            ),
    ]..sort((a, b) => a.did.compareTo(b.did));
    if (changed.isNotEmpty) {
      changes[header] = changed;
    }
  }
  return changes;
}
