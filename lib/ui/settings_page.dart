import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import '../settings/settings_repository.dart';

/// Settings only configure the recording — none of them block the owner
/// from starting, stopping, or sharing a recording regardless of what's
/// set here.
class SettingsPage extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  SettingsPage({super.key, SettingsRepository? repository})
    : repository = repository ?? const SettingsRepository();

  final SettingsRepository repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings? _settings;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await widget.repository.load();
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
                _IntSliderSetting(
                  label: 'Max reads per second',
                  subtitle:
                      'The adapter manages about 6–8 reads per second over '
                      'BLE.',
                  value: settings.maxReadsPerSecond,
                  min: 1,
                  max: 8,
                  divisions: 7,
                  formatValue: (v) => '$v',
                  onChanged: (v) =>
                      _update((s) => s.copyWith(maxReadsPerSecond: v)),
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
                          'The recurring plan reads only the speed signal '
                          'plus whatever discovery finds -- no vag-ppe or '
                          'fixed vehicle signals.',
                        ),
                        value: RecordingMode.scoutOnly,
                      ),
                      RadioListTile<RecordingMode>(
                        title: Text('Scout and record known signals'),
                        subtitle: Text(
                          'The recurring plan also reads every known '
                          'vag-ppe DID plus the fixed energy/range/'
                          'odometer/outside-temperature/12V/accelerator '
                          'signals.',
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
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
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
