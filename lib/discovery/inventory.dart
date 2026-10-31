/// Manufacturer ECU inventory: candidate request/response headers and the
/// identification DID list, ported from didscout's `_inventory_ecus11`/
/// `_inventory_ecus29`. OBDonUDS functional discovery and support
/// bitmaps are out of scope here.
library;

import '../bridge/vag_ppe_plan_data.dart';
import 'probe.dart';

/// 11-bit request id the sweep never probes: the gateway answers requests
/// sent there too (NO DATA instead of NRC 31 for unsupported DIDs), so a hit
/// is a phantom ECU, not a physical one.
const int phantomEcu11RequestId = 0x700;

/// Module id a sweep hit at [phantomEcu11RequestId] was persisted under.
const String phantomEcu11EcuId = 'ecus11-700';

/// 11-bit manufacturer-ECU request ids: 0x700-0x7EF, excluding the
/// legislative functional broadcast 0x7DF (mode 01/OBDonUDS, not here) and
/// [phantomEcu11RequestId].
final List<int> ecu11RequestIds = [
  for (var request = 0x700; request < 0x7F0; request++)
    if (request != 0x7DF && request != phantomEcu11RequestId) request,
];

/// Identification DIDs read for every newly found ECU, in scan order --
/// never the serial number or any VIN DID.
const List<String> identificationDids = ['F187', 'F189', 'F191', 'F197'];

/// Module id for the 11-bit sweep probe at request header [requestHex]
/// (3 hex digits, e.g. `"70E"`).
String ecu11ModuleId(String requestHex) => 'ecu11-$requestHex';

/// Module id for an identified 11-bit ECU.
String ecu11EcuId(String requestHex) => 'ecus11-$requestHex';

/// The receive filter/mask value (without the `ATCF`/`ATCM` prefix) that
/// accepts a reply from any 11-bit header in the manufacturer range
/// 0x700-0x7FF, regardless of which request header the sweep used --
/// needed because an ECU may answer from a header other than the one it
/// was addressed on.
const String ecu11ReceiveFilter = '700';
const String ecu11ReceiveMask = '700';

/// One [ProbeModule]/[ProbeStep] pair that sweeps 11-bit request header
/// [requestHex] (3 hex digits) with a single `22F189` probe, accepting a
/// reply from any 0x7xx header.
(ProbeModule, ProbeStep) ecu11SweepProbe(String requestHex) {
  final moduleId = ecu11ModuleId(requestHex);
  final module = ProbeModule(
    id: moduleId,
    requestHeader: requestHex,
    protocol: 6,
    receiveFilter: ecu11ReceiveFilter,
    receiveMask: ecu11ReceiveMask,
  );
  final step = ProbeStep(
    signalId: signalIdFor(moduleId, '22F189'),
    command: '22F189',
  );
  return (module, step);
}

String _hex2(int value) =>
    value.toRadixString(16).toUpperCase().padLeft(2, '0');

/// A 29-bit physical addressing scheme the ECU inventory sweeps: the
/// target ids (2 hex digits each) it covers, the request/response headers
/// a target id maps to, and the module id and inventory stage it is
/// recorded under.
class Ecu29Scheme {
  const Ecu29Scheme({
    required this.stage,
    required this.ids,
    required this.requestHeaderOf,
    required this.responseHeaderOf,
  });

  /// Inventory stage name, recorded in
  /// `DiscoveryState.inventoryStagesDone` and used as the module id
  /// prefix.
  final String stage;

  /// Target ids swept, in order.
  final List<String> ids;

  /// The request header addressing target [idHex].
  final String Function(String idHex) requestHeaderOf;

  /// The header target [idHex] answers from.
  final String Function(String idHex) responseHeaderOf;

  /// Module id for the sweep probe / identified ECU at target [idHex],
  /// e.g. `ecus29-04`.
  String ecuId(String idHex) => '$stage-$idHex';

  /// One [ProbeModule]/[ProbeStep] pair that sweeps target [idHex] with a
  /// single `22F189` probe. The response header is always explicit: the
  /// adapter's automatic receive address swaps the request header's last
  /// two bytes, which is right for `18DAxxF1` but misses every `17FE00xx`
  /// reply to a `17FC00xx` request.
  (ProbeModule, ProbeStep) sweepProbe(String idHex) {
    final moduleId = ecuId(idHex);
    final module = ProbeModule(
      id: moduleId,
      requestHeader: requestHeaderOf(idHex),
      responseHeader: responseHeaderOf(idHex),
      protocol: 7,
    );
    final step = ProbeStep(
      signalId: signalIdFor(moduleId, '22F189'),
      command: '22F189',
    );
    return (module, step);
  }
}

/// ISO 15765-4 normal fixed addressing, request `18DA<id>F1`, response
/// `18DAF1<id>`: every target id except the tester address (0xF1).
final Ecu29Scheme ecu29Scheme = Ecu29Scheme(
  stage: 'ecus29',
  ids: [
    for (var i = 0; i < 0x100; i++)
      if (i != 0xF1) _hex2(i),
  ],
  requestHeaderOf: (idHex) => '18DA${idHex}F1',
  responseHeaderOf: (idHex) => '18DAF1$idHex',
);

/// VW/Audi physical addressing, request `17FC00<id>`, response
/// `17FE00<id>` (e.g. the HV battery management at `17FC007B`): every
/// target id, since the tester address is not part of these headers.
final Ecu29Scheme vag29Scheme = Ecu29Scheme(
  stage: 'vag29',
  ids: [for (var i = 0; i < 0x100; i++) _hex2(i)],
  requestHeaderOf: (idHex) => '17FC00$idHex',
  responseHeaderOf: (idHex) => '17FE00$idHex',
);

/// Builds the [ProbeModule]/[ProbeStep] pair that reads identification DID
/// [did] for an ECU already known to answer at [requestHeader]/
/// [responseHeader].
(ProbeModule, ProbeStep) identificationProbe({
  required String moduleId,
  required String requestHeader,
  required String responseHeader,
  required int protocol,
  required String did,
}) {
  final module = ProbeModule(
    id: moduleId,
    requestHeader: requestHeader,
    responseHeader: responseHeader,
    protocol: protocol,
  );
  final command = '22$did';
  final step = ProbeStep(
    signalId: signalIdFor(moduleId, command),
    command: command,
  );
  return (module, step);
}

/// Known ECUs the vag-ppe profile seeds the discovery state with, so they
/// get DID-scanned right away without needing generic discovery.
List<({String id, String request, String response, int protocol})>
vagPpeSeedEcus() => [
  for (final module in vagPpeModules)
    (
      id: module.id,
      request: module.request,
      response: module.response,
      protocol: int.parse(module.protocol),
    ),
];
