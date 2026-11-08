/// Builds the FFmpeg argument list for a rendered video. Pure Dart: the same arguments are
/// used with the bundled FFmpeg binary on Android and with FFmpeg on Windows/Linux.
///
/// Inputs, in order:
///   scene stills (one per scene, pre-rendered by Flutter at 1.5x the output size),
///   optional subtitle track (ffconcat list of transparent PNGs),
///   optional animated text overlays (one transparent PNG per scene that has text),
///   optional narration (mono WAV laid out on the final timeline),
///   optional background music (looped).
library;

import 'timeline.dart';
import 'video_project.dart';

class TextOverlay {
  const TextOverlay({required this.pngPath, required this.start, required this.end});
  final String pngPath;
  final double start;
  final double end;
}

class RenderInputs {
  const RenderInputs({
    required this.scenePngs,
    required this.motions,
    required this.transitions,
    required this.plan,
    required this.outputPath,
    this.subtitleListPath,
    this.textOverlays = const [],
    this.narrationWavPath,
    this.musicPath,
    this.musicVolume = 0.35,
    this.crf = 21,
    this.preset = 'veryfast',
    this.threads = 0,
  });

  final List<String> scenePngs;

  /// Already resolved (no [CameraMotion.auto]).
  final List<CameraMotion> motions;

  /// Transition after each scene (the last one is ignored).
  final List<SceneTransition> transitions;
  final TimelinePlan plan;
  final String outputPath;
  final String? subtitleListPath;
  final List<TextOverlay> textOverlays;
  final String? narrationWavPath;
  final String? musicPath;
  final double musicVolume;
  final int crf;
  final String preset;

  /// 0 = let FFmpeg decide.
  final int threads;
}

/// "auto" alternates gentle moves so consecutive scenes never feel the same.
List<CameraMotion> resolveMotions(List<CameraMotion> motions) {
  const cycle = [CameraMotion.zoomIn, CameraMotion.panLeft, CameraMotion.zoomOut, CameraMotion.panRight];
  return [
    for (var i = 0; i < motions.length; i++) motions[i] == CameraMotion.auto ? cycle[i % cycle.length] : motions[i],
  ];
}

String _n(double v) {
  final s = v.toStringAsFixed(3);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

/// zoompan expressions for one still: [frames] output frames at 30 fps.
String kenBurnsFilter(CameraMotion motion, int frames, {int width = VideoProject.width, int height = VideoProject.height}) {
  final n = frames < 2 ? 2 : frames;
  const zMax = 1.15;
  String z, x, y;
  const cx = "'iw/2-(iw/zoom/2)'";
  const cy = "'ih/2-(ih/zoom/2)'";
  switch (motion) {
    case CameraMotion.zoomIn || CameraMotion.auto:
      z = "'1+${_n(zMax - 1)}*on/$n'";
      x = cx;
      y = cy;
    case CameraMotion.zoomOut:
      z = "'$zMax-${_n(zMax - 1)}*on/$n'";
      x = cx;
      y = cy;
    case CameraMotion.panLeft:
      z = "'$zMax'";
      x = "'(iw-iw/zoom)*(1-on/$n)'";
      y = cy;
    case CameraMotion.panRight:
      z = "'$zMax'";
      x = "'(iw-iw/zoom)*on/$n'";
      y = cy;
    case CameraMotion.panUp:
      z = "'$zMax'";
      x = cx;
      y = "'(ih-ih/zoom)*(1-on/$n)'";
    case CameraMotion.still:
      z = "'1'";
      x = "'0'";
      y = "'0'";
  }
  return 'zoompan=z=$z:x=$x:y=$y:d=$n:s=${width}x$height:fps=${VideoProject.fps}';
}

/// The concat-demuxer list that turns subtitle PNGs into one overlay stream.
/// [cuePngs] are file names in the same directory as the list; [blankPng] is fully transparent.
String buildSubtitleConcatList(List<SubtitleCue> cues, List<String> cuePngs, String blankPng, double totalSeconds) {
  assert(cues.length == cuePngs.length);
  final b = StringBuffer('ffconcat version 1.0\n');
  var at = 0.0;
  String? last;
  void entry(String file, double seconds) {
    if (seconds <= 0.001) return;
    b
      ..writeln("file '${_quote(file)}'")
      ..writeln('duration ${_n(seconds)}');
    last = file;
  }

  for (var i = 0; i < cues.length; i++) {
    final c = cues[i];
    final start = c.start < at ? at : c.start;
    entry(blankPng, start - at);
    final end = c.end > totalSeconds ? totalSeconds : c.end;
    entry(cuePngs[i], end - start);
    at = end > start ? end : start;
  }
  entry(blankPng, totalSeconds - at);
  if (last == null) entry(blankPng, totalSeconds > 0 ? totalSeconds : 1);
  // The concat demuxer ignores the duration of the final entry unless it is repeated.
  b.writeln("file '${_quote(last ?? blankPng)}'");
  return b.toString();
}

String _quote(String s) => s.replaceAll("'", r"'\''");

List<String> buildFfmpegArgs(RenderInputs r) {
  final plan = r.plan;
  final total = plan.totalSeconds;
  final args = <String>['-hide_banner', '-nostdin', '-y', '-loglevel', 'error'];
  if (r.threads > 0) args.addAll(['-threads', '${r.threads}']);
  final graph = <String>[];
  var input = 0;

  // ---- scene stills + Ken Burns ----
  final sceneLabels = <String>[];
  for (var i = 0; i < r.scenePngs.length; i++) {
    args.addAll(['-i', r.scenePngs[i]]);
    final frames = (plan.scenes[i].duration * VideoProject.fps).round();
    graph.add('[$input:v]format=rgb24,${kenBurnsFilter(r.motions[i], frames)},setsar=1,format=yuv420p[s$i]');
    sceneLabels.add('s$i');
    input++;
  }

  // ---- transitions (chained xfade) ----
  var current = sceneLabels.first;
  final offsets = xfadeOffsets(plan);
  for (var i = 1; i < sceneLabels.length; i++) {
    final t = r.transitions[i - 1];
    final name = t == SceneTransition.cut ? 'fade' : t.key;
    final duration = plan.scenes[i].transitionIn;
    final out = 'x$i';
    graph.add('[$current][${sceneLabels[i]}]xfade=transition=$name:duration=${_n(duration)}:offset=${_n(offsets[i - 1])}[$out]');
    current = out;
  }

  // ---- animated text overlays (fade + slide up) ----
  for (var k = 0; k < r.textOverlays.length; k++) {
    final o = r.textOverlays[k];
    final len = o.end - o.start;
    if (len <= 0.2) continue;
    args.addAll(['-loop', '1', '-framerate', '${VideoProject.fps}', '-t', _n(len), '-i', o.pngPath]);
    final fadeOut = len > 0.7 ? len - 0.3 : len / 2;
    graph.add('[$input:v]format=rgba,fade=t=in:st=0:d=0.35:alpha=1,fade=t=out:st=${_n(fadeOut)}:d=0.3:alpha=1,'
        'setpts=PTS-STARTPTS+${_n(o.start)}/TB[t$k]');
    final out = 'o$k';
    graph.add("[$current][t$k]overlay=x=0:y='if(lt(t-${_n(o.start)},0.35),(1-(t-${_n(o.start)})/0.35)*80,0)'"
        ':eof_action=pass:format=auto[$out]');
    current = out;
    input++;
  }

  // ---- burned-in subtitles ----
  if (r.subtitleListPath != null) {
    args.addAll(['-f', 'concat', '-safe', '0', '-i', r.subtitleListPath!]);
    graph.add('[$input:v]format=rgba[subs]');
    graph.add('[$current][subs]overlay=0:0:eof_action=repeat:format=auto[sub]');
    current = 'sub';
    input++;
  }
  graph.add('[$current]format=yuv420p,trim=duration=${_n(total)},setpts=PTS-STARTPTS[vout]');

  // ---- audio ----
  int? narration;
  int? music;
  if (r.narrationWavPath != null) {
    args.addAll(['-i', r.narrationWavPath!]);
    narration = input++;
  }
  if (r.musicPath != null) {
    args.addAll(['-stream_loop', '-1', '-i', r.musicPath!]);
    music = input++;
  }
  const norm = 'aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo';
  final fadeOutStart = total > 2 ? total - 1.5 : 0.0;
  final musicChain = music == null
      ? ''
      : '[$music:a]$norm,volume=${_n(r.musicVolume.clamp(0.0, 1.0))},atrim=0:${_n(total)},'
          'afade=t=in:st=0:d=0.5,afade=t=out:st=${_n(fadeOutStart)}:d=1.5';
  final narrationChain = narration == null ? '' : '[$narration:a]$norm,apad,atrim=0:${_n(total)}';
  if (narration != null && music != null) {
    graph
      ..add('$narrationChain,asplit=2[nar1][nar2]')
      ..add('$musicChain[mus]')
      ..add('[mus][nar1]sidechaincompress=threshold=0.03:ratio=6:attack=15:release=350[duck]')
      ..add('[duck][nar2]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[aout]');
  } else if (narration != null) {
    graph.add('$narrationChain[aout]');
  } else if (music != null) {
    graph.add('$musicChain[aout]');
  } else {
    graph.add('anullsrc=r=44100:cl=stereo,atrim=0:${_n(total)}[aout]');
  }

  args.addAll([
    '-filter_complex', graph.join(';'),
    '-map', '[vout]',
    '-map', '[aout]',
    '-c:v', 'libx264',
    '-preset', r.preset,
    '-crf', '${r.crf}',
    '-profile:v', 'high',
    '-pix_fmt', 'yuv420p',
    '-r', '${VideoProject.fps}',
    '-c:a', 'aac',
    '-b:a', '128k',
    '-ar', '44100',
    '-movflags', '+faststart',
    '-t', _n(total),
    '-progress', 'pipe:1',
    '-nostats',
    r.outputPath,
  ]);
  return args;
}

/// Parses FFmpeg `-progress` output; returns seconds rendered or null for other lines.
double? parseProgressSeconds(String line) {
  final i = line.indexOf('=');
  if (i <= 0) return null;
  final key = line.substring(0, i).trim();
  final value = line.substring(i + 1).trim();
  if (key == 'out_time_us' || key == 'out_time_ms') {
    final us = int.tryParse(value);
    return us == null || us < 0 ? null : us / 1e6;
  }
  if (key == 'out_time') {
    final m = RegExp(r'^(\d+):(\d+):(\d+(?:\.\d+)?)$').firstMatch(value);
    if (m == null) return null;
    return int.parse(m[1]!) * 3600 + int.parse(m[2]!) * 60 + double.parse(m[3]!);
  }
  return null;
}
