import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../capture/recording_summary.dart' as recording_summary;
import '../capture/recording_summary.dart';

/// The default [RecordingsPage.onShare]: hands [paths] to the platform
/// share sheet as files.
Future<void> _shareFiles(List<String> paths) async {
  await Share.shareXFiles([for (final path in paths) XFile(path)]);
}

/// Lists every past (and the currently running, if any) recording in
/// [recordingsDirectory], newest first: start time, duration, size, and
/// reading/marker counts. Supports sharing one or several at once, and
/// deleting — never the one matching [currentBufferPath], which is marked
/// instead.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({
    super.key,
    required this.recordingsDirectory,
    this.currentBufferPath,
    this.onShare,
    this.listRecordings = recording_summary.listRecordings,
    this.deleteRecording = recording_summary.deleteRecording,
  });

  final Future<Directory> Function() recordingsDirectory;

  /// [RecordingSummary.bufferPath] of the recording currently in progress,
  /// if any — that entry is marked and its delete action is disabled.
  final String? currentBufferPath;

  final Future<void> Function(List<String> paths)? onShare;

  /// Overridable so tests don't have to touch the real filesystem.
  final Future<List<RecordingSummary>> Function(Directory directory)
  listRecordings;
  final Future<void> Function(RecordingSummary summary) deleteRecording;

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  List<RecordingSummary>? _recordings;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final directory = await widget.recordingsDirectory();
    final recordings = await widget.listRecordings(directory);
    if (!mounted) return;
    setState(() {
      _recordings = recordings;
      _selected.removeWhere(
        (id) => !recordings.any((r) => r.sessionId == id),
      );
    });
  }

  bool _isCurrent(RecordingSummary summary) =>
      widget.currentBufferPath != null &&
      summary.bufferPath == widget.currentBufferPath;

  void _toggleSelected(String sessionId) {
    setState(() {
      if (_selected.contains(sessionId)) {
        _selected.remove(sessionId);
      } else {
        _selected.add(sessionId);
      }
    });
  }

  Future<void> _share(List<RecordingSummary> summaries) async {
    final share = widget.onShare ?? _shareFiles;
    final paths = [
      for (final summary in summaries) ...[
        summary.bufferPath,
        if (summary.markersPath != null) summary.markersPath!,
      ],
    ];
    await share(paths);
  }

  Future<bool> _confirmDelete(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(
          count == 1
              ? 'This recording and its markers will be deleted.'
              : 'These $count recordings and their markers will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteOne(RecordingSummary summary) async {
    if (!await _confirmDelete(1)) return;
    await widget.deleteRecording(summary);
    await _reload();
  }

  Future<void> _deleteSelected(List<RecordingSummary> selected) async {
    if (!await _confirmDelete(selected.length)) return;
    for (final summary in selected) {
      await widget.deleteRecording(summary);
    }
    setState(_selected.clear);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final recordings = _recordings;
    final selecting = _selected.isNotEmpty;
    final selectedSummaries = recordings == null
        ? const <RecordingSummary>[]
        : recordings.where((r) => _selected.contains(r.sessionId)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '${_selected.length} selected' : 'Recordings'),
        actions: selecting
            ? [
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Share selected',
                  onPressed: () => _share(selectedSummaries),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete selected',
                  onPressed: selectedSummaries.any(_isCurrent)
                      ? null
                      : () => _deleteSelected(selectedSummaries),
                ),
              ]
            : null,
      ),
      body: recordings == null
          ? const Center(child: CircularProgressIndicator())
          : recordings.isEmpty
          ? const Center(child: Text('No recordings yet.'))
          : ListView.separated(
              itemCount: recordings.length,
              separatorBuilder: (context, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final summary = recordings[index];
                return _RecordingRow(
                  summary: summary,
                  isCurrent: _isCurrent(summary),
                  selected: _selected.contains(summary.sessionId),
                  selecting: selecting,
                  onTap: () {
                    if (selecting) _toggleSelected(summary.sessionId);
                  },
                  onLongPress: () => _toggleSelected(summary.sessionId),
                  onShare: () => _share([summary]),
                  onDelete: _isCurrent(summary)
                      ? null
                      : () => _deleteOne(summary),
                );
              },
            ),
    );
  }
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({
    required this.summary,
    required this.isCurrent,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onShare,
    required this.onDelete,
  });

  final RecordingSummary summary;
  final bool isCurrent;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onShare;
  final VoidCallback? onDelete;

  static String _formatStart(DateTime utc) {
    final local = utc.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _formatDuration(Duration? duration) {
    if (duration == null) return 'duration unknown';
    final totalMinutes = duration.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final subtitle =
        '${_formatDuration(summary.duration)} · '
        '${_formatSize(summary.sizeBytes)} · '
        '${summary.readingCount} readings, ${summary.markerCount} markers';
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onLongPress())
          : const Icon(Icons.description_outlined),
      title: Text(_formatStart(summary.startedAt)),
      subtitle: Text(subtitle),
      trailing: isCurrent
          ? Chip(label: const Text('Recording…'))
          : selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Share',
                  onPressed: onShare,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: onDelete,
                ),
              ],
            ),
    );
  }
}
