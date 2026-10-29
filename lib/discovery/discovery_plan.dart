/// Turns a [DiscoveryState]'s discovered ECUs/DIDs into extra plan entries
/// for the next recording's recurring plan, on top of the generated
/// vag-ppe steps -- so whatever discovery found gets polled from then on,
/// not just read once.
library;

import '../bridge/vag_ppe_plan_data.dart';
import 'did_stability.dart';
import 'discovery_state.dart';

/// One ECU's extra DIDs to add to the next recording's plan, not already
/// covered by the generated vag-ppe steps.
class DiscoveredEcuPlan {
  const DiscoveredEcuPlan({
    required this.moduleId,
    required this.requestHeader,
    required this.responseHeader,
    required this.protocol,
    required this.dids,
    required this.stableDids,
  });

  final String moduleId;
  final String requestHeader;
  final String responseHeader;
  final int protocol;

  /// DIDs (4 hex digits, sorted) to add, deduplicated against whatever the
  /// vag-ppe generator already polls for this module.
  final List<String> dids;

  /// The subset of [dids] that [didLooksStable].
  final Set<String> stableDids;
}

/// Every ECU in [state] with at least one discovered DID not already
/// polled by the generated vag-ppe plan, in module-id order. An ECU vag-ppe
/// already seeds (see `DiscoveryEngine._seedVagPpeEcus`, which keys it by
/// the vag-ppe module's own id) is matched by that same id -- only its new
/// DIDs are added; an ECU discovery found on its own (ids like
/// `ecus11-70E`/`ecus29-04`, see `inventory.dart`) is added whole. An ECU
/// whose responder header was never identified is skipped -- there is no
/// header to address it by.
List<DiscoveredEcuPlan> discoveredPlanAdditions(DiscoveryState state) {
  final vagPpeById = {for (final module in vagPpeModules) module.id: module};
  final additions = <DiscoveredEcuPlan>[];
  final ecuIds = state.ecus.keys.toList()..sort();
  for (final ecuId in ecuIds) {
    final ecu = state.ecus[ecuId]!;
    final responseHeader = ecu.responseHeader;
    if (responseHeader == null) continue;
    final seed = vagPpeById[ecuId];
    final knownDids = seed == null
        ? const <String>{}
        : {for (final did in seed.dids) did.did.toUpperCase()};
    final newDids =
        ecu.discovered
            .map((did) => did.toUpperCase())
            .where((did) => !knownDids.contains(did))
            .toList()
          ..sort();
    if (newDids.isEmpty) continue;
    additions.add(
      DiscoveredEcuPlan(
        moduleId: ecuId,
        requestHeader: ecu.requestHeader,
        responseHeader: responseHeader,
        protocol: ecu.protocol,
        dids: newDids,
        stableDids: {
          for (final did in newDids)
            if (didLooksStable(did, ecu.sampleStats[did])) did,
        },
      ),
    );
  }
  return additions;
}
