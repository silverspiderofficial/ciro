import '../content/content_helpers.dart';
import '../llm/llm_backend.dart';
import '../skills/skill.dart';

/// Focused generation tasks (text, captions, hashtags). Used by the agent tools and by the
/// caption & hashtag screen, so both produce the same quality.
class ContentGenerator {
  ContentGenerator(this.backend, {this.options = const GenerationOptions()});

  final LlmBackend backend;
  final GenerationOptions options;

  String _languageName(String code) => switch (code) {
        'en' => 'English',
        _ => 'Persian (Farsi)',
      };

  String _system(Skill? skill) {
    final b = StringBuffer(
      'You are an expert Instagram content writer. Output only the requested content, '
      'with no preamble, no explanations and no markdown headings.',
    );
    if (skill != null) b.write('\n\n${skill.toPromptBlock()}');
    return b.toString();
  }

  Future<String> writeText({
    required String topic,
    String format = 'post',
    String language = 'fa',
    String length = 'medium',
    Skill? skill,
    CancelToken? cancel,
  }) async {
    final words = switch (length) {
      'short' => '60-100',
      'long' => '250-400',
      _ => '120-200',
    };
    final formatHint = switch (format) {
      'reels_script' || 'reels' =>
        'a Reels script: a 3-second hook, then 3 short beats, then a call to action. Label each beat with on-screen text and voice-over.',
      'carousel' => 'an educational carousel: slide-by-slide text (5-8 slides), slide 1 is a hook title, the last slide is a call to action.',
      'story' => 'a short Instagram story sequence (3-4 frames) with one line per frame.',
      _ => 'an Instagram post text.',
    };
    final prompt = 'Write $formatHint\nTopic: $topic\nLanguage: ${_languageName(language)}\nLength: about $words words.';
    final out = await generateText(
      backend,
      [ChatMessage.system(_system(skill)), ChatMessage.user(prompt)],
      options.copyWith(maxTokens: length == 'long' ? 900 : 600),
      cancel: cancel,
    );
    return CaptionHelper.clean(out, limit: 4000);
  }

  Future<String> writeCaption({
    required String topic,
    String language = 'fa',
    String tone = '',
    Skill? skill,
    CancelToken? cancel,
  }) async {
    final toneLine = tone.isNotEmpty ? '\nTone: $tone' : '';
    final prompt = 'Write one Instagram caption.\nTopic: $topic\nLanguage: ${_languageName(language)}$toneLine\n'
        'Rules: first line is a strong hook (max 12 words); short paragraphs; one clear call to action at the end; '
        'a few fitting emojis are fine; do NOT include hashtags; under 1200 characters.';
    final out = await generateText(
      backend,
      [ChatMessage.system(_system(skill)), ChatMessage.user(prompt)],
      options.copyWith(maxTokens: 500),
      cancel: cancel,
    );
    return CaptionHelper.splitHashtags(CaptionHelper.clean(out)).body;
  }

  /// Returns up to [count] normalised hashtags; falls back to keyword tags if the model output
  /// has none usable.
  Future<List<String>> hashtags({
    required String topic,
    int count = 15,
    String language = 'fa',
    Skill? skill,
    CancelToken? cancel,
  }) async {
    final lang = language == 'both' ? 'both Persian and English' : _languageName(language);
    final prompt = 'List $count Instagram hashtags for this topic, mixing specific (niche) and broad ones.\n'
        'Topic: $topic\nLanguage of hashtags: $lang\n'
        'Output only the hashtags separated by spaces, each starting with #, use _ instead of spaces.';
    List<String> tags = const [];
    try {
      final out = await generateText(
        backend,
        [ChatMessage.system(_system(skill)), ChatMessage.user(prompt)],
        options.copyWith(maxTokens: 200, temperature: 0.5),
        cancel: cancel,
      );
      tags = HashtagHelper.extract(out, max: count);
    } on LlmException {
      if (cancel?.isCancelled ?? false) rethrow;
    }
    if (tags.length < 3) {
      final extra = HashtagHelper.fromKeywords(topic, skill?.topics ?? const []);
      tags = {...tags, ...extra}.take(count).toList();
    }
    return tags;
  }
}
