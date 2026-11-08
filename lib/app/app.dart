import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../data/model_manager.dart';
import '../data/settings.dart';
import '../features/home/home_shell.dart';
import '../features/lock/app_lock.dart';
import '../features/onboarding/device_check_screen.dart';
import '../features/studio/studio_common.dart';
import '../llm/local_backend.dart';
import '../skills/skill_repository.dart';
import '../studio/studio_assets.dart';
import '../studio/studio_service.dart';
import 'services.dart';

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF6D4AFF), brightness: brightness);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Vazirmatn');
  return base.copyWith(
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class KiroApp extends StatelessWidget {
  const KiroApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<SettingsController>.value(value: services.settings),
        ChangeNotifierProvider<SkillRepository>.value(value: services.skills),
        ChangeNotifierProvider<LocalEngine>.value(value: services.engine),
        ChangeNotifierProvider<ModelManager>.value(value: services.models),
        ChangeNotifierProvider<SecurityState>.value(value: services.security),
        ChangeNotifierProvider<AppLockController>(
          create: (_) => AppLockController(services.settings, services.secure),
        ),
        if (services.studio != null) ...[
          ChangeNotifierProvider<StudioService>.value(value: services.studio!),
          ChangeNotifierProvider<StudioAssetManager>.value(value: services.studio!.assets),
        ],
        ChangeNotifierProvider<StudioUiState>(create: (_) => StudioUiState(languageCode: services.settings.languageCode)),
      ],
      child: Consumer<SettingsController>(
        builder: (context, settings, _) => MaterialApp(
          title: 'کیرو',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: settings.themeMode,
          locale: settings.locale,
          supportedLocales: const [Locale('fa', 'IR'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => AppLockGate(child: child ?? const SizedBox.shrink()),
          home: const _FirstRunGate(),
        ),
      ),
    );
  }
}

class _FirstRunGate extends StatelessWidget {
  const _FirstRunGate();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    if (!settings.onboardingDone) {
      return DeviceCheckScreen(
        firstRun: true,
        onDone: () => settings.setOnboardingDone(true),
      );
    }
    return const HomeShell();
  }
}
