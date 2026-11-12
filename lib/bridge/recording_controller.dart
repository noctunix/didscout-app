import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:obdbridge/obdbridge.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:uuid/uuid.dart';

import '../capture/isotp.dart';
import '../capture/readings.dart';
import '../discovery/did_stability.dart';
import '../discovery/discovery_engine.dart';
import '../discovery/discovery_plan.dart';
import '../discovery/discovery_state.dart';
import '../discovery/discovery_state_store.dart';
import '../discovery/discovery_ui_state.dart';
import '../discovery/phase_focus.dart';
import '../discovery/probe.dart'
    show
        ProbeModule,
        ProbeOverflow,
        ProbeResult,
        ProbeStep,
        ProbeTimeout,
        ReadExecutorRejection,
        signalIdFor;
import '../discovery/profile_export.dart';
import '../discovery/scout_status.dart';
import '../discovery/testplan_check.dart';
import '../session/charge_reminder.dart';
import '../session/experiments.dart';
import '../session/session_markers.dart';
import '../settings/app_settings.dart';
import '../settings/settings_repository.dart';
import 'bridge_read_executor.dart';
import 'connection_status.dart';
import 'didscout_policy.dart';
import 'vag_ppe_plan_data.dart';

/// Forwards obdbridge's one-shot result events to the discovery executor
/// currently serving a recording; registered exclusively while one is
/// active, since nothing else in this app listens for [ObdEventsApi]
/// events today.
class _DiscoveryEventsBridge implements ObdEventsApi {
  _DiscoveryEventsBridge(this._executor);

  final BridgeReadExecutor _executor;

  @override
  void onOneShotResult(ObdSignalExchangeMessage result) =>
      _executor.deliverOneShotResult(result);

  @override
  void onLinkState(ObdLinkStateMessage state) {}
}

/// One capture of a guided experiment run.
class _ExperimentCapture {
  _ExperimentCapture({
    required this.experiment,
    required this.stage,
    required this.pending,
    required this.deadline,
  }) : total = pending.length;

  final Experiment experiment;
  final ExperimentCaptureStage stage;

  /// Request header and DID of each read not answered yet, by signal id.
  final Map<String, ({String header, String did})> pending;

  final int total;

  /// When the capture counts as complete even with reads unanswered.
  final DateTime deadline;

  final DidSnapshot snapshot = {};

  ExperimentCapturing get progress => ExperimentCapturing(
    experiment,
    stage: stage,
    answered: total - pending.length,
    total: total,
  );
}

/// The 29-bit module this app's fixed plan reads: ECU address `04`.
const String _module7RequestHeader = '18DA04F1';
const String _module7ResponseHeader = '18DAF104';

/// The 29-bit module carrying the odometer DID: ECU address `06`.
const String _module8RequestHeader = '18DA06F1';
const String _module8ResponseHeader = '18DAF106';

/// The 11-bit module this app's fixed plan reads.
const String _module6RequestHeader = '710';
const String _module6ResponseHeader = '77A';

/// The HV battery management ECU, under the module id discovery's vag29
/// inventory gives it, so its discovered DIDs dedupe onto the fixed steps.
const String _bmsModuleId = 'vag29-7B';
const String _bmsRequestHeader = '17FC007B';
const String _bmsResponseHeader = '17FE007B';

/// Added to [AppSettings.readTimeoutMs] for [_bmsModuleId]'s own read
/// deadline: recordings show this BMS still answering NRC `0x78`
/// (responsePending) a second time right at the plan's own deadline,
/// i.e. extending ISO 14229-2's P2* past what every other module needs.
/// A starting value, not yet measured against a worse real-world case.
const int _bmsReadDeadlineExtraMs = 10000;

/// How often [_bmsModuleId]'s DIDs `06C7`/`06C8` are read -- fixed steps
/// for curve-fitting while charging, not decoded for a live tile.
const int _bmsExtraDidIntervalMs = 30000;

/// A live value counts for this many of its step's planned intervals after
/// it was received, the same rule as [AppSettings.speedFreshnessWindow]:
/// one missed or slow read is tolerated, a stalled one is not shown.
const double _liveFreshnessIntervals = 2.5;

/// A fixed plan step whose answer is also decoded live, keyed by its own
/// [ObdStepMessage.signalId] — used to plan it and to decode
/// [ObdBridge.liveState]'s cached attempts back into a [LiveVehicleInfo]
/// during a recording.
class _LiveSignalSpec {
  const _LiveSignalSpec(
    this.moduleId,
    this.command,
    this.responseHeader, [
    this.intervalMs,
  ]);
  final String moduleId;
  final String command;
  final String responseHeader;

  /// Planned read interval; null for the speed step, which follows
  /// [AppSettings.speedPollIntervalMs].
  final int? intervalMs;

  int plannedIntervalMs(AppSettings settings) =>
      intervalMs ?? settings.speedPollIntervalMs;

  Duration freshnessWindow(AppSettings settings) => Duration(
    milliseconds: (plannedIntervalMs(settings) * _liveFreshnessIntervals)
        .round(),
  );
}

/// Planned in every mode: the speed because discovery is motion-aware and
/// needs it even in [RecordingMode.scoutOnly]; energy, range, odometer,
/// outside temperature, battery temperature and charging power because
/// they are what readings typed off the vehicle's displays are checked
/// against.
const Map<String, _LiveSignalSpec> _liveSignalSpecs = {
  'module7_22f40d': _LiveSignalSpec(
    'module7',
    '22F40D',
    _module7ResponseHeader,
  ),
  'module6_222ab8': _LiveSignalSpec(
    'module6',
    '222AB8',
    _module6ResponseHeader,
    15000,
  ),
  'module6_222ab6': _LiveSignalSpec(
    'module6',
    '222AB6',
    _module6ResponseHeader,
    60000,
  ),
  'module8_22f4a6': _LiveSignalSpec(
    'module8',
    '22F4A6',
    _module8ResponseHeader,
    60000,
  ),
  'module7_22f446': _LiveSignalSpec(
    'module7',
    '22F446',
    _module7ResponseHeader,
    60000,
  ),
  'module6_220311': _LiveSignalSpec(
    'module6',
    '220311',
    _module6ResponseHeader,
    10000,
  ),
  'vag29-7B_221e10': _LiveSignalSpec(
    _bmsModuleId,
    '221E10',
    _bmsResponseHeader,
    30000,
  ),
};

const List<String> _adapterInitCommands = [
  'ATZ',
  'ATE0',
  'ATL0',
  'ATS0',
  'ATH1',
];

/// [_adapterInitCommands] plus, when [AppSettings.adapterResponseTimeoutMs]
/// is set, the `ATST` command right after them -- used for both the plan's
/// `init` and `resync` sequences.
List<String> _adapterSequence(AppSettings settings) => [
  ..._adapterInitCommands,
  ?settings.adapterResponseTimeoutCommand,
];

/// The generator's own default survey interval in `vag_ppe_plan_data.dart`
/// (the interval most of that file's exploratory DIDs carry) — the only
/// value [AppSettings.surveyIntervalMs] is allowed to override; DIDs
/// generated with a different (watch/once) interval are left alone.
const int _generatedSurveyIntervalMs = 180000;

/// Floor of one recurring read's cost: about one physical read over a BLE
/// adapter on 11-bit or 29-bit CAN, measured.
const int _minReadCostMs = 150;

/// Share of the read time, in percent, the survey reads may take at most:
/// the rest stays with the fixed steps and with discovery, whose one-shot
/// reads only run in the poller's idle time.
const int _maxSurveyReadPercent = 40;

/// A recurring DID read planned on top of the fixed steps, before the
/// survey interval is settled.
class _RecurringRead {
  const _RecurringRead({
    required this.signalId,
    required this.moduleId,
    required this.command,
    required this.responseHeader,
    this.ownIntervalMs,
    this.stable = false,
  });

  final String signalId;
  final String moduleId;
  final String command;
  final String responseHeader;

  /// The read's own interval, or null when it follows the survey interval.
  final int? ownIntervalMs;

  /// Whether the read follows the survey interval, but never more often
  /// than every [stableDidIntervalMs].
  final bool stable;

  bool get atSurveyInterval => ownIntervalMs == null && !stable;

  ObdStepMessage step(int surveyIntervalMs) => ObdStepMessage(
    signalId: signalId,
    moduleId: moduleId,
    command: command,
    responseHeader: responseHeader,
    intervalMs:
        ownIntervalMs ??
        (stable
            ? max(surveyIntervalMs, stableDidIntervalMs)
            : surveyIntervalMs),
  );
}

/// How long the native poller holds back a module whose planned reads keep
/// answering NO DATA before probing it again (see
/// `ObdLimitsMessage.quietModuleBackoffMs`) -- shorter than the survey
/// interval, so a module that wakes up loses at most one survey round.
const int quietModuleBackoffMs = 120000;

/// [RecordingController]'s state machine. UI code decides what to show and
/// which buttons to enable purely from [RecordingController.phase] (plus
/// [RecordingController.canStart]/[canStop]/[canShare]), never by re-deriving
/// it from lower-level [ObdBridge] state.
enum RecordingPhase {
  idle,
  requestingPermissions,
  permissionDenied,
  scanning,
  noAdapterFound,
  connecting,
  startingRecording,
  recording,
  stopping,
  finished,
  error,
}

/// Orchestrates didscout's fixed, read-only recording plan over [ObdBridge]:
/// request permissions, scan for the strongest-RSSI adapter, connect,
/// configure, and start a buffered recording; later stop it and expose the
/// buffer plus the session's marker sidecar file for sharing.
///
/// [markers] is this controller's own phase/note log (the UI reads it for
/// display); every marker added through [addPhase]/[addNote] is also
/// appended to the session's marker sidecar file once one exists.
class RecordingController extends ChangeNotifier {
  RecordingController({
    ObdBridge? bridge,
    Future<Directory> Function()? recordingsDirectory,
    String Function()? sessionIdFactory,
    DateTime Function()? clock,
    this._scanDurationMs = 8000,
    Duration tickInterval = const Duration(seconds: 5),
    this._discoveryPumpInterval = const Duration(seconds: 2),
    this._focusSampleInterval = phaseFocusSampleInterval,
    Duration testplanInitialDelay = const Duration(seconds: 8),
    Future<void> Function(List<ph.Permission>)? requestRuntimePermissions,
    Future<AppSettings> Function()? loadSettings,
    Future<DiscoveryState> Function()? loadDiscoveryState,
    Future<void> Function(DiscoveryState)? saveDiscoveryState,
  }) : _bridge = bridge ?? ObdBridge(DidscoutPolicy()),
       _requestRuntimePermissions =
           requestRuntimePermissions ?? _defaultRequestRuntimePermissions,
       _recordingsDirectory =
           recordingsDirectory ?? _defaultRecordingsDirectory,
       _sessionIdFactory = sessionIdFactory ?? (() => const Uuid().v7()),
       // Can't be `this._tickInterval` — the field is private but the
       // constructor parameter name must stay public for tests to pass it.
       // ignore: prefer_initializing_formals
       _tickInterval = tickInterval,
       // ignore: prefer_initializing_formals
       _testplanInitialDelay = testplanInitialDelay,
       _loadSettings = loadSettings ?? const SettingsRepository().load,
       _loadDiscoveryState = loadDiscoveryState ?? _defaultLoadDiscoveryState,
       _saveDiscoveryState = saveDiscoveryState ?? _defaultSaveDiscoveryState,
       _clock = clock,
       markers = SessionMarkerLog(clock: clock),
       _chargeReminder = ChargeReminderScheduler(clock: clock);

  final ObdBridge _bridge;
  final Future<void> Function(List<ph.Permission>) _requestRuntimePermissions;
  final Future<Directory> Function() _recordingsDirectory;
  final String Function() _sessionIdFactory;
  final int _scanDurationMs;

  /// Bound on the fast-reconnect attempt to [_lastAdapter] in [start] --
  /// shorter than native's own connect timeout (~20s), so a remembered
  /// adapter that is no longer in range doesn't delay the scan-path
  /// fallback this optimization exists to avoid slowing down.
  static const Duration _fastReconnectTimeout = Duration(seconds: 5);
  final Duration _tickInterval;
  final Duration _discoveryPumpInterval;
  final Duration _focusSampleInterval;
  final Duration _testplanInitialDelay;
  final Future<AppSettings> Function() _loadSettings;
  final Future<DiscoveryState> Function() _loadDiscoveryState;
  final Future<void> Function(DiscoveryState) _saveDiscoveryState;
  final DateTime Function()? _clock;

  DateTime _now() => (_clock ?? DateTime.now)();

  BridgeReadExecutor? _discoveryExecutor;
  DiscoveryEngine? _discoveryEngine;
  DiscoveryState? _discoveryState;
  Timer? _discoveryTimer;
  int _sessionDiscoveryHits = 0;
  DiscoveryUiState? _discoveryUiState;
  Timer? _focusTimer;
  TestplanCheck? _testplanCheck;

  /// Debounces [_scheduleTestplanRun]: the latest connect or phase-change
  /// trigger always wins, so flipping through phases quickly schedules
  /// one run rather than one per flip.
  Timer? _testplanTimer;

  /// The testplan check's own probe states for the recording currently in
  /// progress, for the "Testplan check" card -- null under the same
  /// conditions as [discoveryUiState].
  TestplanCheck? get testplanCheck => _testplanCheck;

  /// Signal ids of the last focus sample's reads still unanswered, until
  /// [_focusDeadline] -- their results are claimed from the discovery
  /// executor, never handed to the discovery engine.
  final Set<String> _focusPending = {};
  DateTime? _focusDeadline;

  /// Where among the moving and the other reads of the current phase's
  /// [phaseFocusReads] the next focus sample ([nextFocusSample])
  /// continues.
  int _focusMoverCursor = 0;
  int _focusRestCursor = 0;

  /// Per focus read's signal id, the hash of its last positive payload and
  /// when that payload last differed from the one before.
  final Map<String, int> _focusPayloadHashes = {};
  final Map<String, DateTime> _focusMovedAt = {};

  /// The discovery state as last persisted while discovery runs.
  String? _savedDiscoveryJson;

  ExperimentRun? _experimentRun;

  /// The reads each capture of the current experiment run queues, fixed
  /// when it starts so the snapshots cover the same DIDs.
  List<EcuDidRead> _experimentReads = const [];

  _ExperimentCapture? _experimentCapture;
  DidSnapshot _experimentBefore = const {};
  DidSnapshot _experimentAfter = const {};

  /// The guided experiment run of this recording, in progress or last
  /// finished; null before one was started or once dismissed.
  ExperimentRun? get experimentRun => _experimentRun;

  bool get _experimentActive => switch (_experimentRun) {
    ExperimentCapturing() ||
    ExperimentAwaitingAction() ||
    ExperimentAwaitingUndo() => true,
    ExperimentDone() || ExperimentFailed() || null => false,
  };

  /// Snapshot for the recording page's "Scouting" card -- null whenever
  /// discovery isn't currently running (not recording, or "scout while
  /// recording" is off).
  DiscoveryUiState? get discoveryUiState => _discoveryUiState;

  /// Live scouting activity for the recording page's compact status line --
  /// null under the same conditions as [discoveryUiState].
  ScoutStatus? get scoutStatus => _discoveryEngine?.scoutStatus(_now());

  /// The discovery engine's own scouting event log, newest first -- empty
  /// whenever discovery isn't currently running.
  List<ScoutEvent> get scoutEventLog => _discoveryEngine?.eventLog ?? const [];

  /// The discovery executor currently serving a recording, if any -- tests
  /// use this to simulate [ObdEventsApi.onOneShotResult] via
  /// [BridgeReadExecutor.deliverOneShotResult] without reaching into the
  /// real platform channel.
  @visibleForTesting
  BridgeReadExecutor? get discoveryExecutorForTesting => _discoveryExecutor;

  /// The discovery engine currently serving a recording, if any -- tests
  /// use this to inspect scan progress/hits directly.
  @visibleForTesting
  DiscoveryEngine? get discoveryEngineForTesting => _discoveryEngine;

  /// The settings in effect for the recording currently in progress (or the
  /// one most recently started) — reloaded by [start] every time, never
  /// cached across app launches.
  AppSettings _settings = const AppSettings.defaultValues();

  final SessionMarkerLog markers;

  /// Markers added while no sidecar existed, in order, awaiting the next
  /// one [start] creates.
  final List<SessionMarker> _unflushedMarkers = [];
  ChargeReminderScheduler _chargeReminder;
  Timer? _tickTimer;

  LiveVehicleInfo _liveInfo = LiveVehicleInfo.empty;

  /// The vehicle's own live values, polled from [ObdBridge.liveState] while
  /// recording. Stays [LiveVehicleInfo.empty] whenever no live source is
  /// available (not recording, or the query failed) — tiles then simply
  /// show no live info.
  LiveVehicleInfo get liveInfo => _liveInfo;

  /// When the `module7_22f40d` (speed) exchange behind [_liveInfo.speedKmh]
  /// was actually received, per [ObdSignalExchangeMessage.receivedAtEpochMs]
  /// -- null whenever no successful speed read has ever been decoded.
  DateTime? _speedReadAt;

  /// True only when the vehicle is both reporting zero speed and that
  /// reading is still fresh ([AppSettings.speedFreshnessWindow]) -- unknown
  /// or stale speed (no live source yet, or a read that is older than the
  /// window) is treated as moving, never as stationary, since discovery
  /// must not assume it's safe to scan a potentially-safety-relevant ECU
  /// just because speed hasn't been read recently.
  bool get isStationary => _isStationary(_now());

  bool _isStationary(DateTime now) {
    final readAt = _speedReadAt;
    if (_liveInfo.speedKmh != 0 || readAt == null) return false;
    return now.difference(readAt) <= _settings.speedFreshnessWindow;
  }

  /// The adapter [start] last connected to — kept across a stop→start
  /// cycle so the next [start] can retry a direct [ObdBridge.connect] to it
  /// before falling back to a full [ObdBridge.scanAdapters], skipping that
  /// scan's [_scanDurationMs] wait whenever the same adapter answers.
  ObdAdapterMessage? _lastAdapter;

  /// The most recently observed link state, from [ObdBridge.liveState]'s own
  /// link snapshot — used by [_pollConnectionStatus] to tell a live
  /// connection apart from a reconnect in progress.
  ObdLinkStateValueMessage? _linkState;

  DateTime? _reconnectingSince;
  int _reconnectPollAttempts = 0;

  ConnectionStatus? _connectionStatus;

  /// The recording's connection status while [phase] is [RecordingPhase.recording],
  /// plus the final [RecordingConnectionState.stopped] value for the instant native
  /// ends a recording on its own; null at every other time.
  ConnectionStatus? get connectionStatus => _connectionStatus;

  DateTime? _nativeStopAt;
  String? _nativeStopReason;

  /// Set once native has ended a recording on its own (connection lost and
  /// the reconnect budget exhausted, idle vehicle, write failure, …) rather
  /// than the owner tapping Stop — a persistent banner until the next
  /// [start] clears it. Null otherwise, including after an ordinary
  /// owner-initiated stop.
  String? get nativeStopBanner {
    final at = _nativeStopAt;
    final reason = _nativeStopReason;
    if (at == null || reason == null) return null;
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'Recording stopped at ${two(local.hour)}:${two(local.minute)}: '
        '$reason';
  }

  /// The buffer file of the recording currently in progress — null unless
  /// [phase] is [RecordingPhase.recording]. Distinct from [bufferFilePath],
  /// which stays set through [RecordingPhase.finished] so it can still be
  /// shared.
  String? get currentRecordingPath =>
      _phase == RecordingPhase.recording ? _bufferFilePath : null;

  bool _chargeReminderVisible = false;

  /// Whether the charging-round reminder banner should be shown right now.
  bool get chargeReminderVisible => _chargeReminderVisible;

  /// Dismisses the current reminder banner; the next one still fires on
  /// schedule, [ChargeReminderScheduler.interval] after the last one.
  void dismissChargeReminder() {
    if (!_chargeReminderVisible) return;
    _chargeReminderVisible = false;
    notifyListeners();
  }

  static const _blePermissions = [
    ph.Permission.bluetoothScan,
    ph.Permission.bluetoothConnect,
    ph.Permission.notification,
  ];

  static Future<void> _defaultRequestRuntimePermissions(
    List<ph.Permission> permissions,
  ) async {
    await permissions.request();
  }

  RecordingPhase _phase = RecordingPhase.idle;
  RecordingPhase get phase => _phase;

  /// Extra human-readable detail for the current [phase] (adapter name,
  /// rejection/error reason) — null when the phase needs none.
  String? _statusDetail;
  String? get statusDetail => _statusDetail;

  String? _sessionId;
  String? _bufferFilePath;

  /// Set once a recording has been started; also the file shared when
  /// [canShare].
  String? get bufferFilePath => _bufferFilePath;

  /// The session's marker sidecar path, next to [bufferFilePath]. Created at
  /// [start] (with the plan line as its first entry) and so set for as long
  /// as [bufferFilePath] is — never null for a session that has started.
  String? get markersFilePath =>
      _bufferFilePath != null ? '${_bufferFilePath!}.markers.jsonl' : null;

  /// Where [start] creates recording buffers, for anything (e.g. the
  /// Recordings list) that needs to enumerate past recordings too.
  Future<Directory> resolveRecordingsDirectory() => _recordingsDirectory();

  /// Writes whatever discovery has found so far -- the recording currently
  /// in progress's own in-memory state if discovery is running, otherwise
  /// whatever was last persisted -- as a profile-draft TOML file, ready for
  /// a share sheet. Returns the written file's path, or null if nothing
  /// has ever been discovered (including when no discovery state exists
  /// at all).
  Future<String?> writeProfileDraft() async {
    DiscoveryState state;
    final active = _discoveryState;
    if (active != null) {
      state = active;
    } else {
      try {
        state = await _loadDiscoveryState();
      } catch (_) {
        return null;
      }
    }
    if (state.ecus.values.every((ecu) => ecu.discovered.isEmpty)) {
      return null;
    }
    final draft = exportProfileDraft(
      state,
      id: 'didscout-draft',
      name: 'didscout discovery draft',
      description: 'Draft profile from on-device discovery, unverified.',
    );
    final directory = await _recordingsDirectory();
    final path =
        '${directory.path}/profile-draft-'
        '${DateTime.now().toUtc().millisecondsSinceEpoch}.toml';
    await File(path).writeAsString(draft);
    return path;
  }

  bool get canStart =>
      _phase == RecordingPhase.idle ||
      _phase == RecordingPhase.permissionDenied ||
      _phase == RecordingPhase.noAdapterFound ||
      _phase == RecordingPhase.finished ||
      _phase == RecordingPhase.error;

  bool get canStop => _phase == RecordingPhase.recording;

  bool get canShare =>
      _phase == RecordingPhase.finished && _bufferFilePath != null;

  /// The buffer file, plus the marker sidecar if any marker was recorded,
  /// ready to hand to a share sheet once [canShare].
  List<String> get shareableFiles => [?_bufferFilePath, ?markersFilePath];

  void _setPhase(RecordingPhase phase, [String? detail]) {
    _phase = phase;
    _statusDetail = detail;
    notifyListeners();
  }

  /// Records a phase marker, mirroring [SessionMarkerLog.addPhase]; appended
  /// to the session's marker sidecar file once one exists. Entering or
  /// leaving [MarkerPhase.charge] arms/disarms the charging-round reminder;
  /// [phase]'s focus ECUs replace the previous phase's in discovery and
  /// focus sampling.
  void addPhase(MarkerPhase phase) {
    markers.addPhase(phase);
    _chargeReminder.phaseChanged(phase);
    if (phase != MarkerPhase.charge) {
      _chargeReminderVisible = false;
    }
    _discoveryEngine
      ?..handlePhaseChange()
      ..focusRequestHeaders = _focusRequestHeaders;
    _focusMoverCursor = 0;
    _focusRestCursor = 0;
    _scheduleTestplanRun();
    unawaited(_appendLatestMarker());
  }

  /// Records a free-text note marker, mirroring [SessionMarkerLog.addNote];
  /// appended to the session's marker sidecar file once one exists.
  void addNote(String text) {
    markers.addNote(text);
    unawaited(_appendLatestMarker());
  }

  /// Records a short-label event marker, mirroring [SessionMarkerLog.addEvent].
  void addEvent(String label) {
    markers.addEvent(label);
    unawaited(_appendLatestMarker());
  }

  /// Records a tile reading, mirroring [SessionMarkerLog.addReading]; the
  /// vehicle's live speed at read time, if any, is attached automatically.
  void addReading({
    required ReadingQuantity quantity,
    required num value,
    required DateTime readAt,
    required ReadingSource source,
    num? prefill,
    PrefillOrigin? prefillOrigin,
    num? liveValue,
  }) {
    markers.addReading(
      quantity: quantity,
      value: value,
      unit: quantity.unit,
      readAt: readAt,
      source: source,
      prefill: prefill,
      prefillOrigin: prefillOrigin,
      liveValue: liveValue,
      speedKmh: _liveInfo.speedKmh,
    );
    unawaited(_appendLatestMarker());
  }

  /// The F197 name of an ECU addressed by [requestHeader], or null when
  /// none has one or discovery isn't running.
  String? ecuName(String requestHeader) => _discoveryState?.ecus.values
      .where((ecu) => ecu.requestHeader == requestHeader)
      .map((ecu) => ecu.f197Name)
      .nonNulls
      .firstOrNull;

  /// The experiments worth suggesting right now ([suggestedExperiments]):
  /// for the current phase, while stationary, whose target ECUs include
  /// one with found DIDs that is not paused asleep, least often completed
  /// on this vehicle first. Empty while discovery isn't running (not
  /// recording, or [AppSettings.scoutWhileRecording] off).
  List<Experiment> get experimentSuggestions {
    final state = _discoveryState;
    if (state == null) return const [];
    final now = _now();
    return suggestedExperiments(
      phase: markers.currentPhase,
      stationary: _isStationary(now),
      answeringRequestHeaders: {
        for (final ecu in state.ecus.values)
          if (ecu.discovered.isNotEmpty &&
              !(ecu.asleepUntil?.isAfter(now) ?? false))
            ecu.requestHeader,
      },
      completedCounts: state.experimentCompletions,
    );
  }

  /// Starts the experiment [id] from [experimentSuggestions]: records its
  /// `before` marker and reads [experimentReads] of its target ECUs, as
  /// [experimentRun] reports. Once those reads are in, [experimentRun]
  /// asks the owner for the action and the `action` marker is recorded. A
  /// no-op while another run is in progress or when [id] is not suggested
  /// right now.
  void startExperiment(String id) {
    final state = _discoveryState;
    if (_experimentActive || state == null) return;
    final experiment = experimentSuggestions
        .where((suggestion) => suggestion.id == id)
        .firstOrNull;
    if (experiment == null) return;
    final now = _now();
    _experimentReads = experimentReads(
      state,
      experiment,
      includeProfileDids:
          _settings.recordingMode == RecordingMode.scoutAndRecordKnown,
      stationary: _isStationary(now),
      now: now,
    );
    _forgetFocusPayloads(_experimentReads);
    unawaited(
      _beginExperimentCapture(experiment, ExperimentCaptureStage.before),
    );
  }

  /// The owner took the action: records the `after` marker and reads the
  /// same DIDs again; once those reads are in, [experimentRun] asks the
  /// owner to undo the action and the `undo` marker is recorded. Fails
  /// the run instead when the vehicle is no longer stationary. A no-op
  /// unless [experimentRun] is waiting for the action.
  void confirmExperimentAction() {
    if (_experimentRun case ExperimentAwaitingAction(:final experiment)) {
      _resumeExperiment(experiment, ExperimentCaptureStage.after);
    }
  }

  /// The owner undid the action: records the `undone` marker and reads
  /// the same DIDs a third time; [experimentRun] then reports the
  /// changes. Fails the run instead when the vehicle is no longer
  /// stationary. A no-op unless [experimentRun] is waiting for the undo.
  void confirmExperimentUndo() {
    if (_experimentRun case ExperimentAwaitingUndo(:final experiment)) {
      _resumeExperiment(experiment, ExperimentCaptureStage.undone);
    }
  }

  /// Starts the [stage] capture of [experiment] after the owner's step,
  /// or fails the run when the vehicle is no longer stationary.
  void _resumeExperiment(Experiment experiment, ExperimentCaptureStage stage) {
    if (!_isStationary(_now())) {
      _failExperiment(ExperimentFailure.moving);
      return;
    }
    unawaited(_beginExperimentCapture(experiment, stage));
  }

  /// Abandons the experiment run in progress, recording its `cancelled`
  /// marker with reason [ExperimentFailure.cancelled]; reads already
  /// queued still run, their results are dropped.
  /// A no-op unless a run is in progress.
  void cancelExperiment() => _failExperiment(ExperimentFailure.cancelled);

  /// Clears a finished or failed [experimentRun]; a no-op while one is in
  /// progress.
  void dismissExperiment() {
    if (_experimentRun == null || _experimentActive) return;
    _experimentRun = null;
    notifyListeners();
  }

  void _addExperimentStep(
    String id,
    ExperimentStep step, {
    ExperimentFailure? reason,
  }) {
    markers.addExperimentStep(id, step, reason: reason);
    unawaited(_appendLatestMarker());
  }

  /// Records the marker that starts the [stage] capture of [experiment]
  /// (`before`, `after` or `undone`) and queues [_experimentReads] for it.
  /// The capture completes once every read has returned
  /// ([_claimExperimentResult]) or at the deadline a discovery batch that
  /// size would get ([_superviseExperiment]).
  Future<void> _beginExperimentCapture(
    Experiment experiment,
    ExperimentCaptureStage stage,
  ) async {
    _addExperimentStep(experiment.id, switch (stage) {
      ExperimentCaptureStage.before => ExperimentStep.before,
      ExperimentCaptureStage.after => ExperimentStep.after,
      ExperimentCaptureStage.undone => ExperimentStep.undone,
    });
    final executor = _discoveryExecutor!;
    final (modules, steps) = _probeBatch(_experimentReads);
    final capture = _ExperimentCapture(
      experiment: experiment,
      stage: stage,
      pending: {
        for (final read in _experimentReads)
          _readSignalId(read): (header: read.requestHeader, did: read.did),
      },
      deadline: _now().add(
        defaultBatchDeadlineBase +
            defaultBatchDeadlinePerStep * _experimentReads.length,
      ),
    );
    _experimentCapture = capture;
    _experimentRun = capture.progress;
    notifyListeners();
    if (capture.pending.isEmpty) {
      _finishExperimentCapture();
      return;
    }
    try {
      await executor.submit(modules, steps);
    } on ReadExecutorRejection {
      if (identical(_experimentCapture, capture)) {
        _failExperiment(ExperimentFailure.rejected);
      }
    }
  }

  /// Drops the last focus payload of each of [reads], so the action an
  /// experiment asks for never counts as a value moving on its own.
  void _forgetFocusPayloads(List<EcuDidRead> reads) {
    for (final read in reads) {
      _focusPayloadHashes.remove(_readSignalId(read));
    }
  }

  /// Takes [result] if the current focus sample is waiting for it, noting
  /// when its payload differs from that DID's previous focus read.
  bool _claimFocusResult(ProbeResult result) {
    if (!_focusPending.remove(result.signalId)) return false;
    if (result.status is ProbeOverflow) {
      _discoveryEngine?.quarantineOversized(result.signalId);
    }
    if (result.payload case final payload?) {
      final hash = Object.hashAll(payload);
      final previous = _focusPayloadHashes[result.signalId];
      _focusPayloadHashes[result.signalId] = hash;
      if (previous != null && previous != hash) {
        _focusMovedAt[result.signalId] = result.at;
      }
    }
    return true;
  }

  /// Takes [result] if the current experiment capture is waiting for it,
  /// keeping a positive payload in the capture's snapshot; NO DATA, an
  /// NRC, a timeout or a cancelled read just count as returned.
  bool _claimExperimentResult(ProbeResult result) {
    final capture = _experimentCapture;
    final read = capture?.pending.remove(result.signalId);
    if (capture == null || read == null) return false;
    if (result.payload case final payload?) {
      capture.snapshot.putIfAbsent(read.header, () => {})[read.did] =
          Uint8List.fromList(payload);
    }
    if (capture.pending.isEmpty) {
      _finishExperimentCapture();
    } else {
      _experimentRun = capture.progress;
      notifyListeners();
    }
    return true;
  }

  /// Folds one testplan probe result into discovery state, matching its
  /// request header against a known ECU: a survey-eligible positive
  /// reply is booked as discovered and reported through [DiscoveryEngine.
  /// onHit], the same path a regular discovery hit uses, so it enters the
  /// recurring survey; a timeout quarantines the DID into [EcuInfo.slow]
  /// so discovery (and the next run of this check) never requests it
  /// again. A no-op once no known ECU answers [probe]'s request header.
  void _handleTestplanResult(TestplanProbe probe, ProbeResult result) {
    final did = probe.did;
    final discoveryState = _discoveryState;
    if (did == null || discoveryState == null) return;
    final hit = discoveryState.ecus.entries
        .where((entry) => entry.value.requestHeader == probe.requestHeader)
        .firstOrNull;
    if (hit == null) return;
    final ecu = hit.value;
    if (probe.countsTowardSurvey) {
      if (result.payload case final payload?) {
        ecu.discovered.add(did);
        ecu.conditional.remove(did);
        _discoveryEngine?.onHit(hit.key, did, payload);
        return;
      }
    }
    if (result.status is ProbeTimeout) {
      ecu.slow.add(did);
      ecu.discovered.remove(did);
      ecu.conditional.remove(did);
    }
  }

  /// Ends the current capture with whatever returned: after the before
  /// capture, asks for the action; after the after capture, asks to undo
  /// it; after the undone capture, reports the changes and counts the
  /// experiment as completed. A capture in which no read returned a value
  /// fails the run.
  void _finishExperimentCapture() {
    final capture = _experimentCapture!;
    final experiment = capture.experiment;
    if (capture.snapshot.isEmpty) {
      _failExperiment(ExperimentFailure.noAnswer);
      return;
    }
    _experimentCapture = null;
    switch (capture.stage) {
      case ExperimentCaptureStage.before:
        _experimentBefore = capture.snapshot;
        _experimentRun = ExperimentAwaitingAction(experiment);
        _addExperimentStep(experiment.id, ExperimentStep.action);
      case ExperimentCaptureStage.after:
        _experimentAfter = capture.snapshot;
        _experimentRun = ExperimentAwaitingUndo(experiment);
        _addExperimentStep(experiment.id, ExperimentStep.undo);
      case ExperimentCaptureStage.undone:
        // Persisted by the next discovery tick: saving here could overlap
        // a save already in flight and corrupt the file.
        _discoveryState!.experimentCompletions.update(
          experiment.id,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        final changes = experimentChanges(
          before: _experimentBefore,
          after: _experimentAfter,
        );
        _experimentRun = ExperimentDone(
          experiment,
          changes: changes,
          notReturned: unreturnedChanges(
            changes: changes,
            undone: capture.snapshot,
          ),
          movingOnTheirOwn: {
            for (final read in _experimentReads)
              if (_focusMovedAt.containsKey(_readSignalId(read)))
                (header: read.requestHeader, did: read.did),
          },
        );
        _forgetFocusPayloads(_experimentReads);
        _experimentBefore = const {};
        _experimentAfter = const {};
    }
    notifyListeners();
  }

  /// Ends the run in progress as failed for [failure], recording its
  /// `cancelled` marker with [failure] as the reason; a no-op unless a
  /// run is in progress.
  void _failExperiment(ExperimentFailure failure) {
    final run = _experimentRun;
    if (run == null || !_experimentActive) return;
    _experimentCapture = null;
    _experimentBefore = const {};
    _experimentAfter = const {};
    _forgetFocusPayloads(_experimentReads);
    _experimentRun = ExperimentFailed(run.experiment, failure);
    _addExperimentStep(
      run.experiment.id,
      ExperimentStep.cancelled,
      reason: failure,
    );
    notifyListeners();
  }

  /// Fails the run in progress once the vehicle is no longer stationary
  /// -- experiments never run while moving -- and ends a capture whose
  /// deadline passed.
  void _superviseExperiment() {
    if (!_experimentActive) return;
    final now = _now();
    if (!_isStationary(now)) {
      _failExperiment(ExperimentFailure.moving);
      return;
    }
    final capture = _experimentCapture;
    if (capture != null && !now.isBefore(capture.deadline)) {
      _finishExperimentCapture();
    }
  }

  Future<void> _appendLatestMarker() async {
    if (_bufferFilePath == null) {
      // No sidecar exists right now — the marker is held back and flushed
      // to the next one [start] creates.
      _unflushedMarkers.add(markers.markers.last);
      return;
    }
    // Readings/notes/events can still be entered after a recording has
    // ended (deliberately, by the owner, or because native stopped it) —
    // they land in the last recording's sidecar, flagged as not actually
    // belonging to a running recording.
    await _appendMarkerLine(
      markers.markers.last,
      tagInactive: _phase != RecordingPhase.recording,
    );
    notifyListeners();
  }

  Future<void> _appendMarkerLine(
    SessionMarker marker, {
    bool tagInactive = false,
  }) {
    var json = marker.toJson();
    if (tagInactive && marker is! PhaseMarker) {
      json = {...json, 'recording_active': false};
    }
    return _appendSidecarLine(markersFilePath!, json);
  }

  /// Appends [json] to the sidecar at [path] as one whole line. The write
  /// is synchronous: two concurrent async append-mode writes of a long
  /// line do interleave mid-line.
  static Future<void> _appendSidecarLine(
    String path,
    Map<String, dynamic> json,
  ) => Future.sync(
    () => File(
      path,
    ).writeAsStringSync('${jsonEncode(json)}\n', mode: FileMode.append),
  );

  /// Adopts a recording native is still running from before this
  /// controller existed, if any, and returns whether it did. The plugin's
  /// foreground service outlives the Flutter engine: a recreated UI that
  /// stayed idle beside it would never see the adapter again, since
  /// native rejects every scan while the recording holds the link.
  /// A no-op returning false unless [canStart].
  Future<bool> adoptRunningRecording() async {
    if (!canStart) return false;
    final ObdRecordingStateMessage state;
    try {
      state = await _bridge.recordingState();
    } catch (_) {
      // Native state unknown -- proceed as if nothing were running, which
      // is what a start did before adopting existed.
      return false;
    }
    final sessionId = state.sessionId;
    // Re-checked after the await: a concurrent adopt or start may have
    // claimed the controller meanwhile.
    if (state.state != ObdRecordingStateValueMessage.recording ||
        sessionId == null ||
        !canStart) {
      return false;
    }
    _setPhase(RecordingPhase.startingRecording);
    try {
      await _adoptSession(sessionId);
    } catch (error) {
      // Still reported as adopted: a scan instead would only fail again
      // while native holds the adapter.
      _setPhase(RecordingPhase.error, 'could not resume recording: $error');
    }
    return true;
  }

  Future<void> _adoptSession(String sessionId) async {
    try {
      _settings = await _loadSettings();
    } catch (_) {
      // Advisory, as in [start].
    }
    _chargeReminder = ChargeReminderScheduler(
      interval: _settings.chargeReminderInterval,
      clock: _clock,
    );
    _nativeStopAt = null;
    _nativeStopReason = null;
    _experimentRun = null;
    final directory = await _recordingsDirectory();
    final bufferFilePath = '${directory.path}/$sessionId.jsonl';
    final sidecar = File('$bufferFilePath.markers.jsonl');
    final sidecarModuleIds = <String>{};
    PhaseMarker? lastPhase;
    if (sidecar.existsSync()) {
      for (final line in await sidecar.readAsLines()) {
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          switch (json['type']) {
            case 'plan' || 'modules':
              for (final module in json['modules'] as List<dynamic>) {
                sidecarModuleIds.add(
                  (module as Map<String, dynamic>)['id'] as String,
                );
              }
            case 'phase':
              lastPhase = PhaseMarker(
                at: DateTime.parse(json['at'] as String),
                phase: MarkerPhase.values.byName(json['phase'] as String),
              );
          }
        } catch (_) {
          // A line torn by the killed process that wrote it; the rest of
          // the sidecar still holds.
        }
      }
    }
    if (lastPhase != null && markers.currentPhase == null) {
      markers.restorePhase(lastPhase.phase, lastPhase.at);
      _chargeReminder.phaseChanged(lastPhase.phase);
    }
    DiscoveryState discoveryState;
    try {
      discoveryState = await _loadDiscoveryState();
    } catch (_) {
      // As in [start]: no discovered DIDs this time rather than no
      // recording.
      discoveryState = DiscoveryState();
    }
    _sessionId = sessionId;
    _bufferFilePath = bufferFilePath;
    final unflushed = List.of(_unflushedMarkers);
    _unflushedMarkers.clear();
    for (final marker in unflushed) {
      await _appendMarkerLine(marker);
    }
    _setPhase(RecordingPhase.recording);
    _startTicking();
    _startDiscovery(discoveryState, sidecarModuleIds);
  }

  /// Runs the whole connect-and-record flow, or adopts a recording native
  /// is still running ([adoptRunningRecording]). A no-op unless
  /// [canStart].
  Future<void> start() async {
    if (!canStart) return;
    if (await adoptRunningRecording() || !canStart) return;
    _sessionId = null;
    _bufferFilePath = null;
    _nativeStopAt = null;
    _nativeStopReason = null;
    _connectionStatus = null;
    _reconnectingSince = null;
    _reconnectPollAttempts = 0;
    _experimentRun = null;
    try {
      _settings = await _loadSettings();
    } catch (_) {
      // Settings are advisory — a store that's unavailable or corrupt must
      // never stop a recording from starting; keep whatever was last
      // applied (the defaults, the first time).
    }
    _chargeReminder = ChargeReminderScheduler(
      interval: _settings.chargeReminderInterval,
      clock: _clock,
    );
    try {
      _setPhase(RecordingPhase.requestingPermissions);
      var permission = await _bridge.permissionStatus();
      if (permission == ObdPermissionStatusMessage.denied) {
        // The plugin only reports the current state; the system dialogs have to
        // come from the app.
        await _requestRuntimePermissions(_blePermissions);
        permission = await _bridge.requestPermissions();
      }
      if (permission == ObdPermissionStatusMessage.denied) {
        // Android 11 and older need location for BLE scanning.
        await _requestRuntimePermissions(const [
          ph.Permission.locationWhenInUse,
        ]);
        permission = await _bridge.requestPermissions();
      }
      if (permission != ObdPermissionStatusMessage.granted) {
        _setPhase(RecordingPhase.permissionDenied, permission.name);
        return;
      }

      ObdAdapterMessage? adapter;
      final remembered = _lastAdapter;
      if (remembered != null) {
        _setPhase(
          RecordingPhase.connecting,
          remembered.advertisedName ?? remembered.handle,
        );
        try {
          final fastLink = await _bridge
              .connect(remembered.handle)
              .timeout(_fastReconnectTimeout);
          if (fastLink.state == ObdLinkStateValueMessage.connected) {
            adapter = remembered;
          }
        } on TimeoutException {
          try {
            // Cancels the stuck native connect attempt so its own
            // activeHandle doesn't block the scan path's own connect below.
            await _bridge.disconnect();
          } catch (_) {
            // Best-effort -- see the fast path's own catch below.
          }
        } catch (_) {
          // A failed fast reconnect is never fatal -- fall through to the
          // ordinary scan path exactly as if no adapter had been remembered.
        }
      }
      if (adapter == null) {
        _setPhase(RecordingPhase.scanning);
        final adapters = await _bridge.scanAdapters(_scanDurationMs);
        final found = _strongestAdapter(adapters);
        if (found == null) {
          _setPhase(RecordingPhase.noAdapterFound);
          return;
        }
        adapter = found;

        _setPhase(
          RecordingPhase.connecting,
          adapter.advertisedName ?? adapter.handle,
        );
        final link = await _bridge.connect(adapter.handle);
        if (link.state != ObdLinkStateValueMessage.connected) {
          _setPhase(RecordingPhase.error, 'connect failed: ${link.state.name}');
          return;
        }
      }
      _lastAdapter = adapter;

      await _bridge.configure(
        ObdBridgeConfigMessage(
          activityClassName: 'de.noctunix.didscout_app.MainActivity',
          smallIconResourceName: 'ic_stat_didscout',
          sharedPreferencesName: 'didscout_bridge',
          bufferFormatId: 'didscout-buffer',
        ),
      );

      final directory = await _recordingsDirectory();
      final sessionId = _sessionIdFactory();
      final bufferFilePath = '${directory.path}/$sessionId.jsonl';

      DiscoveryState discoveryState;
      try {
        discoveryState = await _loadDiscoveryState();
      } catch (_) {
        // A corrupt/unavailable discovery state must never stop a
        // recording from starting; the plan simply carries no extra
        // discovered DIDs this time.
        discoveryState = DiscoveryState();
      }
      try {
        if (await learnFromRecordings(discoveryState, directory)) {
          await _saveDiscoveryState(discoveryState);
        }
      } on FileSystemException {
        // Learning only stretches sampling intervals; an unreadable
        // recording must never stop a new one from starting.
      }

      _setPhase(RecordingPhase.startingRecording);
      final plan = _buildPlan(_settings, discoveryState);
      final started = await _bridge.startRecording(
        ObdStartRecordingRequest(
          sessionId: sessionId,
          vehicleId: sessionId,
          bufferFilePath: bufferFilePath,
          startedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
          plan: plan,
          options: ObdRecordingOptionsMessage(holdWakeLock: true),
          notification: ObdRecordingNotificationMessage(
            channelName: 'didscout recording',
            title: 'didscout recording',
            body: 'Recording a read-only vehicle session',
            stopActionLabel: 'Stop',
          ),
        ),
      );
      if (!started) {
        _setPhase(RecordingPhase.error, 'recording did not start');
        return;
      }

      _sessionId = sessionId;
      _bufferFilePath = bufferFilePath;
      // The sidecar always exists once a recording has started, with the
      // actually-sent plan as its first line — created here, not lazily on
      // the first marker.
      await File(
        '$bufferFilePath.markers.jsonl',
      ).writeAsString('${jsonEncode(_planSidecarLine(plan))}\n');
      // [markers] outlives a recording; only what no earlier sidecar has
      // received yet belongs in this one.
      final unflushed = List.of(_unflushedMarkers);
      _unflushedMarkers.clear();
      for (final marker in unflushed) {
        await _appendMarkerLine(marker);
      }
      _setPhase(
        RecordingPhase.recording,
        adapter.advertisedName ?? adapter.handle,
      );
      _startTicking();
      _startDiscovery(discoveryState, {
        for (final module in plan.modules) module.moduleId,
      });
    } catch (error) {
      _setPhase(RecordingPhase.error, error.toString());
    }
  }

  /// Stops the active recording, making it shareable. A no-op unless
  /// [canStop]. [reason], when given (e.g. a power-only setting reacting to
  /// unplugging), is recorded the same way a native-initiated stop is, so
  /// [nativeStopBanner] surfaces it too.
  Future<void> stop({String? reason}) async {
    if (!canStop) return;
    final sessionId = _sessionId;
    if (sessionId == null) {
      _setPhase(RecordingPhase.error, 'no active session');
      return;
    }
    _stopTicking();
    await _teardownDiscovery();
    _setPhase(RecordingPhase.stopping);
    try {
      await _bridge.stopRecording(sessionId);
      if (reason != null) {
        _nativeStopAt = DateTime.now().toUtc();
        _nativeStopReason = reason;
      }
      try {
        // Native keeps the GATT link up across a stop for its own, unrelated
        // reuse case, but the OBDLink CX stops BLE-advertising once a GATT
        // link to it exists, so the next start's scan would never find it
        // again without this.
        await _bridge.disconnect();
      } catch (_) {
        // Best-effort -- a disconnect failure must never block stopping.
      }
      _setPhase(RecordingPhase.finished);
    } catch (error) {
      _setPhase(RecordingPhase.error, error.toString());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicking();
    unawaited(_teardownDiscovery());
    super.dispose();
  }

  bool _disposed = false;

  /// A tick, live-state poll or discovery pump already awaiting the bridge
  /// when [dispose] runs still finishes afterwards; its update has nobody
  /// left to notify.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _startTicking() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(_tickInterval, (_) => unawaited(_tick()));
  }

  void _stopTicking() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _liveInfo = LiveVehicleInfo.empty;
    _speedReadAt = null;
    _linkState = null;
    _connectionStatus = null;
    _reconnectingSince = null;
    _reconnectPollAttempts = 0;
  }

  /// Starts the discovery engine, focus sampling ([_sampleFocus]) and
  /// experiment supervision ([_superviseExperiment]) for the recording
  /// that just started or was adopted, whose sidecar already lists the
  /// modules in [sidecarModuleIds], when [AppSettings.scoutWhileRecording]
  /// is on; a no-op otherwise, and [discoveryUiState] then stays null and
  /// [experimentSuggestions] empty for the whole recording.
  void _startDiscovery(
    DiscoveryState discoveryState,
    Set<String> sidecarModuleIds,
  ) {
    if (!_settings.scoutWhileRecording) return;
    _discoveryState = discoveryState;
    final sidecarPath = markersFilePath!;
    final executor = BridgeReadExecutor(
      _bridge,
      onAccepted: (modules) =>
          _recordOneShotModules(sidecarPath, sidecarModuleIds, modules),
      // Focus first: a focus read queued before an experiment capture
      // must not stand in for the capture's own read of the same DID.
      // The testplan check needs no claim here -- every signal id in its
      // catalogue is unique to it, so it subscribes to `executor.results`
      // directly instead, the same way `DiscoveryEngine` does.
      claimResult: (result) =>
          _claimFocusResult(result) || _claimExperimentResult(result),
    );
    _discoveryExecutor = executor;
    ObdEventsApi.setUp(_DiscoveryEventsBridge(executor));
    _sessionDiscoveryHits = 0;
    final engine = DiscoveryEngine(
      executor: executor,
      state: discoveryState,
      onHit: (_, _, _) => _sessionDiscoveryHits++,
      batchSize: _settings.discoveryBatchSize,
    )..focusRequestHeaders = _focusRequestHeaders;
    _discoveryEngine = engine;
    _testplanCheck = TestplanCheck(
      executor: executor,
      onResult: _handleTestplanResult,
    );
    _scheduleTestplanRun();
    _savedDiscoveryJson = jsonEncode(discoveryState.toJson());
    final stationary = _isStationary(_now());
    _discoveryUiState = buildDiscoveryUiState(
      engine: engine,
      stationary: stationary,
      now: _now(),
      sessionHits: _sessionDiscoveryHits,
      allowedToRun: stationary || _settings.scoutWhileDriving,
    );
    _discoveryTimer = Timer.periodic(_discoveryPumpInterval, (_) {
      _superviseExperiment();
      unawaited(_pumpDiscovery());
    });
    _focusTimer = Timer.periodic(
      _focusSampleInterval,
      (_) => unawaited(_sampleFocus()),
    );
  }

  /// Schedules a testplan check run [_testplanInitialDelay] out, for
  /// whatever phase is current once it fires -- called once discovery
  /// starts (the "shortly after connecting" trigger) and again on every
  /// [addPhase], replacing any still-pending timer so a phase flipped
  /// through quickly schedules one run, not one per flip.
  void _scheduleTestplanRun() {
    _testplanTimer?.cancel();
    _testplanTimer = Timer(_testplanInitialDelay, () {
      unawaited(_testplanCheck?.runForPhase(markers.currentPhase));
    });
  }

  /// Request headers of the current phase's focus ECUs; empty while no
  /// phase is set.
  Set<String> get _focusRequestHeaders =>
      phaseFocusRequestHeaders[markers.currentPhase] ?? const {};

  /// Queues the next [maxPhaseFocusReads] of the current phase's
  /// [phaseFocusReads], continuing where the previous sample left off
  /// ([_probeBatch]). Skipped while the previous sample's reads are
  /// unanswered, up to the deadline a discovery batch that size would get,
  /// and while [AppSettings.keepSamplingFoundDids] is off; a rejected
  /// batch is simply left to the next sample. The target ECUs of an
  /// experiment capture in progress are left out; the capture reads them
  /// itself.
  Future<void> _sampleFocus() async {
    final executor = _discoveryExecutor;
    final discoveryState = _discoveryState;
    final now = _now();
    if (executor == null ||
        discoveryState == null ||
        !_settings.keepSamplingFoundDids ||
        (_focusPending.isNotEmpty && now.isBefore(_focusDeadline!))) {
      return;
    }
    _focusPending.clear();
    final reads = phaseFocusReads(
      discoveryState,
      // An experiment's target ECUs stay out for the whole run: a focus
      // read between its captures would see the owner's action.
      _focusRequestHeaders.difference({
        if (_experimentActive) ...?_experimentRun?.experiment.targetHeaders,
      }),
      stationary: _isStationary(now),
      now: now,
    );
    final next = nextFocusSample(
      reads,
      isMover: (read) {
        final movedAt = _focusMovedAt[_readSignalId(read)];
        return movedAt != null && now.difference(movedAt) < focusMoverWindow;
      },
      moverCursor: _focusMoverCursor,
      restCursor: _focusRestCursor,
    );
    if (next.sample.isEmpty) return;
    final (modules, steps) = _probeBatch(next.sample);
    _focusPending.addAll(steps.map((step) => step.signalId));
    _focusDeadline = now.add(
      defaultBatchDeadlineBase +
          defaultBatchDeadlinePerStep * next.sample.length,
    );
    _focusMoverCursor = next.moverCursor;
    _focusRestCursor = next.restCursor;
    try {
      await executor.submit(modules, steps);
    } on ReadExecutorRejection {
      if (identical(_discoveryExecutor, executor)) _focusPending.clear();
    }
  }

  /// The one-shot modules and steps for [reads], under the signal ids the
  /// plan's survey steps use for the same DIDs -- the reads add samples to
  /// the same signals.
  static (List<ProbeModule>, List<ProbeStep>) _probeBatch(
    List<EcuDidRead> reads,
  ) {
    final modules = <String, ProbeModule>{};
    final steps = <ProbeStep>[];
    for (final read in reads) {
      final moduleId = _effectiveModuleId(read.ecuId);
      modules[moduleId] ??= ProbeModule(
        id: moduleId,
        requestHeader: read.requestHeader,
        responseHeader: read.responseHeader,
        protocol: read.protocol,
      );
      steps.add(
        ProbeStep(signalId: _readSignalId(read), command: '22${read.did}'),
      );
    }
    return (modules.values.toList(), steps);
  }

  static String _readSignalId(EcuDidRead read) =>
      signalIdFor(_effectiveModuleId(read.ecuId), '22${read.did}');

  /// Appends a `{"type":"modules",…}` line to the sidecar at [sidecarPath]
  /// for every module in [modules] that has a known responder and is not
  /// in [recordedIds] yet, adding it there. One-shot rows of a module the
  /// plan line doesn't name can then still be mapped to their headers;
  /// a sweep module without a responder can't be, so it is left out.
  void _recordOneShotModules(
    String sidecarPath,
    Set<String> recordedIds,
    List<ProbeModule> modules,
  ) {
    final added = [
      for (final module in modules)
        if (module.responseHeader case final responseHeader?)
          if (recordedIds.add(module.id))
            {
              'id': module.id,
              'request': module.requestHeader,
              'response': responseHeader,
              'protocol': module.protocol.toString(),
            },
    ];
    if (added.isEmpty) return;
    unawaited(
      _appendSidecarLine(sidecarPath, {
        'type': 'modules',
        'at': _now().toUtc().toIso8601String(),
        'modules': added,
      }),
    );
  }

  /// Guards [_pumpDiscovery] against overlapping ticks: [DiscoveryEngine]
  /// isn't designed to have [DiscoveryEngine.pump] called again before a
  /// previous call finished, and the pump interval can be shorter than one
  /// round-trip through a slow or heavily-loaded one-shot queue.
  bool _discoveryPumpInFlight = false;

  /// One discovery scheduler tick: skips [DiscoveryEngine.pump] entirely
  /// while the vehicle is moving and [AppSettings.scoutWhileDriving] is
  /// off (the engine's own safety blocklist in `did_order.dart` applies
  /// regardless of this setting, inside `pump` itself), persists
  /// [_discoveryState] whenever it changed since it was last persisted,
  /// and always refreshes [discoveryUiState].
  Future<void> _pumpDiscovery() async {
    if (_discoveryPumpInFlight) return;
    final engine = _discoveryEngine;
    final discoveryState = _discoveryState;
    if (engine == null || discoveryState == null) return;
    _discoveryPumpInFlight = true;
    try {
      await _pumpDiscoveryOnce(engine, discoveryState);
    } finally {
      _discoveryPumpInFlight = false;
    }
  }

  Future<void> _pumpDiscoveryOnce(
    DiscoveryEngine engine,
    DiscoveryState discoveryState,
  ) async {
    final now = _now();
    final stationary = _isStationary(now);
    final allowedToRun = stationary || _settings.scoutWhileDriving;
    if (allowedToRun) {
      // A rejected enqueue (queue full, or no active recording while the
      // plugin reconnects) is backed off and retried inside `engine.pump`
      // itself until it is accepted or the engine is cancelled, so this
      // never throws.
      await engine.pump(stationary: stationary, now: now);
      // `_teardownDiscovery` may have run while the await above was
      // in flight (it never awaits this call itself -- see `cancel`'s
      // doc comment): once that happened, this engine is no longer
      // `_discoveryEngine` and nothing below may touch persisted state
      // or notify listeners on a controller that could itself be
      // disposed by now.
      if (!identical(_discoveryEngine, engine)) {
        return;
      }
    }
    final json = jsonEncode(discoveryState.toJson());
    if (json != _savedDiscoveryJson) {
      _savedDiscoveryJson = json;
      await _saveDiscoveryState(discoveryState);
    }
    _discoveryUiState = buildDiscoveryUiState(
      engine: engine,
      stationary: stationary,
      now: now,
      sessionHits: _sessionDiscoveryHits,
      allowedToRun: allowedToRun,
    );
    notifyListeners();
  }

  /// Stops and persists discovery for the recording that just ended (or is
  /// ending), failing an experiment run in progress, called from every
  /// exit path ([stop], [_handleNativeStop], [dispose]) -- a no-op if
  /// discovery was never started for it.
  Future<void> _teardownDiscovery() async {
    _failExperiment(ExperimentFailure.recordingStopped);
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _focusTimer?.cancel();
    _focusTimer = null;
    _focusPending.clear();
    _focusMoverCursor = 0;
    _focusRestCursor = 0;
    _focusPayloadHashes.clear();
    _focusMovedAt.clear();
    _testplanTimer?.cancel();
    _testplanTimer = null;
    _testplanCheck?.dispose();
    _testplanCheck = null;
    final engine = _discoveryEngine;
    final discoveryState = _discoveryState;
    _discoveryEngine = null;
    _discoveryExecutor?.dispose();
    _discoveryExecutor = null;
    _discoveryState = null;
    _savedDiscoveryJson = null;
    _discoveryUiState = null;
    _sessionDiscoveryHits = 0;
    engine?.dispose();
    if (engine != null) {
      ObdEventsApi.setUp(null);
    }
    if (discoveryState != null) {
      try {
        await _saveDiscoveryState(discoveryState);
      } catch (_) {
        // Best-effort -- a save failure must never block stopping.
      }
    }
  }

  static Future<DiscoveryState> _defaultLoadDiscoveryState() async {
    final file = await discoveryStateFile(defaultVehicleLabel);
    return DiscoveryState.loadFromFile(file);
  }

  static Future<void> _defaultSaveDiscoveryState(DiscoveryState state) async {
    final file = await discoveryStateFile(defaultVehicleLabel);
    await state.saveToFile(file);
  }

  Future<void> _tick() async {
    await _pollLiveState();
    await _pollConnectionStatus();
    if (_chargeReminder.checkDue()) {
      _chargeReminderVisible = true;
      notifyListeners();
    }
  }

  /// Queries [ObdBridge.liveState] for this plan's signals and decodes
  /// whatever answered into [_liveInfo]. A value only counts while it was
  /// received within its step's [_LiveSignalSpec.freshnessWindow]; an
  /// older one, or one without a receive time, is left null. Any failure
  /// (no live-state support, transport error, …) leaves [_liveInfo] at
  /// [LiveVehicleInfo.empty] — the tiles then simply show no live info,
  /// never a stale or fabricated one. Also records the link state
  /// exchanges carry, for [_pollConnectionStatus].
  Future<void> _pollLiveState() async {
    try {
      final state = await _bridge.liveState(_liveSignalSpecs.keys.toList());
      final now = _now();
      _linkState = state.link.state;
      int? speedKmh;
      double? odometerKm;
      int? outsideTempC;
      int? rangeKm;
      int? storedEnergyWh;
      double? batteryTempC;
      double? chargePowerKw;
      for (final exchange in state.exchanges) {
        if (exchange.transport != ObdTransportStatusMessage.ok ||
            exchange.rawResponseText == null) {
          continue;
        }
        final spec = _liveSignalSpecs[exchange.signalId];
        final receivedAtEpochMs = exchange.receivedAtEpochMs;
        if (spec == null || receivedAtEpochMs == null) continue;
        final receivedAt = DateTime.fromMillisecondsSinceEpoch(
          receivedAtEpochMs,
        );
        if (now.difference(receivedAt) > spec.freshnessWindow(_settings)) {
          continue;
        }
        final payload = decodePositivePayload(
          spec.command,
          exchange.rawResponseText!,
          spec.responseHeader,
        );
        if (payload == null) continue;
        switch (exchange.signalId) {
          case 'module7_22f40d':
            speedKmh = decodeSpeedKmh(payload);
            _speedReadAt = receivedAt;
          case 'module7_22f446':
            outsideTempC = decodeOutsideTempC(payload);
          case 'module8_22f4a6':
            odometerKm = decodeOdometerKm(payload);
          case 'module6_222ab6':
            rangeKm = decodeRangeKm(payload);
          case 'module6_222ab8':
            storedEnergyWh = decodeStoredEnergyWh(payload);
          case 'module6_220311':
            chargePowerKw = decodeChargePowerKw(payload);
          case 'vag29-7B_221e10':
            batteryTempC = decodeBatteryTempC(payload);
        }
      }
      _liveInfo = LiveVehicleInfo(
        speedKmh: speedKmh,
        odometerKm: odometerKm,
        outsideTempC: outsideTempC,
        rangeKm: rangeKm,
        storedEnergyWh: storedEnergyWh,
        batteryTempC: batteryTempC,
        chargePowerKw: chargePowerKw,
      );
    } catch (_) {
      _liveInfo = LiveVehicleInfo.empty;
      _speedReadAt = null;
      _linkState = ObdLinkStateValueMessage.disconnected;
    }
    notifyListeners();
  }

  /// Polls [ObdBridge.recordingState] while [phase] is
  /// [RecordingPhase.recording] and derives [connectionStatus] from it, plus
  /// [_linkState] ([_pollLiveState]'s own, already-polled link snapshot).
  /// Native ending the recording on its own (not via [stop]) is handled
  /// here too, via [_handleNativeStop] — the app must never keep showing a
  /// recording as live once native has actually ended it.
  Future<void> _pollConnectionStatus() async {
    if (_phase != RecordingPhase.recording) {
      _connectionStatus = null;
      _reconnectingSince = null;
      _reconnectPollAttempts = 0;
      return;
    }
    try {
      final state = await _bridge.recordingState();
      if (state.state == ObdRecordingStateValueMessage.stopped ||
          state.state == ObdRecordingStateValueMessage.interrupted) {
        _handleNativeStop(state.writeError ?? state.state.name);
        return;
      }
      _discoveryExecutor?.applyRecordingState(state.oneShotQueueDepth);
    } catch (_) {
      // Treated as "link not confirmed" below, same as a bad link state.
    }
    final connected =
        _linkState == ObdLinkStateValueMessage.connected ||
        _linkState == ObdLinkStateValueMessage.running;
    if (connected) {
      _connectionStatus = const ConnectionStatus.connected();
      _reconnectingSince = null;
      _reconnectPollAttempts = 0;
    } else {
      _reconnectingSince ??= DateTime.now();
      _reconnectPollAttempts++;
      _connectionStatus = ConnectionStatus.reconnecting(
        since: _reconnectingSince!,
        attempt: _reconnectPollAttempts,
      );
    }
    notifyListeners();
  }

  /// Native ended the recording by itself — reconnect budget exhausted, a
  /// write failure, etc. Switches [phase] out of [RecordingPhase.recording]
  /// immediately (as [finished], so the buffer up to that point is still
  /// shareable and a new recording can start right away) and records
  /// [reason] for [nativeStopBanner].
  void _handleNativeStop(String reason) {
    _nativeStopAt = DateTime.now().toUtc();
    _nativeStopReason = reason;
    _stopTicking();
    unawaited(_teardownDiscovery());
    // Same best-effort disconnect as `stop()` — see its own comment for why
    // the BLE link needs an explicit disconnect at all.
    unawaited(_bridge.disconnect().catchError((_) {}));
    // After `_stopTicking` (which clears `_connectionStatus` along with the
    // rest of the live polling state) so the final status shown is `stopped`,
    // not `null`.
    _connectionStatus = ConnectionStatus.stopped(reason);
    _setPhase(RecordingPhase.finished, reason);
  }

  static ObdAdapterMessage? _strongestAdapter(
    List<ObdAdapterMessage> adapters,
  ) {
    ObdAdapterMessage? strongest;
    var strongestRssi = -1 << 30;
    for (final adapter in adapters) {
      final rssi = adapter.rssi ?? -1 << 30;
      if (strongest == null || rssi > strongestRssi) {
        strongest = adapter;
        strongestRssi = rssi;
      }
    }
    return strongest;
  }

  /// Module id used for a profile module in this plan: the gateway shares the
  /// base plan's `module6` (same headers), every other module keeps its
  /// profile id.
  static String _planModuleId(VagPpeModuleSpec spec) =>
      spec.request == _module6RequestHeader ? 'module6' : spec.id;

  static ObdProtocol _protocolOf(VagPpeModuleSpec spec) => spec.protocol == '7'
      ? ObdProtocol.twentyNineBitCan
      : ObdProtocol.elevenBitCan;

  /// Modules for every vehicle module known from the vag-ppe profile.
  static List<ObdModuleMessage> _knownDidModules() => [
    for (final spec in vagPpeModules)
      ObdModuleMessage(
        moduleId: _planModuleId(spec),
        protocol: _protocolOf(spec).wireValue,
        setup: buildModuleSetupCommands(
          protocol: _protocolOf(spec),
          requestHeader: spec.request,
          responseHeader: spec.response,
        ),
      ),
  ];

  /// One read per DID known to answer on this vehicle platform. DIDs
  /// generated with the survey default ([_generatedSurveyIntervalMs])
  /// follow the survey interval instead; every other (watch/once) DID
  /// keeps its generated interval unchanged.
  static List<_RecurringRead> _knownDidReads() => [
    for (final spec in vagPpeModules)
      for (final did in spec.dids)
        _RecurringRead(
          signalId: '${_planModuleId(spec)}_22${did.did.toLowerCase()}',
          moduleId: _planModuleId(spec),
          command: '22${did.did}',
          responseHeader: spec.response,
          ownIntervalMs: did.intervalMs == _generatedSurveyIntervalMs
              ? null
              : did.intervalMs,
        ),
  ];

  /// The effective plan module id for a [DiscoveredEcuPlan] found by
  /// discovery: a vag-ppe-seeded ECU (see
  /// `DiscoveryEngine._seedVagPpeEcus`, which keys the engine's own state by
  /// the vag-ppe module's id) maps onto that module's own [_planModuleId]
  /// (so a `gateway` hit lands on the already-planned `module6`, not a
  /// second module addressing the same header); any other, genuinely new
  /// ECU keeps its own id.
  static String _effectiveModuleId(String discoveredModuleId) {
    for (final spec in vagPpeModules) {
      if (spec.id == discoveredModuleId) return _planModuleId(spec);
    }
    return discoveredModuleId;
  }

  /// Modules for every [DiscoveredEcuPlan] not already covered by
  /// [existingModuleIds] (the base plan plus [_knownDidModules]).
  static List<ObdModuleMessage> _discoveredModules(
    List<DiscoveredEcuPlan> additions,
    Set<String> existingModuleIds,
  ) {
    final seen = <String>{};
    return [
      for (final addition in additions)
        if (seen.add(_effectiveModuleId(addition.moduleId)) &&
            !existingModuleIds.contains(_effectiveModuleId(addition.moduleId)))
          ObdModuleMessage(
            moduleId: _effectiveModuleId(addition.moduleId),
            protocol: addition.protocol,
            setup: buildModuleSetupCommands(
              protocol: ObdProtocol.fromWireValue(addition.protocol)!,
              requestHeader: addition.requestHeader,
              responseHeader: addition.responseHeader,
            ),
          ),
    ];
  }

  /// One read per discovered DID, at the survey interval or, for a DID
  /// that has kept one value ([DiscoveredEcuPlan.stableDids]), at
  /// [stableDidIntervalMs] if that is longer -- empty whenever
  /// [AppSettings.keepSamplingFoundDids] is off.
  static List<_RecurringRead> _discoveredReads(
    List<DiscoveredEcuPlan> additions,
    AppSettings settings,
  ) => [
    if (settings.keepSamplingFoundDids)
      for (final addition in additions)
        for (final did in addition.dids)
          _RecurringRead(
            signalId: signalIdFor(
              _effectiveModuleId(addition.moduleId),
              '22$did',
            ),
            moduleId: _effectiveModuleId(addition.moduleId),
            command: '22$did',
            responseHeader: addition.responseHeader,
            stable: addition.stableDids.contains(did),
          ),
  ];

  /// [AppSettings.surveyIntervalMs], stretched where needed so that
  /// [surveyReads] reads at that interval take at most
  /// [_maxSurveyReadPercent] of the read time.
  static int _surveyIntervalMs(AppSettings settings, int surveyReads) {
    final readCostMs = max(
      _minReadCostMs,
      1000 ~/ max(settings.maxReadsPerSecond, 1),
    );
    final budgetedMs = (surveyReads * readCostMs * 100 / _maxSurveyReadPercent)
        .ceil();
    return max(settings.surveyIntervalMs, budgetedMs);
  }

  @visibleForTesting
  static ObdPlanMessage buildPlanForTesting({
    AppSettings? settings,
    DiscoveryState? discoveryState,
  }) => _buildPlan(
    settings ?? const AppSettings.defaultValues(),
    discoveryState ?? DiscoveryState(),
  );

  static ObdPlanMessage _buildPlan(
    AppSettings settings,
    DiscoveryState discoveryState,
  ) {
    final module7 = ObdModuleMessage(
      moduleId: 'module7',
      protocol: ObdProtocol.twentyNineBitCan.wireValue,
      setup: buildModuleSetupCommands(
        protocol: ObdProtocol.twentyNineBitCan,
        requestHeader: _module7RequestHeader,
        responseHeader: _module7ResponseHeader,
      ),
    );
    final module8 = ObdModuleMessage(
      moduleId: 'module8',
      protocol: ObdProtocol.twentyNineBitCan.wireValue,
      setup: buildModuleSetupCommands(
        protocol: ObdProtocol.twentyNineBitCan,
        requestHeader: _module8RequestHeader,
        responseHeader: _module8ResponseHeader,
      ),
    );
    final module6 = ObdModuleMessage(
      moduleId: 'module6',
      protocol: ObdProtocol.elevenBitCan.wireValue,
      setup: buildModuleSetupCommands(
        protocol: ObdProtocol.elevenBitCan,
        requestHeader: _module6RequestHeader,
        responseHeader: _module6ResponseHeader,
      ),
    );

    final bms = ObdModuleMessage(
      moduleId: _bmsModuleId,
      protocol: ObdProtocol.twentyNineBitCan.wireValue,
      setup: buildModuleSetupCommands(
        protocol: ObdProtocol.twentyNineBitCan,
        requestHeader: _bmsRequestHeader,
        responseHeader: _bmsResponseHeader,
      ),
      readDeadlineMs: settings.readTimeoutMs + _bmsReadDeadlineExtraMs,
    );

    final recordKnown =
        settings.recordingMode == RecordingMode.scoutAndRecordKnown;
    final fixedModules = [module7, module8, module6, bms];
    final fixedModuleIds = {for (final module in fixedModules) module.moduleId};
    final knownModules = [
      ...fixedModules,
      // Profile modules already planned above are not added twice.
      if (recordKnown)
        for (final module in _knownDidModules())
          if (!fixedModuleIds.contains(module.moduleId)) module,
    ];
    final discoveredAdditions = discoveredPlanAdditions(discoveryState);
    final discoveredModules = _discoveredModules(discoveredAdditions, {
      for (final module in knownModules) module.moduleId,
    });

    final adapterSequence = _adapterSequence(settings);

    final fixedSteps = [
      for (final MapEntry(key: signalId, value: spec)
          in _liveSignalSpecs.entries)
        ObdStepMessage(
          signalId: signalId,
          moduleId: spec.moduleId,
          command: spec.command,
          responseHeader: spec.responseHeader,
          intervalMs: spec.plannedIntervalMs(settings),
        ),
      ObdStepMessage(
        signalId: signalIdFor(_bmsModuleId, '2206C7'),
        moduleId: _bmsModuleId,
        command: '2206C7',
        responseHeader: _bmsResponseHeader,
        intervalMs: _bmsExtraDidIntervalMs,
      ),
      ObdStepMessage(
        signalId: signalIdFor(_bmsModuleId, '2206C8'),
        moduleId: _bmsModuleId,
        command: '2206C8',
        responseHeader: _bmsResponseHeader,
        intervalMs: _bmsExtraDidIntervalMs,
      ),
      if (recordKnown) ...[
        ObdStepMessage(
          signalId: 'module7_22f449',
          moduleId: 'module7',
          command: '22F449',
          responseHeader: _module7ResponseHeader,
          intervalMs: 5000,
        ),
        ObdStepMessage(
          signalId: 'module7_22f442',
          moduleId: 'module7',
          command: '22F442',
          responseHeader: _module7ResponseHeader,
          intervalMs: 60000,
        ),
      ],
    ];
    final fixedSignalIds = {for (final step in fixedSteps) step.signalId};
    final knownReads = [
      // A profile DID that is also a fixed step keeps the fixed interval.
      if (recordKnown)
        for (final read in _knownDidReads())
          if (!fixedSignalIds.contains(read.signalId)) read,
    ];
    final knownSignalIds = {
      ...fixedSignalIds,
      for (final read in knownReads) read.signalId,
    };
    final recurringReads = [
      ...knownReads,
      // A gateway scan hit on a fixed module6 DID maps onto that step's
      // own signal id.
      for (final read in _discoveredReads(discoveredAdditions, settings))
        if (!knownSignalIds.contains(read.signalId)) read,
    ];
    final surveyIntervalMs = _surveyIntervalMs(
      settings,
      recurringReads.where((read) => read.atSurveyInterval).length,
    );

    return ObdPlanMessage(
      planId: 'didscout-fixed-plan',
      planVersion: 1,
      formatVersion: 1,
      init: adapterSequence,
      resync: adapterSequence,
      modules: [...knownModules, ...discoveredModules],
      steps: [
        ...fixedSteps,
        for (final read in recurringReads) read.step(surveyIntervalMs),
      ],
      limits: ObdLimitsMessage(
        maxResponseBytes: 4096,
        adapterStepDeadlineMs: settings.readTimeoutMs,
        vehicleReadDeadlineMs: settings.readTimeoutMs,
        maxReadsPerSecond: settings.maxReadsPerSecond,
        maxConsecutiveTimeouts: 3,
        // A burst of read failures resyncs the adapter and keeps scouting
        // instead of ending a long session.
        onConsecutiveFailures:
            ObdConsecutiveFailuresPolicyMessage.resyncAndContinue,
        idleVehicleStopAfterMs: settings.idleVehicleStopAfterMs,
        quietModuleBackoffMs: quietModuleBackoffMs,
        reconnectBackoffMinMs: settings.reconnectBackoffMinMs,
        reconnectBackoffMaxMs: settings.reconnectBackoffMaxMs,
        maxReconnectAttemptsPerGap: settings.maxReconnectAttemptsPerGap,
        // 0 disables the cap entirely (see `ObdLimitsMessage.maxRecordingMs`)
        // — already well past the 72h floor a long session needs.
        maxRecordingMs: 0,
        maxBufferBytes: 200 * 1024 * 1024,
      ),
    );
  }

  /// The marker sidecar's first line (`{"type":"plan",…}`), built from
  /// [plan] exactly as sent to native rather than from this class's own
  /// header constants — so the sidecar always reflects what actually went
  /// out, even if a future plan version diverges from them.
  static Map<String, dynamic> _planSidecarLine(ObdPlanMessage plan) => {
    'type': 'plan',
    'planId': plan.planId,
    'planVersion': plan.planVersion,
    'at': DateTime.now().toUtc().toIso8601String(),
    'modules': [
      for (final module in plan.modules)
        {
          'id': module.moduleId,
          'request': _setupHeader(module.setup, 'ATSH'),
          'response': _setupHeader(module.setup, 'ATCRA'),
          'protocol': module.protocol.toString(),
        },
    ],
  };

  /// Reads the request/response header a module's compiled `setup` sequence
  /// carries, by its `ATSH`/`ATCRA` command — the single source of truth
  /// [buildModuleSetupCommands] itself compiled it from.
  static String _setupHeader(List<String> setup, String prefix) {
    for (final command in setup) {
      if (command.startsWith(prefix)) return command.substring(prefix.length);
    }
    throw StateError('module setup has no $prefix command');
  }

  static Future<Directory> _defaultRecordingsDirectory() async {
    final documents = await path_provider.getApplicationDocumentsDirectory();
    final recordings = Directory('${documents.path}/recordings');
    if (!await recordings.exists()) {
      await recordings.create(recursive: true);
    }
    return recordings;
  }
}
