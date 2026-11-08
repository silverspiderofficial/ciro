import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/native_bridge.dart';
import '../data/device_info.dart';
import '../data/model_catalog.dart';
import '../data/model_manager.dart';
import '../data/repositories.dart';
import '../data/secure_store.dart';
import '../data/settings.dart';
import '../llm/llm_backend.dart';
import '../llm/local_backend.dart';
import '../llm/remote_backend.dart';
import '../skills/skill_repository.dart';
import '../studio/image/image_engine.dart';
import '../studio/platform/studio_platform.dart';
import '../studio/studio_assets.dart';
import '../studio/studio_service.dart';
import '../studio/tts/tts_engine.dart';

/// Integrity status shared with the UI; sensitive features check [apiAllowed].
class SecurityState extends ChangeNotifier {
  SecurityStatus status = SecurityStatus.clean;
  bool warningShown = false;

  bool get apiAllowed => !status.compromised;

  void update(SecurityStatus s) {
    status = s;
    notifyListeners();
  }
}

/// Everything the app needs, created once at startup (or with fakes in tests).
class AppServices {
  AppServices({
    required this.bridge,
    required this.settings,
    required this.secure,
    required this.chats,
    required this.drafts,
    required this.skills,
    required this.engine,
    required this.models,
    required this.security,
    this.studio,
  });

  final NativeBridge bridge;
  final SettingsController settings;
  final SecureStore secure;
  final ChatRepository chats;
  final DraftsRepository drafts;
  final SkillRepository skills;
  final LocalEngine engine;
  final ModelManager models;
  final SecurityState security;

  /// Image, template and video work (null only in tests that do not need it).
  final StudioService? studio;

  static Future<AppServices> create() async {
    final bridge = NativeBridge();
    final settings = await SettingsController.load();
    final db = await KiroDatabase.open();
    final support = await getApplicationSupportDirectory();
    final skills = SkillRepository(DirectorySkillStorage(Directory(p.join(support.path, 'skills'))));
    await skills.init();
    final models = ModelManager(bridge);
    await models.init();
    final engine = LocalEngine(bridge);
    await engine.refreshStatus();
    final security = SecurityState()..update(await bridge.security());
    final db2 = db;
    final studio = StudioService(
      platform: StudioPlatform.create(),
      imageEngine: ImageEngine.create(),
      tts: SherpaTtsEngine(),
      assets: StudioAssetManager(Platform.isAndroid ? NativeAssetDownloader(bridge) : HttpAssetDownloader()),
      settings: settings,
      bridge: bridge,
      drafts: db2,
      onAiProcessUsed: engine.markUnloadedByStudio,
    );
    await studio.init();
    final services = AppServices(
      bridge: bridge,
      settings: settings,
      secure: KeystoreSecureStore(),
      chats: db,
      drafts: db,
      skills: skills,
      engine: engine,
      models: models,
      security: security,
      studio: studio,
    );
    engine.autoReload = () => services.ensureModelLoaded();
    await services._tuneEngineOnce();
    return services;
  }

  /// First launch: pick threads and context from the hardware.
  Future<void> _tuneEngineOnce() async {
    if (settings.engineTuned) return;
    final info = await bridge.deviceInfo();
    if (info == null) return;
    await settings.setThreads(recommendedThreads(info));
    await settings.setContextSize(recommendedContext(info));
    await settings.setEngineTuned(true);
  }

  GenerationOptions get generationOptions =>
      GenerationOptions(maxTokens: settings.maxTokens, temperature: settings.temperature);

  /// The backend the agent should use right now: the user's API when enabled, allowed and
  /// configured; otherwise the on-device engine.
  Future<LlmBackend> resolveBackend() async {
    if (settings.useRemote && security.apiAllowed) {
      final key = await secure.read(SecureStore.apiKey);
      if (key != null && key.isNotEmpty) {
        return RemoteBackend(
          provider: settings.remoteProvider,
          apiKey: key,
          model: settings.remoteModel,
          baseUrl: settings.remoteBaseUrl,
        );
      }
    }
    return engine;
  }

  /// Loads the active model when the local engine is idle. Returns an error code or null.
  Future<String?> ensureModelLoaded({bool force = false}) async {
    final file = models.fileFor(settings.activeModelFile);
    if (file == null) return 'no_model';
    if (engine.isReady && engine.loadedPath == file.path) return null;
    return engine.load(file.path, nCtx: settings.contextSize, threads: settings.threads, force: force);
  }
}
