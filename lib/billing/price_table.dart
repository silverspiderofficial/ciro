/// Price list for generated videos. Prices are fixed in TON (nanotons), not in fiat.
library;

import 'nanoton.dart';

/// Seconds of footage produced per generated clip; longer videos are stitched from clips.
const int segmentSeconds = 10;

/// Number of ~10 s clips needed for [d] (ceil). Zero or negative durations need 0 clips.
int segmentCount(Duration d, {int perSegment = segmentSeconds}) {
  final s = d.inMilliseconds;
  if (s <= 0) return 0;
  final per = perSegment * 1000;
  return (s + per - 1) ~/ per;
}

class PriceTier {
  const PriceTier(this.duration, this.nanotons);

  /// Builds a tier from a decimal TON string; throws [ArgumentError] on a malformed price
  /// (configuration error, caught by tests).
  factory PriceTier.ton(Duration duration, String ton) {
    final n = parseTonToNanotons(ton);
    if (n == null || n <= 0) throw ArgumentError.value(ton, 'ton', 'invalid price');
    return PriceTier(duration, n);
  }

  final Duration duration;
  final int nanotons;

  int get segments => segmentCount(duration);

  String get tonText => formatNanotons(nanotons);
}

class PriceTable {
  /// [tiers] may be given in any order; they are sorted by duration. Durations must be unique
  /// and prices must not decrease as duration grows.
  PriceTable(List<PriceTier> tiers) : tiers = _sorted(tiers) {
    if (this.tiers.isEmpty) throw ArgumentError('empty price table');
    for (var i = 1; i < this.tiers.length; i++) {
      if (this.tiers[i].duration == this.tiers[i - 1].duration) throw ArgumentError('duplicate duration');
      if (this.tiers[i].nanotons < this.tiers[i - 1].nanotons) throw ArgumentError('price decreases');
    }
  }

  /// Default list: 10 s 0.3, 20 s 0.5, 30 s 0.7, 60 s 1.2, 3 min 3, 5 min 4.5, 10 min 8 TON.
  factory PriceTable.standard() => PriceTable([
        PriceTier.ton(const Duration(seconds: 10), '0.3'),
        PriceTier.ton(const Duration(seconds: 20), '0.5'),
        PriceTier.ton(const Duration(seconds: 30), '0.7'),
        PriceTier.ton(const Duration(seconds: 60), '1.2'),
        PriceTier.ton(const Duration(minutes: 3), '3'),
        PriceTier.ton(const Duration(minutes: 5), '4.5'),
        PriceTier.ton(const Duration(minutes: 10), '8'),
      ]);

  final List<PriceTier> tiers;

  static List<PriceTier> _sorted(List<PriceTier> input) {
    final copy = List<PriceTier>.of(input)..sort((a, b) => a.duration.compareTo(b.duration));
    return List<PriceTier>.unmodifiable(copy);
  }

  /// The durations the user can pick from.
  List<Duration> get durations => [for (final t in tiers) t.duration];

  Duration get maxDuration => tiers.last.duration;

  /// The tier that covers [d]: the shortest tier whose duration is >= [d]. Null when [d] is
  /// zero/negative or longer than the longest tier.
  PriceTier? tierFor(Duration d) {
    if (d <= Duration.zero) return null;
    for (final t in tiers) {
      if (t.duration >= d) return t;
    }
    return null;
  }

  /// Price in nanotons for [d], or null when not sold.
  int? priceFor(Duration d) => tierFor(d)?.nanotons;
}
