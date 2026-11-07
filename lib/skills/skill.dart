import 'dart:convert';

/// A skill is a Markdown file whose front matter is a JSON object between `---` lines:
///
/// ```
/// ---
/// {"id": "viral-content", "name": "محتوای ویرال", "tone": "...", ...}
/// ---
/// # Markdown guidance for the agent
/// ```
class Skill {
  const Skill({
    required this.id,
    required this.name,
    this.description = '',
    this.pageStyle = '',
    this.audience = '',
    this.tone = '',
    this.topics = const [],
    this.postFormat = 'mixed',
    this.language = 'fa',
    this.body = '',
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String description;
  final String pageStyle;
  final String audience;
  final String tone;
  final List<String> topics;

  /// reels | carousel | single | story | mixed
  final String postFormat;

  /// fa | en | both
  final String language;
  final String body;
  final bool builtIn;

  static const postFormats = ['mixed', 'reels', 'carousel', 'single', 'story'];
  static const languages = ['fa', 'en', 'both'];

  Skill copyWith({
    String? id,
    String? name,
    String? description,
    String? pageStyle,
    String? audience,
    String? tone,
    List<String>? topics,
    String? postFormat,
    String? language,
    String? body,
    bool? builtIn,
  }) =>
      Skill(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        pageStyle: pageStyle ?? this.pageStyle,
        audience: audience ?? this.audience,
        tone: tone ?? this.tone,
        topics: topics ?? this.topics,
        postFormat: postFormat ?? this.postFormat,
        language: language ?? this.language,
        body: body ?? this.body,
        builtIn: builtIn ?? this.builtIn,
      );

  Map<String, Object?> frontMatter() => {
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'page_style': pageStyle,
        'audience': audience,
        'tone': tone,
        'topics': topics,
        'post_format': postFormat,
        'language': language,
        if (builtIn) 'built_in': true,
      };

  /// Serialises to the on-disk Markdown format.
  String toMarkdown() {
    const encoder = JsonEncoder.withIndent('  ');
    return '---\n${encoder.convert(frontMatter())}\n---\n${body.trim()}\n';
  }

  /// Text injected into the agent's system prompt when this skill is active.
  String toPromptBlock() {
    final b = StringBuffer('ACTIVE SKILL: $name\n');
    if (pageStyle.isNotEmpty) b.writeln('- Page style: $pageStyle');
    if (audience.isNotEmpty) b.writeln('- Audience: $audience');
    if (tone.isNotEmpty) b.writeln('- Tone: $tone');
    if (topics.isNotEmpty) b.writeln('- Topics: ${topics.join(', ')}');
    b.writeln('- Preferred post format: $postFormat');
    b.writeln('- Content language: ${language == 'both' ? 'Persian and English' : language == 'en' ? 'English' : 'Persian'}');
    if (body.trim().isNotEmpty) {
      b.writeln('Guidelines:');
      b.writeln(body.trim());
    }
    return b.toString().trim();
  }

  String get summary {
    final parts = <String>[
      if (tone.isNotEmpty) tone,
      if (audience.isNotEmpty) audience,
      postFormat,
    ];
    return parts.join(' · ');
  }
}

class SkillParseException implements Exception {
  SkillParseException(this.message);
  final String message;
  @override
  String toString() => 'SkillParseException: $message';
}

/// Parses a skill file. [fallbackId] is used when the front matter has no id.
Skill parseSkill(String source, {String? fallbackId}) {
  var text = source.replaceAll('\r\n', '\n');
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  text = text.trimLeft();
  if (!text.startsWith('---')) {
    throw SkillParseException('missing front matter');
  }
  final firstNl = text.indexOf('\n');
  if (firstNl < 0) throw SkillParseException('missing front matter');
  final closing = RegExp(r'^---[ \t]*$', multiLine: true);
  final match = closing.firstMatch(text.substring(firstNl + 1));
  if (match == null) throw SkillParseException('unterminated front matter');
  final jsonText = text.substring(firstNl + 1, firstNl + 1 + match.start).trim();
  final body = text.substring(firstNl + 1 + match.end).trim();

  Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw SkillParseException('invalid JSON: ${e.message}');
  }
  if (decoded is! Map<String, Object?>) throw SkillParseException('front matter must be a JSON object');
  final m = decoded;

  String str(String key, [String alt = '']) {
    final v = m[key] ?? m[alt];
    return v is String ? v.trim() : '';
  }

  final name = str('name');
  if (name.isEmpty) throw SkillParseException('name is required');
  final rawId = str('id');
  final id = slugify(rawId.isNotEmpty ? rawId : (fallbackId ?? name));

  final topicsRaw = m['topics'];
  final topics = <String>[
    if (topicsRaw is List<Object?>)
      ...topicsRaw.whereType<String>().map((t) => t.trim()).where((t) => t.isNotEmpty)
    else if (topicsRaw is String)
      ...topicsRaw.split(RegExp(r'[,،\n]')).map((t) => t.trim()).where((t) => t.isNotEmpty),
  ];

  var format = str('post_format', 'postFormat').toLowerCase();
  if (!Skill.postFormats.contains(format)) format = 'mixed';
  var language = str('language').toLowerCase();
  if (!Skill.languages.contains(language)) language = 'fa';

  return Skill(
    id: id,
    name: name,
    description: str('description'),
    pageStyle: str('page_style', 'pageStyle'),
    audience: str('audience'),
    tone: str('tone'),
    topics: topics,
    postFormat: format,
    language: language,
    body: body,
    builtIn: m['built_in'] == true,
  );
}

/// File-system safe id. Non-Latin names get a stable hash-based id.
String slugify(String input) {
  final lower = input.trim().toLowerCase();
  final buf = StringBuffer();
  var lastDash = false;
  for (final r in lower.runes) {
    final c = String.fromCharCode(r);
    final ok = RegExp(r'[a-z0-9]').hasMatch(c);
    if (ok) {
      buf.write(c);
      lastDash = false;
    } else if (!lastDash && buf.isNotEmpty) {
      buf.write('-');
      lastDash = true;
    }
  }
  var slug = buf.toString().replaceAll(RegExp(r'-+$'), '');
  if (slug.length > 48) slug = slug.substring(0, 48).replaceAll(RegExp(r'-+$'), '');
  if (slug.isEmpty) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(input)) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    slug = 'skill-${h.toRadixString(16)}';
  }
  return slug;
}
