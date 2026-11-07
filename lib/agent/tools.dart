import 'dart:convert';

import '../content/content_helpers.dart';
import '../data/repositories.dart';
import '../llm/llm_backend.dart';
import '../skills/skill.dart';
import '../skills/skill_repository.dart';
import 'content_generator.dart';
import 'tool_call_parser.dart';

/// Everything a tool may touch while it runs.
class ToolContext {
  ToolContext({
    required this.generator,
    required this.skills,
    required this.drafts,
    required this.activeSkill,
    required this.onSkillApplied,
    required this.language,
    this.cancel,
  });

  final ContentGenerator generator;
  final SkillRepository skills;
  final DraftsRepository drafts;
  Skill? activeSkill;
  final Future<void> Function(Skill skill) onSkillApplied;

  /// UI language, used as the default content language.
  final String language;
  final CancelToken? cancel;
}

class ToolResult {
  const ToolResult(this.ok, this.data);
  final bool ok;
  final Map<String, Object?> data;

  String toJson() => jsonEncode(data);
}

abstract class AgentTool {
  String get name;

  /// One-line signature + description for the system prompt.
  String get usage;
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx);
}

String _lang(Map<String, Object?> args, ToolContext ctx) {
  final l = argString(args, ['language', 'lang'], fallback: ctx.activeSkill?.language ?? ctx.language).toLowerCase();
  if (l.startsWith('en')) return 'en';
  if (l == 'both') return 'both';
  return 'fa';
}

class WriteTextTool implements AgentTool {
  @override
  String get name => 'write_text';
  @override
  String get usage =>
      'write_text(topic, format: post|reels_script|carousel|story, language: fa|en, length: short|medium|long) — writes post text or a script.';

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final topic = argString(args, ['topic', 'subject', 'prompt', 'text']);
    if (topic.isEmpty) return const ToolResult(false, {'error': 'topic is required'});
    var lang = _lang(args, ctx);
    if (lang == 'both') lang = 'fa';
    final text = await ctx.generator.writeText(
      topic: topic,
      format: argString(args, ['format', 'type'], fallback: ctx.activeSkill?.postFormat ?? 'post'),
      language: lang,
      length: argString(args, ['length'], fallback: 'medium'),
      skill: ctx.activeSkill,
      cancel: ctx.cancel,
    );
    return ToolResult(true, {'text': text});
  }
}

class WriteCaptionTool implements AgentTool {
  @override
  String get name => 'write_caption';
  @override
  String get usage => 'write_caption(topic, language: fa|en|both, tone) — writes an Instagram caption (no hashtags).';

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final topic = argString(args, ['topic', 'subject', 'text', 'prompt']);
    if (topic.isEmpty) return const ToolResult(false, {'error': 'topic is required'});
    final lang = _lang(args, ctx);
    final tone = argString(args, ['tone'], fallback: ctx.activeSkill?.tone ?? '');
    final result = <String, Object?>{};
    if (lang == 'fa' || lang == 'both') {
      result['caption_fa'] =
          await ctx.generator.writeCaption(topic: topic, language: 'fa', tone: tone, skill: ctx.activeSkill, cancel: ctx.cancel);
    }
    if (lang == 'en' || lang == 'both') {
      result['caption_en'] =
          await ctx.generator.writeCaption(topic: topic, language: 'en', tone: tone, skill: ctx.activeSkill, cancel: ctx.cancel);
    }
    return ToolResult(true, result);
  }
}

class GenerateHashtagsTool implements AgentTool {
  @override
  String get name => 'generate_hashtags';
  @override
  String get usage =>
      'generate_hashtags(topic, count, language: fa|en|both) — hashtag sets of at most 5 (Instagram allows 5 per post).';

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final topic = argString(args, ['topic', 'subject', 'text', 'keywords']);
    if (topic.isEmpty) return const ToolResult(false, {'error': 'topic is required'});
    final count = argInt(args, ['count', 'n', 'number'], fallback: 15, min: 5, max: 30);
    final tags = await ctx.generator.hashtags(
      topic: topic,
      count: count,
      language: _lang(args, ctx),
      skill: ctx.activeSkill,
      cancel: ctx.cancel,
    );
    final sets = HashtagHelper.buildSets(tags);
    return ToolResult(true, {
      'sets': sets.map((s) => s.join(' ')).toList(),
      'all': tags,
      'note': 'Instagram allows at most $instagramHashtagLimit hashtags per post.',
    });
  }
}

class ApplySkillTool implements AgentTool {
  @override
  String get name => 'apply_skill';
  @override
  String get usage => 'apply_skill(name) — switches the active skill (writing style / page profile).';

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final query = argString(args, ['name', 'skill', 'id']);
    final skill = ctx.skills.find(query);
    if (skill == null) {
      return ToolResult(false, {
        'error': 'skill not found',
        'available': ctx.skills.skills.map((s) => s.name).toList(),
      });
    }
    ctx.activeSkill = skill;
    await ctx.onSkillApplied(skill);
    return ToolResult(true, {'applied': skill.name, 'summary': skill.summary});
  }
}

class SaveToDraftsTool implements AgentTool {
  @override
  String get name => 'save_to_drafts';
  @override
  String get usage => 'save_to_drafts(title, content, caption, hashtags) — saves finished content to the drafts list.';

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final content = argString(args, ['content', 'text', 'body']);
    final caption = argString(args, ['caption', 'caption_fa', 'caption_en']);
    final tagsRaw = args['hashtags'] ?? args['tags'];
    final tags = tagsRaw is List<Object?>
        ? tagsRaw.map((e) => e.toString()).join(' ')
        : (tagsRaw is String ? tagsRaw : '');
    if (content.isEmpty && caption.isEmpty) {
      return const ToolResult(false, {'error': 'content or caption is required'});
    }
    var title = argString(args, ['title', 'name']);
    if (title.isEmpty) {
      final source = (content.isNotEmpty ? content : caption).split('\n').first;
      title = source.length > 60 ? '${source.substring(0, 60)}…' : source;
    }
    final normalized = HashtagHelper.extract(tags).take(instagramHashtagLimit).join(' ');
    final id = await ctx.drafts.add(Draft(
      title: title,
      content: content,
      caption: caption,
      hashtags: normalized,
      createdAt: DateTime.now(),
    ));
    return ToolResult(true, {'saved': true, 'draft_id': id, 'title': title});
  }
}

class ToolRegistry {
  ToolRegistry(List<AgentTool> tools) : _tools = {for (final t in tools) t.name: t};

  factory ToolRegistry.standard() => ToolRegistry([
        WriteTextTool(),
        WriteCaptionTool(),
        GenerateHashtagsTool(),
        ApplySkillTool(),
        SaveToDraftsTool(),
      ]);

  final Map<String, AgentTool> _tools;

  Iterable<AgentTool> get tools => _tools.values;
  AgentTool? operator [](String name) => _tools[name] ?? _tools[name.toLowerCase().replaceAll('-', '_')];
}
