import 'package:flutter/foundation.dart';

import '../bridge/vag_ppe_plan_data.dart';
import '../capture/diff.dart';
import '../capture/readings.dart';
import '../discovery/did_order.dart';
import '../discovery/discovery_state.dart';
import '../discovery/phase_focus.dart';
import 'session_markers.dart';

/// One guided experiment: a single action the owner takes while the
/// vehicle is stationary and then undoes, with the [targetHeaders] ECUs'
/// discovered DIDs read before the action, after it, and after the undo.
@immutable
class Experiment {
  const Experiment({
    required this.id,
    required this.title,
    required this.instruction,
    required this.undoInstruction,
    required this.phases,
    required this.targetHeaders,
    this.followUp,
  });

  /// Stable id recorded in [ExperimentMarker.id]; never renamed, another
  /// component matches markers by it.
  final String id;

  final String title;

  /// What the owner is asked to do between the before and after reads;
  /// the changed state stays in place for the after reads.
  final String instruction;

  /// What the owner is asked to do between the after and undone reads to
  /// bring the vehicle back to its state before [instruction].
  final String undoInstruction;

  /// The phases in which this experiment may be suggested.
  final Set<MarkerPhase> phases;

  /// Request headers of the ECUs expected to reflect the action.
  final List<String> targetHeaders;

  /// The display value to ask the owner for once the run is done, if the
  /// action changes one.
  final ReadingQuantity? followUp;
}

// Only manually confirmed phases: the automatic stand phase also starts at
// a red light, where no experiment may ask the driver to act.
const Set<MarkerPhase> _parked = {MarkerPhase.park};
const Set<MarkerPhase> _parkedOrCharging = {
  MarkerPhase.park,
  MarkerPhase.charge,
};

/// Every experiment the app can suggest, in suggestion order among
/// equally often completed ones.
const List<Experiment> experimentCatalog = [
  Experiment(
    id: 'charge-flap-left',
    title: 'Left charge flap',
    instruction: 'Open the left charge flap and leave it open.',
    undoInstruction: 'Close the left charge flap.',
    phases: _parkedOrCharging,
    targetHeaders: ['17FC0082'],
  ),
  Experiment(
    id: 'charge-flap-right',
    title: 'Right charge flap',
    instruction: 'Open the right charge flap and leave it open.',
    undoInstruction: 'Close the right charge flap.',
    phases: _parkedOrCharging,
    targetHeaders: ['17FC0083'],
  ),
  Experiment(
    id: 'door-driver',
    title: 'Driver door',
    instruction: 'Open the driver door and leave it open.',
    undoInstruction: 'Close the driver door.',
    phases: _parkedOrCharging,
    targetHeaders: ['74A'],
  ),
  Experiment(
    id: 'door-passenger',
    title: 'Passenger door',
    instruction: 'Open the front passenger door and leave it open.',
    undoInstruction: 'Close the front passenger door.',
    phases: _parkedOrCharging,
    targetHeaders: ['74B'],
  ),
  Experiment(
    id: 'door-rear-left',
    title: 'Rear left door',
    instruction: 'Open the rear left door and leave it open.',
    undoInstruction: 'Close the rear left door.',
    phases: _parkedOrCharging,
    targetHeaders: ['73E'],
  ),
  Experiment(
    id: 'door-rear-right',
    title: 'Rear right door',
    instruction: 'Open the rear right door and leave it open.',
    undoInstruction: 'Close the rear right door.',
    phases: _parkedOrCharging,
    targetHeaders: ['73F'],
  ),
  Experiment(
    id: 'window-driver',
    title: 'Driver window',
    instruction: 'Lower the driver window a little.',
    undoInstruction: 'Raise the driver window again.',
    phases: _parked,
    targetHeaders: ['74A'],
  ),
  Experiment(
    id: 'climate-setpoint',
    title: 'Cabin temperature',
    instruction: 'Raise the cabin temperature setpoint by 3 °C.',
    undoInstruction: 'Lower the cabin temperature setpoint by 3 °C again.',
    phases: _parkedOrCharging,
    targetHeaders: ['767'],
    followUp: ReadingQuantity.insideTemp,
  ),
  Experiment(
    id: 'climate-ac',
    title: 'A/C',
    instruction: 'Switch the A/C off, or on if it is off.',
    undoInstruction: 'Switch the A/C back the way it was.',
    phases: _parkedOrCharging,
    targetHeaders: ['767'],
  ),
  Experiment(
    id: 'climate-fan',
    title: 'Fan',
    instruction: 'Set the fan to maximum.',
    undoInstruction: 'Set the fan back to where it was.',
    phases: _parkedOrCharging,
    targetHeaders: ['767'],
  ),
  Experiment(
    id: 'preconditioning',
    title: 'Preconditioning',
    instruction:
        'Start climate or battery preconditioning in the vehicle or the '
        'app.',
    undoInstruction: 'Stop the preconditioning.',
    phases: _parkedOrCharging,
    targetHeaders: ['767', '742', '17FC007B'],
  ),
  Experiment(
    id: 'seat-heating',
    title: 'Seat heating',
    instruction: 'Switch the driver seat heating to the highest level.',
    undoInstruction: 'Switch the driver seat heating off.',
    phases: _parkedOrCharging,
    targetHeaders: ['74C'],
  ),
  Experiment(
    id: 'steering-wheel-heating',
    title: 'Steering wheel heating',
    instruction: 'Switch the steering wheel heating on.',
    undoInstruction: 'Switch the steering wheel heating off.',
    phases: _parkedOrCharging,
    targetHeaders: ['767', '70C'],
  ),
  Experiment(
    id: 'rear-window-heating',
    title: 'Rear window heating',
    instruction: 'Switch the rear window heating on.',
    undoInstruction: 'Switch the rear window heating off.',
    phases: _parkedOrCharging,
    targetHeaders: ['767', '70E'],
  ),
  Experiment(
    id: 'lights',
    title: 'Low beam',
    instruction: 'Switch the low beam on.',
    undoInstruction: 'Switch the low beam off.',
    phases: _parkedOrCharging,
    targetHeaders: ['70E'],
  ),
  Experiment(
    id: 'hazard-lights',
    title: 'Hazard lights',
    instruction: 'Switch the hazard lights on.',
    undoInstruction: 'Switch the hazard lights off.',
    phases: _parkedOrCharging,
    targetHeaders: ['70E'],
  ),
  Experiment(
    id: 'lock',
    title: 'Lock and unlock',
    instruction: 'Lock the car with the key or the app.',
    undoInstruction: 'Unlock the car.',
    phases: _parked,
    targetHeaders: ['70E', '74A', '74B'],
  ),
  Experiment(
    id: 'tailgate',
    title: 'Tailgate',
    instruction: 'Open the tailgate and leave it open.',
    undoInstruction: 'Close the tailgate.',
    phases: _parked,
    targetHeaders: ['17FC008B', '70E'],
  ),
  Experiment(
    id: 'phone-charger',
    title: 'Wireless phone charger',
    instruction: 'Place a phone on the wireless charging pad.',
    undoInstruction: 'Take the phone off the pad.',
    phases: _parked,
    targetHeaders: ['17FC00A5'],
  ),
  Experiment(
    id: 'drive-select',
    title: 'Driving mode',
    instruction: 'Switch to another driving mode.',
    undoInstruction: 'Switch back to the previous driving mode.',
    phases: _parked,
    targetHeaders: ['18DA0FF1', '710'],
  ),
  Experiment(
    id: 'recuperation-level',
    title: 'Recuperation level',
    instruction: 'Change the recuperation level by one step.',
    undoInstruction: 'Set the recuperation level back to where it was.',
    phases: _parked,
    targetHeaders: ['18DA0FF1', '18DA07F1', '18DA06F1'],
  ),
  Experiment(
    id: 'charge-limit',
    title: 'Charge limit',
    instruction:
        'Change the charge limit in the vehicle or the app by 10 '
        'percentage points.',
    undoInstruction: 'Set the charge limit back to where it was.',
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
/// Only DIDs present in both snapshots are compared. A DID counts as
/// changed when a byte of the shorter payload's length differs (see
/// [diffBytes]) or when the payload length differs; [DidDiff.changes]
/// then lists only the differing bytes of the common prefix, and
/// [DidDiff.before]/[DidDiff.after] carry both lengths. Each
/// [DidDiff.module] is the request header. Headers without a changed DID
/// are left out; each header's DIDs are sorted by DID.
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
              when bytes.isNotEmpty ||
                  beforePayload.length != afterPayload.length)
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

/// The DIDs of [changes], by request header, that did not return to
/// their before payload once the owner undid the action: [undone], the
/// reads after the undo, has another payload for them, or none.
Set<({String header, String did})> unreturnedChanges({
  required Map<String, List<DidDiff>> changes,
  required DidSnapshot undone,
}) => {
  for (final MapEntry(key: header, value: diffs) in changes.entries)
    for (final diff in diffs)
      if (!listEquals(undone[header]?[diff.did], diff.before))
        (header: header, did: diff.did),
};

/// Most reads one capture of an experiment queues.
const int maxExperimentReads = 150;

/// The reads each capture of [experiment] queues: every found DID of the
/// ECUs in [state] addressed by one of [Experiment.targetHeaders], stable
/// ones included -- an action can change a value that never changed
/// before -- plus, with [includeProfileDids], the vag-ppe profile DIDs of
/// an ECU seeded from that profile. ECUs come in id order, each with its
/// DIDs sorted, cut off after [maxExperimentReads] reads.
///
/// Leaves out an ECU without a known responder and one [ecuReadable]
/// rejects at [now] given [stationary]; never yields one of the [vinDids]
/// or the [serialNumberDid].
List<EcuDidRead> experimentReads(
  DiscoveryState state,
  Experiment experiment, {
  required bool includeProfileDids,
  required bool stationary,
  required DateTime now,
}) {
  final profileDids = {
    if (includeProfileDids)
      for (final module in vagPpeModules)
        module.id: [for (final did in module.dids) did.did.toUpperCase()],
  };
  final reads = <EcuDidRead>[];
  for (final ecuId in state.ecus.keys.toList()..sort()) {
    final ecu = state.ecus[ecuId]!;
    final responseHeader = ecu.responseHeader;
    if (responseHeader == null ||
        !experiment.targetHeaders.contains(ecu.requestHeader) ||
        !ecuReadable(ecu, stationary: stationary, now: now)) {
      continue;
    }
    final dids = {
      for (final did in ecu.discovered) did.toUpperCase(),
      ...?profileDids[ecuId],
    }.where((did) => !vinDids.contains(did) && did != serialNumberDid);
    for (final did in dids.toList()..sort()) {
      if (reads.length == maxExperimentReads) {
        return reads;
      }
      reads.add((
        ecuId: ecuId,
        requestHeader: ecu.requestHeader,
        responseHeader: responseHeader,
        protocol: ecu.protocol,
        did: did,
      ));
    }
  }
  return reads;
}

/// Which reads of an experiment run a capture collects: before the
/// action, after it, or after the owner undid it.
enum ExperimentCaptureStage { before, after, undone }

/// Where a guided experiment run stands: capturing the before reads,
/// waiting for the owner's action, capturing the after reads, waiting for
/// the owner to undo the action, capturing the undone reads, then done or
/// failed.
@immutable
sealed class ExperimentRun {
  const ExperimentRun(this.experiment);

  final Experiment experiment;
}

/// The reads of [stage] are being collected; [answered] of [total] reads
/// have returned so far.
class ExperimentCapturing extends ExperimentRun {
  const ExperimentCapturing(
    super.experiment, {
    required this.stage,
    required this.answered,
    required this.total,
  });

  final ExperimentCaptureStage stage;
  final int answered;
  final int total;
}

/// The before reads are in; the owner is asked to take the action.
class ExperimentAwaitingAction extends ExperimentRun {
  const ExperimentAwaitingAction(super.experiment);
}

/// The after reads are in; the owner is asked to undo the action.
class ExperimentAwaitingUndo extends ExperimentRun {
  const ExperimentAwaitingUndo(super.experiment);
}

/// All three captures are in; [changes] as [experimentChanges] reports
/// them between the before and after reads.
class ExperimentDone extends ExperimentRun {
  const ExperimentDone(
    super.experiment, {
    required this.changes,
    this.notReturned = const {},
    this.movingOnTheirOwn = const {},
  });

  final Map<String, List<DidDiff>> changes;

  /// The changed DIDs, by request header, that [unreturnedChanges] finds
  /// did not return once the action was undone: a change that outlasts
  /// the undo need not come from the action.
  final Set<({String header, String did})> notReturned;

  /// The read DIDs, by request header, whose value also changed between
  /// two focus samples of this recording, outside any experiment: a
  /// change in one of them need not come from the action.
  final Set<({String header, String did})> movingOnTheirOwn;
}

/// The run ended before its result, for [failure].
class ExperimentFailed extends ExperimentRun {
  const ExperimentFailed(super.experiment, this.failure);

  final ExperimentFailure failure;
}
