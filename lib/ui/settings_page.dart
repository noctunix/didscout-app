import 'package:flutter/material.dart';

import '../bridge/recording_controller.dart';
import '../settings/app_settings.dart';
import '../settings/settings_repository.dart';

/// Settings only configure the recording — none of them block the owner
/// from starting, stopping, or sharing a recording regardless of what's
/// set here.
class SettingsPage extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  SettingsPage({
    super.key,
    SettingsRepository? repository,
    this.recordingController,
  }) : repository = repository ?? const SettingsRepository();

  final SettingsRepository repository;

  /// The recording in progress, if settings were opened while one is
  /// running -- only used to show the measured reads/min next to the
  /// "Scout speed" section header; null otherwise.
  final RecordingController? recordingController;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings? _settings;
  bool _saving = false;

  /// The last finite value the owner chose for "Max reads per second",
  /// restored if they turn "Unlimited" back off.
  int _lastFiniteMaxReadsPerSecond =
      const AppSettings.defaultValues().maxReadsPerSecond;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await widget.repository.load();
    if (loaded.maxReadsPerSecond < unlimitedMaxReadsPerSecond) {
      _lastFiniteMaxReadsPerSecond = loaded.maxReadsPerSecond;
    }
    if (mounted) setState(() => _settings = loaded);
  }

  Future<void> _save() async {
    final settings = _settings;
    if (settings == null) return;
    setState(() => _saving = true);
    await widget.repository.save(settings);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _resetToDefaults() async {
    await widget.repository.resetToDefaults();
    _lastFiniteMaxReadsPerSecond =
        const AppSettings.defaultValues().maxReadsPerSecond;
    if (mounted) setState(() => _settings = const AppSettings.defaultValues());
  }

  void _update(AppSettings Function(AppSettings) update) {
    final settings = _settings;
    if (settings == null) return;
    setState(() => _settings = update(settings));
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Reset to defaults',
            onPressed: settings == null ? null : _resetToDefaults,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Save',
            onPressed: settings == null || _saving ? null : _save,
          ),
        ],
      ),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const _SectionHeader('Connection'),
                _IntSliderSetting(
                  label: 'Read timeout per request',
                  value: settings.readTimeoutMs,
                  min: 500,
                  max: 10000,
                  divisions: 19,
                  formatValue: (v) => '$v ms',
                  onChanged: (v) =>
                      _update((s) => s.copyWith(readTimeoutMs: v)),
                ),
                _IntSliderSetting(
                  label: 'Reconnect backoff, minimum',
                  value: settings.reconnectBackoffMinS,
                  min: 1,
                  max: 30,
                  divisions: 29,
                  formatValue: (v) => '$v s',
                  onChanged: (v) =>
                      _update((s) => s.copyWith(reconnectBackoffMinS: v)),
                ),
                _IntSliderSetting(
                  label: 'Reconnect backoff, maximum',
                  value: settings.reconnectBackoffMaxS,
                  min: 10,
                  max: 300,
                  divisions: 29,
                  formatValue: (v) => '$v s',
                  onChanged: (v) =>
                      _update((s) => s.copyWith(reconnectBackoffMaxS: v)),
                ),
                SwitchListTile(
                  title: const Text('Never give up reconnecting'),
                  value: settings.neverGiveUpReconnecting,
                  onChanged: (v) =>
                      _update((s) => s.copyWith(neverGiveUpReconnecting: v)),
                ),
                if (!settings.neverGiveUpReconnecting)
                  _IntSliderSetting(
                    label: 'Reconnect attempts',
                    value: settings.reconnectAttempts,
                    min: 1,
                    max: 200,
                    divisions: 199,
                    formatValue: (v) => '$v',
                    onChanged: (v) =>
                        _update((s) => s.copyWith(reconnectAttempts: v)),
                  ),
                _IntSliderSetting(
                  label: 'Stop after no vehicle data for',
                  value: settings.stopAfterNoVehicleDataMinutes,
                  min: 5,
                  max: 120,
                  divisions: 23,
                  formatValue: (v) => '$v min',
                  onChanged: (v) => _update(
                    (s) => s.copyWith(stopAfterNoVehicleDataMinutes: v),
                  ),
                ),
                const Divider(),
                const _SectionHeader('Recording'),
                _IntSliderSetting(
                  label: 'Survey interval for exploratory DIDs',
                  value: settings.surveyIntervalMinutes,
                  min: 1,
                  max: 10,
                  divisions: 9,
                  formatValue: (v) => '$v min',
                  onChanged: (v) =>
                      _update((s) => s.copyWith(surveyIntervalMinutes: v)),
                ),
                _IntSliderSetting(
                  label: 'Charging reminder interval',
                  value: settings.chargeReminderIntervalMinutes,
                  min: 1,
                  max: 30,
                  divisions: 29,
                  formatValue: (v) => '$v min',
                  onChanged: (v) => _update(
                    (s) => s.copyWith(chargeReminderIntervalMinutes: v),
                  ),
                ),
                const Divider(),
                const _SectionHeader('Power'),
                SwitchListTile(
                  title: const Text(
                    'Start recording automatically when connected to power',
                  ),
                  subtitle: const Text(
                    'Only while the app is open — starting without it open '
                    'needs a later companion-device feature.',
                  ),
                  value: settings.autoStartOnPower,
                  onChanged: (v) =>
                      _update((s) => s.copyWith(autoStartOnPower: v)),
                ),
                SwitchListTile(
                  title: const Text('Record only while connected to power'),
                  subtitle: const Text(
                    'Stops the recording cleanly as soon as the phone is '
                    'unplugged.',
                  ),
                  value: settings.recordOnlyWhilePoweredOn,
                  onChanged: (v) =>
                      _update((s) => s.copyWith(recordOnlyWhilePoweredOn: v)),
                ),
                const Divider(),
                const _SectionHeader('Scouting'),
                RadioGroup<RecordingMode>(
                  groupValue: settings.recordingMode,
                  onChanged: (v) => _update(
                    (s) => s.copyWith(recordingMode: v ?? s.recordingMode),
                  ),
                  child: const Column(
                    children: [
                      RadioListTile<RecordingMode>(
                        title: Text('Scout only'),
                        subtitle: Text(
                          'The recurring plan reads only speed, energy, '
                          'range, odometer and the battery temperature '
                          'candidate plus whatever discovery finds '
                          '-- no other vag-ppe or fixed vehicle signals.',
                        ),
                        value: RecordingMode.scoutOnly,
                      ),
                      RadioListTile<RecordingMode>(
                        title: Text('Scout and record known signals'),
                        subtitle: Text(
                          'The recurring plan also reads every known '
                          'vag-ppe DID plus the fixed outside-temperature/'
                          '12V/accelerator signals.',
                        ),
                        value: RecordingMode.scoutAndRecordKnown,
                      ),
                    ],
                  ),
                ),
                SwitchListTile(
                  title: const Text('Keep sampling found DIDs'),
                  subtitle: const Text(
                    'Finding a DID only proves it exists; sampling it over '
                    'time together with your readings reveals what it '
                    'means.',
                  ),
                  value: settings.keepSamplingFoundDids,
                  onChanged: (v) =>
                      _update((s) => s.copyWith(keepSamplingFoundDids: v)),
                ),
                SwitchListTile(
                  title: const Text('Scout while recording'),
                  subtitle: const Text(
                    'Looks for new ECUs and DIDs in the background during a '
                    'recording; anything found is added to future recordings.',
                  ),
                  value: settings.scoutWhileRecording,
                  onChanged: (v) =>
                      _update((s) => s.copyWith(scoutWhileRecording: v)),
                ),
                SwitchListTile(
                  title: const Text('Scout while driving'),
                  subtitle: const Text(
                    'Safety systems (ABS, ESC, steering, airbag, parking '
                    'lock) are only scouted when stationary, regardless of '
                    'this setting.',
                  ),
                  value: settings.scoutWhileDriving,
                  onChanged: settings.scoutWhileRecording
                      ? (v) => _update((s) => s.copyWith(scoutWhileDriving: v))
                      : null,
                ),
                const Divider(),
                _ScoutSpeedSectionHeader(
                  recordingController: widget.recordingController,
                ),
                SwitchListTile(
                  title: const Text('Unlimited max reads per second'),
                  subtitle: const Text(
                    'The adapter manages about 6-8 reads per second over '
                    'BLE; unlimited removes the app-side cap entirely and '
                    'lets the adapter and vehicle set the real limit.',
                  ),
                  value:
                      settings.maxReadsPerSecond >= unlimitedMaxReadsPerSecond,
                  onChanged: (v) => _update(
                    (s) => s.copyWith(
                      maxReadsPerSecond: v
                          ? unlimitedMaxReadsPerSecond
                          : _lastFiniteMaxReadsPerSecond,
                    ),
                  ),
                ),
                if (settings.maxReadsPerSecond < unlimitedMaxReadsPerSecond)
                  _IntSliderSetting(
                    label: 'Max reads per second',
                    value: settings.maxReadsPerSecond,
                    min: 1,
                    max: 12,
                    divisions: 11,
                    formatValue: (v) => '$v',
                    onChanged: (v) {
                      _lastFiniteMaxReadsPerSecond = v;
                      _update((s) => s.copyWith(maxReadsPerSecond: v));
                    },
                  ),
                _IntSliderSetting(
                  label: 'Speed polling interval',
                  subtitle:
                      'Less often leaves more time for scouting, but '
                      'motion is noticed later.',
                  value: settings.speedPollIntervalS,
                  min: 2,
                  max: 60,
                  divisions: 58,
                  formatValue: (v) => '$v s',
                  onChanged: (v) =>
                      _update((s) => s.copyWith(speedPollIntervalS: v)),
                ),
                _IntSliderSetting(
                  label: 'Discovery batch size',
                  subtitle: 'DIDs read per discovery batch.',
                  value: settings.discoveryBatchSize,
                  min: 8,
                  max: 64,
                  divisions: 56,
                  formatValue: (v) => '$v',
                  onChanged: (v) =>
                      _update((s) => s.copyWith(discoveryBatchSize: v)),
                ),
                _AdapterResponseTimeoutSetting(
                  value: settings.adapterResponseTimeoutMs,
                  onChanged: (v) =>
                      _update((s) => s.copyWith(adapterResponseTimeoutMs: v)),
                ),
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.trailing});

  final String title;

  /// Extra detail shown at the trailing edge of the header, e.g. a live
  /// measurement -- null for a plain header.
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: style)),
          if (trailing != null) Text(trailing!, style: style),
        ],
      ),
    );
  }
}

/// The "Scout speed" section header, showing the measured reads/min next
/// to the title while [recordingController] has a recording with discovery
/// active -- a plain header otherwise.
class _ScoutSpeedSectionHeader extends StatelessWidget {
  const _ScoutSpeedSectionHeader({this.recordingController});

  final RecordingController? recordingController;

  @override
  Widget build(BuildContext context) {
    final controller = recordingController;
    if (controller == null) {
      return const _SectionHeader('Scout speed');
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final status = controller.scoutStatus;
        return _SectionHeader(
          'Scout speed',
          trailing: status == null ? null : '${status.readsPerMinute}/min',
        );
      },
    );
  }
}

/// A row of selectable chips for [AppSettings.adapterResponseTimeoutMs]:
/// "Adapter default" (null, no `ATST` sent) or one of the fixed ms values.
class _AdapterResponseTimeoutSetting extends StatelessWidget {
  const _AdapterResponseTimeoutSetting({
    required this.value,
    required this.onChanged,
  });

  static const _options = <int?>[null, 50, 100, 150, 200];

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Adapter response timeout (ATST)'),
          const Text(
            'Too short can miss a slow ECU behind the gateway.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final option in _options)
                ChoiceChip(
                  label: Text(
                    option == null ? 'Adapter default' : '$option ms',
                  ),
                  selected: value == option,
                  onSelected: (_) => onChanged(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IntSliderSetting extends StatelessWidget {
  const _IntSliderSetting({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.formatValue,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final int value;
  final int min;
  final int max;
  final int divisions;
  final String Function(int value) formatValue;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                formatValue(value),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          if (subtitle != null)
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            label: formatValue(value),
            onChanged: (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}
