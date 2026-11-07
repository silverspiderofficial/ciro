import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/skills/builtin_skills.dart';
import 'package:kiro/skills/skill.dart';
import 'package:kiro/skills/skill_repository.dart';

const sample = '''---
{
  "id": "cafe-page",
  "name": "پیج کافه",
  "page_style": "گرم و دنج",
  "audience": "دانشجوها",
  "tone": "صمیمی",
  "topics": ["قهوه", "کیک"],
  "post_format": "carousel",
  "language": "fa"
}
---
# راهنما
- همیشه از عکس نور طبیعی بگو.
''';

void main() {
  group('parseSkill', () {
    test('parses JSON front matter and body', () {
      final s = parseSkill(sample);
      expect(s.id, 'cafe-page');
      expect(s.name, 'پیج کافه');
      expect(s.topics, ['قهوه', 'کیک']);
      expect(s.postFormat, 'carousel');
      expect(s.body, startsWith('# راهنما'));
      expect(s.builtIn, isFalse);
    });

    test('round-trips through toMarkdown', () {
      final s = parseSkill(sample);
      final again = parseSkill(s.toMarkdown());
      expect(again.name, s.name);
      expect(again.topics, s.topics);
      expect(again.body, s.body);
      expect(again.tone, s.tone);
    });

    test('tolerates CRLF, BOM, string topics and unknown format', () {
      final src = '\uFEFF---\r\n{"name": "X", "topics": "a، b, c", "post_format": "weird"}\r\n---\r\nbody';
      final s = parseSkill(src, fallbackId: 'my file');
      expect(s.id, 'my-file');
      expect(s.topics, ['a', 'b', 'c']);
      expect(s.postFormat, 'mixed');
      expect(s.body, 'body');
    });

    test('rejects invalid files', () {
      expect(() => parseSkill('no front matter'), throwsA(isA<SkillParseException>()));
      expect(() => parseSkill('---\n{"name": "x"\n'), throwsA(isA<SkillParseException>()));
      expect(() => parseSkill('---\n{bad json}\n---\n'), throwsA(isA<SkillParseException>()));
      expect(() => parseSkill('---\n{"tone": "x"}\n---\n'), throwsA(isA<SkillParseException>()));
      expect(() => parseSkill('---\n[1,2]\n---\n'), throwsA(isA<SkillParseException>()));
    });

    test('slugify handles Persian names with a stable id', () {
      expect(slugify('Viral Content!'), 'viral-content');
      final a = slugify('محتوای ویرال');
      expect(a, startsWith('skill-'));
      expect(slugify('محتوای ویرال'), a);
    });

    test('prompt block includes the profile and guidelines', () {
      final block = parseSkill(sample).toPromptBlock();
      expect(block, contains('ACTIVE SKILL: پیج کافه'));
      expect(block, contains('Tone: صمیمی'));
      expect(block, contains('همیشه از عکس'));
    });
  });

  group('built-in viral skill', () {
    test('parses and covers hook, reels, carousel and CTA', () {
      final s = parseSkill(viralContentSkill.toMarkdown());
      expect(s.id, viralSkillId);
      expect(s.builtIn, isTrue);
      expect(s.body, contains('۳ ثانیه'));
      expect(s.body, contains('ساختار ریلز'));
      expect(s.body, contains('کاروسل آموزشی'));
      expect(s.body, contains('دعوت به اقدام'));
    });
  });

  group('SkillRepository', () {
    test('seeds built-ins, imports with unique ids, finds and deletes', () async {
      final storage = MemorySkillStorage();
      final repo = SkillRepository(storage);
      await repo.init();
      expect(repo.skills.map((s) => s.id), contains(viralSkillId));

      final a = await repo.importSource(sample);
      final b = await repo.importSource(sample);
      expect(a.id, 'cafe-page');
      expect(b.id, 'cafe-page-2');
      expect(repo.find('کافه')?.id, isNotNull);
      expect(repo.find('viral-content')?.id, viralSkillId);

      await repo.delete(viralSkillId);
      expect(repo.byId(viralSkillId), isNull);
      await repo.restoreBuiltIns();
      expect(repo.byId(viralSkillId), isNotNull);
    });

    test('skips damaged files', () async {
      final storage = MemorySkillStorage()..files['bad'] = 'garbage';
      final repo = SkillRepository(storage);
      await repo.init(seedBuiltIns: false);
      expect(repo.skills, isEmpty);
    });
  });
}
