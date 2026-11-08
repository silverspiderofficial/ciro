/// The editable description of a vertical (9:16) video: scenes on a simple timeline.
/// Every enum has an explicit string key so saved projects survive obfuscation.
library;

import 'dart:convert';

enum CameraMotion {
  auto('auto'),
  zoomIn('zoom_in'),
  zoomOut('zoom_out'),
  panLeft('pan_left'),
  panRight('pan_right'),
  panUp('pan_up'),
  still('still');

  const CameraMotion(this.key);
  final String key;

  static CameraMotion fromKey(String? k) =>
      CameraMotion.values.firstWhere((m) => m.key == k, orElse: () => CameraMotion.auto);
}

/// Transitions into the next scene (names are FFmpeg xfade transitions, except [cut]).
enum SceneTransition {
  fade('fade'),
  dissolve('dissolve'),
  slideLeft('slideleft'),
  slideUp('slideup'),
  wipeLeft('wipeleft'),
  circleOpen('circleopen'),
  zoomIn('zoomin'),
  cut('cut');

  const SceneTransition(this.key);
  final String key;

  static SceneTransition fromKey(String? k) =>
      SceneTransition.values.firstWhere((t) => t.key == k, orElse: () => SceneTransition.fade);
}

/// Narrator voice. Keys match [voiceCatalog] ids.
enum NarratorVoice {
  none('none'),
  persian('piper-fa_IR-amir-medium'),
  english('piper-en_US-joe-medium');

  const NarratorVoice(this.key);
  final String key;

  static NarratorVoice fromKey(String? k) =>
      NarratorVoice.values.firstWhere((v) => v.key == k, orElse: () => NarratorVoice.none);
}

class VideoScene {
  const VideoScene({
    required this.imagePath,
    this.narration = '',
    this.overlayText = '',
    this.durationSeconds,
    this.motion = CameraMotion.auto,
    this.transition = SceneTransition.fade,
  });

  /// PNG/JPEG on disk (generated image, template export or imported photo).
  final String imagePath;

  /// Spoken by the narrator and shown as burned-in subtitles.
  final String narration;

  /// Big animated on-screen text (hook / title) for this scene.
  final String overlayText;

  /// Fixed length; null = follow the narration (with a minimum).
  final double? durationSeconds;
  final CameraMotion motion;

  /// Transition from this scene into the next one.
  final SceneTransition transition;

  VideoScene copyWith({
    String? imagePath,
    String? narration,
    String? overlayText,
    double? durationSeconds,
    bool clearDuration = false,
    CameraMotion? motion,
    SceneTransition? transition,
  }) =>
      VideoScene(
        imagePath: imagePath ?? this.imagePath,
        narration: narration ?? this.narration,
        overlayText: overlayText ?? this.overlayText,
        durationSeconds: clearDuration ? null : (durationSeconds ?? this.durationSeconds),
        motion: motion ?? this.motion,
        transition: transition ?? this.transition,
      );

  Map<String, Object?> toJson() => {
        'image': imagePath,
        'narration': narration,
        'text': overlayText,
        if (durationSeconds != null) 'duration': durationSeconds,
        'motion': motion.key,
        'transition': transition.key,
      };

  factory VideoScene.fromJson(Map<String, Object?> j) => VideoScene(
        imagePath: (j['image'] as String?) ?? '',
        narration: (j['narration'] as String?) ?? '',
        overlayText: (j['text'] as String?) ?? '',
        durationSeconds: (j['duration'] as num?)?.toDouble(),
        motion: CameraMotion.fromKey(j['motion'] as String?),
        transition: SceneTransition.fromKey(j['transition'] as String?),
      );
}

class VideoProject {
  const VideoProject({
    this.title = '',
    this.scenes = const [],
    this.voice = NarratorVoice.none,
    this.musicTrackId = 'none',
    this.musicVolume = 0.35,
    this.subtitles = true,
    this.transitionSeconds = 0.6,
    this.speechSpeed = 1.0,
  });

  final String title;
  final List<VideoScene> scenes;
  final NarratorVoice voice;

  /// Id from [musicCatalog] or 'none'.
  final String musicTrackId;

  /// 0..1 background music level (it is also ducked under the narrator).
  final double musicVolume;
  final bool subtitles;
  final double transitionSeconds;
  final double speechSpeed;

  static const width = 1080;
  static const height = 1920;
  static const fps = 30;

  VideoProject copyWith({
    String? title,
    List<VideoScene>? scenes,
    NarratorVoice? voice,
    String? musicTrackId,
    double? musicVolume,
    bool? subtitles,
    double? transitionSeconds,
    double? speechSpeed,
  }) =>
      VideoProject(
        title: title ?? this.title,
        scenes: scenes ?? this.scenes,
        voice: voice ?? this.voice,
        musicTrackId: musicTrackId ?? this.musicTrackId,
        musicVolume: musicVolume ?? this.musicVolume,
        subtitles: subtitles ?? this.subtitles,
        transitionSeconds: transitionSeconds ?? this.transitionSeconds,
        speechSpeed: speechSpeed ?? this.speechSpeed,
      );

  Map<String, Object?> toJson() => {
        'v': 1,
        'title': title,
        'scenes': scenes.map((s) => s.toJson()).toList(),
        'voice': voice.key,
        'music': musicTrackId,
        'musicVolume': musicVolume,
        'subtitles': subtitles,
        'transition': transitionSeconds,
        'speed': speechSpeed,
      };

  String encode() => jsonEncode(toJson());

  factory VideoProject.fromJson(Map<String, Object?> j) => VideoProject(
        title: (j['title'] as String?) ?? '',
        scenes: ((j['scenes'] as List<Object?>?) ?? const [])
            .whereType<Map<String, Object?>>()
            .map(VideoScene.fromJson)
            .toList(),
        voice: NarratorVoice.fromKey(j['voice'] as String?),
        musicTrackId: (j['music'] as String?) ?? 'none',
        musicVolume: ((j['musicVolume'] as num?)?.toDouble() ?? 0.35).clamp(0.0, 1.0),
        subtitles: (j['subtitles'] as bool?) ?? true,
        transitionSeconds: ((j['transition'] as num?)?.toDouble() ?? 0.6).clamp(0.2, 1.5),
        speechSpeed: ((j['speed'] as num?)?.toDouble() ?? 1.0).clamp(0.6, 1.6),
      );

  static VideoProject decode(String s) => VideoProject.fromJson(jsonDecode(s) as Map<String, Object?>);
}
