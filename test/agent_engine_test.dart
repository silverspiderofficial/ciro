import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/agent/agent_engine.dart';
import 'package:kiro/agent/content_generator.dart';
import 'package:kiro/agent/tools.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/llm/llm_backend.dart';
import 'package:kiro/skills/builtin_skills.dart';
import 'package:kiro/skills/skill_repository.dart';

import 'fakes.dart';

Future<(List<AgentEvent>, ToolContext, MemoryRepository)> runAgent(
  ScriptedBackend backend,
  String input, {
  int maxSteps = 4,
}) async {
  final repo = MemoryRepository();
  final skills = SkillRepository(MemorySkillStorage());
  await skills.init();
  final ctx = ToolContext(
    generator: ContentGenerator(backend),
    skills: skills,
    drafts: repo,
    activeSkill: null,
    onSkillApplied: (_) async {},
    language: 'fa',
  );
  final engine = AgentEngine(backend: backend, registry: ToolRegistry.standard(), options: const GenerationOptions(), maxSteps: maxSteps);
  final events = await engine.run(history: const [], userMessage: input, context: ctx).toList();
  return (events, ctx, repo);
}

void main() {
  test('plain answer finishes in one step', () async {
    final backend = ScriptedBackend(['سلام! چطور کمک کنم؟']);
    final (events, _, _) = await runAgent(backend, 'سلام');
    expect(events.last, isA<AgentFinal>());
    expect((events.last as AgentFinal).text, 'سلام! چطور کمک کنم؟');
    expect(events.whereType<AgentDelta>(), isNotEmpty);
    // system prompt lists every tool
    final system = backend.prompts.first.first.content;
    for (final t in ['write_text', 'write_caption', 'generate_hashtags', 'apply_skill', 'save_to_drafts']) {
      expect(system, contains(t));
    }
  });

  test('tool call → result fed back → final answer', () async {
    final backend = ScriptedBackend([
      '{"tool": "write_caption", "args": {"topic": "کافه دنج", "language": "fa"}}',
      'کپشن: «یک فنجان آرامش ☕»', // ContentGenerator.writeCaption sub-call
      'این کپشن آماده است: یک فنجان آرامش ☕',
    ]);
    final (events, _, _) = await runAgent(backend, 'یک کپشن برای کافه بنویس');
    final started = events.whereType<AgentToolStarted>().single;
    expect(started.call.name, 'write_caption');
    final finished = events.whereType<AgentToolFinished>().single;
    expect(finished.result.ok, isTrue);
    expect(finished.result.data['caption_fa'], 'یک فنجان آرامش ☕');
    expect((events.last as AgentFinal).text, contains('یک فنجان آرامش'));
    // the third prompt contains the tool result
    expect(backend.prompts[2].last.content, startsWith('TOOL_RESULT write_caption'));
  });

  test('save_to_drafts and apply_skill tools work', () async {
    final backend = ScriptedBackend([
      '{"tool": "apply_skill", "args": {"name": "محتوای ویرال"}}',
      '{"tool": "save_to_drafts", "args": {"title": "t1", "content": "متن نهایی", "hashtags": ["#a", "#b"]}}',
      'ذخیره شد.',
    ]);
    final (events, ctx, repo) = await runAgent(backend, 'ذخیره کن');
    expect(ctx.activeSkill?.id, viralSkillId);
    final drafts = await repo.all();
    expect(drafts.single.title, 't1');
    expect(drafts.single.hashtags, '#a #b');
    // after apply_skill, the system prompt carries the skill block
    expect(backend.prompts[1].first.content, contains('ACTIVE SKILL: محتوای ویرال'));
    expect(events.last, isA<AgentFinal>());
  });

  test('generate_hashtags returns sets of at most 5', () async {
    final backend = ScriptedBackend([
      '{"tool":"generate_hashtags","args":{"topic":"عکاسی غذا","count":12}}',
      '#عکاسی_غذا #غذا #فودی #آشپزی #رستوران #food #foodphotography #yummy #دسر #کیک',
      'تمام',
    ]);
    final (events, _, _) = await runAgent(backend, 'هشتگ');
    final result = events.whereType<AgentToolFinished>().single.result;
    final sets = (result.data['sets'] as List<Object?>).cast<String>();
    expect(sets, isNotEmpty);
    for (final s in sets) {
      expect(s.split(' ').length, lessThanOrEqualTo(5));
    }
  });

  test('unknown tool is reported back to the model', () async {
    final backend = ScriptedBackend(['{"tool": "post_now", "args": {}}', 'نمی‌توانم منتشر کنم.']);
    final (events, _, _) = await runAgent(backend, 'منتشر کن');
    final r = events.whereType<AgentToolFinished>().single.result;
    expect(r.ok, isFalse);
    expect(r.data['error'], contains('unknown tool'));
    expect((events.last as AgentFinal).text, 'نمی‌توانم منتشر کنم.');
  });

  test('stops after maxSteps and asks for a plain final answer', () async {
    final backend = ScriptedBackend([
      '{"tool":"apply_skill","args":{"name":"viral-content"}}',
      '{"tool":"apply_skill","args":{"name":"viral-content"}}',
      'پاسخ نهایی',
    ]);
    final (events, _, _) = await runAgent(backend, 'x', maxSteps: 2);
    expect(events.whereType<AgentToolFinished>(), hasLength(2));
    expect((events.last as AgentFinal).text, 'پاسخ نهایی');
  });

  test('backend errors surface as AgentFailed', () async {
    final skills = SkillRepository(MemorySkillStorage());
    final backend = FailingBackend('process_died');
    final engine = AgentEngine(backend: backend, registry: ToolRegistry.standard(), options: const GenerationOptions());
    final events = await engine
        .run(
          history: const [],
          userMessage: 'hi',
          context: ToolContext(
            generator: ContentGenerator(backend),
            skills: skills,
            drafts: MemoryRepository(),
            activeSkill: null,
            onSkillApplied: (_) async {},
            language: 'fa',
          ),
        )
        .toList();
    expect(events.single, isA<AgentFailed>());
    expect((events.single as AgentFailed).error.code, 'process_died');
  });

  test('trimHistory keeps newest turns within budget and starts with a user turn', () {
    final h = [
      const ChatMessage.user('aaaaaaaaaa'),
      const ChatMessage.assistant('bbbbbbbbbb'),
      const ChatMessage.user('cccccccccc'),
      const ChatMessage.assistant('dddddddddd'),
      const ChatMessage.user('eeeeeeeeee'),
    ];
    final t = trimHistory(h, 60);
    expect(t.first.role, 'user');
    expect(t.last.content, 'eeeeeeeeee');
    expect(t.length, lessThan(h.length));
    expect(trimHistory(h, 1).single.content, 'eeeeeeeeee');
  });
}
