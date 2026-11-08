import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/format.dart';
import '../../l10n/strings.dart';
import '../../studio/studio_assets.dart';
import '../../studio/studio_catalog.dart';
import '../../studio/studio_service.dart';
import '../../studio/templates/templates.dart';
import '../../studio/video/timeline.dart';
import '../../studio/video/video_project.dart';
import '../../studio/video/video_renderer.dart';
import 'paid_video_card.dart';
import 'studio_assets_screen.dart';
import 'studio_common.dart';

class VideoTab extends StatelessWidget {
  const VideoTab({super.key});

  Future<void> _addScene(BuildContext context) async {
    final s = context.sRead;
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final recent = await studio.recentImages();
    if (!context.mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (recent.isNotEmpty) ...[
              ListTile(title: Text(s.t('vidPickFromRecent'))),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: recent.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => InkWell(
                    onTap: () => Navigator.pop(ctx, recent[i]),
                    child: SizedBox(width: 100, child: FileImagePreview(path: recent[i])),
                  ),
                ),
              ),
            ],
            if (studio.platform.canPickImage)
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(s.t('vidPickFromGallery')),
                onTap: () async {
                  final p = await studio.importImage();
                  if (ctx.mounted) Navigator.pop(ctx, p);
                },
              ),
            ListTile(
              leading: const Icon(Icons.title),
              title: Text(s.t('vidPickTemplate')),
              onTap: () => Navigator.pop(ctx, '#card'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == '#card') {
      final text = await _askText(context, s.t('vidCardText'));
      if (text == null || text.trim().isEmpty || !context.mounted) return;
      final path = await runStudio(context, () => studio.templateFallback(text.trim(), format: TemplateFormat.story));
      if (path != null) ui.addScene(path);
      return;
    }
    ui.addScene(choice);
  }

  Future<String?> _askText(BuildContext context, String label) {
    final c = TextEditingController();
    final s = context.sRead;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: TextField(controller: c, autofocus: true, maxLines: 3, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(s.t('ok'))),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.watch<StudioUiState>();
    final studio = context.watch<StudioService>();
    final assets = context.watch<StudioAssetManager>();
    final project = ui.project;
    final lang = s.languageCode;
    final voiceSpec = studioAssetById(project.voice.key);
    final voiceMissing = voiceSpec != null && !assets.isInstalled(voiceSpec);
    final estimate = planTimeline(
      project,
      project.scenes.map((x) => estimateReadingSeconds(x.narration)).toList(),
    ).totalSeconds;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const PaidVideoCard(),
        const SizedBox(height: 16),
        Text(s.t('paidManualTitle'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<NarratorVoice>(
                  value: project.voice,
                  decoration: InputDecoration(labelText: s.t('vidVoice')),
                  items: [
                    DropdownMenuItem(value: NarratorVoice.none, child: Text(s.t('voice_none'))),
                    DropdownMenuItem(value: NarratorVoice.persian, child: Text(s.t('voice_fa'))),
                    DropdownMenuItem(value: NarratorVoice.english, child: Text(s.t('voice_en'))),
                  ],
                  onChanged: (v) => ui.setProject(project.copyWith(voice: v)),
                ),
                if (voiceMissing)
                  TextButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: Text(s.t('vidVoiceMissing')),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StudioAssetsScreen())),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: project.musicTrackId,
                  decoration: InputDecoration(labelText: s.t('vidMusic')),
                  items: [
                    DropdownMenuItem(value: 'none', child: Text(s.t('music_none'))),
                    for (final m in musicCatalog)
                      DropdownMenuItem(value: m.id, child: Text('${m.title} — ${s.isFa ? m.moodFa : m.moodEn}')),
                  ],
                  onChanged: (v) => ui.setProject(project.copyWith(musicTrackId: v)),
                ),
                if (project.musicTrackId != 'none') ...[
                  const SizedBox(height: 8),
                  Text(s.t('vidMusicVolume')),
                  Slider(value: project.musicVolume, onChanged: (v) => ui.setProject(project.copyWith(musicVolume: v))),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.t('vidSubtitles')),
                  value: project.subtitles,
                  onChanged: (v) => ui.setProject(project.copyWith(subtitles: v)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: Text(s.t('vidScenes'), style: Theme.of(context).textTheme.titleMedium)),
            if (project.scenes.isNotEmpty)
              Text(s.t('vidEstimated', {'n': localizeDigits(estimate.toStringAsFixed(0), lang)}), style: Theme.of(context).textTheme.bodySmall),
            IconButton(
              tooltip: s.t('vidClear'),
              icon: const Icon(Icons.clear_all),
              onPressed: project.scenes.isEmpty ? null : () => ui.setProject(project.copyWith(scenes: const [])),
            ),
          ],
        ),
        if (project.scenes.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(s.t('vidNoScenes'), textAlign: TextAlign.center)),
        for (var i = 0; i < project.scenes.length; i++)
          _SceneCard(key: ValueKey('$i|${project.scenes[i].imagePath}'), index: i, scene: project.scenes[i], last: i == project.scenes.length - 1),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: () => _addScene(context), icon: const Icon(Icons.add_photo_alternate_outlined), label: Text(s.t('vidAddScene'))),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.movie_outlined),
          label: Text(s.t('vidRender')),
          onPressed: studio.busy || project.scenes.isEmpty
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final path = await runStudio(context, () => studio.renderVideo(project));
                  if (path == null) return;
                  ui.setLastVideo(path);
                  messenger.showSnackBar(SnackBar(content: Text(s.t('vidRendered'))));
                },
        ),
        if (ui.lastVideo != null) ...[
          const SizedBox(height: 16),
          VideoPreview(path: ui.lastVideo!),
          const SizedBox(height: 12),
          MediaActions(path: ui.lastVideo!, title: project.title.isNotEmpty ? project.title : s.t('studioTabVideo'), extra: project.encode()),
        ],
      ],
    );
  }
}

class _SceneCard extends StatefulWidget {
  const _SceneCard({super.key, required this.index, required this.scene, required this.last});
  final int index;
  final VideoScene scene;
  final bool last;

  @override
  State<_SceneCard> createState() => _SceneCardState();
}

class _SceneCardState extends State<_SceneCard> {
  late final _narration = TextEditingController(text: widget.scene.narration);
  late final _overlay = TextEditingController(text: widget.scene.overlayText);

  @override
  void dispose() {
    _narration.dispose();
    _overlay.dispose();
    super.dispose();
  }

  void _save(VideoScene Function(VideoScene s) change) {
    final ui = context.read<StudioUiState>();
    if (widget.index >= ui.project.scenes.length) return;
    ui.updateScene(widget.index, change(ui.project.scenes[widget.index]));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.read<StudioUiState>();
    final scene = widget.scene;
    final lang = s.languageCode;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: File(scene.imagePath).existsSync()
                      ? FileImagePreview(path: scene.imagePath, aspect: 9 / 16)
                      : const AspectRatio(aspectRatio: 9 / 16, child: Icon(Icons.broken_image_outlined)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(s.t('vidScene', {'i': localizeDigits('${widget.index + 1}', lang)}), style: Theme.of(context).textTheme.titleSmall)),
                          IconButton(
                            tooltip: s.t('vidMoveUp'),
                            icon: const Icon(Icons.arrow_upward),
                            onPressed: widget.index == 0 ? null : () => ui.moveScene(widget.index, widget.index - 1),
                          ),
                          IconButton(
                            tooltip: s.t('vidMoveDown'),
                            icon: const Icon(Icons.arrow_downward),
                            onPressed: widget.last ? null : () => ui.moveScene(widget.index, widget.index + 1),
                          ),
                          IconButton(tooltip: s.t('delete'), icon: const Icon(Icons.delete_outline), onPressed: () => ui.removeScene(widget.index)),
                        ],
                      ),
                      TextField(
                        controller: _overlay,
                        decoration: InputDecoration(labelText: s.t('vidOverlay'), isDense: true),
                        onChanged: (v) => _save((x) => x.copyWith(overlayText: v)),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _narration,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(labelText: s.t('vidNarration'), isDense: true),
                        onChanged: (v) => _save((x) => x.copyWith(narration: v)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text('${s.t('vidMotion')} · ${s.t('vidTransition')} · ${s.t('vidDuration')}'),
              children: [
                DropdownButtonFormField<CameraMotion>(
                  value: scene.motion,
                  decoration: InputDecoration(labelText: s.t('vidMotion'), isDense: true),
                  items: [for (final m in CameraMotion.values) DropdownMenuItem(value: m, child: Text(s.t('motion_${m.key}')))],
                  onChanged: (v) => _save((x) => x.copyWith(motion: v)),
                ),
                const SizedBox(height: 8),
                if (!widget.last)
                  DropdownButtonFormField<SceneTransition>(
                    value: scene.transition,
                    decoration: InputDecoration(labelText: s.t('vidTransition'), isDense: true),
                    items: [for (final t in SceneTransition.values) DropdownMenuItem(value: t, child: Text(s.t('trans_${t.key}')))],
                    onChanged: (v) => _save((x) => x.copyWith(transition: v)),
                  ),
                Row(
                  children: [
                    Text(s.t('vidDuration')),
                    Expanded(
                      child: Slider(
                        value: scene.durationSeconds ?? 0,
                        min: 0,
                        max: 15,
                        divisions: 30,
                        label: scene.durationSeconds == null ? s.t('vidAuto') : s.t('vidSeconds', {'n': localizeDigits(scene.durationSeconds!.toStringAsFixed(1), lang)}),
                        onChanged: (v) => _save((x) => v < 1 ? x.copyWith(clearDuration: true) : x.copyWith(durationSeconds: v)),
                      ),
                    ),
                    Text(scene.durationSeconds == null ? s.t('vidAuto') : s.t('vidSeconds', {'n': localizeDigits(scene.durationSeconds!.toStringAsFixed(1), lang)})),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Plays a rendered video (Android); elsewhere shows where the file is.
class VideoPreview extends StatefulWidget {
  const VideoPreview({super.key, required this.path});
  final String path;

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(VideoPreview old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _c?.dispose();
      _c = null;
      _open();
    }
  }

  Future<void> _open() async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      setState(() => _failed = true);
      return;
    }
    final c = VideoPlayerController.file(File(widget.path));
    try {
      await c.initialize();
      await c.setLooping(true);
      if (!mounted) return c.dispose();
      setState(() => _c = c);
    } on Object {
      await c.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_failed) return ListTile(leading: const Icon(Icons.movie_outlined), title: Text(widget.path.split(Platform.pathSeparator).last));
    if (c == null) return const AspectRatio(aspectRatio: 9 / 16, child: Center(child: CircularProgressIndicator()));
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: c.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(c),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (_, v, __) => IconButton.filledTonal(
                    iconSize: 36,
                    icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () => v.isPlaying ? c.pause() : c.play(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
