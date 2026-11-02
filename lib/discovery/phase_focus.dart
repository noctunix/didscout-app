/// The ECUs each vehicle phase puts in focus.
library;

import '../session/session_markers.dart';

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
