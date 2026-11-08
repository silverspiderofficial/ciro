/// The Studio's single entry point, used by the Studio tab and by the agent's tools:
/// image generation (with the template fallback for weak phones), template export, video
/// rendering, saving to the gallery and to drafts. It enforces the power rule, wraps heavy
/// work in the platform's keep-alive (Android foreground service) and allows one job at a time.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../billing/billing.dart';

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
import 'video/ffmpeg_command.dart';
import 'video/video_project.dart';
import 'video/ffmpeg_runner.dart';
import 'video/video_renderer.dart';

enum StudioJobKind { image, template, video }

class StudioJob {
  const StudioJob(this.kind, this.phase, this.fraction, {this.detail = ''});
  final StudioJobKind kind;

  /// image: loading | sampling | decoding; video: voice | frames | encode | clip | stitch;
  /// template: render
  final String phase;
  final double? fraction;

  /// Extra progress text shown next to the phase (e.g. "3/6" clips). Never user content.
  final String detail;
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
    this.billing,
    this.loadAsset,
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

  /// Pay-per-video credit. Null when billing could not be opened: paid video is then disabled
  /// (the rest of the Studio keeps working).
  BillingService? billing;

  /// Asset loader for background music (tests override it).
  final Future<ByteData> Function(String key)? loadAsset;
  bool _imageActive = false;
  FfmpegRunner? _stitchRunner;

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
    await _cleanPaidWork();
  }

  /// Removes work folders left by a paid render that was killed (best effort). Its credit
  /// reservation is released by the billing ledger on startup.
  Future<void> _cleanPaidWork() async {
    try {
      final work = Directory(p.join(_dir!.path, 'work'));
      if (!await work.exists()) return;
      await for (final e in work.list()) {
        if (e is Directory && p.basename(e.path).startsWith('paid_')) {
          try {
            await e.delete(recursive: true);
          } on FileSystemException {
            // ignore
          }
        }
      }
    } on Object {
      // ignore
    }
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

  void _progress(StudioJobKind kind, String phase, double? fraction, String notification, {String detail = ''}) {
    _setJob(StudioJob(kind, phase, fraction, detail: detail));
    unawaited(platform.updateHeavyWork(notification, fraction).catchError((Object _) {}));
  }

  Future<void> cancel() async {
    _cancel?.cancel();
    _renderer?.cancel();
    _stitchRunner?.cancel();
    if (job?.kind == StudioJobKind.image || _imageActive) {
      try {
        await imageEngine.cancel();
      } on Object {
        // ignore
      }
    }
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
      return _runImage(
        ImageRequest(
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
        ),
        onProgress: (e) => _progress(StudioJobKind.image, e.phase, e.fraction, e.phase == 'loading' ? '…' : '${e.step}/${e.steps}'),
      );
    });
  }

  /// Runs one image request on the engine. Throws [StudioException].
  Future<String> _runImage(ImageRequest request, {required void Function(ImageProgress e) onProgress}) async {
    _imageActive = true;
    try {
      await for (final e in imageEngine.generate(request)) {
        switch (e) {
          case ImageProgress():
            onProgress(e);
          case ImageDone():
            return e.path;
          case ImageFailed():
            if (_cancel?.isCancelled ?? false) throw const StudioException('cancelled');
            throw StudioException(e.code, e.code == 'low_ram' ? '${e.availBytes ?? 0}/${e.needBytes ?? 0}' : '');
        }
      }
      throw const StudioException('generate_failed');
    } finally {
      _imageActive = false;
      if (Platform.isAndroid) onAiProcessUsed?.call();
    }
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

  /// Why a paid topic video cannot start right now, as a [StudioException] code, or null when
  /// it can. Checked before any credit is reserved, so a blocked render never costs anything.
  String? get paidVideoBlocker {
    if (billing == null) return 'billing_unavailable';
    final b = imageBlocker;
    if (b == ImageGenBlocker.noModel) return 'no_model';
    if (b != ImageGenBlocker.none) return 'device_unsupported';
    return null;
  }

  /// Paid video from a topic: reserves the price of [duration] once, generates one picture per
  /// ~10 s clip ([planSegments]), renders each clip with the FFmpeg pipeline, joins them into
  /// one 9:16 video and lays the music over it. The credit is spent only when the video is
  /// finished; any error or cancel releases it (and a crash is released on the next start).
  /// Throws [StudioException] only.
  Future<String> renderTopicVideo({
    required String topic,
    required Duration duration,
    String musicTrackId = 'none',
    double musicVolume = 0.35,
  }) async {
    final blocker = paidVideoBlocker;
    if (blocker != null) throw StudioException(blocker);
    final b = billing!;
    final tier = b.priceFor(duration);
    if (tier == null) throw const StudioException('billing_unsupportedDuration');
    final segments = planSegments(topic, tier.duration);
    if (segments.isEmpty) throw const StudioException('no_topic');
    if (busy) throw const StudioException('busy');
    await _checkPower();
    final String? ffmpeg;
    try {
      ffmpeg = await platform.ffmpegPath();
    } on Object {
      throw const StudioException('no_ffmpeg');
    }
    if (ffmpeg == null) throw const StudioException('no_ffmpeg');

    final BillingResult<Reservation> reserved;
    try {
      reserved = await b.reserve(tier.duration);
    } on Object catch (e) {
      throw StudioException('billing_storage', e.runtimeType.toString());
    }
    final reservation = switch (reserved) {
      Ok(:final value) => value,
      Err(:final error) => throw StudioException('billing_${error.code.name}'),
    };
    var settled = false;
    try {
      final path = await _heavy(StudioJobKind.video, 'Kiro', () => _renderSegments(segments, ffmpeg!, musicTrackId, musicVolume));
      settled = true;
      try {
        await b.commit(reservation.id);
      } on Object {
        // The video exists; an unrecorded spend is released on the next start (lenient).
      }
      return path;
    } on StudioException {
      rethrow;
    } on Object catch (e) {
      throw StudioException('render_failed', e.runtimeType.toString());
    } finally {
      if (!settled) {
        try {
          await b.release(reservation.id);
        } on Object {
          // Released on the next start by the ledger's reconcile.
        }
      }
    }
  }

  static const _clipMotions = [CameraMotion.zoomIn, CameraMotion.panLeft, CameraMotion.zoomOut, CameraMotion.panRight];

  Future<String> _renderSegments(List<SegmentPrompt> segments, String ffmpeg, String musicTrackId, double musicVolume) async {
    final dir = _dir ??= await platform.studioDir();
    final work = Directory(p.join(dir.path, 'work', 'paid_${DateTime.now().millisecondsSinceEpoch}'));
    await work.create(recursive: true);
    final cancel = _cancel;
    void checkCancel() {
      if (cancel?.isCancelled ?? false) throw const StudioException('cancelled');
    }

    final n = segments.length;
    // Share of the bar per clip: picture 60 %, clip encode 40 %; joining takes the last 5 %.
    double overall(int i, double part) => ((i + part.clamp(0.0, 1.0)) / n) * 0.95;
    try {
      final model = imageModel;
      final modelPath = assets.pathOf(model.primary);
      if (modelPath == null) throw const StudioException('no_model');
      final taesd = assets.pathOf(taesdFile) ?? '';
      final clips = <String>[];
      for (var i = 0; i < n; i++) {
        checkCancel();
        final seg = segments[i];
        final detail = '${i + 1}/$n';
        _progress(StudioJobKind.video, 'clip', overall(i, 0), detail, detail: detail);
        final image = await _runImage(
          ImageRequest(
            prompt: seg.prompt,
            negativePrompt: 'text, watermark, logo, blurry, low quality',
            modelPath: modelPath,
            taesdPath: taesd,
            outPath: p.join(work.path, 'img_$i.png'),
            width: 512,
            height: 512,
            steps: model.defaultSteps,
            cfg: model.defaultCfg,
            seed: -1,
            threads: _threads(),
          ),
          onProgress: (e) => _progress(StudioJobKind.video, 'clip', overall(i, (e.fraction ?? 0) * 0.6), detail, detail: detail),
        );
        checkCancel();
        final clip = p.join(work.path, 'clip_$i.mp4');
        final renderer = VideoRenderer(
          ffmpegPath: () async => ffmpeg,
          tts: tts,
          voiceFiles: _voiceFiles,
          workRoot: work.path,
        );
        _renderer = renderer;
        try {
          await renderer.render(
            VideoProject(
              scenes: [
                VideoScene(
                  imagePath: image,
                  durationSeconds: seg.duration.inMilliseconds / 1000,
                  motion: _clipMotions[i % _clipMotions.length],
                ),
              ],
              subtitles: false,
            ),
            clip,
            cancel: cancel,
            onProgress: (phase, f) => _progress(StudioJobKind.video, 'clip', overall(i, 0.6 + (f ?? 0) * 0.4), detail, detail: detail),
          );
        } finally {
          _renderer = null;
        }
        clips.add(clip);
        try {
          await File(image).delete();
        } on FileSystemException {
          // ignore
        }
      }
      checkCancel();

      _progress(StudioJobKind.video, 'stitch', 0.95, '…');
      final out = p.join((await outputsDir()).path, 'video_${_stamp()}.mp4');
      final list = p.join(work.path, 'clips.ffconcat');
      await File(list).writeAsString(buildClipConcatList([for (final c in clips) p.basename(c)]));
      final track = musicById(musicTrackId);
      final total = segments.fold<int>(0, (s, x) => s + x.duration.inMilliseconds) / 1000;
      if (track == null) {
        await _runStitch(ffmpeg, buildConcatArgs(list, out), cancel);
      } else {
        final joined = p.join(work.path, 'joined.mp4');
        await _runStitch(ffmpeg, buildConcatArgs(list, joined), cancel);
        checkCancel();
        final data = await (loadAsset ?? rootBundle.load)(track.asset);
        final music = p.join(work.path, p.basename(track.asset));
        await File(music).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        await _runStitch(
          ffmpeg,
          buildMusicMuxArgs(videoPath: joined, musicPath: music, musicVolume: musicVolume, totalSeconds: total, outputPath: out),
          cancel,
        );
      }
      if (!await File(out).exists()) throw const StudioException('render_failed', 'no output');
      return out;
    } finally {
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // best effort
      }
    }
  }

  Future<void> _runStitch(String ffmpeg, List<String> args, CancelToken? cancel) async {
    final runner = FfmpegRunner(ffmpeg);
    _stitchRunner = runner;
    cancel?.onCancel(runner.cancel);
    try {
      await runner.run(args);
    } on FfmpegException catch (e) {
      if (e.code == 'cancelled') throw const StudioException('cancelled');
      throw StudioException(e.code == 'missing' ? 'no_ffmpeg' : 'render_failed', e.detail);
    } finally {
      _stitchRunner = null;
    }
  }

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
