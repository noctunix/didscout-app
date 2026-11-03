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

/// Discovered DIDs, by request header, whose meaning is settled and that
/// therefore never join the survey or focus sampling: read by a fixed plan
/// step already, a copy of one, or a candidate that was ruled out.
const Map<String, Set<String>> settledDids = {
  // Fixed steps: speed, outside temperature.
  '18DA04F1': {'F40D', 'F446'},
  // Fixed step: odometer.
  '18DA06F1': {'F4A6'},
  // Fixed steps: range, stored energy, charging power; 0430 is a ring
  // buffer of past charging events, not a live value.
  '710': {'2AB6', '2AB8', '0311', '0430'},
  // Fixed step: battery temperature.
  '17FC007B': {'1E10'},
  // The odometer again, as the cluster shows it.
  '714': {'2203'},
  // Ruled out as the battery temperature.
  '18DA0FF1': {'2A26', '2A2D'},
};

/// Every ECU in [state] with at least one discovered DID not already
/// polled by the generated vag-ppe plan nor [settledDids], in module-id
/// order. An ECU vag-ppe
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
    final knownDids = {
      if (seed != null)
        for (final did in seed.dids) did.did.toUpperCase(),
      ...?settledDids[ecu.requestHeader],
    };
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
