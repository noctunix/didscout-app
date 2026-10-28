/// [AppSettings.maxReadsPerSecond] value meaning "no throttling" — the
/// native poller clamps its per-read spacing to
/// `1000 ~/ maxReadsPerSecond` ms (see `CxPoller.minGlobalIntervalMs`),
/// and integer division already floors that to zero at any value from
/// 1000 upward, so this is the lowest value that truly means unlimited
/// rather than just "very fast". `0` is not usable for this: the poller
/// clamps it to a floor of 1 read/s, the opposite of unlimited.
const int unlimitedMaxReadsPerSecond = 1000;

/// What a recurring recording plan reads beyond the speed signal.
enum RecordingMode {
  /// Only the speed signal (needed for motion-aware scouting) plus,
  /// optionally, discovered DIDs ([AppSettings.keepSamplingFoundDids]). The
  /// generated vag-ppe DIDs and the fixed energy/range/odometer/
  /// outside-temperature/12V/accelerator steps are omitted.
  scoutOnly,

  /// Today's full plan: the fixed base signals plus every generated
  /// vag-ppe DID, on top of whatever [scoutOnly] already reads.
  scoutAndRecordKnown,
}

/// All didscout settings, persisted as one blob by [SettingsRepository] and
/// read fresh by [RecordingController.start] every time a recording starts.
/// Immutable — call sites replace their copy wholesale via [copyWith] rather
/// than mutating fields in place.
class AppSettings {
  const AppSettings({
    required this.readTimeoutMs,
    required this.reconnectBackoffMinS,
    required this.reconnectBackoffMaxS,
    required this.neverGiveUpReconnecting,
    required this.reconnectAttempts,
    required this.stopAfterNoVehicleDataMinutes,
    required this.maxReadsPerSecond,
    required this.surveyIntervalMinutes,
    required this.chargeReminderIntervalMinutes,
    required this.autoStartOnPower,
    required this.recordOnlyWhilePoweredOn,
    required this.scoutWhileRecording,
    required this.scoutWhileDriving,
    required this.recordingMode,
    required this.keepSamplingFoundDids,
    required this.speedPollIntervalS,
    required this.discoveryBatchSize,
    this.adapterResponseTimeoutMs,
  });

  const AppSettings.defaultValues()
    : readTimeoutMs = 2000,
      reconnectBackoffMinS = 2,
      reconnectBackoffMaxS = 60,
      neverGiveUpReconnecting = true,
      reconnectAttempts = 20,
      stopAfterNoVehicleDataMinutes = 30,
      maxReadsPerSecond = 8,
      surveyIntervalMinutes = 3,
      chargeReminderIntervalMinutes = 5,
      autoStartOnPower = false,
      recordOnlyWhilePoweredOn = false,
      scoutWhileRecording = true,
      scoutWhileDriving = true,
      recordingMode = RecordingMode.scoutOnly,
      keepSamplingFoundDids = true,
      speedPollIntervalS = 20,
      discoveryBatchSize = 16,
      adapterResponseTimeoutMs = null;

  /// Timeout per request, applied to both
  /// `ObdLimitsMessage.adapterStepDeadlineMs` and `.vehicleReadDeadlineMs`.
  final int readTimeoutMs;
  final int reconnectBackoffMinS;
  final int reconnectBackoffMaxS;

  /// When true, `maxReconnectAttemptsPerGap` is set effectively unlimited
  /// instead of [reconnectAttempts] (see [maxReconnectAttemptsPerGap]).
  final bool neverGiveUpReconnecting;
  final int reconnectAttempts;
  final int stopAfterNoVehicleDataMinutes;
  final int maxReadsPerSecond;

  /// Interval applied to every DID in `vag_ppe_plan_data.dart` whose
  /// generated interval equals the generator's own survey default
  /// (`_generatedSurveyIntervalMs` in `recording_controller.dart`); DIDs
  /// generated with a different (watch/once) interval are left alone.
  final int surveyIntervalMinutes;
  final int chargeReminderIntervalMinutes;
  final bool autoStartOnPower;
  final bool recordOnlyWhilePoweredOn;

  /// Whether the discovery engine runs at all while recording.
  final bool scoutWhileRecording;

  /// Whether discovery keeps running while the vehicle is moving (fresh
  /// live speed non-zero or unknown) -- ECU/DID scanning only, never the
  /// safety-system blocklist in `did_order.dart`, which applies regardless
  /// of this setting.
  final bool scoutWhileDriving;

  /// What the recurring plan reads beyond the speed signal.
  final RecordingMode recordingMode;

  /// Whether DIDs discovery finds are kept in the recurring plan
  /// afterwards -- finding a DID only proves it exists; sampling it over
  /// time together with the owner's own readings is what reveals what it
  /// means.
  final bool keepSamplingFoundDids;

  /// How often the plan's `module7_22f40d` (speed) step is read. Less often
  /// leaves more of the adapter's read budget for scouting, but motion is
  /// noticed later.
  final int speedPollIntervalS;

  /// DIDs read per discovery batch; the discovery executor's queue target
  /// scales with it (see [RecordingController._startDiscovery]).
  final int discoveryBatchSize;

  /// Sent as `ATST` + two hex digits (the value in 4 ms units) in the
  /// plan's init and resync sequences, right after the existing formatting
  /// commands -- null (the default) sends no `ATST` at all, leaving the
  /// adapter's own default response timeout in effect. Too short a value
  /// can miss a slow ECU behind a gateway.
  final int? adapterResponseTimeoutMs;

  /// The plugin's reconnect-attempt counter only ever counts up within a
  /// gap, never down, so "never give up" needs a budget that is effectively
  /// unlimited rather than a literal cap.
  int get maxReconnectAttemptsPerGap =>
      neverGiveUpReconnecting ? 100000 : reconnectAttempts;

  int get reconnectBackoffMinMs => reconnectBackoffMinS * 1000;
  int get reconnectBackoffMaxMs => reconnectBackoffMaxS * 1000;
  int get idleVehicleStopAfterMs => stopAfterNoVehicleDataMinutes * 60000;
  int get surveyIntervalMs => surveyIntervalMinutes * 60000;
  Duration get chargeReminderInterval =>
      Duration(minutes: chargeReminderIntervalMinutes);

  int get speedPollIntervalMs => speedPollIntervalS * 1000;

  /// The engine's live speed reading counts as fresh for 2.5x the poll
  /// interval -- generous enough to tolerate one missed/slow read without
  /// falsely treating the vehicle as moving (which would block
  /// safety-relevant discovery unnecessarily), while still catching a
  /// connection that has actually gone stale.
  Duration get speedFreshnessWindow =>
      Duration(milliseconds: (speedPollIntervalMs * 2.5).round());

  /// `ATST` command text for [adapterResponseTimeoutMs], or null when unset.
  String? get adapterResponseTimeoutCommand {
    final ms = adapterResponseTimeoutMs;
    if (ms == null) return null;
    final units = (ms / 4).round().clamp(0, 255);
    return 'ATST${units.toRadixString(16).toUpperCase().padLeft(2, '0')}';
  }

  AppSettings copyWith({
    int? readTimeoutMs,
    int? reconnectBackoffMinS,
    int? reconnectBackoffMaxS,
    bool? neverGiveUpReconnecting,
    int? reconnectAttempts,
    int? stopAfterNoVehicleDataMinutes,
    int? maxReadsPerSecond,
    int? surveyIntervalMinutes,
    int? chargeReminderIntervalMinutes,
    bool? autoStartOnPower,
    bool? recordOnlyWhilePoweredOn,
    bool? scoutWhileRecording,
    bool? scoutWhileDriving,
    RecordingMode? recordingMode,
    bool? keepSamplingFoundDids,
    int? speedPollIntervalS,
    int? discoveryBatchSize,
    Object? adapterResponseTimeoutMs = _unset,
  }) => AppSettings(
    readTimeoutMs: readTimeoutMs ?? this.readTimeoutMs,
    reconnectBackoffMinS: reconnectBackoffMinS ?? this.reconnectBackoffMinS,
    reconnectBackoffMaxS: reconnectBackoffMaxS ?? this.reconnectBackoffMaxS,
    neverGiveUpReconnecting:
        neverGiveUpReconnecting ?? this.neverGiveUpReconnecting,
    reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
    stopAfterNoVehicleDataMinutes:
        stopAfterNoVehicleDataMinutes ?? this.stopAfterNoVehicleDataMinutes,
    maxReadsPerSecond: maxReadsPerSecond ?? this.maxReadsPerSecond,
    surveyIntervalMinutes: surveyIntervalMinutes ?? this.surveyIntervalMinutes,
    chargeReminderIntervalMinutes:
        chargeReminderIntervalMinutes ?? this.chargeReminderIntervalMinutes,
    autoStartOnPower: autoStartOnPower ?? this.autoStartOnPower,
    recordOnlyWhilePoweredOn:
        recordOnlyWhilePoweredOn ?? this.recordOnlyWhilePoweredOn,
    scoutWhileRecording: scoutWhileRecording ?? this.scoutWhileRecording,
    scoutWhileDriving: scoutWhileDriving ?? this.scoutWhileDriving,
    recordingMode: recordingMode ?? this.recordingMode,
    keepSamplingFoundDids: keepSamplingFoundDids ?? this.keepSamplingFoundDids,
    speedPollIntervalS: speedPollIntervalS ?? this.speedPollIntervalS,
    discoveryBatchSize: discoveryBatchSize ?? this.discoveryBatchSize,
    adapterResponseTimeoutMs: identical(adapterResponseTimeoutMs, _unset)
        ? this.adapterResponseTimeoutMs
        : adapterResponseTimeoutMs as int?,
  );

  /// Sentinel for [copyWith]'s `adapterResponseTimeoutMs` so "not passed"
  /// (keep the current value) can be told apart from "pass null" (clear it
  /// back to the adapter default).
  static const _unset = Object();

  Map<String, dynamic> toJson() => {
    'readTimeoutMs': readTimeoutMs,
    'reconnectBackoffMinS': reconnectBackoffMinS,
    'reconnectBackoffMaxS': reconnectBackoffMaxS,
    'neverGiveUpReconnecting': neverGiveUpReconnecting,
    'reconnectAttempts': reconnectAttempts,
    'stopAfterNoVehicleDataMinutes': stopAfterNoVehicleDataMinutes,
    'maxReadsPerSecond': maxReadsPerSecond,
    'surveyIntervalMinutes': surveyIntervalMinutes,
    'chargeReminderIntervalMinutes': chargeReminderIntervalMinutes,
    'autoStartOnPower': autoStartOnPower,
    'recordOnlyWhilePoweredOn': recordOnlyWhilePoweredOn,
    'scoutWhileRecording': scoutWhileRecording,
    'scoutWhileDriving': scoutWhileDriving,
    'recordingMode': recordingMode.name,
    'keepSamplingFoundDids': keepSamplingFoundDids,
    'speedPollIntervalS': speedPollIntervalS,
    'discoveryBatchSize': discoveryBatchSize,
    'adapterResponseTimeoutMs': adapterResponseTimeoutMs,
  };

  /// Missing keys (an older version's blob, or a corrupt one a caller has
  /// already decoded down to a map) fall back to [AppSettings.defaultValues].
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const d = AppSettings.defaultValues();
    return AppSettings(
      readTimeoutMs: json['readTimeoutMs'] as int? ?? d.readTimeoutMs,
      reconnectBackoffMinS:
          json['reconnectBackoffMinS'] as int? ?? d.reconnectBackoffMinS,
      reconnectBackoffMaxS:
          json['reconnectBackoffMaxS'] as int? ?? d.reconnectBackoffMaxS,
      neverGiveUpReconnecting:
          json['neverGiveUpReconnecting'] as bool? ?? d.neverGiveUpReconnecting,
      reconnectAttempts:
          json['reconnectAttempts'] as int? ?? d.reconnectAttempts,
      stopAfterNoVehicleDataMinutes:
          json['stopAfterNoVehicleDataMinutes'] as int? ??
          d.stopAfterNoVehicleDataMinutes,
      maxReadsPerSecond:
          json['maxReadsPerSecond'] as int? ?? d.maxReadsPerSecond,
      surveyIntervalMinutes:
          json['surveyIntervalMinutes'] as int? ?? d.surveyIntervalMinutes,
      chargeReminderIntervalMinutes:
          json['chargeReminderIntervalMinutes'] as int? ??
          d.chargeReminderIntervalMinutes,
      autoStartOnPower: json['autoStartOnPower'] as bool? ?? d.autoStartOnPower,
      recordOnlyWhilePoweredOn:
          json['recordOnlyWhilePoweredOn'] as bool? ??
          d.recordOnlyWhilePoweredOn,
      scoutWhileRecording:
          json['scoutWhileRecording'] as bool? ?? d.scoutWhileRecording,
      scoutWhileDriving:
          json['scoutWhileDriving'] as bool? ?? d.scoutWhileDriving,
      recordingMode: RecordingMode.values.firstWhere(
        (mode) => mode.name == json['recordingMode'],
        orElse: () => d.recordingMode,
      ),
      keepSamplingFoundDids:
          json['keepSamplingFoundDids'] as bool? ?? d.keepSamplingFoundDids,
      speedPollIntervalS:
          json['speedPollIntervalS'] as int? ?? d.speedPollIntervalS,
      discoveryBatchSize:
          json['discoveryBatchSize'] as int? ?? d.discoveryBatchSize,
      adapterResponseTimeoutMs: json['adapterResponseTimeoutMs'] as int?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.readTimeoutMs == readTimeoutMs &&
      other.reconnectBackoffMinS == reconnectBackoffMinS &&
      other.reconnectBackoffMaxS == reconnectBackoffMaxS &&
      other.neverGiveUpReconnecting == neverGiveUpReconnecting &&
      other.reconnectAttempts == reconnectAttempts &&
      other.stopAfterNoVehicleDataMinutes == stopAfterNoVehicleDataMinutes &&
      other.maxReadsPerSecond == maxReadsPerSecond &&
      other.surveyIntervalMinutes == surveyIntervalMinutes &&
      other.chargeReminderIntervalMinutes == chargeReminderIntervalMinutes &&
      other.autoStartOnPower == autoStartOnPower &&
      other.recordOnlyWhilePoweredOn == recordOnlyWhilePoweredOn &&
      other.scoutWhileRecording == scoutWhileRecording &&
      other.scoutWhileDriving == scoutWhileDriving &&
      other.recordingMode == recordingMode &&
      other.keepSamplingFoundDids == keepSamplingFoundDids &&
      other.speedPollIntervalS == speedPollIntervalS &&
      other.discoveryBatchSize == discoveryBatchSize &&
      other.adapterResponseTimeoutMs == adapterResponseTimeoutMs;

  @override
  int get hashCode => Object.hash(
    readTimeoutMs,
    reconnectBackoffMinS,
    reconnectBackoffMaxS,
    neverGiveUpReconnecting,
    reconnectAttempts,
    stopAfterNoVehicleDataMinutes,
    maxReadsPerSecond,
    surveyIntervalMinutes,
    chargeReminderIntervalMinutes,
    autoStartOnPower,
    recordOnlyWhilePoweredOn,
    scoutWhileRecording,
    scoutWhileDriving,
    recordingMode,
    keepSamplingFoundDids,
    speedPollIntervalS,
    discoveryBatchSize,
    adapterResponseTimeoutMs,
  );
}
