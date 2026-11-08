/// Studio → Editor: a simple video editor. Import videos and photos, order/trim/split/speed
/// them, pick the frame and a colour preset, add text, subtitles, music and narration, then
/// preview (free) or export (paid by length, first use free).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../billing/billing.dart';
import '../../core/format.dart';
import '../../l10n/strings.dart';
import '../../studio/editor/edit_project.dart';
import '../../studio/studio_assets.dart';
import '../../studio/studio_catalog.dart';
import '../../studio/studio_service.dart';
import '../../studio/video/video_project.dart' show NarratorVoice;
import '../billing/billing_controller.dart';
import '../billing/paid_ui.dart';
import 'studio_assets_screen.dart';
import 'studio_common.dart';
import 'video_tab.dart' show VideoPreview;

String _secs(S s, double v) => localizeDigits(v.toStringAsFixed(1), s.languageCode);

/// "1:05" style length.
String formatLength(S s, double seconds) {
  final t = seconds.round();
  final m = t ~/ 60, r = t % 60;
  return localizeDigits('$m:${r.toString().padLeft(2, '0')}', s.languageCode);
}

class EditorTab extends StatefulWidget {
  const EditorTab({super.key});

  @override
  State<EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<EditorTab> {
  @override
  void initState() {
    super.initState();
    final ui = context.read<StudioUiState>();
    final studio = context.read<StudioService>();
    ui.editSaver = studio.saveEditorProject;
    if (!ui.editLoaded) {
      studio.loadEditorProject().then((p) {
        if (mounted && !ui.editLoaded) ui.loadEdit(p);
      });
    }
  }

  Future<void> _import() async {
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final clips = await runStudio(context, studio.importEditorMedia);
    if (clips == null || clips.isEmpty) return;
    var p = ui.edit;
    for (final c in clips) {
      p = p.addClip(c);
    }
    ui.setEdit(p);
  }

  Future<void> _addByPath() async {
    final s = context.sRead;
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final c = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('edAddPath')),
        content: Directionality(
          textDirection: TextDirection.ltr,
          child: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: s.t('edPathHint'))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(s.t('ok'))),
        ],
      ),
    ).whenComplete(c.dispose);
    if (path == null || path.isEmpty || !mounted) return;
    final clip = await runStudio(context, () => studio.clipFromFile(path));
    if (clip != null) ui.setEdit(ui.edit.addClip(clip));
  }

  Future<void> _pickMusic() async {
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final path = await runStudio(context, studio.pickEditorMusic);
    if (path != null) ui.setEdit(ui.edit.copyWith(musicTrackId: 'file', musicFile: path));
  }

  Future<void> _preview() async {
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final path = await runStudio(context, () => studio.renderEdit(ui.edit, preview: true));
    if (path != null) ui.setEditPreview(path);
  }

  Future<void> _export(FeatureQuote quote) async {
    final s = context.sRead;
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final messenger = ScaffoldMessenger.of(context);
    final billing = context.read<BillingController>();
    if (!await prepareToPay(context, quote, extraNote: s.t('paidLongNote')) || !mounted) return;
    final path = await runStudio(context, () => studio.renderEdit(ui.edit));
    billing.refreshUi();
    if (path == null) return;
    ui.setLastEdit(path);
    messenger.showSnackBar(SnackBar(content: Text(s.t('edExported'))));
  }

  Future<void> _clear() async {
    final s = context.sRead;
    final ui = context.read<StudioUiState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(s.t('edClearAsk')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('ok'))),
        ],
      ),
    );
    if (ok == true) ui.setEdit(const EditProject());
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final ui = context.watch<StudioUiState>();
    final studio = context.watch<StudioService>();
    context.watch<BillingController>();
    final p = ui.edit;
    final total = p.totalSeconds;
    final quote = studio.quote(PaidFeature.editorExport, duration: p.duration);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ---- clips ----
        Row(
          children: [
            Expanded(
              child: Text(
                p.isEmpty ? s.t('studioTabEditor') : s.t('edTotal', {'t': formatLength(s, total)}),
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(tooltip: s.t('edClear'), icon: const Icon(Icons.delete_sweep_outlined), onPressed: p.isEmpty ? null : _clear),
          ],
        ),
        if (p.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(s.t('edEmpty'), textAlign: TextAlign.center)),
        for (var i = 0; i < p.clips.length; i++)
          _ClipCard(key: ValueKey(p.clips[i].id), index: i, clip: p.clips[i], last: i == p.clips.length - 1),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (studio.platform.canPickMedia)
              FilledButton.tonalIcon(onPressed: studio.busy ? null : _import, icon: const Icon(Icons.video_library_outlined), label: Text(s.t('edImport'))),
            if (!Platform.isAndroid)
              OutlinedButton.icon(onPressed: studio.busy ? null : _addByPath, icon: const Icon(Icons.folder_open_outlined), label: Text(s.t('edAddPath'))),
          ],
        ),
        if (!p.isEmpty) ...[
          const SizedBox(height: 16),
          _LookCard(project: p),
          const SizedBox(height: 12),
          _TextsCard(project: p),
          const SizedBox(height: 12),
          _SubtitlesCard(project: p),
          const SizedBox(height: 12),
          _AudioCard(project: p, onPickMusic: _pickMusic),
          const SizedBox(height: 16),
          Center(child: PriceLine(quote: quote, labelKey: 'priceExport')),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: studio.busy ? null : _preview,
                  icon: const Icon(Icons.play_circle_outline),
                  label: Text(s.t('edPreview'), overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: studio.busy || studio.editorBlocker(p) != null ? null : () => _export(quote),
                  icon: const Icon(Icons.file_download_outlined),
                  label: Text(s.t('edExport'), overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(s.t('edPreviewNote'), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
          if (ui.editPreview != null) ...[
            const SizedBox(height: 12),
            VideoPreview(path: ui.editPreview!),
          ],
          if (ui.lastEdit != null) ...[
            const SizedBox(height: 16),
            VideoPreview(path: ui.lastEdit!),
            const SizedBox(height: 12),
            MediaActions(path: ui.lastEdit!, title: s.t('studioTabEditor'), extra: p.encode()),
          ],
        ],
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.clip});
  final EditClip clip;

  @override
  Widget build(BuildContext context) {
    final studio = context.read<StudioService>();
    return SizedBox(
      width: 64,
      height: 80,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder<String?>(
          future: studio.editorThumb(clip),
          builder: (_, snap) {
            final path = snap.data;
            if (path == null || !File(path).existsSync()) {
              return ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(clip.isImage ? Icons.image_outlined : Icons.movie_outlined),
              );
            }
            return Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined));
          },
        ),
      ),
    );
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({super.key, required this.index, required this.clip, required this.last});
  final int index;
  final EditClip clip;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.read<StudioUiState>();
    final lang = s.languageCode;
    void update(EditClip c) => ui.setEdit(ui.edit.replaceClip(index, c));
    final speedText = clip.isImage ? '' : ' · ${localizeDigits(clip.speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), ''), lang)}x';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                _Thumb(clip: clip),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.t('edClip', {'i': localizeDigits('${index + 1}', lang)}), style: Theme.of(context).textTheme.titleSmall),
                      Text(
                        '${clip.isImage ? s.t('edPhoto') : s.t('edVideo')} · ${s.t('edLengthS', {'n': _secs(s, clip.outSeconds)})}$speedText',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                IconButton(
                  tooltip: s.t('vidMoveUp'),
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: index == 0 ? null : () => ui.setEdit(ui.edit.moveClip(index, index - 1)),
                ),
                IconButton(
                  tooltip: s.t('vidMoveDown'),
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: last ? null : () => ui.setEdit(ui.edit.moveClip(index, index + 1)),
                ),
                IconButton(
                  tooltip: s.t('edSplit'),
                  icon: const Icon(Icons.content_cut),
                  onPressed: clip.outSeconds < minClipSeconds * 2
                      ? null
                      : () => ui.setEdit(ui.edit.splitClip(index, clip.outSeconds / 2, newId: '${DateTime.now().microsecondsSinceEpoch}')),
                ),
                IconButton(tooltip: s.t('delete'), icon: const Icon(Icons.delete_outline), onPressed: () => ui.setEdit(ui.edit.removeClip(index))),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text(clip.isImage ? '${s.t('edLength')} · ${s.t('edTransition')}' : '${s.t('edTrim')} · ${s.t('edSpeed')} · ${s.t('edTransition')}'),
              children: [
                if (clip.isImage)
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: clip.outSeconds.clamp(minClipSeconds, 15.0),
                          min: minClipSeconds,
                          max: 15,
                          divisions: 29,
                          label: s.t('edLengthS', {'n': _secs(s, clip.outSeconds)}),
                          onChanged: (v) => update(clip.copyWith(sourceSeconds: v, trimStart: 0, trimEnd: v)),
                        ),
                      ),
                      Text(s.t('edLengthS', {'n': _secs(s, clip.outSeconds)})),
                    ],
                  )
                else ...[
                  RangeSlider(
                    values: RangeValues(clip.trimStart, clip.trimEnd),
                    min: 0,
                    max: clip.sourceSeconds,
                    labels: RangeLabels(_secs(s, clip.trimStart), _secs(s, clip.trimEnd)),
                    onChanged: (r) {
                      if (r.end - r.start < minClipSeconds) return;
                      update(clip.copyWith(trimStart: r.start, trimEnd: r.end));
                    },
                  ),
                  Text('${_secs(s, clip.trimStart)} – ${_secs(s, clip.trimEnd)}', style: Theme.of(context).textTheme.bodySmall),
                  Row(
                    children: [
                      Text(s.t('edSpeed')),
                      Expanded(
                        child: Slider(
                          value: clip.speed,
                          min: minSpeed,
                          max: maxSpeed,
                          divisions: 6,
                          label: '${localizeDigits(clip.speed.toStringAsFixed(2), lang)}x',
                          onChanged: (v) => update(clip.copyWith(speed: v)),
                        ),
                      ),
                    ],
                  ),
                ],
                if (!last)
                  DropdownButtonFormField<EditTransition>(
                    value: clip.transition,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: s.t('edTransition'), isDense: true),
                    items: [
                      for (final t in EditTransition.values)
                        DropdownMenuItem(value: t, child: Text(s.t(t == EditTransition.none ? 'trans_cut' : 'trans_${t.key}'))),
                    ],
                    onChanged: (v) => update(clip.copyWith(transition: v)),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LookCard extends StatelessWidget {
  const _LookCard({required this.project});
  final EditProject project;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.read<StudioUiState>();
    final p = project;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('edFormat'), style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in EditAspect.values)
                  ChoiceChip(
                    label: Text(s.t(a == EditAspect.portrait ? 'edAspect916' : 'edAspect45')),
                    selected: p.aspect == a,
                    onSelected: (_) => ui.setEdit(p.copyWith(aspect: a)),
                  ),
                for (final f in FitMode.values)
                  ChoiceChip(
                    label: Text(s.t(f == FitMode.crop ? 'edFitCrop' : 'edFitFit')),
                    selected: p.fit == f,
                    onSelected: (_) => ui.setEdit(p.copyWith(fit: f)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(s.t('edFilter'), style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in FilterPreset.values)
                  ChoiceChip(label: Text(s.t('filter_${f.key}')), selected: p.filter == f, onSelected: (_) => ui.setEdit(p.copyWith(filter: f))),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.t('edFadeIn')),
              value: p.fadeIn,
              onChanged: (v) => ui.setEdit(p.copyWith(fadeIn: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.t('edFadeOut')),
              value: p.fadeOut,
              onChanged: (v) => ui.setEdit(p.copyWith(fadeOut: v)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text field that keeps its own controller (so typing does not jump the cursor).
class _LiveField extends StatefulWidget {
  const _LiveField({super.key, required this.initial, required this.label, required this.onChanged, this.maxLines = 2});
  final String initial;
  final String label;
  final ValueChanged<String> onChanged;
  final int maxLines;

  @override
  State<_LiveField> createState() => _LiveFieldState();
}

class _LiveFieldState extends State<_LiveField> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        minLines: 1,
        maxLines: widget.maxLines,
        decoration: InputDecoration(labelText: widget.label, isDense: true),
        onChanged: widget.onChanged,
      );
}

RangeValues _window(double start, double end, double total) {
  final max = total <= 0 ? 1.0 : total;
  final a = start.clamp(0.0, max);
  final b = end.clamp(a, max);
  return RangeValues(a, b);
}

class _TextsCard extends StatelessWidget {
  const _TextsCard({required this.project});
  final EditProject project;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.read<StudioUiState>();
    final p = project;
    final total = p.totalSeconds;
    void set(int i, EditText t) {
      final l = [...ui.edit.texts];
      if (i >= l.length) return;
      l[i] = t;
      ui.setEdit(ui.edit.copyWith(texts: l));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.t('edTexts'), style: Theme.of(context).textTheme.titleSmall),
            for (var i = 0; i < p.texts.length; i++) ...[
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: _LiveField(
                      key: ValueKey('text$i-${p.texts.length}'),
                      initial: p.texts[i].text,
                      label: s.t('edText'),
                      onChanged: (v) => set(i, ui.edit.texts[i].copyWith(text: v)),
                    ),
                  ),
                  IconButton(
                    tooltip: s.t('delete'),
                    icon: const Icon(Icons.close),
                    onPressed: () => ui.setEdit(ui.edit.copyWith(texts: [...ui.edit.texts]..removeAt(i))),
                  ),
                ],
              ),
              RangeSlider(
                values: _window(p.texts[i].start, p.texts[i].end, total),
                min: 0,
                max: total <= 0 ? 1 : total,
                labels: RangeLabels(_secs(s, p.texts[i].start), _secs(s, p.texts[i].end)),
                onChanged: (r) => set(i, p.texts[i].copyWith(start: r.start, end: r.end)),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final pos in TextPosition.values)
                    ChoiceChip(
                      label: Text(s.t('edPos_${pos.key}')),
                      selected: p.texts[i].position == pos,
                      onSelected: (_) => set(i, p.texts[i].copyWith(position: pos)),
                    ),
                  for (var z = 0; z < 3; z++)
                    ChoiceChip(label: Text(s.t('edSize$z')), selected: p.texts[i].size == z, onSelected: (_) => set(i, p.texts[i].copyWith(size: z))),
                ],
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.text_fields),
              label: Text(s.t('edAddText')),
              onPressed: () => ui.setEdit(ui.edit.copyWith(texts: [
                ...ui.edit.texts,
                EditText(text: '', start: 0, end: total < 3 ? total : 3),
              ])),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubtitlesCard extends StatelessWidget {
  const _SubtitlesCard({required this.project});
  final EditProject project;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.read<StudioUiState>();
    final p = project;
    final total = p.totalSeconds;
    void set(int i, EditSubtitle t) {
      final l = [...ui.edit.subtitles];
      if (i >= l.length) return;
      l[i] = t;
      ui.setEdit(ui.edit.copyWith(subtitles: l));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.t('edSubtitles'), style: Theme.of(context).textTheme.titleSmall),
            for (var i = 0; i < p.subtitles.length; i++) ...[
              Row(
                children: [
                  Expanded(
                    child: _LiveField(
                      key: ValueKey('sub$i-${p.subtitles.length}'),
                      initial: p.subtitles[i].text,
                      label: s.t('edText'),
                      onChanged: (v) => set(i, ui.edit.subtitles[i].copyWith(text: v)),
                    ),
                  ),
                  IconButton(
                    tooltip: s.t('delete'),
                    icon: const Icon(Icons.close),
                    onPressed: () => ui.setEdit(ui.edit.copyWith(subtitles: [...ui.edit.subtitles]..removeAt(i))),
                  ),
                ],
              ),
              RangeSlider(
                values: _window(p.subtitles[i].start, p.subtitles[i].end, total),
                min: 0,
                max: total <= 0 ? 1 : total,
                labels: RangeLabels(_secs(s, p.subtitles[i].start), _secs(s, p.subtitles[i].end)),
                onChanged: (r) => set(i, p.subtitles[i].copyWith(start: r.start, end: r.end)),
              ),
            ],
            OutlinedButton.icon(
              icon: const Icon(Icons.subtitles_outlined),
              label: Text(s.t('edAddSubtitle')),
              onPressed: () {
                final last = ui.edit.subtitles.isEmpty ? 0.0 : ui.edit.subtitles.last.end;
                final start = last < total ? last : 0.0;
                ui.setEdit(ui.edit.copyWith(subtitles: [
                  ...ui.edit.subtitles,
                  EditSubtitle(text: '', start: start, end: (start + 2.5).clamp(0, total <= 0 ? 1 : total).toDouble()),
                ]));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioCard extends StatelessWidget {
  const _AudioCard({required this.project, required this.onPickMusic});
  final EditProject project;
  final VoidCallback onPickMusic;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.read<StudioUiState>();
    final studio = context.read<StudioService>();
    final assets = context.watch<StudioAssetManager>();
    final p = project;
    final hasOwnSound = p.clips.any((c) => !c.isImage && c.hasAudio);
    final voiceSpec = studioAssetById(p.voice.key);
    final voiceMissing = voiceSpec != null && !assets.isInstalled(voiceSpec);
    final musicValue = p.musicTrackId == 'file' || musicById(p.musicTrackId) != null ? p.musicTrackId : 'none';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.t('edAudio'), style: Theme.of(context).textTheme.titleSmall),
            if (hasOwnSound) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.t('edMuteOriginal')),
                value: p.muteOriginal,
                onChanged: (v) => ui.setEdit(p.copyWith(muteOriginal: v)),
              ),
              if (!p.muteOriginal) ...[
                Text(s.t('edOriginalVolume')),
                Slider(value: p.originalVolume.clamp(0.0, 2.0), max: 2, onChanged: (v) => ui.setEdit(p.copyWith(originalVolume: v))),
              ],
            ],
            DropdownButtonFormField<String>(
              value: musicValue,
              isExpanded: true,
              decoration: InputDecoration(labelText: s.t('edMusic')),
              items: [
                DropdownMenuItem(value: 'none', child: Text(s.t('music_none'))),
                for (final m in musicCatalog)
                  DropdownMenuItem(value: m.id, child: Text('${m.title} — ${s.isFa ? m.moodFa : m.moodEn}', overflow: TextOverflow.ellipsis)),
                if (studio.platform.canPickMedia || p.musicFile != null) DropdownMenuItem(value: 'file', child: Text(s.t('edMusicFile'))),
              ],
              onChanged: (v) {
                if (v == 'file' && p.musicFile == null) {
                  onPickMusic();
                } else if (v != null) {
                  ui.setEdit(p.copyWith(musicTrackId: v));
                }
              },
            ),
            if (p.musicTrackId == 'file') ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      p.musicFile == null ? '—' : p.musicFile!.split(Platform.pathSeparator).last,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (studio.platform.canPickMedia) TextButton(onPressed: onPickMusic, child: Text(s.t('edPickMusic'))),
                ],
              ),
            ],
            if (p.musicTrackId != 'none') ...[
              const SizedBox(height: 8),
              Text(s.t('edMusicVolume')),
              Slider(value: p.musicVolume, onChanged: (v) => ui.setEdit(p.copyWith(musicVolume: v))),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.t('edDuck')),
                value: p.duck,
                onChanged: (v) => ui.setEdit(p.copyWith(duck: v)),
              ),
            ],
            const SizedBox(height: 8),
            _LiveField(
              key: const ValueKey('narration'),
              initial: p.narration,
              label: s.t('edNarration'),
              maxLines: 4,
              onChanged: (v) => ui.setEdit(ui.edit.copyWith(narration: v)),
            ),
            Text(s.t('edNarrationHint'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            DropdownButtonFormField<NarratorVoice>(
              value: p.voice,
              isExpanded: true,
              decoration: InputDecoration(labelText: s.t('edVoice')),
              items: [
                DropdownMenuItem(value: NarratorVoice.none, child: Text(s.t('voice_none'))),
                DropdownMenuItem(value: NarratorVoice.persian, child: Text(s.t('voice_fa'))),
                DropdownMenuItem(value: NarratorVoice.english, child: Text(s.t('voice_en'))),
              ],
              onChanged: (v) => ui.setEdit(p.copyWith(voice: v)),
            ),
            if (voiceMissing && p.narration.trim().isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: Text(s.t('vidVoiceMissing')),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StudioAssetsScreen())),
              ),
          ],
        ),
      ),
    );
  }
}
