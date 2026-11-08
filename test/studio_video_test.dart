import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/studio/video/ffmpeg_command.dart';
import 'package:kiro/studio/video/timeline.dart';
import 'package:kiro/studio/video/video_project.dart';
import 'package:kiro/studio/video/video_renderer.dart';
import 'package:kiro/studio/video/wav.dart';

VideoProject threeScenes({double t = 0.6, SceneTransition tr = SceneTransition.fade}) => VideoProject(
      transitionSeconds: t,
      scenes: [
        VideoScene(imagePath: '/a.png', narration: 'سلام! به کیرو خوش آمدید.', overlayText: 'قلاب', transition: tr),
        VideoScene(imagePath: '/b.png', transition: tr),
        const VideoScene(imagePath: '/c.png', narration: 'پایان.', durationSeconds: 8),
      ],
    );

void main() {
  group('timeline', () {
    test('scenes overlap by the transition and fit their narration', () {
      final plan = planTimeline(threeScenes(), [4.0, 0, 1.0]);
      final s = plan.scenes;
      expect(s[0].start, 0);
      // lead (0.25) + speech (4) + tail (0.45) + outgoing transition (0.6)
      expect(s[0].duration, closeTo(5.3, 1e-9));
      expect(s[0].narrationStart, closeTo(0.25, 1e-9));
      expect(s[1].duration, minSceneSeconds);
      expect(s[1].start, closeTo(5.3 - 0.6, 1e-9));
      expect(s[1].transitionIn, 0.6);
      expect(s[2].duration, 8); // fixed duration longer than its speech
      expect(s[2].narrationStart, closeTo(s[2].start + 0.6 + narrationLeadIn, 1e-9));
      expect(plan.totalSeconds, closeTo(5.3 + 2.5 + 8 - 1.2, 1e-9));
      expect(xfadeOffsets(plan), [s[1].start, s[2].start]);
    });

    test('a fixed duration never cuts the narrator off', () {
      final p = VideoProject(scenes: const [VideoScene(imagePath: '/a.png', narration: 'x', durationSeconds: 3)]);
      final plan = planTimeline(p, [6]);
      expect(plan.scenes.single.duration, greaterThanOrEqualTo(6 + narrationLeadIn + narrationTail));
    });

    test('cuts use a very short cross-fade', () {
      final plan = planTimeline(threeScenes(tr: SceneTransition.cut), [1, 1, 1]);
      expect(plan.scenes[1].transitionIn, cutSeconds);
    });

    test('subtitle lines split at sentence ends and stay short', () {
      final lines = splitSubtitleLines('سلام! به کیرو خوش آمدید. امروز درباره‌ی قهوه و طرز تهیهٔ آن در خانه صحبت می‌کنیم.', maxChars: 30);
      expect(lines.first, 'سلام! به کیرو خوش آمدید.');
      for (final l in lines) {
        expect(l.length, lessThanOrEqualTo(30));
      }
      expect(lines.join(' '), 'سلام! به کیرو خوش آمدید. امروز درباره‌ی قهوه و طرز تهیهٔ آن در خانه صحبت می‌کنیم.');
    });

    test('subtitle cues cover the spoken time in order', () {
      final project = threeScenes();
      final plan = planTimeline(project, [4, 0, 1]);
      final cues = buildSubtitleCues(plan, project.scenes.map((s) => s.narration).toList());
      expect(cues, isNotEmpty);
      expect(cues.first.start, closeTo(plan.scenes[0].narrationStart, 1e-9));
      for (var i = 1; i < cues.length; i++) {
        expect(cues[i].start, greaterThanOrEqualTo(cues[i - 1].end - 1e-9));
      }
      final firstScene = cues.where((c) => c.start < plan.scenes[1].start).toList();
      expect(firstScene.last.end, closeTo(plan.scenes[0].narrationStart + 4, 1e-9));
    });

    test('silent videos still get readable subtitle time', () {
      expect(estimateReadingSeconds(''), 0);
      expect(estimateReadingSeconds('کوتاه'), 1.2);
      expect(estimateReadingSeconds('a' * 130), closeTo(10, 1e-9));
    });
  });

  group('ffmpeg command', () {
    RenderInputs inputs({String? narration, String? music, String? subs, List<TextOverlay> overlays = const []}) {
      final project = threeScenes();
      final plan = planTimeline(project, [4, 0, 1]);
      return RenderInputs(
        scenePngs: ['/w/s0.png', '/w/s1.png', '/w/s2.png'],
        motions: resolveMotions(project.scenes.map((s) => s.motion).toList()),
        transitions: project.scenes.map((s) => s.transition).toList(),
        plan: plan,
        outputPath: '/w/out.mp4',
        narrationWavPath: narration,
        musicPath: music,
        subtitleListPath: subs,
        textOverlays: overlays,
      );
    }

    test('chains Ken Burns stills with xfade and encodes H.264/AAC 1080x1920', () {
      final args = buildFfmpegArgs(inputs());
      final graph = args[args.indexOf('-filter_complex') + 1];
      expect(RegExp('zoompan=').allMatches(graph).length, 3);
      expect(graph, contains('s=1080x1920:fps=30'));
      expect(graph, contains('[s0][s1]xfade=transition=fade:duration=0.6:offset=4.7[x1]'));
      expect(graph, contains('[x1][s2]xfade=transition=fade'));
      expect(graph, contains('anullsrc=r=44100:cl=stereo'));
      expect(args, containsAllInOrder(['-c:v', 'libx264', '-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(['-c:a', 'aac']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args.last, '/w/out.mp4');
    });

    test('narration ducks the looping music; overlays and subtitles are layered', () {
      final args = buildFfmpegArgs(inputs(
        narration: '/w/n.wav',
        music: '/w/m.mp3',
        subs: '/w/subs.ffconcat',
        overlays: const [TextOverlay(pngPath: '/w/t0.png', start: 0.15, end: 4.5)],
      ));
      final graph = args[args.indexOf('-filter_complex') + 1];
      expect(args, containsAllInOrder(['-stream_loop', '-1', '-i', '/w/m.mp3']));
      expect(args, containsAllInOrder(['-f', 'concat', '-safe', '0', '-i', '/w/subs.ffconcat']));
      expect(graph, contains('sidechaincompress'));
      expect(graph, contains('amix=inputs=2'));
      expect(graph, contains('fade=t=in:st=0:d=0.35:alpha=1'));
      expect(graph, contains('setpts=PTS-STARTPTS+0.15/TB'));
      expect(graph, contains('overlay=0:0:eof_action=repeat'));
      // inputs: 3 stills, 1 overlay, 1 subtitle track, narration, music
      expect(RegExp(r'(^|;)\[6:a\]').hasMatch(graph), isTrue);
    });

    test('Ken Burns expressions per motion', () {
      expect(kenBurnsFilter(CameraMotion.zoomIn, 90), contains("z='1+0.15*on/90'"));
      expect(kenBurnsFilter(CameraMotion.zoomOut, 90), contains("z='1.15-0.15*on/90'"));
      expect(kenBurnsFilter(CameraMotion.panLeft, 90), contains("x='(iw-iw/zoom)*(1-on/90)'"));
      expect(kenBurnsFilter(CameraMotion.still, 10), contains("z='1'"));
      expect(resolveMotions(List.filled(5, CameraMotion.auto)),
          [CameraMotion.zoomIn, CameraMotion.panLeft, CameraMotion.zoomOut, CameraMotion.panRight, CameraMotion.zoomIn]);
    });

    test('subtitle concat list fills gaps with a blank frame and repeats the last entry', () {
      final list = buildSubtitleConcatList(
        const [SubtitleCue(1, 2.5, 'a'), SubtitleCue(3, 4, 'b')],
        ['sub_0.png', 'sub_1.png'],
        'blank.png',
        6,
      );
      expect(list.split('\n').where((l) => l.isNotEmpty).toList(), [
        'ffconcat version 1.0',
        "file 'blank.png'", 'duration 1',
        "file 'sub_0.png'", 'duration 1.5',
        "file 'blank.png'", 'duration 0.5',
        "file 'sub_1.png'", 'duration 1',
        "file 'blank.png'", 'duration 2',
        "file 'blank.png'",
      ]);
    });

    test('progress lines', () {
      expect(parseProgressSeconds('out_time_us=2500000'), 2.5);
      expect(parseProgressSeconds('out_time_ms=1000000'), 1.0);
      expect(parseProgressSeconds('out_time=00:01:02.500000'), 62.5);
      expect(parseProgressSeconds('frame=10'), isNull);
      expect(parseProgressSeconds('out_time_us=N/A'), isNull);
    });
  });

  group('wav', () {
    test('encode/decode round trip and duration', () {
      final a = PcmAudio(Int16List.fromList([0, 1000, -1000, 32767, -32768]), 22050);
      final b = decodeWav(encodeWav(a));
      expect(b.sampleRate, 22050);
      expect(b.samples, a.samples);
      expect(PcmAudio.silence(1.5, 16000).seconds, 1.5);
    });

    test('float samples are clipped to 16 bit', () {
      final a = PcmAudio.fromFloat(Float32List.fromList([0, 0.5, 1.5, -2]), 8000);
      expect(a.samples, [0, 16384, 32767, -32768]);
    });

    test('clips are placed at their start time and resampled', () {
      final clip = PcmAudio(Int16List.fromList(List.filled(100, 1000)), 100);
      final track = layoutTrack([(start: 1.0, audio: clip)], 3, 200);
      expect(track.samples.length, 600);
      expect(track.samples[199], 0);
      expect(track.samples[200], 1000);
      expect(track.samples[399], 1000);
      expect(track.samples[401], 0);
    });

    test('rejects non-wave data', () {
      expect(() => decodeWav(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])), throwsA(isA<WavFormatException>()));
    });
  });

  test('video project survives JSON with explicit keys', () {
    final p = threeScenes().copyWith(voice: NarratorVoice.english, musicTrackId: 'city_loop', subtitles: false);
    final back = VideoProject.decode(p.encode());
    expect(back.scenes.length, 3);
    expect(back.voice, NarratorVoice.english);
    expect(back.musicTrackId, 'city_loop');
    expect(back.subtitles, isFalse);
    expect(back.scenes[0].overlayText, 'قلاب');
    expect(back.scenes[2].durationSeconds, 8);
    expect(p.encode(), contains('"voice":"piper-en_US-joe-medium"'));
  });
}
