import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/ton_verifier.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/data/settings.dart';
import 'package:kiro/features/billing/billing_controller.dart';
import 'package:kiro/features/billing/credit_tiles.dart';
import 'package:kiro/features/studio/editor_tab.dart';
import 'package:kiro/features/studio/studio_common.dart';
import 'package:kiro/studio/editor/edit_project.dart';
import 'package:kiro/studio/studio_assets.dart';
import 'package:kiro/studio/studio_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'billing/billing_test_utils.dart';
import 'fakes.dart';
import 'studio_fakes.dart';

final _png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

Future<(SettingsController, StudioService, BillingController, StudioUiState)> _setup({String lang = 'fa'}) async {
  SharedPreferences.setMockInitialValues({'onboardingDone': true, 'languageCode': lang});
  final settings = await SettingsController.load();
  final studio = await fakeStudio(settings: settings, bridge: FakeBridge(), drafts: MemoryRepository(), owner: false);
  final dir = await Directory.systemTemp.createTemp('kiro_edit_ui');
  final ex = FakeExplorer(testPaymentId);
  final keys = MemorySecureKeyStore();
  final svc = (await BillingService.open(
    keys: keys,
    dataDir: dir,
    verifier: (addr) => PaymentVerifier.standard(receiveAddress: addr, client: ex.client, sleep: noSleep),
    rng: Random(9),
  ))
      .valueOrNull!;
  await svc.restoreFromRecoveryCode(testRecovery);
  final owner = OwnerAccess(keys, hash: testOwnerHash());
  final billing = BillingController(svc, gate: studio.gate, owner: owner);
  studio.gate.owner = owner;
  await billing.checkPayments();
  final photo = File('${dir.path}/p.png')..writeAsBytesSync(_png);
  final ui = StudioUiState(languageCode: lang);
  ui.loadEdit(const EditProject(
    texts: [EditText(text: 'متن نمونه', start: 0, end: 2)],
    subtitles: [EditSubtitle(text: 'زیرنویس', start: 0, end: 2)],
    musicTrackId: 'happy_loop',
  )
      .addClip(EditClip(id: '1', path: photo.path, kind: MediaKind.image, sourceSeconds: 4))
      .addClip(EditClip(id: '2', path: '${dir.path}/v.mp4', kind: MediaKind.video, sourceSeconds: 12, hasAudio: true)));
  return (settings, studio, billing, ui);
}

Widget _app(SettingsController settings, StudioService studio, BillingController billing, StudioUiState ui, Widget child, {String lang = 'fa'}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<StudioService>.value(value: studio),
        ChangeNotifierProvider<StudioAssetManager>.value(value: studio.assets),
        ChangeNotifierProvider<BillingController>.value(value: billing),
        ChangeNotifierProvider<StudioUiState>.value(value: ui),
      ],
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: const [Locale('fa', 'IR'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: child),
      ),
    );

void main() {
  for (final lang in ['fa', 'en']) {
    testWidgets('editor tab ($lang, small phone): clips, tools and the export price, no overflow', (tester) async {
      tester.view.physicalSize = const Size(720, 1520);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final (settings, studio, billing, ui) = (await tester.runAsync(() => _setup(lang: lang)))!;
      await tester.pumpWidget(_app(settings, studio, billing, ui, const EditorTab(), lang: lang));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final fa = lang == 'fa';
      expect(find.text(fa ? 'کلیپ ۱' : 'Clip 1'), findsOneWidget);
      expect(find.text(fa ? 'کلیپ ۲' : 'Clip 2'), findsOneWidget);
      await tester.scrollUntilVisible(find.text(fa ? 'خروجی MP4' : 'Export MP4'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      // First export is free.
      expect(find.textContaining(fa ? 'اولین بار رایگان' : 'First use free'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('editor: split, move and delete update the project', (tester) async {
    final (settings, studio, billing, ui) = (await tester.runAsync(() => _setup()))!;
    await tester.pumpWidget(_app(settings, studio, billing, ui, const EditorTab()));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('نصف کردن').last);
    await tester.pumpAndSettle();
    expect(ui.edit.clips, hasLength(3));
    expect(ui.edit.clips[1].outSeconds, 6);
    await tester.tap(find.byTooltip('بالا').last);
    await tester.pumpAndSettle();
    expect(ui.edit.clips.map((c) => c.outSeconds), [4, 6, 6]);
    await tester.tap(find.byTooltip('حذف').first);
    await tester.pumpAndSettle();
    expect(ui.edit.clips, hasLength(2));
    await tester.pump(const Duration(seconds: 1)); // let the autosave timer fire
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner access in settings: a wrong code is refused, the right one unlocks for good', (tester) async {
    final (settings, studio, billing, ui) = (await tester.runAsync(() => _setup()))!;
    await tester.pumpWidget(_app(settings, studio, billing, ui, const SingleChildScrollView(child: OwnerAccessTile())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('owner-code')), 'WRONG0-WRONG0-WRONG0-WRONG0-WRONG0');
    await tester.tap(find.text('فعال‌سازی'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
    expect(find.text('کد درست نیست.'), findsOneWidget);
    expect(billing.ownerUnlocked, isFalse);

    await tester.enterText(find.byKey(const ValueKey('owner-code')), testOwnerCode);
    await tester.tap(find.text('فعال‌سازی'));
    for (var i = 0; i < 20 && !billing.ownerUnlocked; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    await tester.pumpAndSettle();
    expect(billing.ownerUnlocked, isTrue);
    expect(find.text('فعال است: همهٔ امکانات پولی روی این گوشی رایگان است.'), findsOneWidget);
    expect(studio.quote(PaidFeature.editorExport, duration: const Duration(minutes: 3)).free, FreeReason.owner);
    expect(tester.takeException(), isNull);
  });
}
