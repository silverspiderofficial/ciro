import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../agent/content_generator.dart';
import '../../app/services.dart';
import '../../content/content_helpers.dart';
import '../../core/format.dart';
import '../../data/repositories.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../llm/llm_backend.dart';
import '../../llm/local_backend.dart';
import '../../skills/skill_repository.dart';
import '../common/engine_banner.dart';

/// Topic → Persian / English caption + hashtag sets (max 5 each), all copyable.
class CaptionScreen extends StatefulWidget {
  const CaptionScreen({super.key});

  @override
  State<CaptionScreen> createState() => _CaptionScreenState();
}

class _CaptionScreenState extends State<CaptionScreen> {
  final _topic = TextEditingController();
  String _language = 'fa';
  String? _skillId;
  bool _busy = false;
  CancelToken? _cancel;
  String? _captionFa;
  String? _captionEn;
  List<List<String>> _sets = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _skillId = context.read<SettingsController>().activeSkillId;
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _topic.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final s = context.sRead;
    final topic = _topic.text.trim();
    if (topic.isEmpty) {
      setState(() => _error = s.t('topicRequired'));
      return;
    }
    final services = context.read<AppServices>();
    final skill = context.read<SkillRepository>().byId(_skillId);
    setState(() {
      _busy = true;
      _error = null;
      _captionFa = null;
      _captionEn = null;
      _sets = const [];
    });
    final backend = await services.resolveBackend();
    if (!backend.isRemote) {
      final err = await services.ensureModelLoaded();
      if (err != null) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = errorMessage(s, err, engine: services.engine);
          });
        }
        return;
      }
    }
    final cancel = _cancel = CancelToken();
    final gen = ContentGenerator(backend, options: services.generationOptions);
    try {
      if (_language == 'fa' || _language == 'both') {
        final c = await gen.writeCaption(topic: topic, language: 'fa', tone: skill?.tone ?? '', skill: skill, cancel: cancel);
        if (mounted) setState(() => _captionFa = c);
      }
      if (cancel.isCancelled) return;
      if (_language == 'en' || _language == 'both') {
        final c = await gen.writeCaption(topic: topic, language: 'en', tone: skill?.tone ?? '', skill: skill, cancel: cancel);
        if (mounted) setState(() => _captionEn = c);
      }
      if (cancel.isCancelled) return;
      final tags = await gen.hashtags(topic: topic, language: _language, skill: skill, cancel: cancel);
      if (mounted) setState(() => _sets = HashtagHelper.buildSets(tags));
    } on LlmException catch (e) {
      if (mounted && !cancel.isCancelled) setState(() => _error = errorMessage(s, e.code, engine: services.engine));
    } finally {
      if (mounted) setState(() => _busy = false);
      _cancel = null;
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.sRead.t('copied'))));
  }

  Future<void> _saveDraft() async {
    final services = context.read<AppServices>();
    final messenger = ScaffoldMessenger.of(context);
    final s = context.sRead;
    final caption = [_captionFa, _captionEn].whereType<String>().join('\n\n');
    await services.drafts.add(Draft(
      title: _topic.text.trim(),
      content: '',
      caption: caption,
      hashtags: _sets.isEmpty ? '' : _sets.first.join(' '),
      createdAt: DateTime.now(),
    ));
    messenger.showSnackBar(SnackBar(content: Text(s.t('savedToDrafts'))));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final skills = context.watch<SkillRepository>().skills;
    context.watch<LocalEngine>();
    final hasResult = _captionFa != null || _captionEn != null || _sets.isNotEmpty;
    final firstSet = _sets.isEmpty ? const <String>[] : _sets.first;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('captionTitle'))),
      body: Column(
        children: [
          const EngineBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _topic,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(labelText: s.t('captionTopic'), hintText: s.t('captionTopicHint')),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'fa', label: Text(s.t('langFa'))),
                    ButtonSegment(value: 'en', label: Text(s.t('langEn'))),
                    ButtonSegment(value: 'both', label: Text(s.t('langBoth'))),
                  ],
                  selected: {_language},
                  onSelectionChanged: _busy ? null : (v) => setState(() => _language = v.first),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  value: skills.any((k) => k.id == _skillId) ? _skillId : null,
                  decoration: InputDecoration(labelText: s.t('skillForContent')),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text(s.t('noSkill'))),
                    for (final k in skills) DropdownMenuItem<String?>(value: k.id, child: Text(k.name)),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _skillId = v),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _generate,
                        icon: _busy
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_awesome),
                        label: Text(_busy ? s.t('generating') : s.t('generate')),
                      ),
                    ),
                    if (_busy) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: () => _cancel?.cancel(), child: Text(s.t('stop'))),
                    ],
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                if (_captionFa != null) _ResultCard(title: s.t('captionFa'), text: _captionFa!, onCopy: _copy),
                if (_captionEn != null) _ResultCard(title: s.t('captionEn'), text: _captionEn!, onCopy: _copy, ltr: true),
                if (_sets.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(s.t('hashtagSets'), style: Theme.of(context).textTheme.titleMedium),
                  for (var i = 0; i < _sets.length; i++)
                    _ResultCard(
                      title: s.t('hashtagSet', {'n': localizeDigits('${i + 1}', s.languageCode)}),
                      text: _sets[i].join(' '),
                      onCopy: _copy,
                    ),
                ],
                if (hasResult && !_busy) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_captionFa != null)
                        OutlinedButton.icon(
                          onPressed: () => _copy(CaptionHelper.compose(_captionFa!, firstSet)),
                          icon: const Icon(Icons.copy_all),
                          label: Text('${s.t('copyAll')} (${s.t('langFa')})'),
                        ),
                      if (_captionEn != null)
                        OutlinedButton.icon(
                          onPressed: () => _copy(CaptionHelper.compose(_captionEn!, firstSet)),
                          icon: const Icon(Icons.copy_all),
                          label: Text('${s.t('copyAll')} (${s.t('langEn')})'),
                        ),
                      FilledButton.tonalIcon(
                        onPressed: _saveDraft,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: Text(s.t('saveToDrafts')),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.title, required this.text, required this.onCopy, this.ltr = false});
  final String title;
  final String text;
  final ValueChanged<String> onCopy;
  final bool ltr;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.labelLarge)),
                IconButton(icon: const Icon(Icons.copy), onPressed: () => onCopy(text)),
              ],
            ),
            Directionality(
              textDirection: ltr ? TextDirection.ltr : Directionality.of(context),
              child: SelectableText(text),
            ),
          ],
        ),
      ),
    );
  }
}
