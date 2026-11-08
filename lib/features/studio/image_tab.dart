import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../core/format.dart';
import '../../l10n/strings.dart';
import '../../studio/image/prompt_builder.dart';
import '../../studio/studio_assets.dart';
import '../../studio/studio_catalog.dart';
import '../../studio/studio_errors.dart';
import '../../studio/studio_service.dart';
import 'studio_assets_screen.dart';
import 'studio_common.dart';

class ImageTab extends StatefulWidget {
  const ImageTab({super.key});

  @override
  State<ImageTab> createState() => _ImageTabState();
}

class _ImageTabState extends State<ImageTab> {
  final _prompt = TextEditingController();
  final _negative = TextEditingController(text: defaultNegativePrompt);
  final _seed = TextEditingController();
  ImageStyle _style = ImageStyle.photo;
  double? _steps;
  bool _writingPrompt = false;

  @override
  void dispose() {
    _prompt.dispose();
    _negative.dispose();
    _seed.dispose();
    super.dispose();
  }

  Future<String?> _englishPrompt(String idea) async {
    final services = context.read<AppServices>();
    final backend = await services.resolveBackend();
    if (!backend.isRemote) {
      final err = await services.ensureModelLoaded();
      if (err != null) return null;
    }
    final p = await makeImagePrompt(backend, services.generationOptions, topic: idea, style: ImageStyle.photo);
    return p.prompt;
  }

  Future<void> _writePrompt() async {
    final idea = _prompt.text.trim();
    if (idea.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final s = context.sRead;
    setState(() => _writingPrompt = true);
    try {
      final p = await _englishPrompt(idea);
      if (p != null && mounted) {
        _prompt.text = p;
        messenger.showSnackBar(SnackBar(content: Text(s.t('studioPromptReady'))));
      }
    } on Object {
      // keep the user's text
    } finally {
      if (mounted) setState(() => _writingPrompt = false);
    }
  }

  Future<void> _generate({bool force = false}) async {
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    var prompt = _prompt.text.trim();
    if (prompt.isEmpty) return;
    if (containsPersian(prompt)) {
      setState(() => _writingPrompt = true);
      try {
        prompt = await _englishPrompt(prompt) ?? prompt;
        if (mounted) _prompt.text = prompt;
      } on Object {
        // generate with what we have
      } finally {
        if (mounted) setState(() => _writingPrompt = false);
      }
    }
    if (!mounted) return;
    final s = context.sRead;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await studio.generateImage(
        prompt: withStyle(cleanImagePrompt(prompt), _style),
        negative: _negative.text.trim(),
        steps: _steps?.round() ?? 0,
        seed: int.tryParse(toLatinDigits(_seed.text.trim())) ?? -1,
        force: force,
      );
      ui.setLastImage(path);
    } on StudioException catch (e) {
      if (!mounted) return;
      if (e.code == 'low_ram') {
        messenger.showSnackBar(SnackBar(
          content: Text(s.t('studioErr_low_ram')),
          action: SnackBarAction(label: s.t('studioForce'), onPressed: () => _generate(force: true)),
        ));
      } else {
        await runStudio<void>(context, () => Future.error(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final studio = context.watch<StudioService>();
    context.watch<StudioAssetManager>();
    final ui = context.watch<StudioUiState>();
    final model = studio.imageModel;
    final blocker = studio.imageBlocker;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (blocker != ImageGenBlocker.none) _BlockerCard(blocker: blocker, model: model),
        if (blocker == ImageGenBlocker.none || blocker == ImageGenBlocker.noModel) ...[
          TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(labelText: s.t('studioPrompt'), hintText: s.t('studioPromptHint')),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _writingPrompt ? null : _writePrompt,
              icon: _writingPrompt
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_fix_high_outlined),
              label: Text(s.t('studioMakePrompt')),
            ),
          ),
          Text(s.t('studioStyle'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final st in ImageStyle.values)
                ChoiceChip(label: Text(s.t('styleFa_${st.key}')), selected: _style == st, onSelected: (_) => setState(() => _style = st)),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(s.t('studioAdvanced')),
            children: [
              Text(s.t('studioSteps', {'n': localizeDigits('${(_steps ?? model.defaultSteps.toDouble()).round()}', s.languageCode)})),
              Slider(
                value: _steps ?? model.defaultSteps.toDouble(),
                min: 1,
                max: (model.defaultSteps * 2).clamp(4, 40).toDouble(),
                divisions: (model.defaultSteps * 2).clamp(4, 40) - 1,
                onChanged: (v) => setState(() => _steps = v),
              ),
              TextField(
                controller: _seed,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: s.t('studioSeed'), hintText: s.t('studioSeedRandom')),
              ),
              const SizedBox(height: 8),
              TextField(controller: _negative, maxLines: 3, decoration: InputDecoration(labelText: s.t('studioNegative'))),
              const SizedBox(height: 8),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: studio.busy || blocker != ImageGenBlocker.none || _writingPrompt ? null : _generate,
            icon: const Icon(Icons.auto_awesome),
            label: Text(s.t('studioGenerate')),
          ),
        ],
        const SizedBox(height: 16),
        if (ui.lastImage != null) ...[
          FileImagePreview(path: ui.lastImage!),
          const SizedBox(height: 12),
          MediaActions(
            path: ui.lastImage!,
            title: _prompt.text,
            onAddToVideo: () {
              ui.addScene(ui.lastImage!);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('studioAddedToVideo'))));
            },
            onUseAsBackground: () {
              ui.setTemplate(ui.template.copyWith(backgroundImagePath: ui.lastImage));
              ui.tabRequest.value = 1;
            },
          ),
        ] else
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(s.t('studioEmptyImage'), textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

class _BlockerCard extends StatelessWidget {
  const _BlockerCard({required this.blocker, required this.model});
  final ImageGenBlocker blocker;
  final StudioAssetSpec model;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final ram = studio.device == null ? '' : formatBytes(studio.device!.totalRamBytes, languageCode: s.languageCode);
    final noModel = blocker == ImageGenBlocker.noModel;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t(noModel ? 'studioNoModelTitle' : 'studioWeakTitle'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(noModel
                ? s.t('studioNoModelBody', {'name': model.name, 'size': formatBytes(model.totalBytes, languageCode: s.languageCode)})
                : s.t('studioWeak_${blocker.name}', {'ram': ram})),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                if (noModel)
                  FilledButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: Text(s.t('studioDownloadModel')),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StudioAssetsScreen())),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: Text(s.t('studioUseTemplate')),
                  onPressed: () => ui.tabRequest.value = 1,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
