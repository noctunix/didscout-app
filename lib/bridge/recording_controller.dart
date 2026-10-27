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
import 'didscout_policy.dart';

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
  bool _markersWritten = false;

  /// Set once a recording has been started; also the file shared when
  /// [canShare].
  String? get bufferFilePath => _bufferFilePath;

  /// The session's marker sidecar path, next to [bufferFilePath]. Null until
  /// a marker has actually been written for this session — a session with
  /// no markers has no sidecar file.
  String? get markersFilePath =>
      _markersWritten ? '${_bufferFilePath!}.markers.jsonl' : null;

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
      // No session yet — the marker stays in [markers] only and is flushed
      // to the sidecar once [start] creates one.
      return;
    }
    await _appendMarkerLine(markers.markers.last);
    _markersWritten = true;
    notifyListeners();
  }

  Future<void> _appendMarkerLine(SessionMarker marker) {
    return File(
      '${_bufferFilePath!}.markers.jsonl',
    ).writeAsString('${jsonEncode(marker.toJson())}\n', mode: FileMode.append);
  }

  /// Runs the whole connect-and-record flow. A no-op unless [canStart].
  Future<void> start() async {
    if (!canStart) return;
    _sessionId = null;
    _bufferFilePath = null;
    _markersWritten = false;
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
      final started = await _bridge.startRecording(
        ObdStartRecordingRequest(
          sessionId: sessionId,
          vehicleId: sessionId,
          bufferFilePath: bufferFilePath,
          startedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
          plan: _buildPlan(),
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
      // Flush markers recorded before the sidecar path existed.
      for (final marker in markers.markers) {
        await _appendMarkerLine(marker);
        _markersWritten = true;
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
  }

  Future<void> _tick() async {
    await _pollLiveState();
    if (_chargeReminder.checkDue()) {
      _chargeReminderVisible = true;
      notifyListeners();
    }
  }

  /// Queries [ObdBridge.liveState] for this plan's signals and decodes
  /// whatever answered into [_liveInfo]. Any failure (no live-state support,
  /// transport error, …) leaves [_liveInfo] at [LiveVehicleInfo.empty] — the
  /// tiles then simply show no live info, never a stale or fabricated one.
  Future<void> _pollLiveState() async {
    try {
      final state = await _bridge.liveState(_liveSignalSpecs.keys.toList());
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
    }
    notifyListeners();
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
      modules: [module7, module8, module6],
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
      ],
      limits: ObdLimitsMessage(
        maxResponseBytes: 4096,
        adapterStepDeadlineMs: 2000,
        vehicleReadDeadlineMs: 2000,
        maxReadsPerSecond: 5,
        maxConsecutiveTimeouts: 3,
        // Comfortably above the plan's slowest step (60s) so a quiet bus
        // doesn't look idle before it actually is.
        idleVehicleStopAfterMs: 300000,
        reconnectBackoffMinMs: 1000,
        reconnectBackoffMaxMs: 30000,
        maxReconnectAttemptsPerGap: 5,
        maxRecordingMs: 0,
        maxBufferBytes: 50 * 1024 * 1024,
      ),
    );
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
