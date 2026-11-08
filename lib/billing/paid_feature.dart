/// Paid features and their prices (TON, integer nanotons). The first use of every feature is
/// free once per device / recovery code (tracked in the ledger).
library;

import 'nanoton.dart';
import 'price_table.dart';

enum PaidFeature {
  /// AI video from a topic (priced by the [PriceTable] tiers).
  topicVideo,

  /// Video from the user's own scenes (same tiers, by output length).
  scenesVideo,

  /// Video editor export (by output length).
  editorExport,

  /// On-device image generation (per image).
  image,

  /// AI text: a chat reply, a caption/hashtag generation (per generation).
  aiText,
}

/// Stable keys (persisted in the ledger and key store; explicit so they survive obfuscation).
extension PaidFeatureKey on PaidFeature {
  String get key => switch (this) {
        PaidFeature.topicVideo => 'topic_video',
        PaidFeature.scenesVideo => 'scenes_video',
        PaidFeature.editorExport => 'editor_export',
        PaidFeature.image => 'image',
        PaidFeature.aiText => 'ai_text',
      };

  /// True when the price depends on an output length.
  bool get byDuration => this == PaidFeature.topicVideo || this == PaidFeature.scenesVideo || this == PaidFeature.editorExport;

  static PaidFeature? fromKey(String? k) {
    for (final f in PaidFeature.values) {
      if (f.key == k) return f;
    }
    return null;
  }
}

/// Editor export tiers: up to 1 min 0.2, up to 5 min 0.5, up to 10 min 1, longer 1.5 TON.
class EditorPriceTier {
  const EditorPriceTier(this.upTo, this.nanotons);

  /// Null = any longer length.
  final Duration? upTo;
  final int nanotons;
}

class FeaturePricing {
  FeaturePricing({
    PriceTable? videoTable,
    List<EditorPriceTier>? editorTiers,
    int? imageNanotons,
    int? aiTextNanotons,
  })  : videoTable = videoTable ?? PriceTable.standard(),
        editorTiers = editorTiers ?? standardEditorTiers,
        imageNanotons = imageNanotons ?? parseTonToNanotons('0.1')!,
        aiTextNanotons = aiTextNanotons ?? parseTonToNanotons('0.02')!;

  static final List<EditorPriceTier> standardEditorTiers = [
    EditorPriceTier(const Duration(minutes: 1), parseTonToNanotons('0.2')!),
    EditorPriceTier(const Duration(minutes: 5), parseTonToNanotons('0.5')!),
    EditorPriceTier(const Duration(minutes: 10), parseTonToNanotons('1')!),
    EditorPriceTier(null, parseTonToNanotons('1.5')!),
  ];

  final PriceTable videoTable;
  final List<EditorPriceTier> editorTiers;
  final int imageNanotons;
  final int aiTextNanotons;

  /// Price in nanotons, or null when not sold ([duration] missing, zero, or above the longest
  /// video tier). [units] multiplies per-item prices (images).
  int? priceFor(PaidFeature f, {Duration? duration, int units = 1}) {
    switch (f) {
      case PaidFeature.topicVideo:
      case PaidFeature.scenesVideo:
        if (duration == null) return null;
        return videoTable.priceFor(duration);
      case PaidFeature.editorExport:
        if (duration == null || duration <= Duration.zero) return null;
        for (final t in editorTiers) {
          if (t.upTo == null || duration <= t.upTo!) return t.nanotons;
        }
        return null;
      case PaidFeature.image:
        return units <= 0 ? null : imageNanotons * units;
      case PaidFeature.aiText:
        return units <= 0 ? null : aiTextNanotons * units;
    }
  }

  /// Duration recorded for a video feature: the tier length for tiered videos, the real
  /// length for editor exports, zero otherwise.
  Duration billedDuration(PaidFeature f, Duration? d) {
    if (d == null) return Duration.zero;
    if (f == PaidFeature.topicVideo || f == PaidFeature.scenesVideo) return videoTable.tierFor(d)?.duration ?? d;
    return d;
  }
}
