import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../bridge/recording_controller.dart';
import '../session/session_markers.dart';

/// The default [RecordingPage.onShare]: hands [paths] to the platform share
/// sheet as files.
Future<void> _shareFiles(List<String> paths) async {
  await Share.shareXFiles([for (final path in paths) XFile(path)]);
}

/// The main (and currently only) screen: adapter connection/recording
/// status, phase buttons, a note field, the session's marker log, and
/// start/stop/share controls for the recording itself.
class RecordingPage extends StatefulWidget {
  RecordingPage({super.key, RecordingController? controller, this.onShare})
    : controller = controller ?? RecordingController();

  final RecordingController controller;

  /// Shares [RecordingController.shareableFiles]; overridable so tests don't
  /// have to go through the real platform share sheet.
  final Future<void> Function(List<String> paths)? onShare;

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  final TextEditingController _noteController = TextEditingController();

  RecordingController get _controller => widget.controller;

  @override
  void dispose() {
    _controller.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _addNote() {
    final text = _noteController.text.trim();
    if (text.isEmpty) {
      return;
    }
    _controller.addNote(text);
    _noteController.clear();
  }

  Future<void> _share() async {
    final share = widget.onShare ?? _shareFiles;
    await share(_controller.shareableFiles);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('didscout')),
      body: AnimatedBuilder(
        animation: Listenable.merge([_controller, _controller.markers]),
        builder: (context, _) {
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusCard(controller: _controller, onShare: _share),
                const SizedBox(height: 16),
                _PhaseButtonGrid(controller: _controller),
                const SizedBox(height: 16),
                _NoteInput(controller: _noteController, onSubmit: _addNote),
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
                  color: controller.phase == RecordingPhase.error ||
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

class _NoteInput extends StatelessWidget {
  const _NoteInput({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Note',
                helperText: 'Only while stationary or as a passenger',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: onSubmit,
                child: const Text('Add note'),
              ),
            ),
          ],
        ),
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
          ListTile(
            leading: Icon(
              marker.kind == MarkerKind.phase
                  ? Icons.flag
                  : Icons.sticky_note_2,
            ),
            title: Text(
              marker.kind == MarkerKind.phase
                  ? _phaseLabel(marker.phase!)
                  : marker.text!,
            ),
            subtitle: Text(_formatTime(marker.timestamp)),
          ),
      ],
    );
  }
}
