import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/data/settings.dart';
import 'package:kiro/studio/platform/studio_platform.dart';
import 'package:kiro/studio/render/canvas_render.dart';
import 'package:kiro/studio/studio_catalog.dart';
import 'package:kiro/studio/studio_errors.dart';
import 'package:kiro/studio/studio_service.dart';
import 'package:kiro/studio/templates/templates.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'studio_fakes.dart';

Future<(StudioService, FakeImageEngine, FakeStudioPlatform, MemoryRepository)> setup({PowerStatus? power}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await SettingsController.load();
  final dir = await Directory.systemTemp.createTemp('kiro_svc');
  final platform = FakeStudioPlatform(dir, power: power ?? const PowerStatus(level: 80, charging: false));
  final engine = FakeImageEngine();
  final repo = MemoryRepository();
  final studio = await fakeStudio(settings: settings, bridge: FakeBridge(), drafts: repo, engine: engine, platform: platform);
  return (studio, engine, platform, repo);
}

void main() {
  test('image generation needs the model; after download it runs as heavy work', () async {
    final (studio, engine, platform, repo) = await setup();
    expect(studio.imageBlocker, ImageGenBlocker.noModel);
    await expectLater(studio.generateImage(prompt: 'a cat'), throwsA(isA<StudioException>().having((e) => e.code, 'code', 'no_model')));

    final ok = await studio.assets.download(imageModelCatalog.first);
    expect(ok, isTrue);
    expect(studio.canGenerateImages, isTrue);
    final path = await studio.generateImage(prompt: 'a cat');
    expect(File(path).existsSync(), isTrue);
    final req = engine.requests.single;
    expect(req.steps, imageModelCatalog.first.defaultSteps);
    expect(req.cfg, imageModelCatalog.first.defaultCfg);
    expect(req.taesdPath, endsWith('taesd.safetensors'));
    expect(platform.calls, ['begin', 'end']);
    expect(studio.busy, isFalse);

    final id = await studio.saveMediaDraft(title: 'cat', path: path);
    final d = (await repo.all()).single;
    expect(d.id, id);
    expect(d.isImage, isTrue);
  });

  test('the power rule blocks heavy work on a low battery', () async {
    final (studio, _, _, _) = await setup(power: const PowerStatus(level: 20, charging: false));
    await studio.assets.download(imageModelCatalog.first);
    await expectLater(studio.generateImage(prompt: 'x'), throwsA(isA<StudioException>().having((e) => e.code, 'code', 'power_blocked')));
    await studio.settings.setHeavyWorkPowerRule(false);
    await studio.generateImage(prompt: 'x');
  });

  test('engine errors surface as studio errors', () async {
    final (studio, engine, _, _) = await setup();
    await studio.assets.download(imageModelCatalog.first);
    engine.failWith = 'low_ram';
    await expectLater(studio.generateImage(prompt: 'x'), throwsA(isA<StudioException>().having((e) => e.code, 'code', 'low_ram')));
    expect(studio.busy, isFalse);
  });

  test('shared TAESD is kept while another image model uses it', () async {
    final (studio, _, _, _) = await setup();
    final a = imageModelCatalog[0], b = imageModelCatalog[1];
    await studio.assets.download(a);
    await studio.assets.download(b);
    await studio.assets.delete(a);
    expect(studio.assets.isInstalled(b), isTrue);
    expect(studio.assets.isInstalled(a), isFalse);
  });

  testWidgets('templates render to PNG at the export size', (tester) async {
    final (studio, _, _, _) = await setup();
    await tester.runAsync(() async {
      for (final kind in TemplateKind.values) {
        final path = await studio.exportTemplate(TemplateData(
          kind: kind,
          title: 'عنوان آزمایشی',
          body: kind == TemplateKind.list ? '۱. اول\n۲. دوم\n- سوم' : 'متن نمونه برای قالب',
          format: kind == TemplateKind.title ? TemplateFormat.story : TemplateFormat.portrait,
          slideIndex: 2,
          slideCount: 5,
        ));
        final bytes = await File(path).readAsBytes();
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        final w = ByteData.sublistView(bytes).getUint32(16);
        final h = ByteData.sublistView(bytes).getUint32(20);
        expect(w, 1080);
        expect(h, kind == TemplateKind.title ? 1920 : 1350);
      }
    });
  });

  test('template helpers', () {
    expect(parseListItems('1. one\n- two\n• three\n۴) چهار\n\n'), ['one', 'two', 'three', 'چهار']);
    expect(directionOf('سلام world'), TextDirection.rtl);
    expect(directionOf('Hello دنیا'), TextDirection.ltr);
    expect(directionOf('123'), TextDirection.rtl);
    expect(fitFontSize((s) => s <= 40.2, minSize: 10, maxSize: 90), closeTo(40.2, 0.5));
    expect(fitFontSize((s) => true, minSize: 10, maxSize: 90), 90);
    expect(fitFontSize((s) => false, minSize: 10, maxSize: 90), 10);
    final r = coverSource(const Size(1000, 500), const Size(100, 100));
    expect(r, const Rect.fromLTWH(250, 0, 500, 500));
  });
}
