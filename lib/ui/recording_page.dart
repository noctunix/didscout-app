import 'package:flutter/material.dart';

import '../session/session_markers.dart';

/// The main (and currently only) screen: phase buttons, a note field, and
/// the session's marker log. Pure UI - no Bluetooth or platform code.
class RecordingPage extends StatefulWidget {
  const RecordingPage({super.key});

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  final SessionMarkerLog _log = SessionMarkerLog();
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _log.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _addNote() {
    final text = _noteController.text.trim();
    if (text.isEmpty) {
      return;
    }
    _log.addNote(text);
    _noteController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('didscout')),
      body: AnimatedBuilder(
        animation: _log,
        builder: (context, _) {
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusCard(),
                const SizedBox(height: 16),
                _PhaseButtonGrid(log: _log),
                const SizedBox(height: 16),
                _NoteInput(controller: _noteController, onSubmit: _addNote),
                const SizedBox(height: 16),
                Text('Markers', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _MarkerList(markers: _log.markers),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard();

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
                Icon(
                  Icons.bluetooth_disabled,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Not connected — recording comes with the adapter connection',
                    semanticsLabel:
                        'Not connected. Recording comes with the adapter connection.',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: null,
                child: const Text('Start recording'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhaseButtonGrid extends StatelessWidget {
  const _PhaseButtonGrid({required this.log});

  final SessionMarkerLog log;

  static const _phases = [
    (MarkerPhase.drive, 'Drive', Icons.directions_car),
    (MarkerPhase.charge, 'Charge', Icons.ev_station),
    (MarkerPhase.stand, 'Stand', Icons.pause_circle),
    (MarkerPhase.park, 'Park', Icons.local_parking),
  ];

  @override
  Widget build(BuildContext context) {
    final current = log.currentPhase;
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
            onPressed: () => log.addPhase(phase),
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
