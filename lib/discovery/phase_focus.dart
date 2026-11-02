/// The ECUs each vehicle phase puts in focus, and which of their found
/// DIDs a focus sample reads.
library;

import '../session/session_markers.dart';
import 'did_order.dart';
import 'discovery_plan.dart';
import 'discovery_state.dart';

/// How often the focus ECUs' found DIDs are sampled: the survey interval
/// is minutes long, too coarse to follow values moving within a phase.
const Duration phaseFocusSampleInterval = Duration(seconds: 30);

/// Most focus reads queued per [phaseFocusSampleInterval]: they share the
/// poller's idle time with discovery, which must keep a part of it.
const int maxPhaseFocusReads = 60;

const Set<String> _standFocus = {
  '74A', '74B', '73E', '73F', // doors
  '70E', // body control
  '767', // climate
  '74C', // front seats
  '17FC0082', '17FC0083', // charge sockets left/right
  '17FC008B', // rear sensor/actor
  '17FC00A5', // wireless phone charger
  '17FC00CE', // passenger display
};

/// Request headers of the ECUs whose values change, or can be triggered,
/// in each phase.
const Map<MarkerPhase, Set<String>> phaseFocusRequestHeaders = {
  MarkerPhase.charge: {
    '17FC007B', // HV battery controller
    '17FC0082', '17FC0083', // charge sockets left/right
    '742', // thermal management
    '710', // gateway
    '18DA0FF1', // HCP1
    '767', // climate
  },
  MarkerPhase.drive: {
    '18DA07F1', '18DA06F1', // front/rear drive motor
    '742', // thermal management
    '18DA0FF1', // HCP1
    '17FC00B3', // HCP2
    '17FC007B', // HV battery controller
  },
  MarkerPhase.stand: _standFocus,
  MarkerPhase.park: _standFocus,
};

/// One found DID a focus sample reads, with the ECU it belongs to.
typedef PhaseFocusRead = ({DiscoveredEcuPlan ecu, String did});

/// The found DIDs [discoveredPlanAdditions] plans for the ECUs in [state]
/// addressed by one of [requestHeaders], minus the stable ones
/// ([DiscoveredEcuPlan.stableDids]), in that same order. Leaves out an ECU
/// paused asleep at [now] and, unless [stationary], one
/// [movingDiscoveryBlocked] keeps out of reads while moving; never yields
/// one of the [vinDids] or the [serialNumberDid].
List<PhaseFocusRead> phaseFocusReads(
  DiscoveryState state,
  Set<String> requestHeaders, {
  required bool stationary,
  required DateTime now,
}) => [
  for (final ecu in discoveredPlanAdditions(state))
    if (requestHeaders.contains(ecu.requestHeader) &&
        _readable(state.ecus[ecu.moduleId]!, stationary: stationary, now: now))
      for (final did in ecu.dids)
        if (!ecu.stableDids.contains(did) &&
            !vinDids.contains(did) &&
            did != serialNumberDid)
          (ecu: ecu, did: did),
];

bool _readable(
  EcuInfo ecu, {
  required bool stationary,
  required DateTime now,
}) =>
    (stationary || !movingDiscoveryBlocked(ecu.f197Name)) &&
    !(ecu.asleepUntil?.isAfter(now) ?? false);
