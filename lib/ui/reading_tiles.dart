import 'package:flutter/material.dart';

import '../capture/readings.dart';
import '../session/reading_prompts.dart';
import '../session/session_markers.dart';
import 'reading_entry_sheet.dart';

/// The reading tiles shown in [phase], in display order, two per row. The
/// order is fixed so a tile never moves under the owner's finger; the
/// third slot holds whichever charging power the vehicle displays in
/// [phase]: the power flowing while charging, the predicted maximum
/// otherwise.
List<ReadingQuantity> _tileQuantities(MarkerPhase? phase) => [
  ReadingQuantity.soc,
  ReadingQuantity.batteryTemp,
  phase == MarkerPhase.charge
      ? ReadingQuantity.chargePower
      : ReadingQuantity.chargePowerMax,
  ReadingQuantity.range,
  ReadingQuantity.outsideTemp,
  ReadingQuantity.insideTemp,
  ReadingQuantity.odometer,
];

/// [age] in words: `just now`, `12 min ago` or `2 h ago`.
String describeAge(Duration age) {
  if (age < const Duration(minutes: 1)) return 'just now';
  if (age < const Duration(hours: 1)) return '${age.inMinutes} min ago';
  return '${age.inHours} h ago';
}

/// The reading tiles in rows of two. Each shows its quantity's live
/// vehicle value, else the owner's last entry with its age, and opens the
/// entry sheet when tapped.
class ReadingTiles extends StatelessWidget {
  const ReadingTiles({
    super.key,
    required this.liveValues,
    required this.lastEntries,
    required this.phase,
    required this.due,
    required this.now,
    required this.onTap,
  });

  /// The vehicle's own live value per quantity, where it has one; the
  /// state of charge one is an estimate.
  final Map<ReadingQuantity, num> liveValues;

  /// Each quantity's most recent reading.
  final Map<ReadingQuantity, ReadingMarker> lastEntries;

  /// The session's current phase, which decides when an entry is stale
  /// and which charging power tile is shown.
  final MarkerPhase? phase;

  /// The quantities a [ReadingPrompt] asks for now.
  final Set<ReadingQuantity> due;

  /// The time entry ages are measured against.
  final DateTime now;

  final void Function(ReadingQuantity quantity) onTap;

  Widget _tile(ReadingQuantity quantity) => _ReadingTile(
    quantity: quantity,
    liveValue: liveValues[quantity],
    lastEntry: lastEntries[quantity],
    phase: phase,
    due: due.contains(quantity),
    now: now,
    onTap: () => onTap(quantity),
  );

  @override
  Widget build(BuildContext context) {
    final quantities = _tileQuantities(phase);
    return Column(
      children: [
        for (var i = 0; i < quantities.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _tile(quantities[i])),
                const SizedBox(width: 12),
                Expanded(
                  child: i + 1 < quantities.length
                      ? _tile(quantities[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// What a tile shows below its label: the value ([number] and, unless
/// there is none, [unit]), where it came from, and the same for screen
/// readers.
typedef _TileContent = ({
  String number,
  String? unit,
  IconData? icon,
  String origin,
  String spoken,
  bool muted,
});

class _ReadingTile extends StatelessWidget {
  const _ReadingTile({
    required this.quantity,
    required this.liveValue,
    required this.lastEntry,
    required this.phase,
    required this.due,
    required this.now,
    required this.onTap,
  });

  final ReadingQuantity quantity;
  final num? liveValue;
  final ReadingMarker? lastEntry;
  final MarkerPhase? phase;
  final bool due;
  final DateTime now;
  final VoidCallback onTap;

  String _number(num value) => quantity == ReadingQuantity.odometer
      ? '${value.truncate()}'
      : formatReadingValue(value);

  String _spoken(String number) =>
      '${number.startsWith('-') ? 'minus ${number.substring(1)}' : number} '
      '${quantity.spokenUnit}';

  _TileContent _live(num value) {
    final number = _number(value);
    return quantity == ReadingQuantity.soc
        ? (
            number: '≈ $number',
            unit: quantity.unit,
            icon: Icons.sensors,
            origin: 'Estimate',
            spoken:
                'approximately ${_spoken(number)}, estimated from the vehicle',
            muted: false,
          )
        : (
            number: number,
            unit: quantity.unit,
            icon: Icons.sensors,
            origin: 'Vehicle',
            spoken: '${_spoken(number)}, from the vehicle',
            muted: false,
          );
  }

  _TileContent _entry(ReadingMarker entry) {
    final number = _number(entry.value);
    final age = now.difference(entry.readAt);
    final ageText = describeAge(age);
    return (
      number: number,
      unit: quantity.unit,
      icon: Icons.schedule,
      origin: '${ageText[0].toUpperCase()}${ageText.substring(1)}',
      spoken: '${_spoken(number)}, entered $ageText',
      muted: age > readingStaleAfter(quantity, phase),
    );
  }

  _TileContent get _content => switch ((liveValue, lastEntry)) {
    (final num value, _) => _live(value),
    (null, final ReadingMarker entry) => _entry(entry),
    (null, null) => (
      number: '—',
      unit: null,
      icon: null,
      origin: 'Not read',
      spoken: 'not read',
      muted: true,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final content = _content;
    final valueColor = content.muted
        ? colors.onSurfaceVariant
        : colors.onSurface;
    final originStyle = textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label:
          '${quantity.label}, ${content.spoken}'
          '${due ? ', reading due' : ''}',
      // excludeSemantics also drops the InkWell's own tap action.
      onTap: onTap,
      onTapHint: 'enter reading',
      child: Card.filled(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: due
              ? BorderSide(color: colors.primary, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          quantity.label,
                          style: textTheme.labelLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (due)
                        Icon(
                          Icons.visibility_outlined,
                          size: 18,
                          color: colors.primary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: content.number,
                          style: textTheme.titleLarge?.copyWith(
                            color: valueColor,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (content.unit case final unit?)
                          TextSpan(
                            text: ' $unit',
                            style: textTheme.bodyMedium?.copyWith(
                              color: valueColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (content.icon case final icon?) ...[
                        Icon(icon, size: 16, color: colors.onSurfaceVariant),
                        const SizedBox(width: 4),
                      ],
                      Flexible(child: Text(content.origin, style: originStyle)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
