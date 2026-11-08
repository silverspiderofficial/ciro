/// Downloadable Studio assets: image models (Stable Diffusion via stable-diffusion.cpp) and
/// narrator voices (Piper via sherpa-onnx), plus the CC0 music bundled in the app.
///
/// Verified on 2026-11-08 against the Hugging Face API (`/api/models/<repo>/tree/<rev>`; for
/// LFS files `lfs.oid` is the SHA-256). Small non-LFS files (tokens.txt) were downloaded from
/// the pinned revision and hashed. Every URL is pinned to a commit, so the bytes cannot change
/// under the app. No account or token is needed.
library;

import '../data/device_info.dart';

enum StudioAssetKind {
  imageModel('image'),
  voice('voice');

  const StudioAssetKind(this.key);
  final String key;
}

class StudioFile {
  const StudioFile({required this.repo, required this.revision, required this.path, required this.fileName, required this.sizeBytes, required this.sha256});
  final String repo;
  final String revision;

  /// Path inside the repository.
  final String path;

  /// Local file name (inside the Studio models folder).
  final String fileName;
  final int sizeBytes;
  final String sha256;

  String get url => 'https://huggingface.co/$repo/resolve/$revision/$path';
}

class StudioAssetSpec {
  const StudioAssetSpec({
    required this.id,
    required this.kind,
    required this.name,
    required this.files,
    required this.license,
    required this.licenseUrl,
    required this.descriptionFa,
    required this.descriptionEn,
    this.minRamMb = 0,
    this.defaultSteps = 0,
    this.defaultCfg = 0,
    this.language = '',
  });

  final String id;
  final StudioAssetKind kind;
  final String name;
  final List<StudioFile> files;
  final String license;
  final String licenseUrl;
  final String descriptionFa;
  final String descriptionEn;

  /// Image models: below this total RAM the model is not offered.
  final int minRamMb;
  final int defaultSteps;
  final double defaultCfg;

  /// Voices: 'fa' | 'en'.
  final String language;

  int get totalBytes => files.fold(0, (a, f) => a + f.sizeBytes);
  StudioFile get primary => files.first;
}

/// Tiny autoencoder used instead of the full VAE (MIT). It makes decoding ~10x cheaper,
/// which is what lets 512x512 generation fit in a phone's memory.
const taesdFile = StudioFile(
  repo: 'madebyollin/taesd',
  revision: '614f76814bbe30edbe2e627ace1c2234c81a2c0e',
  path: 'diffusion_pytorch_model.safetensors',
  fileName: 'taesd.safetensors',
  sizeBytes: 9793292,
  sha256: 'db169d69145ec4ff064e49d99c95fa05d3eb04ee453de35824a6d0f325513549',
);

const List<StudioAssetSpec> imageModelCatalog = [
  StudioAssetSpec(
    id: 'sd-turbo-q8',
    kind: StudioAssetKind.imageModel,
    name: 'SD-Turbo (Q8_0)',
    files: [
      StudioFile(
        repo: 'Green-Sky/SD-Turbo-GGUF',
        revision: '19a31586d02d64a73b4419bc193b3ecfaf38e1f0',
        path: 'sd_turbo-f16-q8_0.gguf',
        fileName: 'sd_turbo-f16-q8_0.gguf',
        sizeBytes: 2023745376,
        sha256: 'd50be7655f0a554cf8041c145d88b210bd5f3c545423119dee62ae08cae51580',
      ),
      taesdFile,
    ],
    license: 'Stability AI Community License',
    licenseUrl: 'https://huggingface.co/stabilityai/sd-turbo/blob/main/LICENSE.md',
    descriptionFa: 'سریع‌ترین گزینه: تصویر ۵۱۲×۵۱۲ در ۱ تا ۴ گام. پیشنهادی برای گوشی.',
    descriptionEn: 'Fastest: 512x512 images in 1-4 steps. Recommended for phones.',
    minRamMb: 4500,
    defaultSteps: 4,
    defaultCfg: 1.0,
  ),
  StudioAssetSpec(
    id: 'sd15-q4_0',
    kind: StudioAssetKind.imageModel,
    name: 'Stable Diffusion 1.5 (Q4_0)',
    files: [
      StudioFile(
        repo: 'second-state/stable-diffusion-v1-5-GGUF',
        revision: '031b5f5df991f511b3f5fa8fed6d99048ababb69',
        path: 'stable-diffusion-v1-5-pruned-emaonly-Q4_0.gguf',
        fileName: 'stable-diffusion-v1-5-pruned-emaonly-Q4_0.gguf',
        sizeBytes: 1566768416,
        sha256: 'b8944e9fe0b69b36ae1b5bb0185b3a7b8ef14347fe0fa9af6c64c4829022261f',
      ),
      taesdFile,
    ],
    license: 'CreativeML OpenRAIL-M',
    licenseUrl: 'https://huggingface.co/second-state/stable-diffusion-v1-5-GGUF',
    descriptionFa: 'کیفیت و تنوع سبک بیشتر، ولی کندتر (حدود ۲۰ گام).',
    descriptionEn: 'More styles and detail, but slower (about 20 steps).',
    minRamMb: 4500,
    defaultSteps: 20,
    defaultCfg: 7.0,
  ),
];

const List<StudioAssetSpec> voiceCatalog = [
  StudioAssetSpec(
    id: 'piper-fa_IR-amir-medium',
    kind: StudioAssetKind.voice,
    name: 'Persian — Amir (Piper, medium)',
    language: 'fa',
    files: [
      StudioFile(
        repo: 'csukuangfj/vits-piper-fa_IR-amir-medium',
        revision: 'e852208889c7cb924b8b43eace4e8bff847b13a1',
        path: 'fa_IR-amir-medium.onnx',
        fileName: 'fa_IR-amir-medium.onnx',
        sizeBytes: 63531507,
        sha256: '5a832803df099857d92cf7ec1e340c7ef6910433f089d9aca9ff1ebf9b7fa6c5',
      ),
      StudioFile(
        repo: 'csukuangfj/vits-piper-fa_IR-amir-medium',
        revision: 'e852208889c7cb924b8b43eace4e8bff847b13a1',
        path: 'tokens.txt',
        fileName: 'fa_IR-amir-medium.tokens.txt',
        sizeBytes: 940,
        sha256: 'ef3a7e4a8d1af0c9d4dc45aaae1a6242ebe24a7ed6f3d025a49eb29682784c6d',
      ),
    ],
    license: 'Dataset CC0 (fine-tuned from Piper lessac)',
    licenseUrl: 'https://huggingface.co/csukuangfj/vits-piper-fa_IR-amir-medium',
    descriptionFa: 'گویندهٔ مرد فارسی، طبیعی و واضح.',
    descriptionEn: 'Persian male narrator, clear and natural.',
  ),
  StudioAssetSpec(
    id: 'piper-en_US-joe-medium',
    kind: StudioAssetKind.voice,
    name: 'English — Joe (Piper, medium)',
    language: 'en',
    files: [
      StudioFile(
        repo: 'csukuangfj/vits-piper-en_US-joe-medium',
        revision: 'cda0697165d154bb152754dcdf4ea4ad13650e37',
        path: 'en_US-joe-medium.onnx',
        fileName: 'en_US-joe-medium.onnx',
        sizeBytes: 63201425,
        sha256: 'c9dc0dd883bd662937e8986af97efb25636c557469bde904dc4fcc9344cd2918',
      ),
      StudioFile(
        repo: 'csukuangfj/vits-piper-en_US-joe-medium',
        revision: 'cda0697165d154bb152754dcdf4ea4ad13650e37',
        path: 'tokens.txt',
        fileName: 'en_US-joe-medium.tokens.txt',
        sizeBytes: 899,
        sha256: 'da19d3f9a439574f66c072baafced1d1c79f42d8c5981619ea9274a7ab0dbba5',
      ),
    ],
    license: 'Dataset CC0 (fine-tuned from Piper lessac)',
    licenseUrl: 'https://huggingface.co/csukuangfj/vits-piper-en_US-joe-medium',
    descriptionFa: 'گویندهٔ مرد انگلیسی (آمریکایی).',
    descriptionEn: 'English (US) male narrator.',
  ),
];

List<StudioAssetSpec> get studioCatalog => [...imageModelCatalog, ...voiceCatalog];

StudioAssetSpec? studioAssetById(String id) {
  for (final a in studioCatalog) {
    if (a.id == id) return a;
  }
  return null;
}

StudioAssetSpec? voiceForLanguage(String lang) {
  for (final v in voiceCatalog) {
    if (v.language == lang) return v;
  }
  return null;
}

class MusicTrack {
  const MusicTrack({required this.id, required this.asset, required this.title, required this.author, required this.sourceUrl, required this.moodFa, required this.moodEn});
  final String id;
  final String asset;
  final String title;
  final String author;
  final String sourceUrl;
  final String moodFa;
  final String moodEn;
}

/// Royalty-free music bundled in the app. All three are CC0 (public domain dedication) on
/// OpenGameArt; the files are unmodified (see assets/music/LICENSE.md).
const List<MusicTrack> musicCatalog = [
  MusicTrack(
    id: 'happy_loop',
    asset: 'assets/music/happy_loop.mp3',
    title: 'Happy Loop',
    author: 'wipics',
    sourceUrl: 'https://opengameart.org/content/happy-loop',
    moodFa: 'شاد و پرانرژی',
    moodEn: 'Happy, upbeat',
  ),
  MusicTrack(
    id: 'city_loop',
    asset: 'assets/music/city_loop.mp3',
    title: 'City Loop',
    author: 'wipics',
    sourceUrl: 'https://opengameart.org/content/city-loop-0',
    moodFa: 'شهری و ریتمیک',
    moodEn: 'Urban, rhythmic',
  ),
  MusicTrack(
    id: 'heavenly_loop',
    asset: 'assets/music/heavenly_loop.ogg',
    title: 'Heavenly Loop',
    author: 'isaiah658',
    sourceUrl: 'https://opengameart.org/content/heavenly-loop',
    moodFa: 'آرام و رؤیایی',
    moodEn: 'Calm, dreamy',
  ),
];

MusicTrack? musicById(String id) {
  for (final m in musicCatalog) {
    if (m.id == id) return m;
  }
  return null;
}

/// Why on-device image generation is (not) available. Weak phones use the templates.
enum ImageGenBlocker { none, notArm64, noDotprod, lowRam, noModel }

ImageGenBlocker imageGenBlocker({required DeviceInfo? device, required StudioAssetSpec model, required bool installed}) {
  if (device != null) {
    if (!device.isArm64) return ImageGenBlocker.notArm64;
    // The image engine is compiled for armv8.2-a + dotprod (every SoC with enough RAM has it).
    if (!device.dotprod) return ImageGenBlocker.noDotprod;
    if (device.totalRamBytes ~/ (1024 * 1024) < model.minRamMb) return ImageGenBlocker.lowRam;
  }
  if (!installed) return ImageGenBlocker.noModel;
  return ImageGenBlocker.none;
}

/// The image model to suggest: SD-Turbo (fast) unless the device cannot run any.
StudioAssetSpec? recommendedImageModel(DeviceInfo? device) {
  if (device == null) return imageModelCatalog.first;
  final mb = device.totalRamBytes ~/ (1024 * 1024);
  if (!device.isArm64 || !device.dotprod) return null;
  for (final m in imageModelCatalog) {
    if (mb >= m.minRamMb) return m;
  }
  return null;
}
