import 'dart:convert';
import 'dart:io';

import 'inventory.dart';

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
  }) : discoverRanges = discoverRanges ?? const [],
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

  /// Profile-supplied DID ranges to prioritize in this ECU's scan order
  /// (see `discoveryDidOrder`); empty for an ECU found by generic
  /// discovery rather than seeded from a profile.
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

  /// The decoded F197 system name, or null if never identified -- used by
  /// the moving-vehicle safety blocklist.
  String? get f197Name => identification['F197'];

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
  );
}

/// Persisted discovery state for one vehicle: known ECUs and their scan
/// progress, inventory stages already completed, and the last
/// rediscovery time. JSON-serialisable; the caller owns where the file
/// lives (one per vehicle label).
class DiscoveryState {
  DiscoveryState({
    Map<String, EcuInfo>? ecus,
    Set<String>? inventoryStagesDone,
    this.lastRediscoveryTime,
  }) : ecus = ecus ?? {},
       inventoryStagesDone = inventoryStagesDone ?? {};

  /// Known ECUs, keyed by module id.
  Map<String, EcuInfo> ecus;

  /// One-shot inventory stages already run, e.g. `{'ecus11', 'ecus29'}`.
  Set<String> inventoryStagesDone;

  /// Wall-clock time of the last ECU rediscovery sweep.
  DateTime? lastRediscoveryTime;

  Map<String, dynamic> toJson() => {
    'ecus': ecus.map((key, value) => MapEntry(key, value.toJson())),
    'inventoryStagesDone': inventoryStagesDone.toList(),
    'lastRediscoveryTime': lastRediscoveryTime?.toUtc().toIso8601String(),
  };

  /// Drops a [phantomEcu11EcuId] entry an earlier sweep persisted, so it is
  /// neither scanned again nor added to a recording's plan.
  factory DiscoveryState.fromJson(Map<String, dynamic> json) => DiscoveryState(
    ecus: {
      for (final MapEntry(:key, :value)
          in (json['ecus'] as Map<dynamic, dynamic>? ?? {}).entries)
        if (key != phantomEcu11EcuId)
          key as String: EcuInfo.fromJson(value as Map<String, dynamic>),
    },
    inventoryStagesDone: Set<String>.from(
      json['inventoryStagesDone'] as List<dynamic>? ?? [],
    ),
    lastRediscoveryTime: json['lastRediscoveryTime'] != null
        ? DateTime.parse(json['lastRediscoveryTime'] as String)
        : null,
  );

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
