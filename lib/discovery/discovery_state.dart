import 'dart:convert';
import 'dart:io';

import 'did_order.dart';
import 'inventory.dart';

/// What the discovery engine stores under an identification DID in
/// place of a decoded value when the read didn't return one.
final RegExp _identificationStatus = RegExp(
  r'^(OK|MISSING|NO DATA|NRC [0-9A-F]{2}|TIMEOUT|TRANSPORT_ERROR|CANCELLED)$',
);

/// How one discovered DID's value has behaved across the recurring reads
/// of past recordings (see `did_stability.dart`).
class DidSampleStats {
  DidSampleStats({
    this.lastPayloadHash,
    this.stableSamples = 0,
    this.stableRecordings = 0,
    this.everChanged = false,
  });

  /// Hash of the most recent positive payload -- the payload itself is
  /// not kept.
  int? lastPayloadHash;

  /// Samples in a row, up to and including the latest, that carried the
  /// payload hashed as [lastPayloadHash].
  int stableSamples;

  /// Recordings those [stableSamples] were spread over.
  int stableRecordings;

  /// Whether two consecutive samples ever differed.
  bool everChanged;

  /// Counts one positive sample hashing to [payloadHash];
  /// [firstInRecording] marks the DID's first sample of a recording.
  void record(int payloadHash, {required bool firstInRecording}) {
    if (payloadHash == lastPayloadHash) {
      stableSamples += 1;
      if (firstInRecording) {
        stableRecordings += 1;
      }
      return;
    }
    everChanged = everChanged || lastPayloadHash != null;
    lastPayloadHash = payloadHash;
    stableSamples = 1;
    stableRecordings = 1;
  }

  Map<String, dynamic> toJson() => {
    'lastPayloadHash': lastPayloadHash,
    'stableSamples': stableSamples,
    'stableRecordings': stableRecordings,
    'everChanged': everChanged,
  };

  factory DidSampleStats.fromJson(Map<String, dynamic> json) => DidSampleStats(
    lastPayloadHash: json['lastPayloadHash'] as int?,
    stableSamples: json['stableSamples'] as int? ?? 0,
    stableRecordings: json['stableRecordings'] as int? ?? 0,
    everChanged: json['everChanged'] as bool? ?? false,
  );
}

/// Everything the discovery engine knows about one ECU: how to address
/// it, what it identified as, and how far its DID scan has gotten.
class EcuInfo {
  EcuInfo({
    required this.requestHeader,
    this.responseHeader,
    required this.protocol,
    List<(int, int)>? discoverRanges,
    Map<String, String>? identification,
    this.scanPosition = 0,
    Set<String>? discovered,
    Set<String>? conditional,
    List<String>? retryQueue,
    this.asleepUntil,
    this.noDataStreak = 0,
    Map<String, DidSampleStats>? sampleStats,
  }) : sampleStats = sampleStats ?? {},
       discoverRanges = discoverRanges ?? const [],
       identification = identification ?? {},
       discovered = discovered ?? {},
       conditional = conditional ?? {},
       retryQueue = retryQueue ?? [];

  /// 11-bit or 29-bit request header.
  String requestHeader;

  /// Responder header, once known.
  String? responseHeader;

  /// Wire protocol: 6 (11-bit CAN) or 7 (29-bit CAN).
  int protocol;

  /// DID ranges to prioritize in this ECU's scan order (see
  /// `discoveryDidOrder`): the `targetedDiscoverRanges` for its request
  /// header, else empty.
  List<(int, int)> discoverRanges;

  /// Identification DID (F187/F189/F191/F197) results: the decoded ASCII
  /// value for F197 on a positive reply, the exchange status otherwise.
  Map<String, String> identification;

  /// Position of this ECU's DID scan within `discoveryDidOrder(discoverRanges)`.
  int scanPosition;

  /// DIDs (4 hex digits) that answered OK.
  Set<String> discovered;

  /// DIDs pending a retry after NRC 22 (conditionsNotCorrect) or NRC 33
  /// (securityAccessDenied) -- retried once a phase change happens.
  Set<String> conditional;

  /// Conditional DIDs queued for their next retry batch.
  List<String> retryQueue;

  /// Set when a batch looked asleep (`batchIsAsleep`); scanning on this
  /// ECU pauses until this time.
  DateTime? asleepUntil;

  /// Discovery batches in a row that looked NO-DATA-asleep; scales the
  /// next such pause (see `noDataAsleepPause`).
  int noDataStreak;

  /// Recurring-read statistics per discovered DID (4 hex digits).
  Map<String, DidSampleStats> sampleStats;

  /// The decoded F197 system name, or null if never identified or the
  /// read didn't return a name -- used by the moving-vehicle safety
  /// blocklist.
  String? get f197Name {
    final value = identification['F197'];
    return value == null || _identificationStatus.hasMatch(value)
        ? null
        : value;
  }

  /// Folds [other], an entry for the same ECU stored under a different
  /// id, into this one: found and conditional DIDs are united, the scan
  /// resumes from whichever entry got further, a name or sample statistics
  /// only [other] has are kept, and the later sleep pause and longer
  /// NO-DATA streak win.
  void absorb(EcuInfo other) {
    responseHeader ??= other.responseHeader;
    for (final MapEntry(:key, :value) in other.identification.entries) {
      identification.putIfAbsent(key, () => value);
    }
    if (f197Name == null && other.f197Name != null) {
      identification['F197'] = other.f197Name!;
    }
    if (sameRanges(discoverRanges, other.discoverRanges) &&
        other.scanPosition > scanPosition) {
      scanPosition = other.scanPosition;
    }
    discovered.addAll(other.discovered);
    conditional
      ..addAll(other.conditional)
      ..removeAll(discovered);
    retryQueue = {
      ...retryQueue,
      ...other.retryQueue,
    }.where(conditional.contains).toList()..sort();
    final otherAsleepUntil = other.asleepUntil;
    if (otherAsleepUntil != null &&
        (asleepUntil == null || otherAsleepUntil.isAfter(asleepUntil!))) {
      asleepUntil = otherAsleepUntil;
    }
    if (other.noDataStreak > noDataStreak) {
      noDataStreak = other.noDataStreak;
    }
    for (final MapEntry(:key, :value) in other.sampleStats.entries) {
      sampleStats.putIfAbsent(key, () => value);
    }
  }

  Map<String, dynamic> toJson() => {
    'requestHeader': requestHeader,
    'responseHeader': responseHeader,
    'protocol': protocol,
    'discoverRanges': discoverRanges.map((r) => [r.$1, r.$2]).toList(),
    'identification': identification,
    'scanPosition': scanPosition,
    'discovered': discovered.toList(),
    'conditional': conditional.toList(),
    'retryQueue': retryQueue,
    'asleepUntil': asleepUntil?.toUtc().toIso8601String(),
    'noDataStreak': noDataStreak,
    'sampleStats': sampleStats.map(
      (did, stats) => MapEntry(did, stats.toJson()),
    ),
  };

  factory EcuInfo.fromJson(Map<String, dynamic> json) => EcuInfo(
    requestHeader: json['requestHeader'] as String,
    responseHeader: json['responseHeader'] as String?,
    protocol: json['protocol'] as int,
    discoverRanges: (json['discoverRanges'] as List<dynamic>? ?? [])
        .map((r) => ((r as List<dynamic>)[0] as int, r[1] as int))
        .toList(),
    identification: Map<String, String>.from(
      json['identification'] as Map<dynamic, dynamic>? ?? {},
    ),
    scanPosition: json['scanPosition'] as int? ?? 0,
    discovered: Set<String>.from(json['discovered'] as List<dynamic>? ?? []),
    conditional: Set<String>.from(json['conditional'] as List<dynamic>? ?? []),
    retryQueue: List<String>.from(json['retryQueue'] as List<dynamic>? ?? []),
    asleepUntil: json['asleepUntil'] != null
        ? DateTime.parse(json['asleepUntil'] as String)
        : null,
    noDataStreak: json['noDataStreak'] as int? ?? 0,
    sampleStats: {
      for (final MapEntry(:key, :value)
          in (json['sampleStats'] as Map<dynamic, dynamic>? ?? {}).entries)
        key as String: DidSampleStats.fromJson(value as Map<String, dynamic>),
    },
  );
}

/// Folds every ECU in [ecus] that shares a protocol and request header
/// with an earlier one into a single entry, keyed by the vag-ppe seed id
/// for that header when there is one. An inventory sweep that ran before
/// the seeds existed stored such ECUs under its own `ecus11-`/`ecus29-`
/// id, so each was scanned and sampled twice.
Map<String, EcuInfo> _mergeByRequestHeader(Map<String, EcuInfo> ecus) {
  final seedIdByHeader = {
    for (final seed in vagPpeSeedEcus()) (seed.protocol, seed.request): seed.id,
  };
  final idByHeader = <(int, String), String>{};
  final merged = <String, EcuInfo>{};
  for (final MapEntry(key: id, value: ecu) in ecus.entries) {
    final header = (ecu.protocol, ecu.requestHeader);
    final mergedId = idByHeader[header];
    if (mergedId != null) {
      merged[mergedId]!.absorb(ecu);
      continue;
    }
    final targetId = seedIdByHeader[header] ?? id;
    idByHeader[header] = targetId;
    merged[targetId] = ecu;
  }
  return merged;
}

/// Persisted discovery state for one vehicle: known ECUs and their scan
/// progress, inventory stages already completed and their sweep progress,
/// and the last rediscovery time. JSON-serialisable; the caller owns where
/// the file lives (one per vehicle label).
class DiscoveryState {
  DiscoveryState({
    Map<String, EcuInfo>? ecus,
    Set<String>? inventoryStagesDone,
    Map<String, Set<String>>? inventorySwept,
    this.lastRediscoveryTime,
    Set<String>? learnedRecordings,
  }) : ecus = ecus ?? {},
       inventoryStagesDone = inventoryStagesDone ?? {},
       inventorySwept = inventorySwept ?? {},
       learnedRecordings = learnedRecordings ?? {};

  /// Known ECUs, keyed by module id.
  Map<String, EcuInfo> ecus;

  /// One-shot inventory stages already run, e.g. `{'ecus11', 'ecus29'}`.
  Set<String> inventoryStagesDone;

  /// Per inventory stage, the target ids whose sweep probe got an answer
  /// (OK, NO DATA, an NRC or a timeout): the 3-hex request header for
  /// `ecus11`, the 2-hex target id for a 29-bit scheme. A sweep of a stage
  /// not yet done skips them, and the stage is done once every id it
  /// probed is in here.
  Map<String, Set<String>> inventorySwept;

  /// Wall-clock time of the last ECU rediscovery sweep.
  DateTime? lastRediscoveryTime;

  /// Session ids of the recordings already folded into
  /// [EcuInfo.sampleStats].
  Set<String> learnedRecordings;

  Map<String, dynamic> toJson() => {
    'ecus': ecus.map((key, value) => MapEntry(key, value.toJson())),
    'inventoryStagesDone': inventoryStagesDone.toList(),
    'inventorySwept': inventorySwept.map(
      (stage, ids) => MapEntry(stage, ids.toList()),
    ),
    'lastRediscoveryTime': lastRediscoveryTime?.toUtc().toIso8601String(),
    'learnedRecordings': learnedRecordings.toList(),
  };

  /// Drops a [phantomEcu11EcuId] entry an earlier sweep persisted, so it is
  /// neither scanned again nor added to a recording's plan, merges entries
  /// that address the same ECU ([_mergeByRequestHeader]), and un-marks an
  /// inventory stage done without an [inventorySwept] entry, which an
  /// aborted sweep may have marked done, so it runs again.
  factory DiscoveryState.fromJson(Map<String, dynamic> json) {
    final inventorySwept = {
      for (final MapEntry(:key, :value)
          in (json['inventorySwept'] as Map<dynamic, dynamic>? ?? {}).entries)
        key as String: Set<String>.from(value as List<dynamic>),
    };
    return DiscoveryState(
      ecus: _mergeByRequestHeader({
        for (final MapEntry(:key, :value)
            in (json['ecus'] as Map<dynamic, dynamic>? ?? {}).entries)
          if (key != phantomEcu11EcuId)
            key as String: EcuInfo.fromJson(value as Map<String, dynamic>),
      }),
      inventoryStagesDone: {
        for (final stage in json['inventoryStagesDone'] as List<dynamic>? ?? [])
          if (inventorySwept.containsKey(stage)) stage as String,
      },
      inventorySwept: inventorySwept,
      lastRediscoveryTime: json['lastRediscoveryTime'] != null
          ? DateTime.parse(json['lastRediscoveryTime'] as String)
          : null,
      learnedRecordings: Set<String>.from(
        json['learnedRecordings'] as List<dynamic>? ?? [],
      ),
    );
  }

  /// Loads state from [file], or a fresh empty state if it doesn't exist
  /// or doesn't parse -- a corrupt state file must never block discovery
  /// from starting over.
  static Future<DiscoveryState> loadFromFile(File file) async {
    if (!await file.exists()) {
      return DiscoveryState();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      return DiscoveryState.fromJson(decoded as Map<String, dynamic>);
    } on FormatException {
      return DiscoveryState();
    }
  }

  Future<void> saveToFile(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(toJson()));
  }
}
