import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

/// Reads/writes the single [AppSettings] blob to `shared_preferences`.
class SettingsRepository {
  const SettingsRepository();

  static const _key = 'didscout_app_settings_v1';

  /// Falls back to [AppSettings.defaultValues] both when nothing has ever
  /// been saved and when the stored value can't be decoded (a corrupt blob,
  /// or one from an incompatible future version) — a settings-store problem
  /// must never stop the app from launching.
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const AppSettings.defaultValues();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings.defaultValues();
    }
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }

  Future<void> resetToDefaults() => save(const AppSettings.defaultValues());
}
