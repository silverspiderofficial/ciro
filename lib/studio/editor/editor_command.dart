/// FFmpeg arguments for the video editor (pure Dart, same on Android and desktop).
///
/// Video: each clip is trimmed (input seek), sped up/down, fitted to the frame (crop, or the
/// whole picture over a blurred copy) and joined with chained `xfade`; then colour preset,
/// fade in/out, text overlays, subtitles and (preview only) a watermark.
/// Audio: the clips' own sound (delayed to each clip's start, faded at the joins), narration
/// and music (ducked under speech), mixed and limited.
///
/// Only filters enabled in tool/ffmpeg/build_ffmpeg.sh are used (checked by a test).
library;

import 'dart:math' as math;

import '../video/ffmpeg_command.dart' show TextOverlay;
import 'edit_project.dart';

/// One resolved clip. Images are pre-rendered by Flutter to a PNG of the output size.
class EditInput {
  const EditInput({
    required this.path,
    required this.isImage,
    required this.trimStart,
    required this.sourceSeconds,
    required this.speed,
    required this.hasAudio,
    required this.outSeconds,
  });

  final String path;
  final bool isImage;
  final double trimStart;
  final double sourceSeconds;
  final double speed;
  final bool hasAudio;
  final double outSeconds;
}

class EditRenderInputs {
  const EditRenderInputs({
    required this.clips,
    required this.transitions,
    required this.transitionNames,
    required this.width,
    required this.height,
    required this.outputPath,
    this.fit = FitMode.crop,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.fadeIn = false,
    this.fadeOut = false,
    this.overlays = const [],
    this.subtitleListPath,
    this.narrationWavPath,
    this.musicPath,
    this.musicVolume = 0.35,
    this.duck = true,
    this.muteOriginal = false,
    this.originalVolume = 1,
    this.watermarkPng,
    this.scaleDown = 1,
    this.crf = 21,
    this.preset = 'veryfast',
  });

  final List<EditInput> clips;

  /// Cross-fade length after clip i (length clips-1).
  final List<double> transitions;

  /// xfade transition names after clip i (length clips-1).
  final List<String> transitionNames;
  final int width;
  final int height;
  final String outputPath;
  final FitMode fit;
  final double brightness;
  final double contrast;
  final double saturation;
  final bool fadeIn;
  final bool fadeOut;

  /// Full-frame transparent PNGs shown between start and end.
  final List<TextOverlay> overlays;
  final String? subtitleListPath;
  final String? narrationWavPath;
  final String? musicPath;
  final double musicVolume;
  final bool duck;
  final bool muteOriginal;
  final double originalVolume;

  /// Full-frame PNG laid over the whole video (preview).
  final String? watermarkPng;

  /// 2 = half size (preview).
  final int scaleDown;
  final int crf;
  final String preset;

  double get totalSeconds {
    var t = 0.0;
    for (var i = 0; i < clips.length; i++) {
      t += clips[i].outSeconds - (i < transitions.length ? transitions[i] : 0);
    }
    return t;
  }

  /// Output start of each clip.
  List<double> get starts {
    final out = <double>[];
    var t = 0.0;
    for (var i = 0; i < clips.length; i++) {
      out.add(t);
      t += clips[i].outSeconds - (i < transitions.length ? transitions[i] : 0);
    }
    return out;
  }
}

String n3(double v) {
  final s = v.toStringAsFixed(3);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

/// Resolves a project into render inputs. [imagePngs] maps clip index → pre-rendered PNG.
EditRenderInputs resolveEditInputs(
  EditProject p, {
  required String outputPath,
  Map<int, String> imagePngs = const {},
  List<TextOverlay> overlays = const [],
  String? subtitleListPath,
  String? narrationWavPath,
  String? musicPath,
  String? watermarkPng,
  bool preview = false,
}) {
  final clips = <EditInput>[];
  for (var i = 0; i < p.clips.length; i++) {
    final c = p.clips[i];
    clips.add(EditInput(
      path: c.isImage ? (imagePngs[i] ?? c.path) : c.path,
      isImage: c.isImage,
      trimStart: c.isImage ? 0 : c.trimStart,
      sourceSeconds: c.sourceUsed,
      speed: c.isImage ? 1 : c.speed,
      hasAudio: !c.isImage && c.hasAudio,
      outSeconds: c.outSeconds,
    ));
  }
  return EditRenderInputs(
    clips: clips,
    transitions: [for (var i = 0; i < p.clips.length - 1; i++) p.transitionAfter(i)],
    transitionNames: [
      for (var i = 0; i < p.clips.length - 1; i++)
        p.clips[i].transition == EditTransition.none ? 'fade' : p.clips[i].transition.key,
    ],
    width: p.aspect.width,
    height: p.aspect.height,
    outputPath: outputPath,
    fit: p.fit,
    brightness: p.filter.brightness,
    contrast: p.filter.contrast,
    saturation: p.filter.saturation,
    fadeIn: p.fadeIn,
    fadeOut: p.fadeOut,
    overlays: overlays,
    subtitleListPath: subtitleListPath,
    narrationWavPath: narrationWavPath,
    musicPath: musicPath,
    musicVolume: p.musicVolume,
    duck: p.duck,
    muteOriginal: p.muteOriginal,
    originalVolume: p.originalVolume,
    watermarkPng: watermarkPng,
    scaleDown: preview ? 2 : 1,
    crf: preview ? 30 : 21,
    preset: preview ? 'ultrafast' : 'veryfast',
  );
}

const _norm = 'aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo';

List<String> buildEditArgs(EditRenderInputs r) {
  if (r.clips.isEmpty) throw ArgumentError('no clips');
  final w = r.width;
  final h = r.height;
  final total = r.totalSeconds;
  final starts = r.starts;
  final args = <String>['-hide_banner', '-nostdin', '-y', '-loglevel', 'error'];
  final graph = <String>[];
  var input = 0;

  // ---- clips ----
  final clipInput = <int>[];
  for (var i = 0; i < r.clips.length; i++) {
    final c = r.clips[i];
    if (c.isImage) {
      args.addAll(['-loop', '1', '-framerate', '30', '-t', n3(c.outSeconds + 0.1), '-i', c.path]);
    } else {
      args.addAll(['-ss', n3(c.trimStart), '-t', n3(c.sourceSeconds + 0.05), '-i', c.path]);
    }
    clipInput.add(input++);
  }
  for (var i = 0; i < r.clips.length; i++) {
    final c = r.clips[i];
    final k = clipInput[i];
    final tail = 'setsar=1,format=yuv420p,trim=duration=${n3(c.outSeconds)},setpts=PTS-STARTPTS,fps=30[v$i]';
    if (c.isImage) {
      graph.add('[$k:v]scale=$w:$h,fps=30,$tail');
      continue;
    }
    final speed = (c.speed - 1).abs() < 0.001 ? 'setpts=PTS-STARTPTS' : 'setpts=(PTS-STARTPTS)/${n3(c.speed)}';
    if (r.fit == FitMode.crop) {
      graph.add('[$k:v]$speed,fps=30,scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,$tail');
    } else {
      final bw = (w ~/ 8) * 2;
      final bh = (h ~/ 8) * 2;
      graph
        ..add('[$k:v]$speed,fps=30,split=2[fa$i][fb$i]')
        ..add('[fa$i]scale=$bw:$bh:force_original_aspect_ratio=increase,crop=$bw:$bh,boxblur=8:2,scale=$w:$h[bg$i]')
        ..add('[fb$i]scale=$w:$h:force_original_aspect_ratio=decrease[fg$i]')
        ..add('[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2,$tail');
    }
  }

  // ---- joins ----
  var current = 'v0';
  var length = r.clips.first.outSeconds;
  for (var i = 1; i < r.clips.length; i++) {
    final t = r.transitions[i - 1];
    final offset = math.max(0.0, length - t);
    graph.add('[$current][v$i]xfade=transition=${r.transitionNames[i - 1]}:duration=${n3(t)}:offset=${n3(offset)}[x$i]');
    current = 'x$i';
    length = offset + r.clips[i].outSeconds;
  }

  // ---- look: colour preset, fades ----
  final look = <String>[];
  final eqNeeded = r.brightness.abs() > 0.001 || (r.contrast - 1).abs() > 0.001 || (r.saturation - 1).abs() > 0.001;
  if (eqNeeded) look.add('eq=brightness=${n3(r.brightness)}:contrast=${n3(r.contrast)}:saturation=${n3(r.saturation)}');
  final fadeLen = math.min(0.6, total / 4);
  if (r.fadeIn && total > 1) look.add('fade=t=in:st=0:d=${n3(fadeLen)}');
  if (r.fadeOut && total > 1) look.add('fade=t=out:st=${n3(total - fadeLen)}:d=${n3(fadeLen)}');
  if (look.isNotEmpty) {
    graph.add('[$current]${look.join(',')}[look]');
    current = 'look';
  }

  // ---- text overlays ----
  for (var k = 0; k < r.overlays.length; k++) {
    final o = r.overlays[k];
    final len = math.min(o.end, total) - o.start;
    if (len <= 0.2) continue;
    args.addAll(['-loop', '1', '-framerate', '30', '-t', n3(len), '-i', o.pngPath]);
    final fd = math.min(0.3, len / 3);
    graph.add('[$input:v]format=rgba,fade=t=in:st=0:d=${n3(fd)}:alpha=1,fade=t=out:st=${n3(len - fd)}:d=${n3(fd)}:alpha=1,'
        'setpts=PTS-STARTPTS+${n3(o.start)}/TB[t$k]');
    graph.add('[$current][t$k]overlay=0:0:eof_action=pass:format=auto[o$k]');
    current = 'o$k';
    input++;
  }

  // ---- subtitles ----
  if (r.subtitleListPath != null) {
    args.addAll(['-f', 'concat', '-safe', '0', '-i', r.subtitleListPath!]);
    graph.add('[$input:v]format=rgba[subs]');
    graph.add('[$current][subs]overlay=0:0:eof_action=repeat:format=auto[sub]');
    current = 'sub';
    input++;
  }

  // ---- watermark (preview) ----
  if (r.watermarkPng != null) {
    args.addAll(['-loop', '1', '-framerate', '30', '-t', n3(total), '-i', r.watermarkPng!]);
    graph.add('[$input:v]format=rgba[wm]');
    graph.add('[$current][wm]overlay=0:0:format=auto[wmk]');
    current = 'wmk';
    input++;
  }
  final down = r.scaleDown > 1 ? 'scale=${(w ~/ (2 * r.scaleDown)) * 2}:${(h ~/ (2 * r.scaleDown)) * 2},' : '';
  graph.add('[$current]${down}format=yuv420p,trim=duration=${n3(total)},setpts=PTS-STARTPTS[vout]');

  // ---- audio: the clips' own sound ----
  final own = <String>[];
  if (!r.muteOriginal && r.originalVolume > 0.001) {
    for (var i = 0; i < r.clips.length; i++) {
      final c = r.clips[i];
      if (!c.hasAudio) continue;
      final tIn = i == 0 ? 0.0 : r.transitions[i - 1];
      final tOut = i < r.transitions.length ? r.transitions[i] : 0.0;
      final chain = <String>['asetpts=PTS-STARTPTS'];
      if ((c.speed - 1).abs() >= 0.001) chain.add('atempo=${n3(c.speed)}');
      chain
        ..add(_norm)
        ..add('atrim=0:${n3(c.outSeconds)}');
      if (tIn > 0.05) chain.add('afade=t=in:st=0:d=${n3(tIn)}');
      if (tOut > 0.05) chain.add('afade=t=out:st=${n3(math.max(0, c.outSeconds - tOut))}:d=${n3(tOut)}');
      final ms = (starts[i] * 1000).round();
      if (ms > 0) chain.add('adelay=$ms|$ms');
      graph.add('[${clipInput[i]}:a]${chain.join(',')}[ca$i]');
      own.add('[ca$i]');
    }
  }
  String? orig;
  if (own.isNotEmpty) {
    final vol = 'volume=${n3(r.originalVolume.clamp(0.0, 2.0))}';
    graph.add(own.length == 1
        ? '${own.first}apad,atrim=0:${n3(total)},$vol[orig]'
        : '${own.join()}amix=inputs=${own.length}:duration=longest:normalize=0,apad,atrim=0:${n3(total)},$vol[orig]');
    orig = 'orig';
  }

  // ---- narration and music ----
  String? nar;
  if (r.narrationWavPath != null) {
    args.addAll(['-i', r.narrationWavPath!]);
    graph.add('[$input:a]$_norm,apad,atrim=0:${n3(total)}[nar]');
    nar = 'nar';
    input++;
  }
  String? mus;
  if (r.musicPath != null) {
    args.addAll(['-stream_loop', '-1', '-i', r.musicPath!]);
    final fo = total > 2 ? total - 1.5 : 0.0;
    graph.add('[$input:a]$_norm,volume=${n3(r.musicVolume.clamp(0.0, 1.0))},atrim=0:${n3(total)},'
        'afade=t=in:st=0:d=0.5,afade=t=out:st=${n3(fo)}:d=1.5[mus]');
    mus = 'mus';
    input++;
  }

  // Ducking: the music is compressed by the voice (narration, else the clips' own sound).
  final voices = [?nar, ?orig];
  final tracks = <String>[];
  if (mus != null && r.duck && voices.isNotEmpty) {
    final key = voices.first;
    graph.add('[$key]asplit=2[key1][key2]');
    graph.add('[mus][key1]sidechaincompress=threshold=0.03:ratio=6:attack=15:release=350[ducked]');
    tracks
      ..add('ducked')
      ..add('key2')
      ..addAll(voices.skip(1));
  } else {
    tracks.addAll([?mus, ...voices]);
  }
  final afades = <String>[];
  if (r.fadeIn && total > 1) afades.add('afade=t=in:st=0:d=${n3(fadeLen)}');
  if (r.fadeOut && total > 1) afades.add('afade=t=out:st=${n3(total - fadeLen)}:d=${n3(fadeLen)}');
  final tailA = afades.isEmpty ? '' : ',${afades.join(',')}';
  if (tracks.isEmpty) {
    graph.add('anullsrc=r=44100:cl=stereo,atrim=0:${n3(total)}[aout]');
  } else if (tracks.length == 1) {
    graph.add('[${tracks.first}]alimiter=limit=0.95$tailA[aout]');
  } else {
    graph.add('${tracks.map((t) => '[$t]').join()}amix=inputs=${tracks.length}:duration=first:normalize=0,'
        'alimiter=limit=0.95$tailA[aout]');
  }

  args.addAll([
    '-filter_complex', graph.join(';'),
    '-map', '[vout]',
    '-map', '[aout]',
    '-c:v', 'libx264',
    '-preset', r.preset,
    '-crf', '${r.crf}',
    '-pix_fmt', 'yuv420p',
    '-r', '30',
    '-c:a', 'aac',
    '-b:a', '128k',
    '-ar', '44100',
    '-movflags', '+faststart',
    '-t', n3(total),
    '-progress', 'pipe:1',
    '-nostats',
    r.outputPath,
  ]);
  return args;
}

/// What `ffmpeg -i <file>` printed about a media file.
class MediaProbe {
  const MediaProbe({required this.seconds, required this.hasVideo, required this.hasAudio, this.width = 0, this.height = 0});
  final double seconds;
  final bool hasVideo;
  final bool hasAudio;
  final int width;
  final int height;
}

/// Parses the stderr of `ffmpeg -hide_banner -i <file>`. Null when it is not a usable video.
MediaProbe? parseProbe(String stderr) {
  final d = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(stderr);
  final video = RegExp(r'Stream #\S+.*?:\s*Video:.*?\b(\d{2,5})x(\d{2,5})\b').firstMatch(stderr);
  final hasAudio = RegExp(r'Stream #\S+.*?:\s*Audio:').hasMatch(stderr);
  if (d == null || video == null) return null;
  final seconds = int.parse(d[1]!) * 3600 + int.parse(d[2]!) * 60 + double.parse(d[3]!);
  if (seconds <= 0) return null;
  return MediaProbe(
    seconds: seconds,
    hasVideo: true,
    hasAudio: hasAudio,
    width: int.parse(video[1]!),
    height: int.parse(video[2]!),
  );
}

/// Every FFmpeg filter name [args] uses (for the build-config test).
Set<String> filterNamesIn(List<String> args) {
  final i = args.indexOf('-filter_complex');
  if (i < 0) return {};
  final names = <String>{};
  for (final stmt in args[i + 1].split(';')) {
    final body = stmt.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    for (final part in body.split(',')) {
      final m = RegExp(r'^\s*([a-z0-9_]+)').firstMatch(part);
      if (m != null) names.add(m[1]!);
    }
  }
  return names;
}
