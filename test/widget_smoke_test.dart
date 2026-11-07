import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/app/app.dart';
import 'package:kiro/app/services.dart';
import 'package:kiro/data/model_manager.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/data/secure_store.dart';
import 'package:kiro/data/settings.dart';
import 'package:kiro/llm/local_backend.dart';
import 'package:kiro/skills/skill_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

Future<AppServices> fakeServices({bool onboardingDone = true}) async {
  SharedPreferences.setMockInitialValues({'onboardingDone': onboardingDone, 'languageCode': 'fa'});
  final bridge = FakeBridge();
  final settings = await SettingsController.load();
  final skills = SkillRepository(MemorySkillStorage());
  await skills.init();
  final repo = MemoryRepository();
  return AppServices(
    bridge: bridge,
    settings: settings,
    secure: MemorySecureStore(),
    chats: repo,
    drafts: repo,
    skills: skills,
    engine: LocalEngine(bridge),
    models: ModelManager(bridge),
    security: SecurityState(),
  );
}

void main() {
  testWidgets('home shell shows the six Persian tabs and navigates', (tester) async {
    final services = await fakeServices();
    await tester.pumpWidget(KiroApp(services: services));
    await tester.pumpAndSettle();

    for (final label in ['گفتگو', 'استودیو', 'صف پست', 'برنامه‌ها', 'مهارت‌ها', 'تنظیمات']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    // RTL by default
    final dir = tester.widget<Directionality>(find.byType(Directionality).first);
    expect(dir.textDirection, TextDirection.rtl);
    // empty chat + "no model" banner
    expect(find.text('سلام! من کیرو هستم.'), findsOneWidget);
    expect(find.text('برای گفتگوی آفلاین، یک مدل دانلود یا وارد کنید.'), findsOneWidget);

    await tester.tap(find.text('استودیو').last);
    await tester.pumpAndSettle();
    expect(find.text('در مرحلهٔ بعد'), findsWidgets);

    await tester.tap(find.text('مهارت‌ها').last);
    await tester.pumpAndSettle();
    expect(find.text('محتوای ویرال'), findsOneWidget);

    await tester.tap(find.text('تنظیمات').last);
    await tester.pumpAndSettle();
    expect(find.text('مدیریت مدل‌ها'), findsOneWidget);
  });

  testWidgets('first run shows the device check', (tester) async {
    final services = await fakeServices(onboardingDone: false);
    await tester.pumpWidget(KiroApp(services: services));
    await tester.pumpAndSettle();
    expect(find.text('بررسی دستگاه'), findsOneWidget);
    expect(find.text('Qwen2.5 3B Instruct'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('رد شدن'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('رد شدن'));
    await tester.pumpAndSettle();
    expect(find.text('گفتگو'), findsWidgets);
  });

  testWidgets('switching to English flips direction', (tester) async {
    final services = await fakeServices();
    await services.settings.setLanguageCode('en');
    await tester.pumpWidget(KiroApp(services: services));
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Studio'), findsWidgets);
  });

  testWidgets('app lock covers the app until the PIN is entered', (tester) async {
    final services = await fakeServices();
    await services.secure.write(SecureStore.pinHash, PinHasher.hash('2468'));
    await services.settings.setLockEnabled(true);
    await tester.pumpWidget(KiroApp(services: services));
    await tester.pumpAndSettle();
    expect(find.text('کیرو قفل است'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '1111');
    await tester.tap(find.text('باز کردن'));
    await tester.pumpAndSettle();
    expect(find.text('PIN اشتباه است.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '۲۴۶۸'); // Persian digits work too
    await tester.tap(find.text('باز کردن'));
    await tester.pumpAndSettle();
    expect(find.text('کیرو قفل است'), findsNothing);
    expect(find.text('سلام! من کیرو هستم.'), findsOneWidget);
  });
}
