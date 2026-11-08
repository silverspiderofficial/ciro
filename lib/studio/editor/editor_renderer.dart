/// Renders an [EditProject] to MP4 (H.264/AAC): Flutter draws stills, text and subtitles,
/// the on-device narrator speaks the narration, and FFmpeg does the rest in one pass.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../llm/llm_backend.dart' show CancelToken;
import '../studio_catalog.dart';
import '../studio_errors.dart';
import '../tts/tts_engine.dart';
import '../video/ffmpeg_command.dart' show TextOverlay, buildSubtitleConcatList;
import '../video/ffmpeg_runner.dart';
import '../video/timeline.dart' show SubtitleCue;
import '../video/video_project.dart' show NarratorVoice;
import '../video/wav.dart';
import 'edit_project.dart';
import 'editor_command.dart';
import 'editor_frames.dart';

typedef EditProgress = void Function(String phase, double? fraction);

/// Previews show at most this many seconds (half size, watermarked).
const double previewSeconds = 20;

/// The first [seconds] of [project] (clips after that are dropped, the last one trimmed).
EditProject cutForPreview(EditProject project, {double seconds = previewSeconds}) {
  if (project.totalSeconds <= seconds) return project;
  final starts = project.clipStarts();
  final out = <EditClip>[];
  for (var i = 0; i < project.clips.length; i++) {
    final c = project.clips[i];
    final left = seconds - starts[i];
    if (left < minClipSeconds) break;
    if (c.outSeconds <= left) {
      out.add(c);
      continue;
    }
    out.add(c.isImage
        ? c.copyWith(sourceSeconds: left, trimEnd: left)
        : c.copyWith(trimEnd: c.trimStart + left * c.speed, transition: EditTransition.none));
    break;
  }
  return project.copyWith(clips: [for (final c in out) c.normalized()]);
}

class EditorRenderer {
  EditorRenderer({
    required this.ffmpegPath,
    required this.tts,
    required this.voiceFiles,
    required this.workRoot,
    Future<ByteData> Function(String key)? loadAsset,
  }) : loadAsset = loadAsset ?? rootBundle.load;

  final Future<String?> Function() ffmpegPath;
  final TtsEngine tts;
  final Future<VoiceFiles?> Function(NarratorVoice voice) voiceFiles;
  final String workRoot;
  final Future<ByteData> Function(String key) loadAsset;
  FfmpegRunner? _runner;

  void cancel() => _runner?.cancel();

  Future<String> render(EditProject source, String outPath, {bool preview = false, EditProgress? onProgress, CancelToken? cancel}) async {
    final project = preview ? cutForPreview(source) : source;
    if (project.clips.isEmpty) throw const StudioException('no_clips');
    for (final c in project.clips) {
      if (!await File(c.path).exists()) throw StudioException('missing_media', p.basename(c.path));
    }
    final total = project.totalSeconds;
    if (total < minClipSeconds) throw const StudioException('no_clips');
    final ffmpeg = await ffmpegPath();
    if (ffmpeg == null) throw const StudioException('no_ffmpeg');
    void checkCancel() {
      if (cancel?.isCancelled ?? false) throw const StudioException('cancelled');
    }

    final w = project.aspect.width, h = project.aspect.height;
    final work = Directory(p.join(workRoot, 'edit_${DateTime.now().millisecondsSinceEpoch}'));
    await work.create(recursive: true);
    try {
      onProgress?.call('frames', 0);
      // ---- stills ----
      final imagePngs = <int, String>{};
      for (var i = 0; i < project.clips.length; i++) {
        final c = project.clips[i];
        if (!c.isImage) continue;
        final out = p.join(work.path, 'img_$i.png');
        try {
          await renderEditImage(c.path, out, width: w, height: h, fit: project.fit);
        } on StudioException {
          rethrow;
        } on Object {
          throw StudioException('bad_image', p.basename(c.path));
        }
        imagePngs[i] = out;
        checkCancel();
      }
      // ---- text overlays ----
      final overlays = <TextOverlay>[];
      for (var k = 0; k < project.texts.length; k++) {
        final t = project.texts[k];
        final start = math.max(0.0, t.start);
        final end = math.min(total, t.end);
        if (t.text.trim().isEmpty || end - start < 0.3) continue;
        final out = p.join(work.path, 'text_$k.png');
        await renderEditText(t.text.trim(), out, width: w, height: h, position: t.position, size: t.size);
        overlays.add(TextOverlay(pngPath: out, start: start, end: end));
      }
      checkCancel();
      // ---- subtitles ----
      String? subtitleList;
      final cues = [
        for (final s in project.subtitles)
          if (s.text.trim().isNotEmpty && math.min(total, s.end) - math.max(0, s.start) >= 0.3)
            SubtitleCue(math.max(0.0, s.start), math.min(total, s.end), s.text.trim()),
      ]..sort((a, b) => a.start.compareTo(b.start));
      if (cues.isNotEmpty) {
        await renderEditBlank(p.join(work.path, 'blank.png'), width: w, height: h);
        final names = <String>[];
        for (var i = 0; i < cues.length; i++) {
          final name = 'sub_$i.png';
          await renderEditSubtitle(cues[i].text, p.join(work.path, name), width: w, height: h);
          names.add(name);
        }
        subtitleList = p.join(work.path, 'subs.ffconcat');
        await File(subtitleList).writeAsString(buildSubtitleConcatList(cues, names, 'blank.png', total));
      }
      checkCancel();
      // ---- narration ----
      String? narration;
      if (project.hasNarration) {
        onProgress?.call('voice', null);
        final voice = await voiceFiles(project.voice);
        if (voice == null) throw const StudioException('no_voice');
        final clips = await tts.synthesizeAll([project.narration.trim()], voice);
        final clip = clips.isEmpty ? null : clips.first;
        if (clip != null && clip.samples.isNotEmpty) {
          narration = p.join(work.path, 'narration.wav');
          await writeWavFile(narration, layoutTrack([(start: 0.3, audio: clip)], total, clip.sampleRate));
        }
      }
      checkCancel();
      // ---- music ----
      String? music;
      if (project.musicTrackId == 'file') {
        final f = project.musicFile;
        if (f == null || !await File(f).exists()) throw const StudioException('missing_music');
        music = f;
      } else {
        final track = musicById(project.musicTrackId);
        if (track != null) {
          final data = await loadAsset(track.asset);
          music = p.join(work.path, p.basename(track.asset));
          await File(music).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        }
      }
      String? watermark;
      if (preview) {
        watermark = p.join(work.path, 'wm.png');
        await renderPreviewWatermark(watermark, width: w, height: h);
      }
      checkCancel();

      final args = buildEditArgs(resolveEditInputs(
        project,
        outputPath: outPath,
        imagePngs: imagePngs,
        overlays: overlays,
        subtitleListPath: subtitleList,
        narrationWavPath: narration,
        musicPath: music,
        watermarkPng: watermark,
        preview: preview,
      ));
      final runner = FfmpegRunner(ffmpeg);
      _runner = runner;
      cancel?.onCancel(runner.cancel);
      onProgress?.call('encode', 0);
      try {
        await runner.run(args, totalSeconds: total, onProgress: (f) => onProgress?.call('encode', f));
      } on FfmpegException catch (e) {
        if (e.code == 'cancelled') throw const StudioException('cancelled');
        throw StudioException(e.code == 'missing' ? 'no_ffmpeg' : 'render_failed', e.detail);
      } finally {
        _runner = null;
      }
      if (!await File(outPath).exists()) throw const StudioException('render_failed', 'no output');
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
