/// Splits a topic into ~10 s scene prompts that the video pipeline renders one by one and
/// stitches into a video of the requested length.
library;

import 'price_table.dart';

class SegmentPrompt {
  const SegmentPrompt({required this.index, required this.total, required this.prompt, required this.duration, required this.beat});

  /// 1-based scene number.
  final int index;
  final int total;
  final String prompt;

  /// Target length of this clip (the last one may be shorter so the sum equals the target).
  final Duration duration;

  /// Narrative role: opening, development, climax, closing.
  final String beat;
}

/// Shared look appended to every scene so the stitched clips stay visually consistent.
const String defaultStyleSuffix =
    'consistent visual style across all scenes, same color palette and lighting, cinematic, '
    'vertical 9:16 framing, smooth camera motion, no text overlays, no watermark';

String _beatFor(int i, int n) {
  if (n == 1) return 'complete short scene';
  if (i == 1) return 'opening, establish the subject';
  if (i == n) return 'closing, resolve and end on a strong final shot';
  if (n >= 4 && i == n - 1) return 'climax, the most striking moment';
  return 'development, show a new aspect';
}

/// Returns `ceil(target / segment)` prompts. Empty when [target] is not positive or the topic
/// is blank.
List<SegmentPrompt> planSegments(
  String topic,
  Duration target, {
  String styleSuffix = defaultStyleSuffix,
  int segment = segmentSeconds,
}) {
  final t = topic.trim().replaceAll(RegExp(r'\s+'), ' ');
  final n = segmentCount(target, perSegment: segment);
  if (t.isEmpty || n == 0) return const [];
  final per = Duration(seconds: segment);
  final out = <SegmentPrompt>[];
  for (var i = 1; i <= n; i++) {
    final remaining = target - per * (i - 1);
    final d = remaining < per ? remaining : per;
    final beat = _beatFor(i, n);
    out.add(SegmentPrompt(
      index: i,
      total: n,
      beat: beat,
      duration: d,
      prompt: 'Scene $i of $n ($beat, about ${d.inSeconds}s): $t. $styleSuffix',
    ));
  }
  return out;
}
