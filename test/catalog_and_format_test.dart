import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/core/format.dart';
import 'package:kiro/data/device_info.dart';
import 'package:kiro/data/model_catalog.dart';
import 'package:kiro/data/secure_store.dart';

DeviceInfo device(int ramGb, {int cores = 8, int big = 4}) => DeviceInfo(
      totalRamBytes: ramGb * 1024 * 1024 * 1024,
      availRamBytes: 1,
      cores: cores,
      bigCores: big,
      maxFreqMhz: 2000,
      soc: '',
      socManufacturer: '',
      manufacturer: '',
      model: '',
      sdkInt: 34,
      release: '14',
      abis: const ['arm64-v8a'],
      dotprod: true,
      i8mm: false,
      freeStorageBytes: 0,
    );

void main() {
  test('catalog entries are well formed and hosted on Hugging Face', () {
    final ids = <String>{};
    for (final m in modelCatalog) {
      expect(ids.add(m.id), isTrue);
      expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(m.url, startsWith('https://huggingface.co/'));
      expect(m.fileName.toLowerCase(), endsWith('q4_k_m.gguf'));
      expect(m.sizeBytes, greaterThan(500 * 1024 * 1024));
      expect(m.minRamMb, lessThanOrEqualTo(m.recommendedRamMb));
    }
    expect(modelCatalog.map((m) => m.family).toSet(), containsAll(['Gemma 3', 'Qwen2.5', 'Llama 3.2']));
  });

  test('recommendations scale with RAM', () {
    final big = recommendModels(device(8));
    expect(big.first.best, isTrue);
    expect(big.first.spec.id, 'qwen2.5-3b-instruct');

    final mid = recommendModels(device(4));
    expect(mid.firstWhere((r) => r.best).spec.id, 'gemma-3-1b-it');
    expect(mid.firstWhere((r) => r.spec.id == 'qwen2.5-3b-instruct').fit, ModelFit.tooHeavy);

    final small = recommendModels(device(3));
    expect(small.where((r) => r.best), hasLength(1));
    expect(small.firstWhere((r) => r.best).spec.sizeBytes, lessThan(900 * 1024 * 1024));
  });

  test('threads and context suggestions', () {
    expect(recommendedThreads(device(8, big: 4)), 4);
    expect(recommendedThreads(device(8, cores: 4, big: 0)), 2);
    expect(recommendedContext(device(8)), 4096);
    expect(recommendedContext(device(4)), 2048);
    expect(recommendedContext(device(2)), 1024);
  });

  test('digit and size formatting', () {
    expect(toPersianDigits('v1.25'), 'v۱.۲۵');
    expect(toLatinDigits('۱۲۳٤'), '1234');
    expect(formatBytes(806058496), '769 MB');
    expect(formatBytes(2104932768, languageCode: 'fa'), '۲.۰ GB');
  });

  test('PIN hashing verifies and rejects', () {
    final stored = PinHasher.hash('1234');
    expect(PinHasher.verify('1234', stored), isTrue);
    expect(PinHasher.verify('1235', stored), isFalse);
    expect(PinHasher.verify('1234', 'garbage'), isFalse);
    expect(PinHasher.hash('1234'), isNot(stored)); // random salt
  });
}
