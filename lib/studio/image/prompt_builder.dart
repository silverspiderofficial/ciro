/// Turns a topic (often Persian) into an English Stable Diffusion prompt. The language model
/// writes the prompt; these helpers add the visual style, clean the model's output and give a
/// safe default negative prompt.
library;

import '../../llm/llm_backend.dart';

enum ImageStyle {
  photo('photo', 'professional photo, natural light, sharp focus, high detail, 35mm'),
  illustration('illustration', 'flat vector illustration, clean shapes, soft pastel colors, modern design'),
  cinematic('cinematic', 'cinematic shot, dramatic lighting, shallow depth of field, film grain, rich colors'),
  minimal('minimal', 'minimalist composition, plenty of negative space, soft studio light, simple background'),
  render3d('3d', '3d render, soft global illumination, octane style, smooth materials, vibrant'),
  watercolor('watercolor', 'watercolor painting, delicate brush strokes, paper texture, soft colors');

  const ImageStyle(this.key, this.suffix);
  final String key;
  final String suffix;

  static ImageStyle fromKey(String? k) => ImageStyle.values.firstWhere((s) => s.key == k, orElse: () => ImageStyle.photo);
}

/// Stable Diffusion renders text badly, and Instagram content gets its words from the
/// templates and overlays instead, so text is always pushed out of the picture.
const defaultNegativePrompt =
    'text, letters, watermark, logo, signature, blurry, low quality, jpeg artifacts, deformed, extra fingers, '
    'bad anatomy, cropped, out of frame, nsfw';

final _persian = RegExp(r'[\u0600-\u06FF]');

bool containsPersian(String s) => _persian.hasMatch(s);

/// Cleans a model's answer down to one comma-separated prompt line.
String cleanImagePrompt(String raw, {int maxChars = 380}) {
  var s = raw.trim();
  // Drop code fences, labels and quotes the model may add.
  s = s.replaceAll(RegExp(r'```[a-zA-Z]*'), '');
  s = s.replaceFirst(RegExp(r'^(positive\s+)?prompt\s*[:：-]\s*', caseSensitive: false), '');
  final neg = RegExp(r'\n\s*negative', caseSensitive: false).firstMatch(s);
  if (neg != null) s = s.substring(0, neg.start);
  s = s.replaceAll(RegExp(r'#\S+'), '');
  s = s.replaceAll(RegExp(r'[\r\n]+'), ', ');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  s = s.replaceAll(RegExp(r'(,\s*)+'), ', ');
  s = s.replaceAll(RegExp(r'''^[,\s"'“”«»]+|[,\s"'“”«»]+$'''), '');
  if (s.length > maxChars) {
    final cut = s.lastIndexOf(',', maxChars);
    s = s.substring(0, cut > maxChars ~/ 2 ? cut : maxChars).trim();
  }
  return s;
}

String withStyle(String prompt, ImageStyle style) {
  final p = prompt.trim();
  if (p.isEmpty) return style.suffix;
  return p.toLowerCase().contains(style.suffix.split(',').first) ? p : '$p, ${style.suffix}';
}

class ImagePrompt {
  const ImagePrompt(this.prompt, this.negative);
  final String prompt;
  final String negative;
  Map<String, Object?> toJson() => {'prompt': prompt, 'negative_prompt': negative};
}

/// Asks the language model for an English prompt. Falls back to the topic itself (already
/// English) when the model is unavailable.
Future<ImagePrompt> makeImagePrompt(
  LlmBackend backend,
  GenerationOptions options, {
  required String topic,
  ImageStyle style = ImageStyle.photo,
  String extra = '',
  CancelToken? cancel,
}) async {
  final instruction = 'Write ONE prompt for the Stable Diffusion image generator.\n'
      'Subject: $topic\n'
      '${extra.isNotEmpty ? 'Details: $extra\n' : ''}'
      'Rules: English only, 15-45 words, comma-separated visual keywords (subject, setting, '
      'composition, lighting, colors). No text, words or letters in the image. No people\'s names. '
      'Output only the prompt.';
  var prompt = '';
  try {
    final out = await generateText(
      backend,
      [
        const ChatMessage.system('You write prompts for text-to-image models. Output only the prompt.'),
        ChatMessage.user(instruction),
      ],
      options.copyWith(maxTokens: 160, temperature: 0.6),
      cancel: cancel,
    );
    prompt = cleanImagePrompt(out);
  } on LlmException {
    if (cancel?.isCancelled ?? false) rethrow;
  }
  if (prompt.isEmpty || containsPersian(prompt)) {
    // No usable English from the model: Stable Diffusion's text encoder only knows English,
    // so keep just the Latin words of the topic plus the style.
    prompt = cleanImagePrompt(topic.replaceAll(_persian, ' '));
  }
  return ImagePrompt(withStyle(prompt, style), defaultNegativePrompt);
}
