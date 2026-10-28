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
  });

  const AppSettings.defaultValues()
    : readTimeoutMs = 2000,
      reconnectBackoffMinS = 2,
      reconnectBackoffMaxS = 60,
      neverGiveUpReconnecting = true,
      reconnectAttempts = 20,
      stopAfterNoVehicleDataMinutes = 30,
      maxReadsPerSecond = 6,
      surveyIntervalMinutes = 3,
      chargeReminderIntervalMinutes = 5,
      autoStartOnPower = false,
      recordOnlyWhilePoweredOn = false,
      scoutWhileRecording = true,
      scoutWhileDriving = true,
      recordingMode = RecordingMode.scoutOnly,
      keepSamplingFoundDids = true;

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
  );

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
      other.keepSamplingFoundDids == keepSamplingFoundDids;

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
  );
}
