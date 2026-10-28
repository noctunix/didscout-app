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
import '../session/session_markers.dart';
import 'recordings_page.dart';
import 'settings_page.dart';

/// The default [RecordingPage.onShare]: hands [paths] to the platform share
/// sheet as files.
Future<void> _shareFiles(List<String> paths) async {
  await Share.shareXFiles([for (final path in paths) XFile(path)]);
}

/// The default [RecordingPage.onReminderVibration]: a short haptic buzz.
Future<void> _vibrate() => HapticFeedback.vibrate();

/// Every reading tile shown on the page, in display order.
const List<ReadingQuantity> _tileQuantities = [
  ReadingQuantity.soc,
  ReadingQuantity.batteryTemp,
  ReadingQuantity.outsideTemp,
  ReadingQuantity.range,
  ReadingQuantity.chargePower,
  ReadingQuantity.odometer,
];

/// The main (and currently only) screen: adapter connection/recording
/// status, phase buttons, the reading tile grid (with a bottom-sheet entry
/// per tile), live vehicle info with one-tap confirmation, a free-text note
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

  @override
  void initState() {
    super.initState();
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
    _powerCoordinator?.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final share = widget.onShare ?? _shareFiles;
    await share(_controller.shareableFiles);
  }

  Future<void> _shareProfileDraft() async {
    final path = await _controller.writeProfileDraft();
    if (path == null) return;
    final share = widget.onShare ?? _shareFiles;
    await share([path]);
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (context) => SettingsPage()));
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

  Future<void> _openTileSheet(ReadingQuantity quantity) async {
    final readAt = DateTime.now();
    final prefill = _controller.markers.lastValueFor(quantity);
    final liveValue = _liveValueFor(quantity, _controller.liveInfo);
    final result = await showModalBottomSheet<_TileEntryResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _TileEntrySheet(quantity: quantity, prefill: prefill),
    );
    if (result == null) return;
    _controller.addReading(
      quantity: quantity,
      value: result.value,
      readAt: readAt,
      source: result.source,
      prefill: prefill,
      liveValue: liveValue,
    );
  }

  Future<void> _confirmLive(ReadingQuantity quantity, num liveValue) async {
    _controller.addReading(
      quantity: quantity,
      value: liveValue,
      readAt: DateTime.now(),
      source: ReadingSource.confirmed,
      liveValue: liveValue,
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
                const SizedBox(height: 16),
                _PhaseButtonGrid(controller: _controller),
                if (reminderVisible) ...[
                  const SizedBox(height: 16),
                  _ChargeReminderBanner(
                    onDismiss: _controller.dismissChargeReminder,
                  ),
                ],
                const SizedBox(height: 16),
                _LiveInfoCard(
                  liveInfo: _controller.liveInfo,
                  onConfirm: _confirmLive,
                ),
                const SizedBox(height: 16),
                _ReadingTileGrid(onTap: _openTileSheet),
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
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _shareProfileDraft,
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Share profile draft'),
                  ),
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

num? _liveValueFor(ReadingQuantity quantity, LiveVehicleInfo info) =>
    switch (quantity) {
      ReadingQuantity.outsideTemp => info.outsideTempC,
      ReadingQuantity.range => info.rangeKm,
      ReadingQuantity.odometer => info.odometerKm,
      ReadingQuantity.soc ||
      ReadingQuantity.batteryTemp ||
      ReadingQuantity.chargePower => null,
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
                  child: Text(
                    _statusText(controller),
                    semanticsLabel: _statusText(controller),
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
              child: ElevatedButton(
                onPressed: busy
                    ? null
                    : (recording ? controller.stop : controller.start),
                child: Text(recording ? 'Stop' : 'Start recording'),
              ),
            ),
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
        ),
      ),
    );
  }
}

class _PhaseButtonGrid extends StatelessWidget {
  const _PhaseButtonGrid({required this.controller});

  final RecordingController controller;

  static const _phases = [
    (MarkerPhase.drive, 'Drive', Icons.directions_car),
    (MarkerPhase.charge, 'Charge', Icons.ev_station),
    (MarkerPhase.stand, 'Stand', Icons.pause_circle),
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
    return Semantics(
      label: selected ? '$label, current phase' : label,
      button: true,
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

class _ChargeReminderBanner extends StatelessWidget {
  const _ChargeReminderBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.notifications_active_outlined),
            const SizedBox(width: 12),
            const Expanded(child: Text('How\'s SoC and battery temp. doing?')),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
              tooltip: 'Dismiss',
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
            Text(
              '${state.ecuCount} known ECUs — '
              '${state.progressPercent.toStringAsFixed(0)}% scanned',
            ),
            Text(
              '${state.totalHits} DIDs found total, '
              '${state.sessionHits} this session',
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

/// Compact one-line summary of [ScoutStatus], shown under the Scouting
/// card for the whole recording -- e.g. `HCP1 · 1A40–1A4F · 284/min · NRC
/// 31 · q 24`, or, once a batch has been pending more than 10 seconds,
/// `waiting 16 for 12 s` in amber. Tapping opens the full event log.
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
      color: pendingLong ? Colors.amber.shade800 : null,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text(text, style: style),
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
      ScoutEventKind.enqueueRejected => 'enqueue rejected',
      ScoutEventKind.inventoryStep => 'inventory step',
    };
    final parts = [
      kind,
      if (event.ecuId != null) event.ecuId!,
      if (event.detail != null) event.detail!,
    ];
    return parts.join(' ');
  }
}

class _LiveInfoCard extends StatelessWidget {
  const _LiveInfoCard({required this.liveInfo, required this.onConfirm});

  final LiveVehicleInfo liveInfo;
  final Future<void> Function(ReadingQuantity quantity, num liveValue)
  onConfirm;

  @override
  Widget build(BuildContext context) {
    if (!liveInfo.hasAnyValue) {
      return const SizedBox.shrink();
    }
    final rows = <Widget>[];
    if (liveInfo.storedEnergyWh != null) {
      rows.add(
        _LiveInfoRow(
          text: 'Vehicle shows stored energy: ${liveInfo.storedEnergyWh} Wh',
        ),
      );
    }
    if (liveInfo.outsideTempC != null) {
      rows.add(
        _LiveInfoRow(
          text: 'Vehicle shows outside temp.: ${liveInfo.outsideTempC} °C',
          onConfirm: () =>
              onConfirm(ReadingQuantity.outsideTemp, liveInfo.outsideTempC!),
        ),
      );
    }
    if (liveInfo.rangeKm != null) {
      rows.add(
        _LiveInfoRow(
          text: 'Vehicle shows range: ${liveInfo.rangeKm} km',
          onConfirm: () => onConfirm(ReadingQuantity.range, liveInfo.rangeKm!),
        ),
      );
    }
    if (liveInfo.odometerKm != null) {
      rows.add(
        _LiveInfoRow(
          text: 'Vehicle shows odometer: ${liveInfo.odometerKm} km',
          onConfirm: () =>
              onConfirm(ReadingQuantity.odometer, liveInfo.odometerKm!),
        ),
      );
    }
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }
}

class _LiveInfoRow extends StatelessWidget {
  const _LiveInfoRow({required this.text, this.onConfirm});

  final String text;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(text)),
          if (onConfirm != null)
            TextButton(
              onPressed: onConfirm,
              child: const Text('Matches display'),
            ),
        ],
      ),
    );
  }
}

class _ReadingTileGrid extends StatelessWidget {
  const _ReadingTileGrid({required this.onTap});

  final void Function(ReadingQuantity quantity) onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        for (final quantity in _tileQuantities)
          _ReadingTile(quantity: quantity, onTap: () => onTap(quantity)),
      ],
    );
  }
}

class _ReadingTile extends StatelessWidget {
  const _ReadingTile({required this.quantity, required this.onTap});

  final ReadingQuantity quantity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${quantity.label}, enter reading',
      button: true,
      child: SizedBox(
        height: 72,
        child: FilledButton.tonal(
          onPressed: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(quantity.label, textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(quantity.unit, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _TileEntryResult {
  const _TileEntryResult(this.value, this.source);
  final num value;
  final ReadingSource source;
}

class _TileEntrySheet extends StatefulWidget {
  const _TileEntrySheet({required this.quantity, required this.prefill});

  final ReadingQuantity quantity;
  final num? prefill;

  @override
  State<_TileEntrySheet> createState() => _TileEntrySheetState();
}

class _TileEntrySheetState extends State<_TileEntrySheet> {
  late num _value;
  late final TextEditingController _controller;
  ReadingSource _source = ReadingSource.typed;
  bool _ignoreNextChange = false;

  @override
  void initState() {
    super.initState();
    _value = widget.prefill ?? 0;
    _controller = TextEditingController(text: _formatValue(_value));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _formatValue(num value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  void _step(int delta) {
    setState(() {
      _value = _value + delta;
      _source = ReadingSource.stepped;
      _ignoreNextChange = true;
      _controller.text = _formatValue(_value);
    });
  }

  void _onChanged(String text) {
    if (_ignoreNextChange) {
      _ignoreNextChange = false;
      return;
    }
    final parsed = num.tryParse(text);
    if (parsed != null) {
      _source = ReadingSource.typed;
      _value = parsed;
    }
  }

  void _save() {
    Navigator.of(context).pop(_TileEntryResult(_value, _source));
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
          Text(
            widget.quantity.label,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              IconButton(
                onPressed: () => _step(-1),
                icon: const Icon(Icons.remove_circle_outline),
                iconSize: 36,
                tooltip: 'Decrease by 1',
              ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                  decoration: InputDecoration(suffixText: widget.quantity.unit),
                  onChanged: _onChanged,
                ),
              ),
              IconButton(
                onPressed: () => _step(1),
                icon: const Icon(Icons.add_circle_outline),
                iconSize: 36,
                tooltip: 'Increase by 1',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
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
