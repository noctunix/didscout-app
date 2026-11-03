import 'package:flutter/material.dart';

import '../bridge/recording_controller.dart';
import '../capture/diff.dart';
import '../capture/readings.dart';
import '../session/experiments.dart';
import '../session/session_markers.dart';

/// How many changed DIDs a result lists before "Show all".
const int _maxChangeRows = 6;

/// The recording page's guided experiment card: the top suggestion with
/// a way to pick another, then each step of the run in progress, then
/// its result or why it ended early.
class ExperimentCard extends StatelessWidget {
  const ExperimentCard({
    super.key,
    required this.controller,
    required this.onEnterReading,
  });

  final RecordingController controller;

  /// Opens the entry sheet for a finished experiment's follow-up reading.
  final void Function(ReadingQuantity quantity) onEnterReading;

  /// Whether the card shows for [controller]: while recording, with a
  /// run to show or in a phase the owner set for standing or charging.
  /// The phase rather than the speed decides, so the card does not come
  /// and go while the vehicle creeps.
  static bool visibleFor(RecordingController controller) =>
      controller.phase == RecordingPhase.recording &&
      (controller.experimentRun != null ||
          switch (controller.markers.currentPhase) {
            MarkerPhase.stand || MarkerPhase.park || MarkerPhase.charge => true,
            MarkerPhase.drive || null => false,
          });

  String _targets(Experiment experiment) => [
    for (final header in experiment.targetHeaders)
      controller.ecuName(header) ?? header,
  ].join(', ');

  Future<void> _chooseExperiment(
    BuildContext context,
    List<Experiment> suggestions,
  ) async {
    final chosen = await showModalBottomSheet<Experiment>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _ExperimentPickerSheet(suggestions: suggestions, targetsOf: _targets),
    );
    if (chosen != null) controller.startExperiment(chosen.id);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.science_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Experiments', style: textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...switch (controller.experimentRun) {
              null => _suggestion(context, controller.experimentSuggestions),
              final ExperimentCapturing run => _capturing(run),
              final ExperimentAwaitingAction run => _awaitingAction(
                context,
                run,
              ),
              final ExperimentDone run => _done(context, run),
              final ExperimentFailed run => _failed(run),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _suggestion(BuildContext context, List<Experiment> suggestions) {
    if (!controller.isStationary) {
      return [
        const Text('Starts when the vehicle stands still'),
        const SizedBox(height: 8),
        const FilledButton(onPressed: null, child: Text('Start')),
      ];
    }
    final top = suggestions.firstOrNull;
    if (top == null) {
      return const [Text('No experiment for the ECUs found so far')];
    }
    return [
      Text(top.title, style: Theme.of(context).textTheme.titleSmall),
      Text(
        'Reads ${_targets(top)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          FilledButton(
            onPressed: () => controller.startExperiment(top.id),
            child: const Text('Start'),
          ),
          if (suggestions.length > 1) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => _chooseExperiment(context, suggestions),
              child: const Text('Choose another'),
            ),
          ],
        ],
      ),
    ];
  }

  List<Widget> _capturing(ExperimentCapturing run) => [
    Text(run.after ? 'Reading after…' : 'Reading before…'),
    const SizedBox(height: 8),
    LinearProgressIndicator(value: run.answered / run.total),
    const SizedBox(height: 4),
    Text('${run.answered} of ${run.total} reads'),
    // End-aligned while Done sits at the start, so a double tap on Done
    // cannot cancel the after reads.
    Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TextButton(
        onPressed: controller.cancelExperiment,
        child: const Text('Cancel'),
      ),
    ),
  ];

  List<Widget> _awaitingAction(
    BuildContext context,
    ExperimentAwaitingAction run,
  ) => [
    Text(run.experiment.title, style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 4),
    Semantics(
      liveRegion: true,
      child: Text(
        run.experiment.instruction,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
    const SizedBox(height: 8),
    Row(
      children: [
        FilledButton(
          onPressed: controller.confirmExperimentAction,
          child: const Text('Done'),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: controller.cancelExperiment,
          child: const Text('Cancel'),
        ),
      ],
    ),
  ];

  /// The first [limit] changed DIDs of [run], grouped per ECU, each
  /// ECU's DIDs that also change on their own last.
  List<Widget> _changeRows(
    BuildContext context,
    ExperimentDone run,
    int limit,
  ) {
    bool moving(DidDiff diff) =>
        run.movingOnTheirOwn.contains((header: diff.module!, did: diff.did));
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final rows = <Widget>[];
    var left = limit;
    for (final MapEntry(key: header, value: diffs) in run.changes.entries) {
      if (left == 0) break;
      final shown = [
        ...diffs.where((diff) => !moving(diff)),
        ...diffs.where(moving),
      ].take(left).toList();
      left -= shown.length;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(controller.ecuName(header) ?? header),
              for (final diff in shown)
                Text(
                  moving(diff)
                      ? '${_describeDiff(diff)}  (moves on its own)'
                      : _describeDiff(diff),
                  style: style,
                ),
            ],
          ),
        ),
      );
    }
    return rows;
  }

  Future<void> _showAllChanges(
    BuildContext context,
    ExperimentDone run,
    int changeCount,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Semantics(
            header: true,
            child: Text(
              run.experiment.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 8),
          ..._changeRows(context, run, changeCount),
        ],
      ),
    ),
  );

  List<Widget> _done(BuildContext context, ExperimentDone run) {
    final followUp = run.experiment.followUp;
    final changeCount = run.changes.values.fold(
      0,
      (count, diffs) => count + diffs.length,
    );
    return [
      Text(run.experiment.title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      if (run.changes.isEmpty)
        const Text('No change seen')
      else
        ..._changeRows(context, run, _maxChangeRows),
      if (changeCount > _maxChangeRows)
        TextButton(
          onPressed: () => _showAllChanges(context, run, changeCount),
          child: Text('Show all ($changeCount)'),
        ),
      Wrap(
        spacing: 8,
        children: [
          if (followUp != null)
            FilledButton.tonal(
              onPressed: () => onEnterReading(followUp),
              child: Text('Enter ${followUp.label}'),
            ),
          TextButton(
            onPressed: controller.dismissExperiment,
            child: const Text('Close'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _failed(ExperimentFailed run) => [
    Text('${run.experiment.title}: ${_failureText(run.failure)}'),
    Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TextButton(
        onPressed: controller.dismissExperiment,
        child: const Text('Close'),
      ),
    ),
  ];
}

String _failureText(ExperimentFailure failure) => switch (failure) {
  ExperimentFailure.cancelled => 'cancelled',
  ExperimentFailure.moving =>
    'cancelled because the vehicle moved or its speed is unknown',
  ExperimentFailure.recordingStopped => 'cancelled, the recording ended',
  ExperimentFailure.rejected => 'the adapter did not accept the reads',
  ExperimentFailure.noAnswer => 'no target ECU answered',
};

String _hex(int byte) => byte.toRadixString(16).toUpperCase().padLeft(2, '0');

/// One DID's changes, e.g. `2A00  byte 0: 00 → 01, length 2 → 3`.
String _describeDiff(DidDiff diff) {
  final parts = [
    for (final change in diff.changes)
      'byte ${change.position}: ${_hex(change.before)} → ${_hex(change.after)}',
    if (diff.before.length != diff.after.length)
      'length ${diff.before.length} → ${diff.after.length}',
  ];
  return '${diff.did}  ${parts.join(', ')}';
}

class _ExperimentPickerSheet extends StatelessWidget {
  const _ExperimentPickerSheet({
    required this.suggestions,
    required this.targetsOf,
  });

  final List<Experiment> suggestions;
  final String Function(Experiment experiment) targetsOf;

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
                'Experiments',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final experiment = suggestions[index];
                  return ListTile(
                    title: Text(experiment.title),
                    subtitle: Text('Reads ${targetsOf(experiment)}'),
                    onTap: () => Navigator.of(context).pop(experiment),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
