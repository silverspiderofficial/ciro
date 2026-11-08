/// Renders a [VideoProject] to an H.264/AAC MP4 (1080x1920, 30 fps):
/// narrator voice (TTS) -> timeline -> Flutter-drawn stills and text layers -> FFmpeg.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../llm/llm_backend.dart' show CancelToken;
import '../studio_catalog.dart';
import '../studio_errors.dart';
import '../tts/tts_engine.dart';
import 'ffmpeg_command.dart';
import 'ffmpeg_runner.dart';
import 'frame_renderer.dart';
import 'timeline.dart';
import 'video_project.dart';
import 'wav.dart';

/// Reading time used for subtitles when there is no narrator (about 13 characters/second).
double estimateReadingSeconds(String text) {
  final chars = text.replaceAll(RegExp(r'\s+'), '').length;
  if (chars == 0) return 0;
  return (chars / 13.0).clamp(1.2, 20.0);
}

typedef RenderProgress = void Function(String phase, double? fraction);

class VideoRenderer {
  VideoRenderer({
    required this.ffmpegPath,
    required this.tts,
    required this.voiceFiles,
    required this.workRoot,
    this.loadAsset = _loadAsset,
  });

  /// Resolved lazily (Android: nativeLibraryDir; desktop: bundled or PATH).
  final Future<String?> Function() ffmpegPath;
  final TtsEngine tts;

  /// Files of a voice, or null when that voice is not downloaded.
  final Future<VoiceFiles?> Function(NarratorVoice voice) voiceFiles;
  final String workRoot;
  final Future<ByteData> Function(String key) loadAsset;

  static Future<ByteData> _loadAsset(String key) => rootBundle.load(key);

  FfmpegRunner? _runner;

  void cancel() => _runner?.cancel();

  Future<String> render(VideoProject project, String outPath, {RenderProgress? onProgress, CancelToken? cancel}) async {
    if (project.scenes.isEmpty) throw const StudioException('no_scenes');
    for (final s in project.scenes) {
      if (!await File(s.imagePath).exists()) throw StudioException('missing_image', s.imagePath);
    }
    final ffmpeg = await ffmpegPath();
    if (ffmpeg == null) throw const StudioException('no_ffmpeg');

    final work = Directory(p.join(workRoot, 'render_${DateTime.now().millisecondsSinceEpoch}'));
    await work.create(recursive: true);
    void checkCancel() {
      if (cancel?.isCancelled ?? false) throw const StudioException('cancelled');
    }

    try {
      // ---- narration ----
      final narrations = project.scenes.map((s) => s.narration.trim()).toList();
      final hasSpeech = project.voice != NarratorVoice.none && narrations.any((n) => n.isNotEmpty);
      var durations = narrations.map((n) => project.subtitles ? estimateReadingSeconds(n) : 0.0).toList();
      List<PcmAudio>? clips;
      if (hasSpeech) {
        onProgress?.call('voice', null);
        final voice = await voiceFiles(project.voice);
        if (voice == null) throw const StudioException('no_voice');
        clips = await tts.synthesizeAll(narrations, voice, speed: project.speechSpeed);
        durations = clips.map((c) => c.seconds).toList();
      }
      checkCancel();
      final plan = planTimeline(project, durations);

      String? narrationPath;
      if (clips != null && clips.any((c) => c.samples.isNotEmpty)) {
        final track = layoutTrack(
          [
            for (var i = 0; i < clips.length; i++)
              if (clips[i].samples.isNotEmpty) (start: plan.scenes[i].narrationStart, audio: clips[i]),
          ],
          plan.totalSeconds,
          clips.firstWhere((c) => c.samples.isNotEmpty).sampleRate,
        );
        narrationPath = p.join(work.path, 'narration.wav');
        await writeWavFile(narrationPath, track);
      }

      // ---- stills and text layers ----
      final stills = <String>[];
      for (var i = 0; i < project.scenes.length; i++) {
        onProgress?.call('frames', i / project.scenes.length);
        final out = p.join(work.path, 'scene_$i.png');
        await renderSceneStill(project.scenes[i].imagePath, out);
        stills.add(out);
        checkCancel();
      }
      final overlays = <TextOverlay>[];
      for (var i = 0; i < project.scenes.length; i++) {
        final text = project.scenes[i].overlayText.trim();
        if (text.isEmpty) continue;
        final out = p.join(work.path, 'title_$i.png');
        await renderTitleOverlay(text, out);
        overlays.add(TextOverlay(pngPath: out, start: plan.scenes[i].textStart, end: plan.scenes[i].textEnd));
      }
      String? subtitleList;
      if (project.subtitles) {
        final cues = buildSubtitleCues(plan, narrations);
        if (cues.isNotEmpty) {
          await renderTransparent(p.join(work.path, 'blank.png'));
          final names = <String>[];
          for (var i = 0; i < cues.length; i++) {
            final name = 'sub_$i.png';
            await renderSubtitle(cues[i].text, p.join(work.path, name));
            names.add(name);
          }
          subtitleList = p.join(work.path, 'subs.ffconcat');
          await File(subtitleList).writeAsString(buildSubtitleConcatList(cues, names, 'blank.png', plan.totalSeconds));
        }
      }
      checkCancel();

      // ---- music ----
      String? musicPath;
      final track = musicById(project.musicTrackId);
      if (track != null) {
        final data = await loadAsset(track.asset);
        musicPath = p.join(work.path, p.basename(track.asset));
        await File(musicPath).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }

      // ---- encode ----
      final args = buildFfmpegArgs(RenderInputs(
        scenePngs: stills,
        motions: resolveMotions(project.scenes.map((s) => s.motion).toList()),
        transitions: project.scenes.map((s) => s.transition).toList(),
        plan: plan,
        outputPath: outPath,
        subtitleListPath: subtitleList,
        textOverlays: overlays,
        narrationWavPath: narrationPath,
        musicPath: musicPath,
        musicVolume: project.musicVolume,
      ));
      final runner = FfmpegRunner(ffmpeg);
      _runner = runner;
      cancel?.onCancel(runner.cancel);
      onProgress?.call('encode', 0);
      try {
        await runner.run(args, totalSeconds: plan.totalSeconds, onProgress: (f) => onProgress?.call('encode', f));
      } on FfmpegException catch (e) {
        if (e.code == 'cancelled') throw const StudioException('cancelled');
        throw StudioException(e.code == 'missing' ? 'no_ffmpeg' : 'render_failed', e.detail);
      } finally {
        _runner = null;
      }
      return outPath;
    } finally {
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // best effort
      }
    }
  }
}
