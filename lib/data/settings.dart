import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a remote (optional) model is served from. String keys survive obfuscation.
enum RemoteProvider {
  gemini('gemini'),
  openAiCompatible('openai');

  const RemoteProvider(this.key);
  final String key;

  static RemoteProvider fromKey(String? key) =>
      RemoteProvider.values.firstWhere((p) => p.key == key, orElse: () => RemoteProvider.gemini);
}

/// Non-secret preferences. Secrets (API key, PIN hash) live in SecureStore.
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs);

  final SharedPreferences _prefs;

  static const defaultGeminiModel = 'gemini-3.8-flash';

  static Future<SettingsController> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsController(prefs);
  }

  T _get<T>(String key, T fallback) {
    final v = _prefs.get(key);
    return v is T ? v : fallback;
  }

  Future<void> _set(String key, Object? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is double) {
      await _prefs.setDouble(key, value);
    } else if (value is String) {
      await _prefs.setString(key, value);
    }
    notifyListeners();
  }

  // ---- appearance ----
  String get languageCode => _get('languageCode', 'fa');
  Future<void> setLanguageCode(String code) => _set('languageCode', code);
  Locale get locale => languageCode == 'en' ? const Locale('en') : const Locale('fa', 'IR');

  ThemeMode get themeMode => switch (_get('themeMode', 'system')) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
  Future<void> setThemeMode(ThemeMode mode) => _set(
        'themeMode',
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        },
      );

  // ---- first run ----
  bool get onboardingDone => _get('onboardingDone', false);
  Future<void> setOnboardingDone(bool v) => _set('onboardingDone', v);

  // ---- local engine ----
  /// File name (inside the models dir) of the model the user picked.
  String? get activeModelFile => _prefs.getString('activeModelFile');
  Future<void> setActiveModelFile(String? f) => _set('activeModelFile', f);

  int get threads => _get('threads', 4);
  Future<void> setThreads(int v) => _set('threads', v);

  int get contextSize => _get('contextSize', 2048);
  Future<void> setContextSize(int v) => _set('contextSize', v);

  double get temperature => _get('temperature', 0.7);
  Future<void> setTemperature(double v) => _set('temperature', v);

  int get maxTokens => _get('maxTokens', 512);
  Future<void> setMaxTokens(int v) => _set('maxTokens', v);

  int get agentMaxSteps => _get('agentMaxSteps', 4);
  Future<void> setAgentMaxSteps(int v) => _set('agentMaxSteps', v);

  bool get engineTuned => _get('engineTuned', false);
  Future<void> setEngineTuned(bool v) => _set('engineTuned', v);

  // ---- optional remote API ----
  bool get useRemote => _get('useRemote', false);
  Future<void> setUseRemote(bool v) => _set('useRemote', v);

  RemoteProvider get remoteProvider => RemoteProvider.fromKey(_prefs.getString('remoteProvider'));
  Future<void> setRemoteProvider(RemoteProvider p) => _set('remoteProvider', p.key);

  String get remoteBaseUrl => _get('remoteBaseUrl', '');
  Future<void> setRemoteBaseUrl(String v) => _set('remoteBaseUrl', v.trim());

  String get remoteModel => _get('remoteModel', defaultGeminiModel);
  Future<void> setRemoteModel(String v) => _set('remoteModel', v.trim());

  // ---- skills ----
  String? get activeSkillId => _prefs.getString('activeSkillId');
  Future<void> setActiveSkillId(String? id) => _set('activeSkillId', id);

  // ---- studio ----
  /// Heavy work (image generation, video rendering) only while charging or above the battery level.
  bool get heavyWorkPowerRule => _get('heavyWorkPowerRule', true);
  Future<void> setHeavyWorkPowerRule(bool v) => _set('heavyWorkPowerRule', v);

  int get heavyWorkMinBattery => _get('heavyWorkMinBattery', 50);
  Future<void> setHeavyWorkMinBattery(int v) => _set('heavyWorkMinBattery', v.clamp(10, 90));

  /// Id from imageModelCatalog.
  String get imageModelId => _get('imageModelId', 'sd-turbo-q8');
  Future<void> setImageModelId(String v) => _set('imageModelId', v);

  /// Page handle printed on templates, e.g. "@my.page".
  String get studioFooter => _get('studioFooter', '');
  Future<void> setStudioFooter(String v) => _set('studioFooter', v.trim());

  // ---- app lock ----
  bool get lockEnabled => _get('lockEnabled', false);
  Future<void> setLockEnabled(bool v) => _set('lockEnabled', v);

  bool get biometricEnabled => _get('biometricEnabled', false);
  Future<void> setBiometricEnabled(bool v) => _set('biometricEnabled', v);
}
