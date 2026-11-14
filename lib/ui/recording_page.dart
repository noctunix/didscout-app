import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../bridge/connection_status.dart';
import '../bridge/recording_controller.dart';
import '../capture/readings.dart';
import '../discovery/discovery_ui_state.dart';
import '../discovery/scout_status.dart';
import '../power/power_monitor.dart';
import '../power/power_recording_coordinator.dart';
import '../session/reading_prompts.dart';
import '../session/session_markers.dart';
import 'experiment_card.dart';
import 'reading_entry_sheet.dart';
import 'reading_tiles.dart';
import 'recordings_page.dart';
import 'settings_page.dart';
import 'testplan_card.dart';

/// The default [RecordingPage.onShare]: hands [paths] to the platform share
/// sheet as files.
Future<void> _shareFiles(List<String> paths) async {
  await SharePlus.instance.share(
    ShareParams(files: [for (final path in paths) XFile(path)]),
  );
}

/// The default [RecordingPage.onReminderVibration]: a short haptic buzz.
Future<void> _vibrate() => HapticFeedback.vibrate();

/// How old the owner's last battery temp. reading may be to still feed the
/// SoC estimate while the vehicle's own value is missing: battery
/// temperature moves by over 15 K within an hour of driving plus fast
/// charging.
const Duration _batteryTempMaxAge = Duration(minutes: 20);

/// The main (and currently only) screen: adapter connection/recording
/// status, phase buttons, guided experiments, the reading tiles (each
/// showing the vehicle's live value or the last entry, with a bottom-sheet
/// entry per tile, and the readings due now highlighted), a free-text note
/// and event quick entry, the session's marker log, and start/stop/share
/// controls for the recording itself.
class RecordingPage extends StatefulWidget {
  RecordingPage({
    super.key,
    RecordingController? controller,
    this.onShare,
    this.onReminderVibration,
    this.powerMonitor,
  }) : controller = controller ?? RecordingController();

  final RecordingController controller;

  /// Shares [RecordingController.shareableFiles]; overridable so tests don't
  /// have to go through the real platform share sheet.
  final Future<void> Function(List<String> paths)? onShare;

  /// Fires the charging-round reminder's short vibration; overridable so
  /// tests don't have to go through the real haptics channel.
  final Future<void> Function()? onReminderVibration;

  /// Wires a [PowerRecordingCoordinator] for the "start/stop with power"
  /// settings while this page is alive; left null (the default, and what
  /// every test uses) skips that entirely, so plain widget tests never touch
  /// the real `battery_plus` platform channel. The production app's entry
  /// point passes a real [PowerMonitor] to opt in.
  final PowerMonitor? powerMonitor;

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  RecordingController get _controller => widget.controller;

  bool _lastReminderVisible = false;
  PowerRecordingCoordinator? _powerCoordinator;

  // Keeps the tiles' entry ages current; while recording, every live poll
  // rebuilds the page anyway.
  late final Timer _ageTicker;

  @override
  void initState() {
    super.initState();
    _ageTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_controller.phase != RecordingPhase.recording) setState(() {});
    });
    unawaited(_controller.adoptRunningRecording());
    final powerMonitor = widget.powerMonitor;
    if (powerMonitor != null) {
      _powerCoordinator = PowerRecordingCoordinator(
        controller: _controller,
        powerMonitor: powerMonitor,
      );
    }
  }

  @override
  void dispose() {
    _ageTicker.cancel();
    _powerCoordinator?.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final share = widget.onShare ?? _shareFiles;
    await share(_controller.shareableFiles);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => SettingsPage(recordingController: _controller),
      ),
    );
  }

  Future<void> _openRecordings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => RecordingsPage(
          recordingsDirectory: _controller.resolveRecordingsDirectory,
          currentBufferPath: _controller.currentRecordingPath,
          onShare: widget.onShare,
          exportProfileDraft: _controller.writeProfileDraft,
        ),
      ),
    );
  }

  /// The battery temperature the SoC estimate uses: the vehicle's own
  /// value, else the owner's last reading of it.
  num? get _recentBatteryTempC =>
      _controller.liveInfo.batteryTempC ??
      _controller.markers.lastValueFor(
        ReadingQuantity.batteryTemp,
        maxAge: _batteryTempMaxAge,
      );

  Map<ReadingQuantity, ReadingMarker> get _lastReadings => {
    for (final marker in _controller.markers.markers)
      if (marker is ReadingMarker) marker.quantity: marker,
  };

  /// The sheet's line explaining what its field was prefilled with.
  String _prefillContext({
    required ReadingQuantity quantity,
    required num? liveValue,
    required num? batteryTempC,
    required ReadingMarker? lastEntry,
    required DateTime now,
  }) {
    final storedEnergyWh = _controller.liveInfo.storedEnergyWh;
    if (liveValue != null &&
        quantity == ReadingQuantity.soc &&
        storedEnergyWh != null) {
      final accuracy = batteryTempC == null
          ? 'no battery temp., up to ±5 pp'
          : 'battery ${formatReadingValue(batteryTempC.round())} °C, '
                '±1.5 pp';
      return 'Vehicle estimate ≈ ${formatReadingValue(liveValue)} % '
          '(${_groupThousands(storedEnergyWh)} Wh, $accuracy)';
    }
    if (liveValue != null) {
      return 'Vehicle reads ${formatReadingValue(liveValue)} ${quantity.unit}';
    }
    if (lastEntry != null) {
      return 'Your last entry, ${describeAge(now.difference(lastEntry.readAt))}';
    }
    return "Read the value off the car's display";
  }

  Future<void> _openTileSheet(ReadingQuantity quantity) async {
    final readAt = DateTime.now();
    final batteryTempC = _recentBatteryTempC;
    final liveValue = _liveValueFor(
      quantity,
      _controller.liveInfo,
      batteryTempC,
    );
    final lastEntry = _lastReadings[quantity];
    final (num? prefill, PrefillOrigin? prefillOrigin) = liveValue != null
        ? (liveValue, PrefillOrigin.live)
        : lastEntry != null
        ? (lastEntry.value, PrefillOrigin.entry)
        : (null, null);
    final result = await showReadingEntrySheet(
      context,
      quantity: quantity,
      prefill: prefill,
      contextLine: _prefillContext(
        quantity: quantity,
        liveValue: liveValue,
        batteryTempC: batteryTempC,
        lastEntry: lastEntry,
        now: readAt,
      ),
    );
    if (result == null) return;
    final (value, source) = result;
    _controller.addReading(
      quantity: quantity,
      value: value,
      readAt: readAt,
      source: source,
      prefill: prefill,
      prefillOrigin: prefillOrigin,
      liveValue: liveValue,
    );
  }

  /// The display values to read off now; none while not recording.
  List<ReadingPrompt> _readingPrompts(
    Map<ReadingQuantity, ReadingMarker> lastReadings,
    DateTime now,
  ) {
    if (_controller.phase != RecordingPhase.recording) return const [];
    return readingPrompts(
      phase: _controller.markers.currentPhase,
      stationary: _controller.isStationary,
      now: now,
      lastReadAt: lastReadings.map(
        (quantity, marker) => MapEntry(quantity, marker.readAt),
      ),
      reportedByVehicle: {
        if (_controller.liveInfo.batteryTempC != null)
          ReadingQuantity.batteryTemp,
        if (_controller.liveInfo.chargePowerKw != null)
          ReadingQuantity.chargePower,
      },
    );
  }

  Future<void> _addNote() async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _NoteEntrySheet(),
    );
    if (text == null || text.trim().isEmpty) return;
    _controller.addNote(text.trim());
  }

  Future<void> _addEvent() async {
    final label = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _EventEntrySheet(),
    );
    if (label == null || label.trim().isEmpty) return;
    _controller.addEvent(label.trim());
  }

  Future<void> _openScoutEventLog() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _ScoutEventLogSheet(events: _controller.scoutEventLog),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('didscout'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Recordings',
            onPressed: _openRecordings,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([_controller, _controller.markers]),
        builder: (context, _) {
          final reminderVisible = _controller.chargeReminderVisible;
          if (reminderVisible && !_lastReminderVisible) {
            final vibrate = widget.onReminderVibration ?? _vibrate;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              unawaited(vibrate());
            });
          }
          _lastReminderVisible = reminderVisible;
          final now = DateTime.now();
          final lastReadings = _lastReadings;
          final batteryTempC = _recentBatteryTempC;
          final prompts = _readingPrompts(lastReadings, now);
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusCard(controller: _controller, onShare: _share),
                if (_controller.nativeStopBanner != null) ...[
                  const SizedBox(height: 16),
                  _NativeStopBanner(
                    message: _controller.nativeStopBanner!,
                    onStartNew: _controller.start,
                  ),
                ],
                if (_controller.discoveryUiState != null) ...[
                  const SizedBox(height: 16),
                  _ScoutingCard(state: _controller.discoveryUiState!),
                ],
                if (_controller.scoutStatus != null)
                  _ScoutStatusLine(
                    status: _controller.scoutStatus!,
                    onTap: _openScoutEventLog,
                  ),
                if (_controller.testplanCheck != null) ...[
                  const SizedBox(height: 16),
                  TestplanCard(check: _controller.testplanCheck!),
                ],
                const SizedBox(height: 16),
                _PhaseButtonGrid(controller: _controller),
                const SizedBox(height: 24),
                _ReadingsHeader(
                  recording: _controller.phase == RecordingPhase.recording,
                  prompts: prompts,
                  chargeReminder: reminderVisible,
                  onDismissReminder: _controller.dismissChargeReminder,
                ),
                const SizedBox(height: 8),
                ReadingTiles(
                  liveValues: {
                    for (final quantity in ReadingQuantity.values)
                      quantity: ?_liveValueFor(
                        quantity,
                        _controller.liveInfo,
                        batteryTempC,
                      ),
                  },
                  lastEntries: lastReadings,
                  phase: _controller.markers.currentPhase,
                  due: {for (final prompt in prompts) prompt.quantity},
                  now: now,
                  onTap: _openTileSheet,
                ),
                if (ExperimentCard.visibleFor(_controller)) ...[
                  const SizedBox(height: 16),
                  ExperimentCard(
                    controller: _controller,
                    onEnterReading: _openTileSheet,
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _addNote,
                        icon: const Icon(Icons.sticky_note_2_outlined),
                        label: const Text('Note'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _addEvent,
                        icon: const Icon(Icons.bolt_outlined),
                        label: const Text('Event'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Markers', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _MarkerList(markers: _controller.markers.markers),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// [value] with its thousands separated by narrow no-break spaces, e.g.
/// `52 375`.
String _groupThousands(int value) =>
    '$value'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => '\u202F');

num? _liveValueFor(
  ReadingQuantity quantity,
  LiveVehicleInfo info,
  num? batteryTempC,
) => switch (quantity) {
  ReadingQuantity.outsideTemp => info.outsideTempC,
  ReadingQuantity.range => info.rangeKm,
  ReadingQuantity.odometer => info.odometerKm,
  ReadingQuantity.soc => info.socEstimatePercent(batteryTempC: batteryTempC),
  // Rounded to whole units, as the vehicle's displays show them.
  ReadingQuantity.batteryTemp => info.batteryTempC?.round(),
  ReadingQuantity.chargePower => info.chargePowerKw?.round(),
  ReadingQuantity.insideTemp ||
  ReadingQuantity.chargePowerMax ||
  ReadingQuantity.tyrePressureFl ||
  ReadingQuantity.tyrePressureFr ||
  ReadingQuantity.tyrePressureRl ||
  ReadingQuantity.tyrePressureRr ||
  ReadingQuantity.tyreTempFl ||
  ReadingQuantity.tyreTempFr ||
  ReadingQuantity.tyreTempRl ||
  ReadingQuantity.tyreTempRr => null,
};

/// Human-readable status line and icon for [RecordingPhase].
String _statusText(RecordingController controller) {
  final detail = controller.statusDetail;
  switch (controller.phase) {
    case RecordingPhase.idle:
      return 'Not connected — tap Start recording to connect';
    case RecordingPhase.requestingPermissions:
      return 'Requesting Bluetooth permissions…';
    case RecordingPhase.permissionDenied:
      return 'Bluetooth permission denied${detail != null ? ' ($detail)' : ''}';
    case RecordingPhase.scanning:
      return 'Scanning for an adapter…';
    case RecordingPhase.noAdapterFound:
      return 'No adapter found';
    case RecordingPhase.connecting:
      return 'Connecting${detail != null ? ' to $detail' : ''}…';
    case RecordingPhase.startingRecording:
      return 'Starting recording…';
    case RecordingPhase.recording:
      return 'Recording${detail != null ? ' via $detail' : ''}';
    case RecordingPhase.stopping:
      return 'Stopping…';
    case RecordingPhase.finished:
      return 'Recording finished — ready to share';
    case RecordingPhase.error:
      return 'Error${detail != null ? ': $detail' : ''}';
  }
}

bool _isBusy(RecordingPhase phase) => switch (phase) {
  RecordingPhase.requestingPermissions ||
  RecordingPhase.scanning ||
  RecordingPhase.connecting ||
  RecordingPhase.startingRecording ||
  RecordingPhase.stopping => true,
  _ => false,
};

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller, required this.onShare});

  final RecordingController controller;
  final Future<void> Function() onShare;

  /// Stops the recording once the owner confirms: Stop sits where Start
  /// was, right above the phase buttons, and a stopped recording cannot
  /// be resumed.
  Future<void> _confirmStop(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop recording?'),
        content: const Text(
          'A stopped recording cannot be continued; '
          'Start recording begins a new one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop recording'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await controller.stop();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isBusy(controller.phase);
    final recording = controller.phase == RecordingPhase.recording;
    final connectionStatus = controller.connectionStatus;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  recording ? Icons.bluetooth_connected : Icons.bluetooth,
                  color:
                      controller.phase == RecordingPhase.error ||
                          controller.phase == RecordingPhase.noAdapterFound ||
                          controller.phase == RecordingPhase.permissionDenied
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_statusText(controller)),
                  ),
                ),
              ],
            ),
            if (recording && connectionStatus != null) ...[
              const SizedBox(height: 8),
              Text(
                describeConnectionStatus(connectionStatus),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color:
                      connectionStatus.state ==
                          RecordingConnectionState.connected
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            if (recording && controller.liveInfo.speedKmh != null) ...[
              const SizedBox(height: 8),
              Text(
                'Speed: ${controller.liveInfo.speedKmh} km/h',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: recording
                  ? OutlinedButton(
                      onPressed: () => _confirmStop(context),
                      child: const Text('Stop'),
                    )
                  : FilledButton(
                      onPressed: busy ? null : controller.start,
                      child: const Text('Start recording'),
                    ),
            ),
            if (!recording) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: controller.canShare ? onShare : null,
                  child: const Text('Share recording'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PhaseButtonGrid extends StatelessWidget {
  const _PhaseButtonGrid({required this.controller});

  final RecordingController controller;

  static const _phases = [
    (MarkerPhase.charge, 'Charge', Icons.ev_station),
    (MarkerPhase.park, 'Park', Icons.local_parking),
  ];

  @override
  Widget build(BuildContext context) {
    final current = controller.markers.currentPhase;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 2,
      children: [
        for (final (phase, label, icon) in _phases)
          _PhaseButton(
            label: label,
            icon: icon,
            selected: current == phase,
            onPressed: () => controller.addPhase(phase),
          ),
      ],
    );
  }
}

class _PhaseButton extends StatelessWidget {
  const _PhaseButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: SizedBox(
          height: 64,
          child: FilledButton.tonal(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: selected ? colorScheme.primary : null,
              foregroundColor: selected ? colorScheme.onPrimary : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [Icon(icon), const SizedBox(height: 4), Text(label)],
            ),
          ),
        ),
      ),
    );
  }
}

class _NativeStopBanner extends StatelessWidget {
  const _NativeStopBanner({required this.message, required this.onStartNew});

  final String message;
  final Future<void> Function() onStartNew;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_outlined,
              color: colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => unawaited(onStartNew()),
              child: const Text('Start new recording'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Human-readable label for [DiscoveryUiState.activity].
String _discoveryActivityText(DiscoveryUiState state) =>
    switch (state.activity) {
      DiscoveryActivity.inventory => 'Looking for ECUs',
      DiscoveryActivity.scanning => 'Scanning ${state.scanningEcuName}',
      DiscoveryActivity.waitingMoving => 'Waiting: vehicle moving',
      DiscoveryActivity.waitingAsleep => 'Waiting: ECU asleep',
      DiscoveryActivity.idle => 'Idle',
    };

class _ScoutingCard extends StatelessWidget {
  const _ScoutingCard({required this.state});

  final DiscoveryUiState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.radar),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Scouting',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${state.ecuCount} known ECUs — '
                        '${state.progressPercent.toStringAsFixed(0)}% scanned '
                        '(${state.totalChecked} DIDs checked)',
                      ),
                      Text(
                        '${state.totalHits} DIDs found total, '
                        '${state.sessionHits} this session',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _ReadsPerMinuteKpi(value: state.readsPerMinute),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _discoveryActivityText(state),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// The Scouting card's prominent reads/min KPI: a large number over the
/// "reads/min" label, next to the progress/hits summary.
class _ReadsPerMinuteKpi extends StatelessWidget {
  const _ReadsPerMinuteKpi({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value', style: Theme.of(context).textTheme.headlineMedium),
        Text('reads/min', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Compact one-line summary of [ScoutStatus], shown under the Scouting
/// card for the whole recording -- e.g. `HCP1 · 1A40–1A4F · 284/min · NRC
/// 31 · q 24`, or, once the oldest in-flight ECU slice has been pending
/// more than 10 seconds, `waiting 16 for 12 s` in the error color (16
/// outstanding results summed across every slice currently in flight, not
/// just that one). Tapping opens the full event log.
class _ScoutStatusLine extends StatelessWidget {
  const _ScoutStatusLine({required this.status, required this.onTap});

  final ScoutStatus status;
  final VoidCallback onTap;

  static const Duration _pendingWarningThreshold = Duration(seconds: 10);

  @override
  Widget build(BuildContext context) {
    final waitingFor = status.waitingFor;
    final pendingLong =
        waitingFor != null && waitingFor > _pendingWarningThreshold;
    final text = pendingLong
        ? 'waiting ${status.waitingCount} for ${waitingFor.inSeconds} s'
        : _summaryText(status);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: pendingLong ? Theme.of(context).colorScheme.error : null,
    );
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(text, style: style),
          ),
        ),
      ),
    );
  }

  static String _summaryText(ScoutStatus status) {
    final parts = <String>[
      status.currentEcuName ?? status.currentEcuId ?? '—',
      if (status.currentDidRangeLabel != null) status.currentDidRangeLabel!,
      '${status.readsPerMinute}/min',
      if (status.lastResultSummary != null) status.lastResultSummary!,
      'q ${status.queueDepth}',
    ];
    return parts.join(' · ');
  }
}

/// Bottom sheet listing [DiscoveryEngine.eventLog], newest first, in local
/// time -- opened by tapping [_ScoutStatusLine].
class _ScoutEventLogSheet extends StatelessWidget {
  const _ScoutEventLogSheet({required this.events});

  final List<ScoutEvent> events;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Scouting events',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: events.isEmpty
                  ? const Center(child: Text('No events yet'))
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: events.length,
                      itemBuilder: (context, index) =>
                          _ScoutEventRow(event: events[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoutEventRow extends StatelessWidget {
  const _ScoutEventRow({required this.event});

  final ScoutEvent event;

  @override
  Widget build(BuildContext context) {
    final local = event.at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
    return ListTile(
      dense: true,
      title: Text(
        _label(event),
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      trailing: Text(time, style: Theme.of(context).textTheme.bodySmall),
    );
  }

  static String _label(ScoutEvent event) {
    final kind = switch (event.kind) {
      ScoutEventKind.batchSubmitted => 'batch submitted',
      ScoutEventKind.hit => 'hit',
      ScoutEventKind.conditional => 'conditional',
      ScoutEventKind.asleep => 'asleep',
      ScoutEventKind.batchTimedOut => 'batch timed out',
      ScoutEventKind.slowDid => 'slow DID quarantined',
      ScoutEventKind.oversizedDid => 'oversized DID quarantined',
      ScoutEventKind.enqueueRejected => 'enqueue rejected',
      ScoutEventKind.inventoryStep => 'inventory step',
      ScoutEventKind.multiDid => 'multi-DID reads',
    };
    final parts = [
      kind,
      if (event.ecuId != null) event.ecuId!,
      if (event.detail != null) event.detail!,
    ];
    return parts.join(' ');
  }
}

/// The readings section's title and, while recording, one line naming
/// the display values to read off now, or the charging-round reminder in
/// its place. The line keeps one height so the tiles below never move.
class _ReadingsHeader extends StatelessWidget {
  const _ReadingsHeader({
    required this.recording,
    required this.prompts,
    required this.chargeReminder,
    required this.onDismissReminder,
  });

  final bool recording;
  final List<ReadingPrompt> prompts;

  /// Whether the charging-round reminder is due.
  final bool chargeReminder;

  final VoidCallback onDismissReminder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (icon, iconColor, text, textColor) = switch ((
      chargeReminder,
      prompts,
    )) {
      (true, _) => (
        Icons.notifications_active_outlined,
        colors.primary,
        'Charging round: check SoC and battery temp.',
        null,
      ),
      (false, []) => (
        Icons.visibility_outlined,
        colors.onSurfaceVariant,
        'Nothing due right now',
        colors.onSurfaceVariant,
      ),
      (false, _) => (
        Icons.visibility_outlined,
        colors.primary,
        'Read now: '
            '${prompts.map((prompt) => prompt.quantity.label).join(', ')}',
        null,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Readings', style: textTheme.titleMedium),
        if (recording)
          Semantics(
            liveRegion: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: textTheme.bodyMedium?.copyWith(color: textColor),
                    ),
                  ),
                  if (chargeReminder)
                    IconButton(
                      onPressed: onDismissReminder,
                      icon: const Icon(Icons.close),
                      tooltip: 'Dismiss',
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NoteEntrySheet extends StatefulWidget {
  const _NoteEntrySheet();

  @override
  State<_NoteEntrySheet> createState() => _NoteEntrySheetState();
}

class _NoteEntrySheetState extends State<_NoteEntrySheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Note', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Note',
              helperText: 'Only while stationary or as a passenger',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (text) => Navigator.of(context).pop(text),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_controller.text),
              child: const Text('Add note'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventEntrySheet extends StatefulWidget {
  const _EventEntrySheet();

  @override
  State<_EventEntrySheet> createState() => _EventEntrySheetState();
}

class _EventEntrySheetState extends State<_EventEntrySheet> {
  static const _suggestions = [
    'climate on',
    'climate off',
    'window open',
    'doors unlocked',
  ];

  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Event', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in _suggestions)
                ActionChip(
                  label: Text(suggestion),
                  onPressed: () => Navigator.of(context).pop(suggestion),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'Label',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (text) => Navigator.of(context).pop(text),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_controller.text),
              child: const Text('Add event'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkerList extends StatelessWidget {
  const _MarkerList({required this.markers});

  final List<SessionMarker> markers;

  static String _formatTime(DateTime utc) {
    final local = utc.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  static String _phaseLabel(MarkerPhase phase) {
    switch (phase) {
      case MarkerPhase.drive:
        return 'Drive';
      case MarkerPhase.charge:
        return 'Charge';
      case MarkerPhase.stand:
        return 'Stand';
      case MarkerPhase.park:
        return 'Park';
    }
  }

  static (IconData, String) _tileFor(SessionMarker marker) => switch (marker) {
    PhaseMarker(phase: final phase) => (Icons.flag, _phaseLabel(phase)),
    NoteMarker(text: final text) => (Icons.sticky_note_2, text),
    EventMarker(label: final label) => (Icons.bolt, label),
    ExperimentMarker(id: final id, step: final step) => (
      Icons.science,
      'Experiment $id: ${step.name}',
    ),
    ReadingMarker(
      quantity: final quantity,
      value: final value,
      unit: final unit,
    ) =>
      (Icons.straighten, '${quantity.label}: $value $unit'),
  };

  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No markers yet.'),
      );
    }
    final newestFirst = markers.reversed.toList();
    return Column(
      children: [
        for (final marker in newestFirst)
          Builder(
            builder: (context) {
              final (icon, title) = _tileFor(marker);
              return ListTile(
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(_formatTime(marker.timestamp)),
              );
            },
          ),
      ],
    );
  }
}
