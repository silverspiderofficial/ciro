import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kReleaseMode) {
    // No logs in release builds.
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Vazirmatn'], ofl);
    yield LicenseEntryWithLineBreaks(
      const ['stable-diffusion.cpp', 'ggml', 'FFmpeg', 'x264', 'sherpa-onnx', 'espeak-ng', 'Piper voices', 'TAESD'],
      await rootBundle.loadString('assets/licenses/THIRD_PARTY.md'),
    );
    yield LicenseEntryWithLineBreaks(const ['Music (CC0)'], await rootBundle.loadString('assets/music/LICENSE.md'));
  });
  final services = await AppServices.create();
  runApp(KiroApp(services: services));
}
