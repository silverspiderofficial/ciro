/// The Studio's single entry point, used by the Studio tab and by the agent's tools:
/// image generation (with the template fallback for weak phones), template export, video
/// rendering, saving to the gallery and to drafts. It enforces the power rule, wraps heavy
/// work in the platform's keep-alive (Android foreground service) and allows one job at a time.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/native_bridge.dart';
import '../data/device_info.dart';
import '../data/repositories.dart';
import '../data/settings.dart';
import '../llm/llm_backend.dart' show CancelToken;
import 'image/image_engine.dart';
import 'platform/studio_platform.dart';
import 'studio_assets.dart';
import 'studio_catalog.dart';
import 'studio_errors.dart';
import 'templates/templates.dart';
import 'tts/tts_engine.dart';
import 'video/video_project.dart';
import 'video/ffmpeg_runner.dart';
import 'video/video_renderer.dart';

enum StudioJobKind { image, template, video }

class StudioJob {
  const StudioJob(this.kind, this.phase, this.fraction);
  final StudioJobKind kind;

  /// image: loading | sampling | decoding; video: voice | frames | encode; template: render
  final String phase;
  final double? fraction;
}

class StudioService extends ChangeNotifier {
  StudioService({
    required this.platform,
    required this.imageEngine,
    required this.tts,
    required this.assets,
    required this.settings,
    required this.bridge,
    required this.drafts,
    this.onAiProcessUsed,
  });

  final StudioPlatform platform;
  final ImageEngine imageEngine;
  final TtsEngine tts;
  final StudioAssetManager assets;
  final SettingsController settings;
  final NativeBridge bridge;
  final DraftsRepository drafts;

  /// Called after the ":ai" process ran an image model (it unloads the chat model to keep one
  /// heavy model in memory), so the chat engine can update its state.
  final VoidCallback? onAiProcessUsed;

  DeviceInfo? device;
  StudioJob? job;
  CancelToken? _cancel;
  VideoRenderer? _renderer;
  Directory? _dir;

  bool get busy => job != null;

  Future<void> init() async {
    device = await bridge.deviceInfo();
    _dir = await platform.studioDir();
    await assets.init();
  }

  Future<Directory> outputsDir() async {
    final d = Directory(p.join((_dir ??= await platform.studioDir()).path, 'outputs'));
    await d.create(recursive: true);
    return d;
  }

  String _stamp() => DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);

  StudioAssetSpec get imageModel => studioAssetById(settings.imageModelId) ?? imageModelCatalog.first;

  ImageGenBlocker get imageBlocker =>
      imageGenBlocker(device: device, model: imageModel, installed: assets.isInstalled(imageModel));

  bool get canGenerateImages => imageBlocker == ImageGenBlocker.none;

  void _setJob(StudioJob? j) {
    job = j;
    notifyListeners();
  }

  Future<void> _checkPower() async {
    final status = await platform.powerStatus();
    if (!heavyWorkAllowed(status, enforce: settings.heavyWorkPowerRule, minLevel: settings.heavyWorkMinBattery)) {
      throw StudioException('power_blocked', '${status.level}');
    }
  }

  Future<T> _heavy<T>(StudioJobKind kind, String title, Future<T> Function() work) async {
    if (busy) throw const StudioException('busy');
    await _checkPower();
    _cancel = CancelToken();
    _setJob(StudioJob(kind, 'start', null));
    try {
      await platform.beginHeavyWork(title);
    } on Object {
      // Keep-alive is best effort (e.g. notification permission denied).
    }
    try {
      return await work();
    } finally {
      _cancel = null;
      _setJob(null);
      try {
        await platform.endHeavyWork();
      } on Object {
        // ignore
      }
    }
  }

  void _progress(StudioJobKind kind, String phase, double? fraction, String notification) {
    _setJob(StudioJob(kind, phase, fraction));
    unawaited(platform.updateHeavyWork(notification, fraction).catchError((Object _) {}));
  }

  Future<void> cancel() async {
    _cancel?.cancel();
    _renderer?.cancel();
    if (job?.kind == StudioJobKind.image) await imageEngine.cancel();
  }

  /// Generates a 512x512 image on the device. Throws [StudioException].
  Future<String> generateImage({
    required String prompt,
    String negative = '',
    int steps = 0,
    double cfg = 0,
    int seed = -1,
    int width = 512,
    int height = 512,
    bool force = false,
  }) async {
    final blocker = imageBlocker;
    if (blocker == ImageGenBlocker.noModel) throw const StudioException('no_model');
    if (blocker != ImageGenBlocker.none) throw StudioException('device_unsupported', blocker.name);
    final model = imageModel;
    final modelPath = assets.pathOf(model.primary);
    final taesd = assets.pathOf(taesdFile) ?? '';
    if (modelPath == null) throw const StudioException('no_model');
    return _heavy(StudioJobKind.image, 'Kiro', () async {
      final out = p.join((await outputsDir()).path, 'image_${_stamp()}.png');
      final request = ImageRequest(
        prompt: prompt,
        negativePrompt: negative,
        modelPath: modelPath,
        taesdPath: taesd,
        outPath: out,
        width: width,
        height: height,
        steps: steps > 0 ? steps : model.defaultSteps,
        cfg: cfg > 0 ? cfg : model.defaultCfg,
        seed: seed,
        threads: _threads(),
        force: force,
      );
      try {
        await for (final e in imageEngine.generate(request)) {
          switch (e) {
            case ImageProgress():
              _progress(StudioJobKind.image, e.phase, e.fraction, e.phase == 'loading' ? '…' : '${e.step}/${e.steps}');
            case ImageDone():
              return e.path;
            case ImageFailed():
              throw StudioException(e.code, e.code == 'low_ram' ? '${e.availBytes ?? 0}/${e.needBytes ?? 0}' : '');
          }
        }
        throw const StudioException('generate_failed');
      } finally {
        if (Platform.isAndroid) onAiProcessUsed?.call();
      }
    });
  }

  int _threads() {
    final d = device;
    if (d == null) return (Platform.numberOfProcessors ~/ 2).clamp(1, 8);
    final big = d.bigCores > 0 ? d.bigCores : d.cores ~/ 2;
    return big.clamp(1, 6);
  }

  Future<String> exportTemplate(TemplateData data) async {
    if (busy) throw const StudioException('busy');
    _setJob(const StudioJob(StudioJobKind.template, 'render', null));
    try {
      final png = await renderTemplate(data.footer.isEmpty && settings.studioFooter.isNotEmpty ? data.copyWith(footer: settings.studioFooter) : data);
      final out = p.join((await outputsDir()).path, 'template_${data.kind.key}_${_stamp()}.png');
      await File(out).writeAsBytes(png, flush: true);
      return out;
    } finally {
      _setJob(null);
    }
  }

  Future<VoiceFiles?> _voiceFiles(NarratorVoice voice) async {
    final spec = studioAssetById(voice.key);
    if (spec == null || !assets.isInstalled(spec)) return null;
    final model = assets.pathOf(spec.files[0]);
    final tokens = assets.pathOf(spec.files[1]);
    if (model == null || tokens == null) return null;
    final dir = _dir ??= await platform.studioDir();
    return VoiceFiles(model: model, tokens: tokens, dataDir: await ensureEspeakData(dir.path));
  }

  Future<String> renderVideo(VideoProject project) => _heavy(StudioJobKind.video, 'Kiro', () async {
        final dir = _dir ??= await platform.studioDir();
        final renderer = VideoRenderer(
          ffmpegPath: platform.ffmpegPath,
          tts: tts,
          voiceFiles: _voiceFiles,
          workRoot: p.join(dir.path, 'work'),
        );
        _renderer = renderer;
        final out = p.join((await outputsDir()).path, 'video_${_stamp()}.mp4');
        try {
          return await renderer.render(project, out, cancel: _cancel, onProgress: (phase, f) {
            _progress(StudioJobKind.video, phase, f, f == null ? '…' : '${(f * 100).round()}%');
          });
        } finally {
          _renderer = null;
        }
      });

  /// For weak phones or when no image model is installed: a title card with the topic.
  Future<String> templateFallback(String title, {String subtitle = '', TemplateFormat format = TemplateFormat.portrait}) =>
      exportTemplate(TemplateData(
        kind: TemplateKind.title,
        title: title,
        body: subtitle,
        format: format,
        paletteId: templatePalettes[title.length % templatePalettes.length].id,
      ));

  Future<String?> saveToGallery(String path) {
    final video = path.toLowerCase().endsWith('.mp4');
    return platform.saveToGallery(path, video: video, displayName: 'kiro_${_stamp()}${video ? '.mp4' : '.png'}');
  }

  /// Poster frame stored next to a rendered video, shown in the drafts list.
  static String videoThumbPath(String video) => '$video.thumb.png';

  /// Best effort: a missing FFmpeg or a failed extraction just leaves the draft without a poster.
  Future<void> _makeVideoThumb(String video) async {
    FfmpegRunner? runner;
    try {
      final exe = await platform.ffmpegPath();
      if (exe == null) return;
      runner = FfmpegRunner(exe);
      await runner.run([
        '-hide_banner', '-loglevel', 'error', '-y',
        '-ss', '0.5', '-i', video,
        '-frames:v', '1', '-vf', 'scale=320:-2', '-c:v', 'png', '-f', 'image2',
        videoThumbPath(video),
      ]).timeout(const Duration(seconds: 20));
    } on Object {
      runner?.cancel();
    }
  }

  Future<int> saveMediaDraft({required String title, required String path, String caption = '', String? extra}) async {
    final video = path.toLowerCase().endsWith('.mp4');
    if (video && !await File(videoThumbPath(path)).exists()) await _makeVideoThumb(path);
    return drafts.add(Draft(
      title: title.isEmpty ? p.basename(path) : title,
      content: '',
      caption: caption,
      mediaPath: path,
      mediaType: video ? 'video' : 'image',
      extra: extra,
      createdAt: DateTime.now(),
    ));
  }

  /// Most recent files the user made (newest first), for the video timeline's image picker.
  Future<List<String>> recentImages({int limit = 40}) async {
    final d = await outputsDir();
    final files = <File>[];
    await for (final e in d.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.png')) files.add(e);
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.take(limit).map((f) => f.path).toList();
  }

  Future<String?> importImage() async {
    final d = await outputsDir();
    return platform.pickImage(d.path);
  }
}
