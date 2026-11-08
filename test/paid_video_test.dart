import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/ton_verifier.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/data/settings.dart';
import 'package:kiro/studio/image/image_engine.dart';
import 'package:kiro/studio/platform/studio_platform.dart';
import 'package:kiro/studio/studio_assets.dart';
import 'package:kiro/studio/studio_catalog.dart';
import 'package:kiro/studio/studio_errors.dart';
import 'package:kiro/studio/studio_service.dart';
import 'package:kiro/studio/video/ffmpeg_command.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'billing/billing_test_utils.dart';
import 'fakes.dart';
import 'studio_fakes.dart';

/// 1x1 PNG so the clip renderer can decode the generated "picture".
final _png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

class _PngEngine extends FakeImageEngine {
  void Function()? onRequest;

  @override
  Stream<ImageEvent> generate(ImageRequest request) async* {
    requests.add(request);
    yield const ImageProgress('sampling', step: 1, steps: 2);
    onRequest?.call();
    if (failWith != null) {
      yield ImageFailed(failWith!);
      return;
    }
    await File(request.outPath).writeAsBytes(_png);
    yield ImageDone(path: request.outPath, seed: 1, millis: 1);
  }
}

/// Platform whose FFmpeg is a shell script: it logs its arguments and writes the output file
/// (the last argument), or fails when [fail] is set.
class _FfmpegPlatform extends FakeStudioPlatform {
  _FfmpegPlatform(super.dir, this.script);
  final String script;

  @override
  Future<String?> ffmpegPath() async => script;
}

Future<String> _fakeFfmpeg(Directory dir, {bool fail = false}) async {
  final log = '${dir.path}/ffmpeg.log';
  final f = File('${dir.path}/${fail ? 'ffmpeg_fail' : 'ffmpeg_ok'}.sh');
  await f.writeAsString(fail
      ? '#!/bin/sh\necho "\$*" >> "$log"\necho boom >&2\nexit 1\n'
      : '#!/bin/sh\necho "\$*" >> "$log"\nfor a in "\$@"; do last="\$a"; done\nprintf x > "\$last"\nexit 0\n');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

class _Rig {
  _Rig(this.studio, this.engine, this.billing, this.dir);
  final StudioService studio;
  final _PngEngine engine;
  final BillingService billing;
  final Directory dir;
  List<String> get ffmpegCalls {
    final f = File('${dir.path}/ffmpeg.log');
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }
}

Future<_Rig> _rig({bool ffmpegFails = false, bool withModel = true, bool withBilling = true, bool freeUsed = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await SettingsController.load();
  final dir = await Directory.systemTemp.createTemp('kiro_paid');
  final engine = _PngEngine();
  final platform = _FfmpegPlatform(dir, await _fakeFfmpeg(dir, fail: ffmpegFails));
  final ex = FakeExplorer(testPaymentId);
  final billing = (await BillingService.open(
    keys: MemorySecureKeyStore(),
    dataDir: dir,
    verifier: (addr) => PaymentVerifier.standard(receiveAddress: addr, client: ex.client, sleep: noSleep),
    rng: Random(3),
  ))
      .valueOrNull!;
  await billing.restoreFromRecoveryCode(testRecovery); // 0.8 TON on the fake chain
  // Most tests check charging, so the free first use is already taken unless asked otherwise.
  if (freeUsed) await billing.markFreeUsedForTest(PaidFeature.topicVideo);
  final studio = StudioService(
    platform: platform,
    imageEngine: engine,
    tts: FakeTts(),
    assets: StudioAssetManager(FakeDownloader('${dir.path}/models')),
    settings: settings,
    bridge: FakeBridge(),
    drafts: MemoryRepository(),
    billing: withBilling ? billing : null,
    loadAsset: (_) async => ByteData.sublistView(Uint8List.fromList([1, 2, 3])),
  );
  await studio.init();
  if (withModel) await studio.assets.download(imageModelCatalog.first);
  return _Rig(studio, engine, billing, dir);
}

Matcher _code(String c) => throwsA(isA<StudioException>().having((e) => e.code, 'code', c));

void main() {
  testWidgets('a paid 20 s video: 2 pictures, 2 clips joined, credit spent once', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig();
      expect(r.billing.balance.available, 800000000);
      final path = await r.studio.renderTopicVideo(topic: 'rainy coffee shop', duration: const Duration(seconds: 20));
      expect(File(path).existsSync(), isTrue);
      expect(r.engine.requests, hasLength(2));
      expect(r.engine.requests.first.prompt, startsWith('Scene 1 of 2'));
      expect(r.engine.requests.last.prompt, contains('rainy coffee shop'));
      // two clip encodes + one join with stream copy
      final calls = r.ffmpegCalls;
      expect(calls, hasLength(3));
      expect(calls.last, contains('-f concat'));
      expect(calls.last, contains('-c copy'));
      expect(r.billing.balance.spent, 500000000);
      expect(r.billing.balance.reserved, 0);
      expect(r.billing.balance.available, 300000000);
      expect(r.studio.busy, isFalse);
    });
  });

  testWidgets('the first topic video is free, the next one is charged', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig(freeUsed: false);
      expect(r.studio.quote(PaidFeature.topicVideo, duration: const Duration(seconds: 20)).free, FreeReason.firstUse);
      await r.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 20));
      expect(r.billing.balance.spent, 0);
      expect(r.billing.balance.available, 800000000);
      expect(r.studio.quote(PaidFeature.topicVideo, duration: const Duration(seconds: 20)).free, FreeReason.none);
      await r.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 20));
      expect(r.billing.balance.spent, 500000000);
    });
  });

  testWidgets('a failed free first use stays free for the next try', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig(freeUsed: false, ffmpegFails: true);
      await expectLater(r.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 10)), _code('render_failed'));
      expect(r.billing.isFirstUseFree(PaidFeature.topicVideo), isTrue);
    });
  });

  testWidgets('background music is laid over the joined video', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig();
      await r.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 10), musicTrackId: musicCatalog.first.id);
      final calls = r.ffmpegCalls;
      expect(calls, hasLength(3)); // clip, join, music
      expect(calls[1], contains('-c copy'));
      expect(calls[2], contains('-stream_loop -1'));
      expect(calls[2], contains('-c:v copy'));
    });
  });

  testWidgets('a failed render releases the credit', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig(ffmpegFails: true);
      await expectLater(r.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 20)), _code('render_failed'));
      expect(r.billing.balance.available, 800000000);
      expect(r.billing.balance.spent, 0);
      expect(r.billing.balance.reserved, 0);
      expect(r.studio.busy, isFalse);
    });
  });

  testWidgets('cancel releases the credit', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig();
      r.engine.onRequest = () {
        unawaited(r.studio.cancel());
        r.engine.failWith = 'cancelled';
      };
      await expectLater(r.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 30)), _code('cancelled'));
      expect(r.engine.requests, hasLength(1));
      expect(r.billing.balance.available, 800000000);
      expect(r.billing.balance.reserved, 0);
    });
  });

  testWidgets('nothing is reserved when credit, model, topic or billing is missing', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig();
      await expectLater(r.studio.renderTopicVideo(topic: 'x', duration: const Duration(minutes: 1)), _code('billing_insufficientFunds'));
      await expectLater(r.studio.renderTopicVideo(topic: '  ', duration: const Duration(seconds: 10)), _code('no_topic'));
      await expectLater(r.studio.renderTopicVideo(topic: 'x', duration: const Duration(minutes: 11)), _code('billing_unsupportedDuration'));
      expect(r.engine.requests, isEmpty);
      expect(r.billing.balance.available, 800000000);

      final noModel = await _rig(withModel: false);
      expect(noModel.studio.paidVideoBlocker, 'no_model');
      await expectLater(noModel.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 10)), _code('no_model'));
      expect(noModel.billing.balance.reserved, 0);

      final noBilling = await _rig(withBilling: false);
      expect(noBilling.studio.paidVideoBlocker, 'billing_unavailable');
      await expectLater(noBilling.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 10)), _code('billing_unavailable'));
    });
  });

  testWidgets('a low battery blocks before any credit is reserved', (tester) async {
    await tester.runAsync(() async {
      final r = await _rig();
      (r.studio.platform as FakeStudioPlatform).power = const PowerStatus(level: 5, charging: false);
      await expectLater(r.studio.renderTopicVideo(topic: 'x', duration: const Duration(seconds: 10)), _code('power_blocked'));
      expect(r.billing.balance.reserved, 0);
      expect(r.billing.balance.available, 800000000);
    });
  });

  group('join commands', () {
    test('concat list quotes names', () {
      expect(buildClipConcatList(['clip_0.mp4', "it's.mp4"]), "ffconcat version 1.0\nfile 'clip_0.mp4'\nfile 'it'\\''s.mp4'\n");
    });

    test('concat copies streams; music mux copies video and trims to the length', () {
      final c = buildConcatArgs('/w/list', '/o.mp4');
      expect(c.join(' '), contains('-f concat -safe 0 -i /w/list -c copy'));
      expect(c.last, '/o.mp4');
      final m = buildMusicMuxArgs(videoPath: '/j.mp4', musicPath: '/m.mp3', musicVolume: 2, totalSeconds: 60, outputPath: '/o.mp4');
      final s = m.join(' ');
      expect(s, contains('-map 0:v -map [aout] -c:v copy'));
      expect(s, contains('volume=1,atrim=0:60'));
      expect(s, contains('afade=t=out:st=58.5:d=1.5'));
      expect(m.last, '/o.mp4');
    });
  });
}
