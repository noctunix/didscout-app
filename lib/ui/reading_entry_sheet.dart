import 'package:flutter/material.dart';

import '../capture/readings.dart';

/// [value] without a trailing `.0` when it is whole, e.g. `12` or `12.5`.
String formatReadingValue(num value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';

final RegExp _readingPattern = RegExp(r'^-?(\d+([.,]\d*)?|[.,]\d+)$');

/// [text] as a reading, with `,` accepted as the decimal separator since
/// many keyboards offer only that; null when it is not a plain number.
num? _parseReading(String text) {
  final trimmed = text.trim();
  if (!_readingPattern.hasMatch(trimmed)) return null;
  return num.parse(trimmed.replaceAll(',', '.'));
}

/// Opens the entry sheet for one reading of [quantity], its field
/// prefilled with [prefill] (left empty when null) and [contextLine]
/// explaining where that value came from.
///
/// Returns the saved value and where it came from: [ReadingSource.confirmed]
/// when it equals [prefill], otherwise how the owner last changed it; null
/// when the sheet was dismissed.
Future<(num, ReadingSource)?> showReadingEntrySheet(
  BuildContext context, {
  required ReadingQuantity quantity,
  required num? prefill,
  required String contextLine,
}) => showModalBottomSheet<(num, ReadingSource)>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => _ReadingEntrySheet(
    quantity: quantity,
    prefill: prefill,
    contextLine: contextLine,
  ),
);

class _ReadingEntrySheet extends StatefulWidget {
  const _ReadingEntrySheet({
    required this.quantity,
    required this.prefill,
    required this.contextLine,
  });

  final ReadingQuantity quantity;
  final num? prefill;
  final String contextLine;

  @override
  State<_ReadingEntrySheet> createState() => _ReadingEntrySheetState();
}

class _ReadingEntrySheetState extends State<_ReadingEntrySheet> {
  late final TextEditingController _text = TextEditingController(
    text: widget.prefill == null ? '' : formatReadingValue(widget.prefill!),
  );
  final FocusNode _focus = FocusNode();
  ReadingSource _lastEdit = ReadingSource.typed;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_selectAllOnFocus);
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  // Runs after the focusing tap has placed the cursor, so typing replaces
  // the prefilled value instead of appending to it.
  void _selectAllOnFocus() {
    if (!_focus.hasFocus) return;
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _text.text.length,
    );
  }

  bool get _signed => switch (widget.quantity) {
    ReadingQuantity.batteryTemp ||
    ReadingQuantity.outsideTemp ||
    ReadingQuantity.insideTemp => true,
    _ => false,
  };

  /// The value the steppers change: the field's, or, while it is empty,
  /// the prefill shown as its hint.
  num? _stepBase(num? value) =>
      value ?? (_text.text.trim().isEmpty ? widget.prefill : null);

  void _step(num base, int delta) {
    setState(() {
      _lastEdit = ReadingSource.stepped;
      _text.text = formatReadingValue(base + delta);
    });
  }

  void _save(num value) {
    Navigator.of(context).pop((
      value,
      value == widget.prefill ? ReadingSource.confirmed : _lastEdit,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final value = _parseReading(_text.text);
    final stepBase = _stepBase(value);
    final prefill = widget.prefill;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              widget.quantity.label,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.contextLine,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              IconButton(
                onPressed: stepBase == null ? null : () => _step(stepBase, -1),
                icon: const Icon(Icons.remove_circle_outline),
                iconSize: 36,
                tooltip: 'Decrease by 1',
              ),
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: true,
                    signed: _signed,
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                  decoration: InputDecoration(
                    suffixText: widget.quantity.unit,
                    hintText: prefill == null
                        ? null
                        : formatReadingValue(prefill),
                    errorText: value == null && _text.text.trim().isNotEmpty
                        ? 'Enter a number'
                        : null,
                  ),
                  onChanged: (_) =>
                      setState(() => _lastEdit = ReadingSource.typed),
                ),
              ),
              IconButton(
                onPressed: stepBase == null ? null : () => _step(stepBase, 1),
                icon: const Icon(Icons.add_circle_outline),
                iconSize: 36,
                tooltip: 'Increase by 1',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: value == null ? null : () => _save(value),
              child: Text(
                prefill != null && value == prefill
                    ? 'Matches display'
                    : 'Save',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
