import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/ton_verifier.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/data/settings.dart';
import 'package:kiro/studio/editor/edit_project.dart';
import 'package:kiro/studio/editor/editor_command.dart';
import 'package:kiro/studio/editor/editor_renderer.dart';
import 'package:kiro/studio/studio_assets.dart';
import 'package:kiro/studio/studio_errors.dart';
import 'package:kiro/studio/studio_service.dart';
import 'package:kiro/studio/video/ffmpeg_command.dart' show TextOverlay;
import 'package:kiro/studio/video/video_project.dart' show NarratorVoice;
import 'package:shared_preferences/shared_preferences.dart';

import 'billing/billing_test_utils.dart';
import 'fakes.dart';
import 'studio_fakes.dart';

EditClip video(String id, double src, {double speed = 1, bool audio = true, EditTransition tr = EditTransition.fade}) =>
    EditClip(id: id, path: '/v/$id.mp4', kind: MediaKind.video, sourceSeconds: src, hasAudio: audio, speed: speed, transition: tr);

EditClip image(String id, double len) => EditClip(id: id, path: '/i/$id.png', kind: MediaKind.image, sourceSeconds: len);

Set<String> _buildScriptFilters() {
  final src = File('tool/ffmpeg/build_ffmpeg.sh').readAsStringSync();
  final out = <String>{};
  for (final m in RegExp(r'--enable-filter=([a-z0-9_,]+)').allMatches(src)) {
    out.addAll(m[1]!.split(','));
  }
  return out;
}

final _png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  group('project', () {
    test('timeline length subtracts the cross-fades; a cut is 0.04 s', () {
      final p = const EditProject(transitionSeconds: 0.5)
          .addClip(video('a', 4))
          .addClip(video('b', 6, tr: EditTransition.none))
          .addClip(image('c', 3));
      expect(p.transitionAfter(0), 0.5);
      expect(p.transitionAfter(1), hardCutSeconds);
      expect(p.transitionAfter(2), 0);
      expect(p.totalSeconds, closeTo(4 + 6 + 3 - 0.5 - 0.04, 1e-9));
      expect(p.clipStarts(), [0, 3.5, closeTo(9.46, 1e-9)]);
    });

    test('a long transition is capped by the shorter clip', () {
      final p = const EditProject(transitionSeconds: 1.5).addClip(video('a', 1)).addClip(video('b', 10));
      expect(p.transitionAfter(0), closeTo(0.4, 1e-9));
    });

    test('trim and speed are clamped; speed changes the output length', () {
      final c = video('a', 10).copyWith(trimStart: 2, trimEnd: 8, speed: 2).normalized();
      expect(c.outSeconds, 3);
      final slow = c.copyWith(speed: 0.1).normalized();
      expect(slow.speed, minSpeed);
      expect(slow.outSeconds, 12);
      final bad = video('a', 10).copyWith(trimStart: 9.9, trimEnd: 3).normalized();
      expect(bad.trimEnd - bad.trimStart, greaterThanOrEqualTo(minClipSeconds));
      expect(bad.trimEnd, lessThanOrEqualTo(10));
    });

    test('split, move, remove', () {
      var p = const EditProject().addClip(video('a', 10, speed: 2).copyWith(trimStart: 2, trimEnd: 10)).addClip(image('b', 4));
      expect(p.clips.first.outSeconds, 4);
      p = p.splitClip(0, 1, newId: 'a2');
      expect(p.clips.map((c) => c.id), ['a', 'a2', 'b']);
      expect(p.clips[0].trimStart, 2);
      expect(p.clips[0].trimEnd, 4); // 1 s of output at 2x = 2 s of source
      expect(p.clips[0].transition, EditTransition.none);
      expect(p.clips[1].trimStart, 4);
      expect(p.clips[1].trimEnd, 10);
      p = p.splitClip(2, 1.5, newId: 'b2');
      expect(p.clips[2].outSeconds, 1.5);
      expect(p.clips[3].outSeconds, 2.5);
      expect(p.splitClip(0, 0.2, newId: 'x'), same(p), reason: 'too short to split');
      p = p.moveClip(3, 0);
      expect(p.clips.first.id, 'b2');
      p = p.removeClip(0);
      expect(p.clips, hasLength(3));
      expect(p.moveClip(0, 9), same(p));
      expect(p.removeClip(9), same(p));
    });

    test('JSON round trip with explicit keys; broken input gives an empty project', () {
      final p = const EditProject(
        aspect: EditAspect.feed,
        fit: FitMode.fit,
        filter: FilterPreset.cinematic,
        musicTrackId: 'file',
        musicFile: '/m/song.mp3',
        voice: NarratorVoice.persian,
        narration: 'سلام',
        muteOriginal: true,
        texts: [EditText(text: 'قلاب', start: 0, end: 2, position: TextPosition.bottom, size: 2)],
        subtitles: [EditSubtitle(text: 'زیرنویس', start: 1, end: 3)],
      ).addClip(video('a', 5, speed: 1.5)).addClip(image('b', 2));
      final back = EditProject.decode(p.encode());
      expect(back.encode(), p.encode());
      expect(jsonDecode(p.encode())['aspect'], '4x5');
      expect(EditProject.decode('{nope').isEmpty, isTrue);
      expect(EditProject.decode('[1,2]').isEmpty, isTrue);
    });

    test('the preview keeps only the first 20 seconds', () {
      final p = const EditProject().addClip(video('a', 15)).addClip(video('b', 15)).addClip(video('c', 15));
      final cut = cutForPreview(p);
      expect(cut.totalSeconds, closeTo(previewSeconds, 0.01));
      expect(cut.clips, hasLength(2));
      final short = const EditProject().addClip(video('a', 5));
      expect(cutForPreview(short), same(short));
    });
  });

  group('FFmpeg command', () {
    EditProject sample() => const EditProject(transitionSeconds: 0.5, filter: FilterPreset.vivid)
        .addClip(video('a', 4, speed: 2))
        .addClip(video('b', 3, audio: false, tr: EditTransition.dissolve))
        .addClip(image('c', 2));

    test('trim by input seek, speed, crop to 9:16, xfade offsets, preset and fades', () {
      final p = sample();
      final args = buildEditArgs(resolveEditInputs(p, outputPath: '/o.mp4', imagePngs: {2: '/w/img_2.png'}));
      final s = args.join(' ');
      expect(s, contains('-ss 0 -t 4.05 -i /v/a.mp4'));
      expect(s, contains('-loop 1 -framerate 30 -t 2.1 -i /w/img_2.png'));
      expect(s, contains('setpts=(PTS-STARTPTS)/2'));
      expect(s, contains('scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920'));
      // clip a lasts 2 s at 2x; 0.5 s cross-fade; then b (3 s) dissolves into the photo.
      expect(s, contains('xfade=transition=fade:duration=0.5:offset=1.5'));
      expect(s, contains('xfade=transition=dissolve:duration=0.5:offset=4'));
      expect(s, contains('eq=brightness=0.02:contrast=1.12:saturation=1.35'));
      expect(s, contains('fade=t=in:st=0:d=0.6'));
      expect(s, contains('atempo=2'));
      expect(s, isNot(contains('[1:a]')), reason: 'clip b has no sound');
      expect(args.last, '/o.mp4');
      expect(args[args.indexOf('-t', args.indexOf('-filter_complex')) + 1], n3(p.totalSeconds));
    });

    test('fit mode blurs a copy behind the picture; 4:5 output; preview is half size and watermarked', () {
      final p = sample().copyWith(fit: FitMode.fit, aspect: EditAspect.feed);
      final s = buildEditArgs(resolveEditInputs(p, outputPath: '/o.mp4', watermarkPng: '/w/wm.png', preview: true)).join(' ');
      expect(s, contains('boxblur'));
      expect(s, contains('force_original_aspect_ratio=decrease'));
      expect(s, contains('overlay=(W-w)/2:(H-h)/2'));
      expect(s, contains('scale=540:674,'));
      expect(s, contains('/w/wm.png'));
      expect(s, contains('-preset ultrafast'));
    });

    test('music is ducked under narration; mute drops the clips\' own sound', () {
      final p = sample().copyWith(muteOriginal: true);
      final s = buildEditArgs(resolveEditInputs(p, outputPath: '/o.mp4', narrationWavPath: '/w/n.wav', musicPath: '/m.mp3')).join(' ');
      expect(s, contains('-stream_loop -1 -i /m.mp3'));
      expect(s, contains('sidechaincompress'));
      expect(s, isNot(contains('atempo')));
      expect(s, isNot(contains('[0:a]')));
      final silent = buildEditArgs(resolveEditInputs(p, outputPath: '/o.mp4')).join(' ');
      expect(silent, contains('anullsrc'));
    });

    test('text overlays and subtitles are laid over in their windows', () {
      final p = sample();
      final s = buildEditArgs(resolveEditInputs(
        p,
        outputPath: '/o.mp4',
        overlays: const [TextOverlay(pngPath: '/w/t.png', start: 1, end: 3)],
        subtitleListPath: '/w/subs.ffconcat',
      )).join(' ');
      expect(s, contains('-loop 1 -framerate 30 -t 2 -i /w/t.png'));
      expect(s, contains('setpts=PTS-STARTPTS+1/TB'));
      expect(s, contains('-f concat -safe 0 -i /w/subs.ffconcat'));
    });

    test('every filter used is enabled in the Android FFmpeg build', () {
      final enabled = _buildScriptFilters();
      final variants = [
        sample(),
        sample().copyWith(fit: FitMode.fit, muteOriginal: false, filter: FilterPreset.mono),
      ];
      for (final p in variants) {
        final used = filterNamesIn(buildEditArgs(resolveEditInputs(
          p,
          outputPath: '/o.mp4',
          overlays: const [TextOverlay(pngPath: '/t.png', start: 0, end: 2)],
          subtitleListPath: '/s.ffconcat',
          narrationWavPath: '/n.wav',
          musicPath: '/m.mp3',
          watermarkPng: '/wm.png',
          preview: true,
        )));
        expect(used.difference(enabled), isEmpty);
      }
      expect(enabled, containsAll(['atempo', 'transpose', 'hflip', 'vflip']));
    });

    test('probe parsing', () {
      const out = '''
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'a.mp4':
  Duration: 00:01:04.52, start: 0.000000, bitrate: 166 kb/s
  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1920x1080 [SAR 1:1 DAR 16:9], 25 fps
  Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s
''';
      final p = parseProbe(out)!;
      expect(p.seconds, closeTo(64.52, 1e-9));
      expect(p.hasAudio, isTrue);
      expect(p.width, 1920);
      expect(p.height, 1080);
      expect(parseProbe(out.replaceAll(RegExp(r'.*Audio:.*\n'), ''))!.hasAudio, isFalse);
      expect(parseProbe('Input #0, mp3\n  Duration: 00:00:10.00\n  Stream #0:0: Audio: mp3'), isNull);
      expect(parseProbe('garbage'), isNull);
    });
  });

  // Runs the real FFmpeg when it is installed (skipped otherwise).
  final ffmpeg = Process.runSync('sh', ['-c', 'command -v ffmpeg']).stdout.toString().trim();
  test('real FFmpeg: trims, speeds, joins and mixes into an H.264/AAC MP4 of the planned length', () async {
    final dir = await Directory.systemTemp.createTemp('kiro_edit_real');
    Future<void> make(List<String> a) async {
      final r = await Process.run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', ...a]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    await make(['-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '4', '-c:v', 'libx264', '-c:a', 'aac', '-shortest', '${dir.path}/a.mp4']);
    await make(['-f', 'lavfi', '-i', 'testsrc2=size=360x640:rate=30', '-t', '3', '-c:v', 'libx264', '${dir.path}/b.mp4']);
    await make(['-f', 'lavfi', '-i', 'color=c=red:s=1080x1920', '-frames:v', '1', '${dir.path}/c.png']);
    await make(['-f', 'lavfi', '-i', 'sine=frequency=220', '-t', '10', '${dir.path}/m.mp3']);
    final probeA = parseProbe((await Process.run(ffmpeg, ['-hide_banner', '-i', '${dir.path}/a.mp4'])).stderr.toString())!;
    final probeB = parseProbe((await Process.run(ffmpeg, ['-hide_banner', '-i', '${dir.path}/b.mp4'])).stderr.toString())!;
    expect(probeA.hasAudio, isTrue);
    expect(probeB.hasAudio, isFalse);
    var p = EditProject(filter: FilterPreset.vivid, fit: FitMode.fit)
        .addClip(EditClip(id: 'a', path: '${dir.path}/a.mp4', kind: MediaKind.video, sourceSeconds: probeA.seconds, hasAudio: true, trimStart: 0.5, trimEnd: 3.5, speed: 1.5))
        .addClip(EditClip(id: 'b', path: '${dir.path}/b.mp4', kind: MediaKind.video, sourceSeconds: probeB.seconds, speed: 0.5, transition: EditTransition.none))
        .addClip(EditClip(id: 'c', path: '${dir.path}/c.png', kind: MediaKind.image, sourceSeconds: 2));
    p = p.splitClip(1, 2, newId: 'b2');
    final out = '${dir.path}/out.mp4';
    final r = await Process.run(ffmpeg, buildEditArgs(resolveEditInputs(p, outputPath: out, musicPath: '${dir.path}/m.mp3')));
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final info = (await Process.run(ffmpeg, ['-hide_banner', '-i', out])).stderr.toString();
    final probe = parseProbe(info)!;
    expect(probe.seconds, closeTo(p.totalSeconds, 0.15));
    expect(probe.width, 1080);
    expect(probe.height, 1920);
    expect(probe.hasAudio, isTrue);
    expect(info, contains('h264'));
    expect(info, contains('aac'));
    await dir.delete(recursive: true);
  }, skip: ffmpeg.isEmpty ? 'ffmpeg not installed' : false, timeout: const Timeout(Duration(minutes: 2)));

  group('studio service', () {
    Future<(StudioService, BillingService, Directory)> rig({bool fail = false}) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await SettingsController.load();
      final dir = await Directory.systemTemp.createTemp('kiro_edit_svc');
      final log = '${dir.path}/ffmpeg.log';
      final script = File('${dir.path}/ffmpeg.sh');
      await script.writeAsString(fail
          ? '#!/bin/sh\necho "\$*" >> "$log"\nexit 1\n'
          : '#!/bin/sh\necho "\$*" >> "$log"\nfor a in "\$@"; do last="\$a"; done\nprintf x > "\$last"\nexit 0\n');
      await Process.run('chmod', ['+x', script.path]);
      final ex = FakeExplorer(testPaymentId);
      final billing = (await BillingService.open(
        keys: MemorySecureKeyStore(),
        dataDir: dir,
        verifier: (addr) => PaymentVerifier.standard(receiveAddress: addr, client: ex.client, sleep: noSleep),
        rng: Random(4),
      ))
          .valueOrNull!;
      await billing.restoreFromRecoveryCode(testRecovery); // 0.8 TON
      final studio = StudioService(
        platform: _ScriptPlatform(dir, script.path),
        imageEngine: FakeImageEngine(),
        tts: FakeTts(),
        assets: StudioAssetManager(FakeDownloader('${dir.path}/models')),
        settings: settings,
        bridge: FakeBridge(),
        drafts: MemoryRepository(),
        billing: billing,
        loadAsset: (_) async => ByteData.sublistView(Uint8List.fromList([1, 2, 3])),
      );
      await studio.init();
      return (studio, billing, dir);
    }

    Future<EditProject> photoProject(Directory dir, double seconds) async {
      final f = File('${dir.path}/photo.png');
      await f.writeAsBytes(_png);
      return const EditProject().addClip(EditClip(id: 'p', path: f.path, kind: MediaKind.image, sourceSeconds: seconds));
    }

    testWidgets('preview is free; the first export is free, the next one is charged by length', (tester) async {
      await tester.runAsync(() async {
        final (studio, billing, dir) = await rig();
        final p = (await photoProject(dir, 5)).copyWith(texts: const [EditText(text: 'سلام', start: 0, end: 3)]);
        final preview = await studio.renderEdit(p, preview: true);
        expect(File(preview).existsSync(), isTrue);
        expect(billing.balance.reserved + billing.balance.spent, 0);
        expect(studio.quote(PaidFeature.editorExport, duration: p.duration).free, FreeReason.firstUse);
        await studio.renderEdit(p);
        expect(billing.balance.spent, 0);
        expect(studio.quote(PaidFeature.editorExport, duration: p.duration).charge, parseTonToNanotons('0.2'));
        final out = await studio.renderEdit(p);
        expect(File(out).existsSync(), isTrue);
        expect(billing.balance.spent, parseTonToNanotons('0.2'));
        final calls = File('${dir.path}/ffmpeg.log').readAsLinesSync();
        expect(calls.first, contains('ultrafast'));
        expect(calls.last, contains('libx264'));
        expect(studio.busy, isFalse);
      });
    });

    testWidgets('a failed export releases the credit; nothing is reserved for an empty project', (tester) async {
      await tester.runAsync(() async {
        final (studio, billing, dir) = await rig(fail: true);
        await billing.markFreeUsedForTest(PaidFeature.editorExport);
        final p = await photoProject(dir, 3);
        await expectLater(studio.renderEdit(p), throwsA(isA<StudioException>().having((e) => e.code, 'code', 'render_failed')));
        expect(billing.balance.reserved, 0);
        expect(billing.balance.spent, 0);
        await expectLater(studio.renderEdit(const EditProject()), throwsA(isA<StudioException>().having((e) => e.code, 'code', 'no_clips')));
        expect(studio.busy, isFalse);
      });
    });

    testWidgets('the editor project is saved and loaded; a missing file is a clear error', (tester) async {
      await tester.runAsync(() async {
        final (studio, _, dir) = await rig();
        final p = await photoProject(dir, 4);
        await studio.saveEditorProject(p);
        expect((await studio.loadEditorProject()).encode(), p.encode());
        await expectLater(studio.clipFromFile('${dir.path}/nope.mp4'), throwsA(isA<StudioException>().having((e) => e.code, 'code', 'missing_media')));
        final img = await studio.clipFromFile('${dir.path}/photo.png');
        expect(img.isImage, isTrue);
        expect(img.outSeconds, defaultImageSeconds);
      });
    });
  });
}

class _ScriptPlatform extends FakeStudioPlatform {
  _ScriptPlatform(super.dir, this.script);
  final String script;
  @override
  Future<String?> ffmpegPath() async => script;
}
