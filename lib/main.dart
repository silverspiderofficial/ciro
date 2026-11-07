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
  });
  final services = await AppServices.create();
  runApp(KiroApp(services: services));
}
