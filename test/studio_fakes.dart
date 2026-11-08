import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kiro/core/native_bridge.dart';
import 'package:kiro/data/model_manager.dart' show DownloadProgress;
import 'package:kiro/data/repositories.dart';
import 'package:kiro/data/settings.dart';
import 'package:kiro/studio/image/image_engine.dart';
import 'package:kiro/studio/platform/studio_platform.dart';
import 'package:kiro/studio/studio_assets.dart';
import 'package:kiro/studio/studio_catalog.dart';
import 'package:kiro/studio/studio_service.dart';
import 'package:kiro/studio/tts/tts_engine.dart';
import 'package:kiro/studio/video/wav.dart';

class FakeStudioPlatform extends StudioPlatform {
  FakeStudioPlatform(this.dir, {this.power = const PowerStatus(level: 80, charging: false)});
  final Directory dir;
  PowerStatus power;
  final List<String> calls = [];

  @override
  Future<Directory> studioDir() async => dir;
  @override
  Future<String?> ffmpegPath() async => null;
  @override
  Future<PowerStatus> powerStatus() async => power;
  @override
  Future<void> beginHeavyWork(String title) async => calls.add('begin');
  @override
  Future<void> updateHeavyWork(String text, double? fraction) async {}
  @override
  Future<void> endHeavyWork() async => calls.add('end');
  @override
  Future<String?> saveToGallery(String path, {required bool video, required String displayName}) async {
    calls.add('gallery:$displayName');
    return '/gallery/$displayName';
  }

  @override
  bool get canPickImage => false;
  @override
  Future<String?> pickImage(String destDir) async => null;
}

/// Writes a tiny file instead of running Stable Diffusion.
class FakeImageEngine implements ImageEngine {
  final List<ImageRequest> requests = [];
  String? failWith;

  @override
  Stream<ImageEvent> generate(ImageRequest request) async* {
    requests.add(request);
    yield const ImageProgress('loading');
    yield const ImageProgress('sampling', step: 1, steps: 2);
    if (failWith != null) {
      yield ImageFailed(failWith!);
      return;
    }
    await File(request.outPath).writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
    yield ImageDone(path: request.outPath, seed: 7, millis: 5);
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> unload() async {}
}

class FakeTts implements TtsEngine {
  @override
  Future<List<PcmAudio>> synthesizeAll(List<String> texts, VoiceFiles voice, {double speed = 1.0, int threads = 2}) async =>
      [for (final t in texts) PcmAudio(Int16List(t.length * 100), 22050)];
}

/// Marks files as present by writing them with the catalog size (sparse) on "download".
class FakeDownloader implements AssetDownloader {
  FakeDownloader(this.root);
  final String root;
  final _events = StreamController<MapEntry<String, DownloadProgress>>.broadcast();
  final List<String> started = [];

  @override
  Future<String> rootDir() async => root;
  @override
  Stream<MapEntry<String, DownloadProgress>> get events => _events.stream;
  @override
  Future<void> cancel(String jobId) async => _events.add(MapEntry(jobId, const DownloadProgress(state: 'cancelled')));

  @override
  Future<void> start({required String jobId, required StudioFile file, required String title}) async {
    started.add(jobId);
    final f = await File('$root/${file.fileName}').create(recursive: true);
    final raf = await f.open(mode: FileMode.write);
    await raf.truncate(file.sizeBytes);
    await raf.close();
    scheduleMicrotask(() => _events.add(MapEntry(jobId, DownloadProgress(state: 'done', received: file.sizeBytes, total: file.sizeBytes))));
  }
}

Future<StudioService> fakeStudio({
  required SettingsController settings,
  required NativeBridge bridge,
  required DraftsRepository drafts,
  FakeImageEngine? engine,
  FakeStudioPlatform? platform,
}) async {
  final dir = await Directory.systemTemp.createTemp('kiro_studio_test');
  final studio = StudioService(
    platform: platform ?? FakeStudioPlatform(dir),
    imageEngine: engine ?? FakeImageEngine(),
    tts: FakeTts(),
    assets: StudioAssetManager(FakeDownloader('${dir.path}/models')),
    settings: settings,
    bridge: bridge,
    drafts: drafts,
  );
  await studio.init();
  return studio;
}
