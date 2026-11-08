import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/data/device_info.dart';
import 'package:kiro/studio/platform/studio_platform.dart';
import 'package:kiro/studio/studio_assets.dart';
import 'package:kiro/studio/studio_catalog.dart';
import 'package:kiro/studio/video/video_project.dart';

DeviceInfo device({int ramGb = 8, bool dotprod = true, List<String> abis = const ['arm64-v8a']}) => DeviceInfo(
      totalRamBytes: ramGb * 1024 * 1024 * 1024,
      availRamBytes: 2 * 1024 * 1024 * 1024,
      cores: 8,
      bigCores: 4,
      maxFreqMhz: 3000,
      soc: 'SM8550',
      socManufacturer: 'QTI',
      manufacturer: 'T',
      model: 'P',
      sdkInt: 34,
      release: '14',
      abis: abis,
      dotprod: dotprod,
      i8mm: true,
      freeStorageBytes: 1 << 34,
    );

void main() {
  test('every studio file is pinned to a Hugging Face commit with a SHA-256', () {
    final hex40 = RegExp(r'^[0-9a-f]{40}$');
    final hex64 = RegExp(r'^[0-9a-f]{64}$');
    final names = <String>{};
    for (final spec in studioCatalog) {
      expect(spec.files, isNotEmpty);
      for (final f in spec.files) {
        expect(f.url, startsWith('https://huggingface.co/${f.repo}/resolve/${f.revision}/'));
        expect(hex40.hasMatch(f.revision), isTrue, reason: f.url);
        expect(hex64.hasMatch(f.sha256), isTrue, reason: f.url);
        expect(f.sizeBytes, greaterThan(0));
        expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(f.fileName), isTrue);
        expect(isAllowedDownloadHost(Uri.parse(f.url).host), isTrue);
      }
      for (final f in spec.files) {
        // Shared files (TAESD) must be identical wherever they appear.
        if (!names.add(f.fileName)) expect(f, same(taesdFile));
      }
    }
    for (final v in NarratorVoice.values.where((v) => v != NarratorVoice.none)) {
      expect(studioAssetById(v.key), isNotNull, reason: v.key);
    }
    expect(voiceForLanguage('fa')!.id, NarratorVoice.persian.key);
    expect(voiceForLanguage('en')!.id, NarratorVoice.english.key);
  });

  test('download host allow-list', () {
    expect(isAllowedDownloadHost('huggingface.co'), isTrue);
    expect(isAllowedDownloadHost('cdn-lfs.huggingface.co'), isTrue);
    expect(isAllowedDownloadHost('us.aws.cdn.hf.co'), isTrue);
    expect(isAllowedDownloadHost('evilhuggingface.co'), isFalse);
    expect(isAllowedDownloadHost('hf.co.evil.com'), isFalse);
  });

  test('image generation blockers send weak phones to the templates', () {
    final model = imageModelCatalog.first;
    expect(imageGenBlocker(device: device(), model: model, installed: true), ImageGenBlocker.none);
    expect(imageGenBlocker(device: device(), model: model, installed: false), ImageGenBlocker.noModel);
    expect(imageGenBlocker(device: device(ramGb: 3), model: model, installed: true), ImageGenBlocker.lowRam);
    expect(imageGenBlocker(device: device(dotprod: false), model: model, installed: true), ImageGenBlocker.noDotprod);
    expect(imageGenBlocker(device: device(abis: const ['armeabi-v7a']), model: model, installed: true), ImageGenBlocker.notArm64);
    // Desktop: no Android device info, only the model matters.
    expect(imageGenBlocker(device: null, model: model, installed: true), ImageGenBlocker.none);
    expect(recommendedImageModel(device())!.id, 'sd-turbo-q8');
    expect(recommendedImageModel(device(ramGb: 3)), isNull);
  });

  test('power rule: charging or above the threshold', () {
    expect(heavyWorkAllowed(const PowerStatus(level: 30, charging: false), enforce: true, minLevel: 50), isFalse);
    expect(heavyWorkAllowed(const PowerStatus(level: 30, charging: true), enforce: true, minLevel: 50), isTrue);
    expect(heavyWorkAllowed(const PowerStatus(level: 51, charging: false), enforce: true, minLevel: 50), isTrue);
    expect(heavyWorkAllowed(const PowerStatus(level: 50, charging: false), enforce: true, minLevel: 50), isFalse);
    expect(heavyWorkAllowed(const PowerStatus(level: 5, charging: false), enforce: false, minLevel: 50), isTrue);
    expect(heavyWorkAllowed(PowerStatus.unknown, enforce: true, minLevel: 50), isTrue);
  });

  test('bundled music exists and is listed in the CC0 licence file', () {
    final licence = File('assets/music/LICENSE.md').readAsStringSync();
    for (final m in musicCatalog) {
      expect(File(m.asset).existsSync(), isTrue, reason: m.asset);
      expect(licence, contains(m.asset.split('/').last));
      expect(m.sourceUrl, startsWith('https://opengameart.org/'));
    }
    expect(licence, contains('CC0'));
  });
}
