/// Derives what the recording page's "Scouting" card shows from a
/// [DiscoveryEngine]'s current state -- kept separate from the engine
/// itself so it can be recomputed on every tick without touching anything
/// that persists.
library;

import 'discovery_engine.dart';

/// What the discovery engine is currently doing, for display.
enum DiscoveryActivity {
  /// Running (or about to run) one-shot ECU inventory.
  inventory,

  /// Reading a DID batch from a known ECU.
  scanning,

  /// Nothing eligible to scan right now because the vehicle is moving and
  /// "scout while driving" is off, or every remaining ECU is
  /// safety-blocklisted while moving.
  waitingMoving,

  /// Every ECU with pending work is currently paused asleep.
  waitingAsleep,

  /// Nothing left to do: every known ECU is fully scanned and not asleep.
  idle,
}

/// Snapshot of discovery progress/activity for the recording page's
/// "Scouting" card.
class DiscoveryUiState {
  const DiscoveryUiState({
    required this.ecuCount,
    required this.progressPercent,
    required this.totalHits,
    required this.sessionHits,
    required this.activity,
    this.scanningEcuName,
  });

  /// Number of ECUs known so far (seeded plus discovered).
  final int ecuCount;

  /// Overall DID scan progress across every known ECU, 0-100.
  final double progressPercent;

  /// Total DIDs discovered across every known ECU, ever (persisted).
  final int totalHits;

  /// DIDs discovered during the recording currently in progress.
  final int sessionHits;

  final DiscoveryActivity activity;

  /// The ECU currently being scanned's display name, set only when
  /// [activity] is [DiscoveryActivity.scanning].
  final String? scanningEcuName;
}

/// Builds a [DiscoveryUiState] from [engine]'s current state, [stationary]
/// (the same flag passed to [DiscoveryEngine.pump]), and [sessionHits]
/// (tracked by the caller, since the engine itself has no notion of "this
/// recording" vs. "ever").
DiscoveryUiState buildDiscoveryUiState({
  required DiscoveryEngine engine,
  required bool stationary,
  required DateTime now,
  required int sessionHits,
}) {
  final progress = engine.scanProgress();
  final totalHits = engine.state.ecus.values.fold<int>(
    0,
    (sum, ecu) => sum + ecu.discovered.length,
  );

  // Mirrors `DiscoveryEngine.pump`'s own order: inventory runs before any
  // ECU scan batch while stationary, so it takes display priority too.
  final incompleteInventory =
      !engine.state.inventoryStagesDone.contains('ecus11') ||
      !engine.state.inventoryStagesDone.contains('ecus29');
  if (stationary && incompleteInventory) {
    return DiscoveryUiState(
      ecuCount: progress.ecuCount,
      progressPercent: progress.percent,
      totalHits: totalHits,
      sessionHits: sessionHits,
      activity: DiscoveryActivity.inventory,
    );
  }

  final nextEcuId = engine.selectNextEcuForScan(
    stationary: stationary,
    now: now,
  );
  if (nextEcuId != null) {
    final ecu = engine.state.ecus[nextEcuId]!;
    return DiscoveryUiState(
      ecuCount: progress.ecuCount,
      progressPercent: progress.percent,
      totalHits: totalHits,
      sessionHits: sessionHits,
      activity: DiscoveryActivity.scanning,
      scanningEcuName: ecu.f197Name ?? nextEcuId,
    );
  }

  DiscoveryActivity activity;
  if (!stationary &&
      engine.state.ecus.keys.any((id) => engine.hasDiscoveryWork(id, now))) {
    // Work exists but every eligible ECU is either blocked by the moving
    // restriction or itself safety-blocklisted (see
    // `movingDiscoveryBlocked`) -- either way, it's waiting on the vehicle
    // to stop, not asleep.
    activity = DiscoveryActivity.waitingMoving;
  } else if (engine.state.ecus.values.any(
    (ecu) => ecu.asleepUntil != null && now.isBefore(ecu.asleepUntil!),
  )) {
    activity = DiscoveryActivity.waitingAsleep;
  } else {
    activity = DiscoveryActivity.idle;
  }

  return DiscoveryUiState(
    ecuCount: progress.ecuCount,
    progressPercent: progress.percent,
    totalHits: totalHits,
    sessionHits: sessionHits,
    activity: activity,
  );
}
