import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:obdbridge/obdbridge.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:uuid/uuid.dart';

import '../capture/isotp.dart';
import '../capture/readings.dart';
import '../session/charge_reminder.dart';
import '../session/session_markers.dart';
import 'connection_status.dart';
import 'didscout_policy.dart';
import 'vag_ppe_plan_data.dart';

/// The 29-bit module this app's fixed plan reads: ECU address `04`.
const String _module7RequestHeader = '18DA04F1';
const String _module7ResponseHeader = '18DAF104';

/// The 29-bit module carrying the odometer DID: ECU address `06`.
const String _module8RequestHeader = '18DA06F1';
const String _module8ResponseHeader = '18DAF106';

/// The 11-bit module this app's fixed plan reads.
const String _module6RequestHeader = '710';
const String _module6ResponseHeader = '77A';

/// A step's command and expected response header, keyed by its own
/// [ObdStepMessage.signalId] — used to decode [ObdBridge.liveState]'s cached
/// attempts back into a [LiveVehicleInfo] during a recording.
class _LiveSignalSpec {
  const _LiveSignalSpec(this.command, this.responseHeader);
  final String command;
  final String responseHeader;
}

const Map<String, _LiveSignalSpec> _liveSignalSpecs = {
  'module7_22f40d': _LiveSignalSpec('22F40D', _module7ResponseHeader),
  'module7_22f446': _LiveSignalSpec('22F446', _module7ResponseHeader),
  'module8_22f4a6': _LiveSignalSpec('22F4A6', _module8ResponseHeader),
  'module6_222ab6': _LiveSignalSpec('222AB6', _module6ResponseHeader),
  'module6_222ab8': _LiveSignalSpec('222AB8', _module6ResponseHeader),
};

const List<String> _adapterInitCommands = [
  'ATZ',
  'ATE0',
  'ATL0',
  'ATS0',
  'ATH1',
];

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
    Future<void> Function(List<ph.Permission>)? requestRuntimePermissions,
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
       markers = SessionMarkerLog(clock: clock),
       _chargeReminder = ChargeReminderScheduler(clock: clock);

  final ObdBridge _bridge;
  final Future<void> Function(List<ph.Permission>) _requestRuntimePermissions;
  final Future<Directory> Function() _recordingsDirectory;
  final String Function() _sessionIdFactory;
  final int _scanDurationMs;
  final Duration _tickInterval;

  final SessionMarkerLog markers;
  final ChargeReminderScheduler _chargeReminder;
  Timer? _tickTimer;

  LiveVehicleInfo _liveInfo = LiveVehicleInfo.empty;

  /// The vehicle's own live values, polled from [ObdBridge.liveState] while
  /// recording. Stays [LiveVehicleInfo.empty] whenever no live source is
  /// available (not recording, or the query failed) — tiles then simply
  /// show no live info.
  LiveVehicleInfo get liveInfo => _liveInfo;

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
  /// leaving [MarkerPhase.charge] arms/disarms the charging-round reminder.
  void addPhase(MarkerPhase phase) {
    markers.addPhase(phase);
    _chargeReminder.phaseChanged(phase);
    if (phase != MarkerPhase.charge) {
      _chargeReminderVisible = false;
    }
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
    num? liveValue,
  }) {
    markers.addReading(
      quantity: quantity,
      value: value,
      unit: quantity.unit,
      readAt: readAt,
      source: source,
      prefill: prefill,
      liveValue: liveValue,
      speedKmh: _liveInfo.speedKmh,
    );
    unawaited(_appendLatestMarker());
  }

  Future<void> _appendLatestMarker() async {
    if (_bufferFilePath == null) {
      // No session has ever started — the marker stays in [markers] only
      // and is flushed to the sidecar once [start] creates one.
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
    return File(
      '${_bufferFilePath!}.markers.jsonl',
    ).writeAsString('${jsonEncode(json)}\n', mode: FileMode.append);
  }

  /// Runs the whole connect-and-record flow. A no-op unless [canStart].
  Future<void> start() async {
    if (!canStart) return;
    _sessionId = null;
    _bufferFilePath = null;
    _nativeStopAt = null;
    _nativeStopReason = null;
    _connectionStatus = null;
    _reconnectingSince = null;
    _reconnectPollAttempts = 0;
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

      _setPhase(RecordingPhase.scanning);
      final adapters = await _bridge.scanAdapters(_scanDurationMs);
      final adapter = _strongestAdapter(adapters);
      if (adapter == null) {
        _setPhase(RecordingPhase.noAdapterFound);
        return;
      }

      _setPhase(
        RecordingPhase.connecting,
        adapter.advertisedName ?? adapter.handle,
      );
      final link = await _bridge.connect(adapter.handle);
      if (link.state != ObdLinkStateValueMessage.connected) {
        _setPhase(RecordingPhase.error, 'connect failed: ${link.state.name}');
        return;
      }

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

      _setPhase(RecordingPhase.startingRecording);
      final plan = _buildPlan();
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
      // Flush markers recorded before the sidecar path existed.
      for (final marker in markers.markers) {
        await _appendMarkerLine(marker);
      }
      _setPhase(
        RecordingPhase.recording,
        adapter.advertisedName ?? adapter.handle,
      );
      _startTicking();
    } catch (error) {
      _setPhase(RecordingPhase.error, error.toString());
    }
  }

  /// Stops the active recording, making it shareable. A no-op unless
  /// [canStop].
  Future<void> stop() async {
    if (!canStop) return;
    final sessionId = _sessionId;
    if (sessionId == null) {
      _setPhase(RecordingPhase.error, 'no active session');
      return;
    }
    _stopTicking();
    _setPhase(RecordingPhase.stopping);
    try {
      await _bridge.stopRecording(sessionId);
      _setPhase(RecordingPhase.finished);
    } catch (error) {
      _setPhase(RecordingPhase.error, error.toString());
    }
  }

  @override
  void dispose() {
    _stopTicking();
    super.dispose();
  }

  void _startTicking() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(_tickInterval, (_) => unawaited(_tick()));
  }

  void _stopTicking() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _liveInfo = LiveVehicleInfo.empty;
    _linkState = null;
    _connectionStatus = null;
    _reconnectingSince = null;
    _reconnectPollAttempts = 0;
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
  /// whatever answered into [_liveInfo]. Any failure (no live-state support,
  /// transport error, …) leaves [_liveInfo] at [LiveVehicleInfo.empty] — the
  /// tiles then simply show no live info, never a stale or fabricated one.
  /// Also records the link state exchanges carry, for [_pollConnectionStatus].
  Future<void> _pollLiveState() async {
    try {
      final state = await _bridge.liveState(_liveSignalSpecs.keys.toList());
      _linkState = state.link.state;
      int? speedKmh;
      double? odometerKm;
      int? outsideTempC;
      int? rangeKm;
      int? storedEnergyWh;
      for (final exchange in state.exchanges) {
        if (exchange.transport != ObdTransportStatusMessage.ok ||
            exchange.rawResponseText == null) {
          continue;
        }
        final spec = _liveSignalSpecs[exchange.signalId];
        if (spec == null) continue;
        final payload = decodePositivePayload(
          spec.command,
          exchange.rawResponseText!,
          spec.responseHeader,
        );
        if (payload == null) continue;
        switch (exchange.signalId) {
          case 'module7_22f40d':
            speedKmh = decodeSpeedKmh(payload);
          case 'module7_22f446':
            outsideTempC = decodeOutsideTempC(payload);
          case 'module8_22f4a6':
            odometerKm = decodeOdometerKm(payload);
          case 'module6_222ab6':
            rangeKm = decodeRangeKm(payload);
          case 'module6_222ab8':
            storedEnergyWh = decodeStoredEnergyWh(payload);
        }
      }
      _liveInfo = LiveVehicleInfo(
        speedKmh: speedKmh,
        odometerKm: odometerKm,
        outsideTempC: outsideTempC,
        rangeKm: rangeKm,
        storedEnergyWh: storedEnergyWh,
      );
    } catch (_) {
      _liveInfo = LiveVehicleInfo.empty;
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

  /// Modules for every vehicle module known from the vag-ppe profile that the
  /// base plan does not already address.
  static List<ObdModuleMessage> _knownDidModules() => [
    for (final spec in vagPpeModules)
      if (_planModuleId(spec) != 'module6')
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

  /// One read step per DID known to answer on this vehicle platform.
  static List<ObdStepMessage> _knownDidSteps() => [
    for (final spec in vagPpeModules)
      for (final did in spec.dids)
        ObdStepMessage(
          signalId: '${_planModuleId(spec)}_22${did.did.toLowerCase()}',
          moduleId: _planModuleId(spec),
          command: '22${did.did}',
          responseHeader: spec.response,
          intervalMs: did.intervalMs,
        ),
  ];

  @visibleForTesting
  static ObdPlanMessage buildPlanForTesting() => _buildPlan();

  static ObdPlanMessage _buildPlan() {
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

    return ObdPlanMessage(
      planId: 'didscout-fixed-plan',
      planVersion: 1,
      formatVersion: 1,
      init: _adapterInitCommands,
      resync: _adapterInitCommands,
      modules: [module7, module8, module6, ..._knownDidModules()],
      steps: [
        ObdStepMessage(
          signalId: 'module7_22f40d',
          moduleId: 'module7',
          command: '22F40D',
          responseHeader: _module7ResponseHeader,
          intervalMs: 5000,
        ),
        ObdStepMessage(
          signalId: 'module6_222ab8',
          moduleId: 'module6',
          command: '222AB8',
          responseHeader: _module6ResponseHeader,
          intervalMs: 15000,
        ),
        ObdStepMessage(
          signalId: 'module6_222ab6',
          moduleId: 'module6',
          command: '222AB6',
          responseHeader: _module6ResponseHeader,
          intervalMs: 60000,
        ),
        ObdStepMessage(
          signalId: 'module7_22f446',
          moduleId: 'module7',
          command: '22F446',
          responseHeader: _module7ResponseHeader,
          intervalMs: 60000,
        ),
        ObdStepMessage(
          signalId: 'module8_22f4a6',
          moduleId: 'module8',
          command: '22F4A6',
          responseHeader: _module8ResponseHeader,
          intervalMs: 60000,
        ),
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
        ..._knownDidSteps(),
      ],
      limits: ObdLimitsMessage(
        maxResponseBytes: 4096,
        adapterStepDeadlineMs: 2000,
        vehicleReadDeadlineMs: 2000,
        maxReadsPerSecond: 5,
        maxConsecutiveTimeouts: 3,
        // 30 min: long charging stops with the bus asleep shouldn't look
        // idle before they actually are.
        idleVehicleStopAfterMs: 1800000,
        reconnectBackoffMinMs: 2000,
        reconnectBackoffMaxMs: 60000,
        // The plugin only counts up per gap, never down — this is
        // effectively unlimited so a long session survives any number of
        // adapter dropouts instead of ending on the plugin's old budget of 5.
        maxReconnectAttemptsPerGap: 100000,
        // 0 disables the cap entirely (see `ObdLimitsMessage.maxRecordingMs`)
        // — already well past the 72h floor a long session needs.
        maxRecordingMs: 0,
        maxBufferBytes: 50 * 1024 * 1024,
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
