import 'package:flutter/material.dart';

import '../discovery/testplan_check.dart';

/// The recording page's "Testplan check" card: collapsed by default to a
/// one-line summary, expanding to the full probe catalogue grouped by
/// [TestplanGroup], one row per probe with its command, target header and
/// status.
class TestplanCard extends StatefulWidget {
  const TestplanCard({super.key, required this.check});

  final TestplanCheck check;

  @override
  State<TestplanCard> createState() => _TestplanCardState();
}

class _TestplanCardState extends State<TestplanCard> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: _expanded
                ? 'Testplan check, tap to collapse'
                : 'Testplan check, tap to expand',
            child: InkWell(
              onTap: _toggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.fact_check_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Testplan check',
                              style: textTheme.titleMedium,
                            ),
                            Text(
                              _summary(widget.check),
                              style: textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final group in TestplanGroup.values)
                    _GroupSection(
                      group: group,
                      states: widget.check.statesByGroup[group] ?? const [],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _summary(TestplanCheck check) {
    final lastRunPhase = check.lastRunPhase;
    final parts = [
      '${check.answeredCount} answered',
      '${check.okCount} OK',
      if (lastRunPhase != null) 'last run: ${lastRunPhase.name}',
    ];
    return parts.join(' · ');
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.group, required this.states});

  final TestplanGroup group;
  final List<TestplanProbeState> states;

  @override
  Widget build(BuildContext context) {
    if (states.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(group.label, style: Theme.of(context).textTheme.titleSmall),
          for (final state in states) _ProbeRow(state: state),
        ],
      ),
    );
  }
}

class _ProbeRow extends StatelessWidget {
  const _ProbeRow({required this.state});

  final TestplanProbeState state;

  @override
  Widget build(BuildContext context) {
    final probe = state.probe;
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    return Semantics(
      label:
          '${probe.command} on ${probe.requestHeader}, ${probe.description}, '
          '${state.statusLabel}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 84,
                child: Text(
                  probe.command,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  probe.requestHeader,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              Expanded(child: Text(probe.description, style: bodySmall)),
              Text(state.statusLabel, style: bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
