/// Agent tools for the Studio: make_image_prompt, generate_image, edit_video.
library;

import '../studio/image/prompt_builder.dart';
import '../studio/studio_catalog.dart';
import '../studio/studio_errors.dart';
import '../studio/studio_service.dart';
import '../studio/templates/templates.dart';
import '../studio/video/video_project.dart';
import 'tool_call_parser.dart';
import 'tools.dart';

/// What the tools need from the Studio (implemented by [StudioToolsAdapter]; faked in tests).
abstract class StudioToolsHost {
  bool get canGenerateImages;

  /// Why images fall back to templates (none | notArm64 | noDotprod | lowRam | noModel).
  String get imageBlocker;
  Future<String> generateImage(String prompt, String negative);
  Future<String> titleCard(String title, String subtitle, {required bool vertical});
  bool voiceInstalled(NarratorVoice voice);
  Future<String> renderVideo(VideoProject project);
  Future<int> saveMediaDraft(String title, String path, {String? extra});
}

class StudioToolsAdapter implements StudioToolsHost {
  StudioToolsAdapter(this.studio);
  final StudioService studio;

  @override
  bool get canGenerateImages => studio.canGenerateImages;
  @override
  String get imageBlocker => studio.imageBlocker.name;
  @override
  Future<String> generateImage(String prompt, String negative) => studio.generateImage(prompt: prompt, negative: negative);
  @override
  Future<String> titleCard(String title, String subtitle, {required bool vertical}) =>
      studio.templateFallback(title, subtitle: subtitle, format: vertical ? TemplateFormat.story : TemplateFormat.portrait);
  @override
  bool voiceInstalled(NarratorVoice voice) {
    final spec = studioAssetById(voice.key);
    return spec != null && studio.assets.isInstalled(spec);
  }

  @override
  Future<String> renderVideo(VideoProject project) => studio.renderVideo(project);
  @override
  Future<int> saveMediaDraft(String title, String path, {String? extra}) => studio.saveMediaDraft(title: title, path: path, extra: extra);
}

class MakeImagePromptTool implements AgentTool {
  @override
  String get name => 'make_image_prompt';
  @override
  String get usage =>
      'make_image_prompt(topic, style: photo|illustration|cinematic|minimal|3d|watercolor) — writes an English prompt for the image generator.';

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final topic = argString(args, ['topic', 'subject', 'text', 'description']);
    if (topic.isEmpty) return const ToolResult(false, {'error': 'topic is required'});
    final prompt = await makeImagePrompt(
      ctx.generator.backend,
      ctx.generator.options,
      topic: topic,
      style: ImageStyle.fromKey(argString(args, ['style'])),
      extra: argString(args, ['details', 'extra']),
      cancel: ctx.cancel,
    );
    return ToolResult(true, prompt.toJson());
  }
}

class GenerateImageTool implements AgentTool {
  @override
  String get name => 'generate_image';
  @override
  String get usage =>
      'generate_image(prompt, topic, style) — makes an image on the phone (512x512) and saves it to drafts. '
      'prompt must be English (use make_image_prompt first); on phones that cannot run the image model a title card is made from topic.';

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final studio = ctx.studio;
    if (studio == null) return const ToolResult(false, {'error': 'studio unavailable'});
    var prompt = argString(args, ['prompt', 'image_prompt']);
    final topic = argString(args, ['topic', 'title', 'subject'], fallback: prompt);
    if (prompt.isEmpty && topic.isEmpty) return const ToolResult(false, {'error': 'prompt or topic is required'});
    final style = ImageStyle.fromKey(argString(args, ['style']));
    try {
      if (!studio.canGenerateImages) {
        final path = await studio.titleCard(topic, '', vertical: false);
        ctx.media.add(path);
        final id = await studio.saveMediaDraft(topic, path);
        return ToolResult(true, {'path': path, 'mode': 'template', 'reason': studio.imageBlocker, 'draft_id': id});
      }
      if (prompt.isEmpty || containsPersian(prompt)) {
        prompt = (await makeImagePrompt(ctx.generator.backend, ctx.generator.options, topic: topic, style: style, cancel: ctx.cancel)).prompt;
      } else {
        prompt = withStyle(cleanImagePrompt(prompt), style);
      }
      final negative = argString(args, ['negative', 'negative_prompt'], fallback: defaultNegativePrompt);
      final path = await studio.generateImage(prompt, negative);
      ctx.media.add(path);
      final id = await studio.saveMediaDraft(topic, path);
      return ToolResult(true, {'path': path, 'mode': 'generated', 'prompt': prompt, 'draft_id': id});
    } on StudioException catch (e) {
      return ToolResult(false, {'error': e.code});
    }
  }
}

class EditVideoTool implements AgentTool {
  @override
  String get name => 'edit_video';
  @override
  String get usage =>
      'edit_video(scenes: [{text, narration, image}], voice: fa|en|none, music: happy|city|calm|none, subtitles: true|false) — '
      'renders a vertical 9:16 Reels video (Ken Burns motion, transitions, animated text, subtitles, narrator, music). '
      'image is optional: images made earlier in this chat are used in order, otherwise title cards are made.';

  static String musicId(String v) => switch (v.toLowerCase()) {
        'none' || 'no' || 'off' || '' => 'none',
        'calm' || 'heavenly' || 'heavenly_loop' || 'soft' => 'heavenly_loop',
        'city' || 'city_loop' || 'urban' => 'city_loop',
        _ => 'happy_loop',
      };

  @override
  Future<ToolResult> run(Map<String, Object?> args, ToolContext ctx) async {
    final studio = ctx.studio;
    if (studio == null) return const ToolResult(false, {'error': 'studio unavailable'});
    final rawScenes = args['scenes'];
    final specs = <Map<String, Object?>>[];
    if (rawScenes is List) {
      for (final s in rawScenes) {
        if (s is Map) {
          specs.add(s.map((k, v) => MapEntry('$k', v)));
        } else if (s is String && s.trim().isNotEmpty) {
          specs.add({'narration': s});
        }
      }
    } else {
      final script = argString(args, ['script', 'narration', 'text']);
      for (final line in script.split(RegExp(r'\n+'))) {
        if (line.trim().isNotEmpty) specs.add({'narration': line.trim()});
      }
    }
    if (specs.isEmpty) return const ToolResult(false, {'error': 'scenes (or script) are required'});
    if (specs.length > 12) specs.removeRange(12, specs.length);

    final lang = argString(args, ['voice', 'language', 'lang'], fallback: ctx.language).toLowerCase();
    var voice = lang.startsWith('en')
        ? NarratorVoice.english
        : (lang == 'none' || lang == 'off')
            ? NarratorVoice.none
            : NarratorVoice.persian;
    final notes = <String>[];
    if (voice != NarratorVoice.none && !studio.voiceInstalled(voice)) {
      notes.add('voice not downloaded; rendered without narrator');
      voice = NarratorVoice.none;
    }
    final subtitlesRaw = args['subtitles'];
    final subtitles = subtitlesRaw is bool ? subtitlesRaw : !(subtitlesRaw is String && subtitlesRaw.toLowerCase() == 'false');

    try {
      final media = List<String>.from(ctx.media);
      final scenes = <VideoScene>[];
      for (var i = 0; i < specs.length; i++) {
        final s = specs[i];
        final narration = argString(s, ['narration', 'voiceover', 'voice_over', 'speech']);
        final text = argString(s, ['text', 'title', 'overlay', 'on_screen_text']);
        var image = argString(s, ['image', 'image_path', 'path']);
        if (image.isEmpty && media.isNotEmpty) image = media.removeAt(0);
        var madeCard = false;
        if (image.isEmpty) {
          final card = text.isNotEmpty ? text : (narration.isNotEmpty ? narration : '${i + 1}');
          image = await studio.titleCard(card, '', vertical: true);
          madeCard = true;
        }
        scenes.add(VideoScene(
          imagePath: image,
          narration: narration,
          // A title card already shows its text; do not repeat it on top.
          overlayText: madeCard ? '' : text,
        ));
      }
      final project = VideoProject(
        title: argString(args, ['title'], fallback: scenes.first.overlayText),
        scenes: scenes,
        voice: voice,
        musicTrackId: musicId(argString(args, ['music'], fallback: 'happy')),
        subtitles: subtitles,
      );
      final path = await studio.renderVideo(project);
      final id = await studio.saveMediaDraft(project.title, path, extra: project.encode());
      return ToolResult(true, {'path': path, 'scenes': scenes.length, 'draft_id': id, if (notes.isNotEmpty) 'note': notes.join('; ')});
    } on StudioException catch (e) {
      return ToolResult(false, {'error': e.code});
    }
  }
}
