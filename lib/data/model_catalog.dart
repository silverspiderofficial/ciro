/// Built-in catalog of on-device chat models (GGUF, Q4_K_M).
///
/// Every URL, size and SHA-256 below was verified on 2026-11-07 against the Hugging Face API
/// (`/api/models/<repo>/tree/main`, where `lfs.oid` is the SHA-256 of the file) and by
/// requesting the `resolve/main` URL anonymously (HTTP 302 to the HF CDN, Range supported,
/// file starts with the `GGUF` magic). No account or token is needed for any of them.
library;

import 'device_info.dart';

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.family,
    required this.params,
    required this.repo,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.minRamMb,
    required this.recommendedRamMb,
    required this.persianQuality,
    required this.license,
    required this.descriptionFa,
    required this.descriptionEn,
  });

  final String id;
  final String name;
  final String family;
  final String params;
  final String repo;
  final String fileName;
  final int sizeBytes;
  final String sha256;

  /// Below this total RAM the model is not offered at all.
  final int minRamMb;

  /// From this total RAM the model runs comfortably next to the UI.
  final int recommendedRamMb;

  /// 1 (weak) .. 3 (good) — expected Persian writing quality, a rough ranking based on each
  /// model family's published multilingual coverage (Llama 3.2 does not list Persian).
  final int persianQuality;
  final String license;
  final String descriptionFa;
  final String descriptionEn;

  String get url => 'https://huggingface.co/$repo/resolve/main/$fileName';
  String get pageUrl => 'https://huggingface.co/$repo';
}

const List<ModelSpec> modelCatalog = [
  ModelSpec(
    id: 'gemma-3-1b-it',
    name: 'Gemma 3 1B IT',
    family: 'Gemma 3',
    params: '1B',
    repo: 'bartowski/google_gemma-3-1b-it-GGUF',
    fileName: 'google_gemma-3-1b-it-Q4_K_M.gguf',
    sizeBytes: 806058496,
    sha256: '12bf0fff8815d5f73a3c9b586bd8fee8e7b248c935de70dec367679873d0f29d',
    minRamMb: 2500,
    recommendedRamMb: 3500,
    persianQuality: 2,
    license: 'Gemma Terms of Use',
    descriptionFa: 'سبک و سریع؛ برای گوشی‌های با رم کم. فارسی قابل قبول.',
    descriptionEn: 'Light and fast; for low-RAM phones. Decent Persian.',
  ),
  ModelSpec(
    id: 'qwen2.5-1.5b-instruct',
    name: 'Qwen2.5 1.5B Instruct',
    family: 'Qwen2.5',
    params: '1.5B',
    repo: 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sizeBytes: 1117320736,
    sha256: '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
    minRamMb: 3500,
    recommendedRamMb: 4500,
    persianQuality: 2,
    license: 'Apache-2.0',
    descriptionFa: 'تعادل خوب سرعت و کیفیت؛ پیروی خوب از دستور ابزارها.',
    descriptionEn: 'Good balance of speed and quality; follows tool instructions well.',
  ),
  ModelSpec(
    id: 'qwen2.5-3b-instruct',
    name: 'Qwen2.5 3B Instruct',
    family: 'Qwen2.5',
    params: '3B',
    repo: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
    fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    sizeBytes: 2104932768,
    sha256: '626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d',
    minRamMb: 5500,
    recommendedRamMb: 7500,
    persianQuality: 3,
    license: 'Qwen Research License (non-commercial)',
    descriptionFa: 'بهترین کیفیت فارسی در این فهرست؛ نیازمند رم ۶ گیگ یا بیشتر.',
    descriptionEn: 'Best Persian quality in this list; needs 6 GB RAM or more.',
  ),
  ModelSpec(
    id: 'llama-3.2-1b-instruct',
    name: 'Llama 3.2 1B Instruct',
    family: 'Llama 3.2',
    params: '1B',
    repo: 'bartowski/Llama-3.2-1B-Instruct-GGUF',
    fileName: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
    sizeBytes: 807694464,
    sha256: '6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83',
    minRamMb: 2500,
    recommendedRamMb: 3500,
    persianQuality: 1,
    license: 'Llama 3.2 Community License',
    descriptionFa: 'بسیار سریع؛ برای متن انگلیسی بهتر از فارسی است.',
    descriptionEn: 'Very fast; better at English than Persian.',
  ),
  ModelSpec(
    id: 'llama-3.2-3b-instruct',
    name: 'Llama 3.2 3B Instruct',
    family: 'Llama 3.2',
    params: '3B',
    repo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    sizeBytes: 2019377696,
    sha256: '6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff',
    minRamMb: 5500,
    recommendedRamMb: 7500,
    persianQuality: 1,
    license: 'Llama 3.2 Community License',
    descriptionFa: 'قوی برای انگلیسی و ابزارها؛ فارسی متوسط.',
    descriptionEn: 'Strong for English and tool use; average Persian.',
  ),
];

ModelSpec? catalogById(String id) {
  for (final m in modelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}

ModelSpec? catalogByFileName(String fileName) {
  for (final m in modelCatalog) {
    if (m.fileName == fileName) return m;
  }
  return null;
}

enum ModelFit { recommended, fits, tooHeavy }

class ModelRecommendation {
  const ModelRecommendation(this.spec, this.fit, {this.best = false});
  final ModelSpec spec;
  final ModelFit fit;
  final bool best;
}

/// Ranks the catalog for a device. The "best" pick favours Persian quality among the models
/// that run comfortably; on very small devices the lightest model wins.
List<ModelRecommendation> recommendModels(DeviceInfo device) {
  final totalMb = device.totalRamBytes ~/ (1024 * 1024);
  final result = <ModelRecommendation>[];
  ModelSpec? best;
  for (final m in modelCatalog) {
    if (totalMb >= m.recommendedRamMb) {
      if (best == null ||
          m.persianQuality > best.persianQuality ||
          (m.persianQuality == best.persianQuality && m.sizeBytes > best.sizeBytes)) {
        best = m;
      }
    }
  }
  if (best == null) {
    // Nothing is comfortable: choose the lightest model that still fits at all.
    for (final m in modelCatalog) {
      if (totalMb >= m.minRamMb && (best == null || m.sizeBytes < best.sizeBytes)) best = m;
    }
  }
  for (final m in modelCatalog) {
    final fit = totalMb >= m.recommendedRamMb
        ? ModelFit.recommended
        : totalMb >= m.minRamMb
            ? ModelFit.fits
            : ModelFit.tooHeavy;
    result.add(ModelRecommendation(m, fit, best: identical(m, best)));
  }
  result.sort((a, b) {
    if (a.best != b.best) return a.best ? -1 : 1;
    final fa = a.fit.index.compareTo(b.fit.index);
    if (fa != 0) return fa;
    return b.spec.persianQuality.compareTo(a.spec.persianQuality);
  });
  return result;
}

/// Threads for llama.cpp: the performance cores, at most 6 (more only adds contention).
int recommendedThreads(DeviceInfo device) {
  final big = device.bigCores > 0 ? device.bigCores : (device.cores / 2).floor();
  return big.clamp(1, 6);
}

/// Context window that fits the device (KV cache grows with it).
int recommendedContext(DeviceInfo device) {
  final gb = device.totalRamBytes / (1024 * 1024 * 1024);
  if (gb >= 7.5) return 4096;
  if (gb >= 3.5) return 2048;
  return 1024;
}
