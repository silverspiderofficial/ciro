import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/agent/content_generator.dart';
import 'package:kiro/agent/studio_tools.dart';
import 'package:kiro/agent/tools.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/llm/llm_backend.dart';
import 'package:kiro/skills/skill_repository.dart';
import 'package:kiro/studio/image/prompt_builder.dart';
import 'package:kiro/studio/studio_errors.dart';
import 'package:kiro/studio/tts/tts_engine.dart';
import 'package:kiro/studio/video/video_project.dart';

import 'fakes.dart';

class FakeHost implements StudioToolsHost {
  FakeHost({this.canGenerate = true, this.voices = const {NarratorVoice.persian}});
  bool canGenerate;
  Set<NarratorVoice> voices;
  final List<String> prompts = [];
  final List<String> cards = [];
  final List<VideoProject> videos = [];
  final List<String> drafts = [];
  String? failCode;

  @override
  bool get canGenerateImages => canGenerate;
  @override
  String get imageBlocker => canGenerate ? 'none' : 'lowRam';
  @override
  Future<String> generateImage(String prompt, String negative) async {
    if (failCode != null) throw StudioException(failCode!);
    prompts.add(prompt);
    return '/out/image_${prompts.length}.png';
  }

  @override
  Future<String> titleCard(String title, String subtitle, {required bool vertical}) async {
    cards.add(title);
    return '/out/template_${cards.length}.png';
  }

  @override
  bool voiceInstalled(NarratorVoice voice) => voices.contains(voice);
  @override
  Future<String> renderVideo(VideoProject project) async {
    videos.add(project);
    return '/out/video.mp4';
  }

  @override
  Future<int> saveMediaDraft(String title, String path, {String? extra}) async {
    drafts.add(path);
    return drafts.length;
  }
}

Future<ToolContext> ctxWith(FakeHost host, List<String> replies) async {
  final skills = SkillRepository(MemorySkillStorage());
  await skills.init();
  return ToolContext(
    generator: ContentGenerator(ScriptedBackend(replies)),
    skills: skills,
    drafts: MemoryRepository(),
    activeSkill: null,
    onSkillApplied: (_) async {},
    language: 'fa',
    studio: host,
  );
}

void main() {
  group('prompt helpers', () {
    test('cleanImagePrompt strips labels, quotes, negatives and hashtags', () {
      expect(cleanImagePrompt('Prompt: "a red bicycle, city street, golden hour" #bike\nNegative: blurry'),
          'a red bicycle, city street, golden hour');
      expect(cleanImagePrompt('```\ncoffee cup,\n\n wooden table\n```'), 'coffee cup, wooden table');
      final long = List.filled(80, 'detail').join(', ');
      expect(cleanImagePrompt(long, maxChars: 100).length, lessThanOrEqualTo(100));
    });

    test('withStyle appends the style once', () {
      expect(withStyle('a cat', ImageStyle.minimal), startsWith('a cat, minimalist composition'));
      final once = withStyle('a cat', ImageStyle.minimal);
      expect(withStyle(once, ImageStyle.minimal), once);
      expect(ImageStyle.fromKey('nope'), ImageStyle.photo);
    });

    test('makeImagePrompt uses the model and falls back to Latin words', () async {
      final ok = await makeImagePrompt(ScriptedBackend(['Prompt: a steaming latte, soft light']), const GenerationOptions(),
          topic: 'قهوه', style: ImageStyle.photo);
      expect(ok.prompt, startsWith('a steaming latte, soft light, professional photo'));
      expect(ok.negative, contains('text'));
      final persianOnly = await makeImagePrompt(ScriptedBackend(['یک فنجان قهوه']), const GenerationOptions(),
          topic: 'latte art قهوه', style: ImageStyle.photo);
      expect(persianOnly.prompt, startsWith('latte art'));
      expect(containsPersian(persianOnly.prompt), isFalse);
    });

    test('cleanForSpeech drops hashtags, mentions, links and emoji', () {
      expect(cleanForSpeech('سلام 👋 به #کیرو خوش آمدی @page https://x.y/z **مهم**'), 'سلام به خوش آمدی مهم');
    });
  });

  group('tools', () {
    test('make_image_prompt returns an English prompt', () async {
      final ctx = await ctxWith(FakeHost(), ['a bowl of saffron rice, top view']);
      final r = await MakeImagePromptTool().run({'topic': 'پلو زعفرانی', 'style': 'minimal'}, ctx);
      expect(r.ok, isTrue);
      expect(r.data['prompt'], startsWith('a bowl of saffron rice, top view, minimalist'));
    });

    test('generate_image translates Persian, generates and saves a draft', () async {
      final host = FakeHost();
      final ctx = await ctxWith(host, ['a minimalist desk setup, laptop, plant']);
      final r = await GenerateImageTool().run({'prompt': 'میز کار مینیمال', 'style': 'photo'}, ctx);
      expect(r.ok, isTrue);
      expect(r.data['mode'], 'generated');
      expect(host.prompts.single, startsWith('a minimalist desk setup'));
      expect(ctx.media, ['/out/image_1.png']);
      expect(host.drafts, ['/out/image_1.png']);
    });

    test('generate_image falls back to a title card on weak phones', () async {
      final host = FakeHost(canGenerate: false);
      final ctx = await ctxWith(host, []);
      final r = await GenerateImageTool().run({'topic': '۵ نکته برای خواب بهتر'}, ctx);
      expect(r.ok, isTrue);
      expect(r.data['mode'], 'template');
      expect(r.data['reason'], 'lowRam');
      expect(host.cards, ['۵ نکته برای خواب بهتر']);
    });

    test('generate_image reports studio errors', () async {
      final host = FakeHost()..failCode = 'power_blocked';
      final ctx = await ctxWith(host, []);
      final r = await GenerateImageTool().run({'prompt': 'a cat on a sofa'}, ctx);
      expect(r.ok, isFalse);
      expect(r.data['error'], 'power_blocked');
    });

    test('edit_video uses earlier images, then title cards, and renders', () async {
      final host = FakeHost();
      final ctx = await ctxWith(host, []);
      ctx.media.add('/out/image_a.png');
      final r = await EditVideoTool().run({
        'scenes': [
          {'text': 'قلاب', 'narration': 'آیا می‌دانستید؟'},
          {'text': 'نکتهٔ دوم', 'narration': 'جمله دوم.'},
          'جمله سوم بدون تصویر.',
        ],
        'voice': 'fa',
        'music': 'calm',
      }, ctx);
      expect(r.ok, isTrue, reason: '${r.data}');
      final p = host.videos.single;
      expect(p.scenes.length, 3);
      expect(p.scenes[0].imagePath, '/out/image_a.png');
      expect(p.scenes[0].overlayText, 'قلاب');
      expect(p.scenes[1].imagePath, '/out/template_1.png');
      expect(p.scenes[1].overlayText, '', reason: 'title cards already show their text');
      expect(p.scenes[2].narration, 'جمله سوم بدون تصویر.');
      expect(p.voice, NarratorVoice.persian);
      expect(p.musicTrackId, 'heavenly_loop');
      expect(host.drafts.single, '/out/video.mp4');
    });

    test('edit_video renders without a narrator when the voice is missing', () async {
      final host = FakeHost(voices: const {});
      final ctx = await ctxWith(host, []);
      final r = await EditVideoTool().run({'script': 'خط اول\nخط دوم', 'voice': 'en', 'music': 'none'}, ctx);
      expect(r.ok, isTrue);
      expect(r.data['note'], contains('voice'));
      expect(host.videos.single.voice, NarratorVoice.none);
      expect(host.videos.single.musicTrackId, 'none');
      expect(host.videos.single.scenes.length, 2);
    });

    test('studio tools are registered only with a studio', () {
      expect(ToolRegistry.standard()['generate_image'], isNull);
      final r = ToolRegistry.standard(studio: true);
      for (final n in ['make_image_prompt', 'generate_image', 'edit_video']) {
        expect(r[n], isNotNull, reason: n);
      }
    });
  });
}
