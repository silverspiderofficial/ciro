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
import 'package:kiro/features/studio/studio_common.dart';
import 'package:kiro/features/studio/video_tab.dart';
import 'package:kiro/studio/studio_assets.dart';
import 'package:kiro/studio/studio_catalog.dart';
import 'package:kiro/studio/studio_service.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'billing/billing_test_utils.dart';
import 'fakes.dart';
import 'studio_fakes.dart';

Future<(SettingsController, StudioService, BillingController)> _setup({String lang = 'fa'}) async {
  SharedPreferences.setMockInitialValues({'onboardingDone': true, 'languageCode': lang});
  final settings = await SettingsController.load();
  final studio = await fakeStudio(settings: settings, bridge: FakeBridge(), drafts: MemoryRepository(), owner: false);
  final dir = await Directory.systemTemp.createTemp('kiro_paid_ui');
  final ex = FakeExplorer(testPaymentId);
  final svc = (await BillingService.open(
    keys: MemorySecureKeyStore(),
    dataDir: dir,
    verifier: (addr) => PaymentVerifier.standard(receiveAddress: addr, client: ex.client, sleep: noSleep),
    rng: Random(5),
  ))
      .valueOrNull!;
  await svc.restoreFromRecoveryCode(testRecovery);
  await svc.markFreeUsedForTest(PaidFeature.topicVideo);
  final billing = BillingController(svc, gate: studio.gate);
  await billing.checkPayments(); // so the screen's own quiet check is skipped
  return (settings, studio, billing);
}

Widget _app(SettingsController settings, StudioService studio, BillingController billing, Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<StudioService>.value(value: studio),
        ChangeNotifierProvider<StudioAssetManager>.value(value: studio.assets),
        ChangeNotifierProvider<BillingController>.value(value: billing),
        ChangeNotifierProvider<StudioUiState>(create: (_) => StudioUiState(languageCode: 'fa')),
      ],
      child: MaterialApp(
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('video tab: tiers with TON price and clips, balance, pay sheet with notice, QR and comment', (tester) async {
    // A typical phone screen (360x800 dp).
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final (settings, studio, billing) = (await tester.runAsync(_setup))!;
    await tester.pumpWidget(_app(settings, studio, billing, const VideoTab()));
    await tester.pumpAndSettle();

    expect(find.text('ویدیوی هوش مصنوعی از یک موضوع'), findsOneWidget);
    expect(find.text('۱۰ ثانیه · ۰.۳ TON · ۱ کلیپ'), findsOneWidget);
    expect(find.text('۱۰ دقیقه · ۸ TON · ۶۰ کلیپ'), findsOneWidget);
    expect(find.textContaining('اعتبار: ۰.۸ TON'), findsOneWidget);
    // No image model in the fake studio: the render button is disabled and nothing is charged.
    expect(find.text('برای ویدیوی هوش مصنوعی ابتدا مدل تصویر را دانلود کنید. تا آن موقع هزینه‌ای کم نمی‌شود.'), findsOneWidget);

    await tester.ensureVisible(find.text('افزایش اعتبار'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزایش اعتبار'));
    await tester.pumpAndSettle();
    expect(find.text(paymentNoticeFa), findsOneWidget);
    // One big wallet button; the comment and QR stay under the collapsed manual section.
    expect(find.text('پرداخت با کیف پول'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('kiro-$testPaymentId'), findsNothing);
    await tester.tap(find.text('پرداخت دستی (اگر کیف پول باز نشد)'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('kiro-$testPaymentId'), findsOneWidget);
    expect(find.text('پرداخت کردم، بررسی کن'), findsOneWidget);
    expect(find.text('مبلغ: ۰.۷ TON'), findsOneWidget); // default tier is 30 s
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: payment id and recovery code sit under a collapsed section; code hidden until tapped', (tester) async {
    final (settings, studio, billing) = (await tester.runAsync(_setup))!;
    await tester.pumpWidget(_app(settings, studio, billing, const SingleChildScrollView(child: CreditTiles())));
    await tester.pumpAndSettle();
    final code = billing.service!.recoveryCode;
    expect(find.text(code), findsNothing);
    expect(find.text(testPaymentId), findsNothing);
    await tester.tap(find.text('پیشرفته / پشتیبان'));
    await tester.pumpAndSettle();
    expect(find.text(testPaymentId), findsOneWidget);
    expect(find.text(code), findsNothing);
    await tester.tap(find.text('برای نمایش بزنید'));
    await tester.pumpAndSettle();
    expect(find.text(code), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without billing the video tab shows a friendly message and still works', (tester) async {
    final (settings, studio, _) = (await tester.runAsync(_setup))!;
    studio.gate = PaidGate();
    await tester.pumpWidget(_app(settings, studio, BillingController(null, gate: studio.gate), const VideoTab()));
    await tester.pumpAndSettle();
    expect(find.text('ویدیوی پولی فعلاً در دسترس نیست. بقیهٔ امکانات استودیو مثل قبل کار می‌کنند.'), findsOneWidget);
    expect(find.text('ویدیو با صحنه‌های خودتان'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('English on a small phone with the model installed: no overflow, render enabled', (tester) async {
    tester.view.physicalSize = const Size(720, 1520);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final (settings, studio, billing) = (await tester.runAsync(() async {
      final r = await _setup(lang: 'en');
      await r.$2.assets.download(imageModelCatalog.first);
      return r;
    }))!;
    await tester.pumpWidget(_app(settings, studio, billing, const VideoTab()));
    await tester.pumpAndSettle();
    expect(find.text('AI video from a topic'), findsOneWidget);
    final make = find.ancestor(of: find.text('Make video (0.7 TON)'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
    expect(make, findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(make).onPressed, isNotNull);
    await tester.ensureVisible(find.text('Add credit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add credit'));
    await tester.pumpAndSettle();
    expect(find.text(paymentNoticeEn), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
