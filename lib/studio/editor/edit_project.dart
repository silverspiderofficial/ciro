/// The video editor's project: imported clips on one timeline plus text, subtitles, music,
/// narration and a colour preset. Pure Dart, JSON round-trip with explicit keys (survives
/// obfuscation), so it is unit-tested and saved as a draft.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../video/video_project.dart' show NarratorVoice;

enum MediaKind {
  video('video'),
  image('image');

  const MediaKind(this.key);
  final String key;
  static MediaKind fromKey(String? k) => k == 'image' ? MediaKind.image : MediaKind.video;
}

/// Output frame: 9:16 (Reels/Stories) or 4:5 (feed).
enum EditAspect {
  portrait('9x16', 1080, 1920),
  feed('4x5', 1080, 1350);

  const EditAspect(this.key, this.width, this.height);
  final String key;
  final int width;
  final int height;
  static EditAspect fromKey(String? k) => k == '4x5' ? EditAspect.feed : EditAspect.portrait;
}

/// crop = fill the frame (edges cut); fit = whole picture over a blurred copy.
enum FitMode {
  crop('crop'),
  fit('fit');

  const FitMode(this.key);
  final String key;
  static FitMode fromKey(String? k) => k == 'fit' ? FitMode.fit : FitMode.crop;
}

/// Transition into the next clip (FFmpeg xfade names, except [none] = a hard cut).
enum EditTransition {
  none('none'),
  fade('fade'),
  dissolve('dissolve'),
  slideLeft('slideleft'),
  wipeLeft('wipeleft'),
  circleOpen('circleopen');

  const EditTransition(this.key);
  final String key;
  static EditTransition fromKey(String? k) =>
      EditTransition.values.firstWhere((t) => t.key == k, orElse: () => EditTransition.none);
}

/// Colour presets (FFmpeg `eq`): brightness −1..1, contrast 0..2, saturation 0..3.
enum FilterPreset {
  none('none', 0, 1, 1),
  bright('bright', 0.06, 1.05, 1.1),
  vivid('vivid', 0.02, 1.12, 1.35),
  soft('soft', 0.04, 0.9, 0.85),
  cinematic('cinematic', -0.03, 1.15, 0.8),
  mono('mono', 0, 1.1, 0);

  const FilterPreset(this.key, this.brightness, this.contrast, this.saturation);
  final String key;
  final double brightness;
  final double contrast;
  final double saturation;
  static FilterPreset fromKey(String? k) => FilterPreset.values.firstWhere((f) => f.key == k, orElse: () => FilterPreset.none);
}

enum TextPosition {
  top('top'),
  center('center'),
  bottom('bottom');

  const TextPosition(this.key);
  final String key;
  static TextPosition fromKey(String? k) => TextPosition.values.firstWhere((p) => p.key == k, orElse: () => TextPosition.top);
}

const double minClipSeconds = 0.5;
const double defaultImageSeconds = 3;
const double minSpeed = 0.5;
const double maxSpeed = 2.0;

/// A hard cut is a 0.04 s cross-fade so every boundary uses the same filter chain.
const double hardCutSeconds = 0.04;

double _r3(double v) => (v * 1000).roundToDouble() / 1000;

class EditClip {
  const EditClip({
    required this.id,
    required this.path,
    required this.kind,
    required this.sourceSeconds,
    this.hasAudio = false,
    this.trimStart = 0,
    double? trimEnd,
    this.speed = 1,
    this.transition = EditTransition.fade,
  }) : trimEnd = trimEnd ?? sourceSeconds;

  final String id;
  final String path;
  final MediaKind kind;

  /// Length of the source file (images: the chosen still length).
  final double sourceSeconds;
  final bool hasAudio;
  final double trimStart;
  final double trimEnd;

  /// 0.5x .. 2x (images are always 1x).
  final double speed;

  /// Transition from this clip into the next one.
  final EditTransition transition;

  bool get isImage => kind == MediaKind.image;

  /// Seconds of source used.
  double get sourceUsed => math.max(0, trimEnd - trimStart);

  /// Seconds on the output timeline.
  double get outSeconds => isImage ? sourceUsed : sourceUsed / speed;

  EditClip copyWith({
    String? id,
    String? path,
    double? sourceSeconds,
    bool? hasAudio,
    double? trimStart,
    double? trimEnd,
    double? speed,
    EditTransition? transition,
  }) =>
      EditClip(
        id: id ?? this.id,
        path: path ?? this.path,
        kind: kind,
        sourceSeconds: sourceSeconds ?? this.sourceSeconds,
        hasAudio: hasAudio ?? this.hasAudio,
        trimStart: trimStart ?? this.trimStart,
        trimEnd: trimEnd ?? this.trimEnd,
        speed: speed ?? this.speed,
        transition: transition ?? this.transition,
      );

  /// Clamps trim and speed to valid values.
  EditClip normalized() {
    if (isImage) {
      final double len = sourceUsed.clamp(minClipSeconds, 60.0).toDouble();
      return copyWith(trimStart: 0, trimEnd: _r3(len), sourceSeconds: _r3(len), speed: 1);
    }
    final src = math.max(minClipSeconds, sourceSeconds);
    final double s = trimStart.clamp(0.0, math.max(0.0, src - minClipSeconds)).toDouble();
    final double e = trimEnd.clamp(s + minClipSeconds, src).toDouble();
    return copyWith(trimStart: _r3(s), trimEnd: _r3(e), speed: speed.clamp(minSpeed, maxSpeed).toDouble());
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'kind': kind.key,
        'src': sourceSeconds,
        'audio': hasAudio,
        'in': trimStart,
        'out': trimEnd,
        'speed': speed,
        'tr': transition.key,
      };

  factory EditClip.fromJson(Map<String, Object?> j) => EditClip(
        id: (j['id'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        kind: MediaKind.fromKey(j['kind'] as String?),
        sourceSeconds: (j['src'] as num?)?.toDouble() ?? defaultImageSeconds,
        hasAudio: (j['audio'] as bool?) ?? false,
        trimStart: (j['in'] as num?)?.toDouble() ?? 0,
        trimEnd: (j['out'] as num?)?.toDouble(),
        speed: (j['speed'] as num?)?.toDouble() ?? 1,
        transition: EditTransition.fromKey(j['tr'] as String?),
      ).normalized();
}

/// On-screen text shown between [start] and [end] (output seconds).
class EditText {
  const EditText({required this.text, required this.start, required this.end, this.position = TextPosition.top, this.size = 1});
  final String text;
  final double start;
  final double end;
  final TextPosition position;

  /// 0 small, 1 medium, 2 large.
  final int size;

  EditText copyWith({String? text, double? start, double? end, TextPosition? position, int? size}) => EditText(
        text: text ?? this.text,
        start: start ?? this.start,
        end: end ?? this.end,
        position: position ?? this.position,
        size: size ?? this.size,
      );

  Map<String, Object?> toJson() => {'text': text, 'start': start, 'end': end, 'pos': position.key, 'size': size};
  factory EditText.fromJson(Map<String, Object?> j) => EditText(
        text: (j['text'] as String?) ?? '',
        start: (j['start'] as num?)?.toDouble() ?? 0,
        end: (j['end'] as num?)?.toDouble() ?? 2,
        position: TextPosition.fromKey(j['pos'] as String?),
        size: ((j['size'] as num?)?.toInt() ?? 1).clamp(0, 2),
      );
}

/// One subtitle line between [start] and [end] (output seconds).
class EditSubtitle {
  const EditSubtitle({required this.text, required this.start, required this.end});
  final String text;
  final double start;
  final double end;

  EditSubtitle copyWith({String? text, double? start, double? end}) =>
      EditSubtitle(text: text ?? this.text, start: start ?? this.start, end: end ?? this.end);
  Map<String, Object?> toJson() => {'text': text, 'start': start, 'end': end};
  factory EditSubtitle.fromJson(Map<String, Object?> j) => EditSubtitle(
        text: (j['text'] as String?) ?? '',
        start: (j['start'] as num?)?.toDouble() ?? 0,
        end: (j['end'] as num?)?.toDouble() ?? 2,
      );
}

class EditProject {
  const EditProject({
    this.clips = const [],
    this.aspect = EditAspect.portrait,
    this.fit = FitMode.crop,
    this.texts = const [],
    this.subtitles = const [],
    this.musicTrackId = 'none',
    this.musicFile,
    this.musicVolume = 0.35,
    this.duck = true,
    this.muteOriginal = false,
    this.originalVolume = 1,
    this.narration = '',
    this.voice = NarratorVoice.none,
    this.fadeIn = true,
    this.fadeOut = true,
    this.filter = FilterPreset.none,
    this.transitionSeconds = 0.5,
  });

  final List<EditClip> clips;
  final EditAspect aspect;
  final FitMode fit;
  final List<EditText> texts;
  final List<EditSubtitle> subtitles;

  /// A bundled track id from the music catalog, 'none', or 'file' for [musicFile].
  final String musicTrackId;
  final String? musicFile;
  final double musicVolume;

  /// Lower the music while someone speaks (narration, or the clips' own sound).
  final bool duck;
  final bool muteOriginal;
  final double originalVolume;

  /// Spoken by the on-device narrator from the start of the video.
  final String narration;
  final NarratorVoice voice;
  final bool fadeIn;
  final bool fadeOut;
  final FilterPreset filter;
  final double transitionSeconds;

  bool get isEmpty => clips.isEmpty;

  bool get hasNarration => voice != NarratorVoice.none && narration.trim().isNotEmpty;

  /// Length of the cross-fade between clip [i] and clip i+1.
  double transitionAfter(int i) {
    if (i < 0 || i >= clips.length - 1) return 0;
    if (clips[i].transition == EditTransition.none) return hardCutSeconds;
    final cap = math.min(clips[i].outSeconds, clips[i + 1].outSeconds) * 0.4;
    return _r3(math.max(hardCutSeconds, math.min(transitionSeconds, cap)));
  }

  /// Start of every clip on the output timeline.
  List<double> clipStarts() {
    final out = <double>[];
    var t = 0.0;
    for (var i = 0; i < clips.length; i++) {
      out.add(_r3(t));
      t += clips[i].outSeconds - transitionAfter(i);
    }
    return out;
  }

  double get totalSeconds {
    if (clips.isEmpty) return 0;
    var t = 0.0;
    for (var i = 0; i < clips.length; i++) {
      t += clips[i].outSeconds - transitionAfter(i);
    }
    return _r3(t);
  }

  Duration get duration => Duration(milliseconds: (totalSeconds * 1000).round());

  // ---- editing operations (each returns a new project) ----

  EditProject copyWith({
    List<EditClip>? clips,
    EditAspect? aspect,
    FitMode? fit,
    List<EditText>? texts,
    List<EditSubtitle>? subtitles,
    String? musicTrackId,
    String? musicFile,
    bool clearMusicFile = false,
    double? musicVolume,
    bool? duck,
    bool? muteOriginal,
    double? originalVolume,
    String? narration,
    NarratorVoice? voice,
    bool? fadeIn,
    bool? fadeOut,
    FilterPreset? filter,
    double? transitionSeconds,
  }) =>
      EditProject(
        clips: clips ?? this.clips,
        aspect: aspect ?? this.aspect,
        fit: fit ?? this.fit,
        texts: texts ?? this.texts,
        subtitles: subtitles ?? this.subtitles,
        musicTrackId: musicTrackId ?? this.musicTrackId,
        musicFile: clearMusicFile ? null : (musicFile ?? this.musicFile),
        musicVolume: musicVolume ?? this.musicVolume,
        duck: duck ?? this.duck,
        muteOriginal: muteOriginal ?? this.muteOriginal,
        originalVolume: originalVolume ?? this.originalVolume,
        narration: narration ?? this.narration,
        voice: voice ?? this.voice,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        filter: filter ?? this.filter,
        transitionSeconds: transitionSeconds ?? this.transitionSeconds,
      );

  EditProject addClip(EditClip c) => copyWith(clips: [...clips, c.normalized()]);

  EditProject replaceClip(int i, EditClip c) {
    if (i < 0 || i >= clips.length) return this;
    final l = [...clips];
    l[i] = c.normalized();
    return copyWith(clips: l);
  }

  EditProject removeClip(int i) {
    if (i < 0 || i >= clips.length) return this;
    return copyWith(clips: [...clips]..removeAt(i));
  }

  EditProject moveClip(int from, int to) {
    if (from < 0 || from >= clips.length || to < 0 || to >= clips.length || from == to) return this;
    final l = [...clips];
    final c = l.removeAt(from);
    l.insert(to, c);
    return copyWith(clips: l);
  }

  /// Splits clip [i] at [atOutput] seconds into that clip (output time). Returns this
  /// unchanged when either half would be shorter than [minClipSeconds].
  EditProject splitClip(int i, double atOutput, {required String newId}) {
    if (i < 0 || i >= clips.length) return this;
    final c = clips[i];
    if (atOutput < minClipSeconds || c.outSeconds - atOutput < minClipSeconds) return this;
    final List<EditClip> parts;
    if (c.isImage) {
      parts = [
        c.copyWith(sourceSeconds: atOutput, trimStart: 0, trimEnd: atOutput, transition: EditTransition.none),
        c.copyWith(id: newId, sourceSeconds: c.outSeconds - atOutput, trimStart: 0, trimEnd: c.outSeconds - atOutput),
      ];
    } else {
      final cut = c.trimStart + atOutput * c.speed;
      parts = [
        c.copyWith(trimEnd: cut, transition: EditTransition.none),
        c.copyWith(id: newId, trimStart: cut),
      ];
    }
    final l = [...clips]..replaceRange(i, i + 1, [for (final p in parts) p.normalized()]);
    return copyWith(clips: l);
  }

  Map<String, Object?> toJson() => {
        'v': 1,
        'kind': 'edit',
        'clips': [for (final c in clips) c.toJson()],
        'aspect': aspect.key,
        'fit': fit.key,
        'texts': [for (final t in texts) t.toJson()],
        'subs': [for (final s in subtitles) s.toJson()],
        'music': musicTrackId,
        if (musicFile != null) 'musicFile': musicFile,
        'musicVolume': musicVolume,
        'duck': duck,
        'mute': muteOriginal,
        'origVolume': originalVolume,
        'narration': narration,
        'voice': voice.key,
        'fadeIn': fadeIn,
        'fadeOut': fadeOut,
        'filter': filter.key,
        'transition': transitionSeconds,
      };

  String encode() => jsonEncode(toJson());

  factory EditProject.fromJson(Map<String, Object?> j) {
    List<Map<String, Object?>> maps(Object? v) => ((v as List<Object?>?) ?? const []).whereType<Map<String, Object?>>().toList();
    return EditProject(
      clips: maps(j['clips']).map(EditClip.fromJson).where((c) => c.path.isNotEmpty).toList(),
      aspect: EditAspect.fromKey(j['aspect'] as String?),
      fit: FitMode.fromKey(j['fit'] as String?),
      texts: maps(j['texts']).map(EditText.fromJson).toList(),
      subtitles: maps(j['subs']).map(EditSubtitle.fromJson).toList(),
      musicTrackId: (j['music'] as String?) ?? 'none',
      musicFile: j['musicFile'] as String?,
      musicVolume: ((j['musicVolume'] as num?)?.toDouble() ?? 0.35).clamp(0.0, 1.0),
      duck: (j['duck'] as bool?) ?? true,
      muteOriginal: (j['mute'] as bool?) ?? false,
      originalVolume: ((j['origVolume'] as num?)?.toDouble() ?? 1).clamp(0.0, 2.0),
      narration: (j['narration'] as String?) ?? '',
      voice: NarratorVoice.fromKey(j['voice'] as String?),
      fadeIn: (j['fadeIn'] as bool?) ?? true,
      fadeOut: (j['fadeOut'] as bool?) ?? true,
      filter: FilterPreset.fromKey(j['filter'] as String?),
      transitionSeconds: ((j['transition'] as num?)?.toDouble() ?? 0.5).clamp(0.2, 1.5),
    );
  }

  /// Never throws: a broken file gives an empty project.
  static EditProject decode(String s) {
    try {
      final j = jsonDecode(s);
      return j is Map<String, Object?> ? EditProject.fromJson(j) : const EditProject();
    } on Object {
      return const EditProject();
    }
  }
}
