/// Everything the Studio needs from the operating system, behind one interface so the
/// image/video code is the same on Android, Windows and Linux. Android-only pieces
/// (foreground service, MediaStore, SAF picker, packaged FFmpeg) live in
/// [AndroidStudioPlatform]; [DesktopStudioPlatform] uses plain files and processes.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PowerStatus {
  const PowerStatus({required this.level, required this.charging});

  /// 0..100, or -1 when unknown (desktop without a battery).
  final int level;
  final bool charging;

  static const unknown = PowerStatus(level: -1, charging: true);
}

/// Heavy work (image generation, video rendering) runs only while charging or above
/// [minLevel] percent, unless the user turned the rule off.
bool heavyWorkAllowed(PowerStatus s, {required bool enforce, required int minLevel}) {
  if (!enforce) return true;
  if (s.charging || s.level < 0) return true;
  return s.level > minLevel;
}

abstract class StudioPlatform {
  /// Path of a runnable FFmpeg binary, or null when none is available.
  Future<String?> ffmpegPath();

  Future<PowerStatus> powerStatus();

  /// Keeps the app alive for long work (Android: foreground service with a notification).
  Future<void> beginHeavyWork(String title);
  Future<void> updateHeavyWork(String text, double? fraction);
  Future<void> endHeavyWork();

  /// Copies a finished file to the user's gallery / Pictures / Videos. Returns where it went.
  Future<String?> saveToGallery(String path, {required bool video, required String displayName});

  bool get canPickImage;

  /// Lets the user choose a photo and copies it into [destDir]. Null when cancelled.
  Future<String?> pickImage(String destDir);

  /// Private working directory for Studio files.
  Future<Directory> studioDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'studio'));
    await d.create(recursive: true);
    return d;
  }

  static StudioPlatform create() => Platform.isAndroid ? AndroidStudioPlatform() : DesktopStudioPlatform();
}

class AndroidStudioPlatform extends StudioPlatform {
  static const _ch = MethodChannel('kiro/studio');
  String? _ffmpeg;

  @override
  Future<String?> ffmpegPath() async {
    if (_ffmpeg != null) return _ffmpeg;
    final dir = await _ch.invokeMethod<String>('nativeLibDir');
    if (dir == null) return null;
    final f = File(p.join(dir, 'libkiro_ffmpeg.so'));
    return _ffmpeg = await f.exists() ? f.path : null;
  }

  @override
  Future<PowerStatus> powerStatus() async {
    final m = await _ch.invokeMapMethod<String, Object?>('battery');
    if (m == null) return PowerStatus.unknown;
    return PowerStatus(level: (m['level'] as num?)?.toInt() ?? -1, charging: (m['charging'] as bool?) ?? false);
  }

  @override
  Future<void> beginHeavyWork(String title) => _ch.invokeMethod<void>('workStart', {'title': title});

  @override
  Future<void> updateHeavyWork(String text, double? fraction) =>
      _ch.invokeMethod<void>('workUpdate', {'text': text, 'progress': fraction == null ? -1 : (fraction * 100).round()});

  @override
  Future<void> endHeavyWork() => _ch.invokeMethod<void>('workStop');

  @override
  Future<String?> saveToGallery(String path, {required bool video, required String displayName}) =>
      _ch.invokeMethod<String>('saveToGallery', {'path': path, 'video': video, 'name': displayName});

  @override
  bool get canPickImage => true;

  @override
  Future<String?> pickImage(String destDir) => _ch.invokeMethod<String>('pickImage', {'dir': destDir});
}

/// Windows / Linux desktop.
class DesktopStudioPlatform extends StudioPlatform {
  @override
  Future<String?> ffmpegPath() async {
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    // 1) shipped next to the app binary, 2) on PATH.
    final bundled = File(p.join(File(Platform.resolvedExecutable).parent.path, exe));
    if (await bundled.exists()) return bundled.path;
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in (Platform.environment['PATH'] ?? '').split(sep)) {
      if (dir.isEmpty) continue;
      final f = File(p.join(dir, exe));
      if (await f.exists()) return f.path;
    }
    return null;
  }

  @override
  Future<PowerStatus> powerStatus() async {
    if (!Platform.isLinux) return PowerStatus.unknown;
    final root = Directory('/sys/class/power_supply');
    if (!await root.exists()) return PowerStatus.unknown;
    var level = -1;
    var charging = false;
    var onAc = false;
    await for (final e in root.list()) {
      Future<String> read(String name) async {
        try {
          return (await File(p.join(e.path, name)).readAsString()).trim();
        } on FileSystemException {
          return '';
        }
      }

      final type = await read('type');
      if (type == 'Battery') {
        level = int.tryParse(await read('capacity')) ?? level;
        final status = await read('status');
        charging = charging || status == 'Charging' || status == 'Full';
      } else if (type == 'Mains' || type == 'USB') {
        onAc = onAc || await read('online') == '1';
      }
    }
    if (level < 0) return PowerStatus.unknown;
    return PowerStatus(level: level, charging: charging || onAc);
  }

  @override
  Future<void> beginHeavyWork(String title) async {}
  @override
  Future<void> updateHeavyWork(String text, double? fraction) async {}
  @override
  Future<void> endHeavyWork() async {}

  @override
  Future<String?> saveToGallery(String path, {required bool video, required String displayName}) async {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null) return null;
    final dir = Directory(p.join(home, video ? 'Videos' : 'Pictures', 'Kiro'));
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, displayName));
    await File(path).copy(target.path);
    return target.path;
  }

  @override
  bool get canPickImage => false;

  @override
  Future<String?> pickImage(String destDir) async => null;
}
