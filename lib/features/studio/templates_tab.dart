import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../l10n/strings.dart';
import '../../studio/render/canvas_render.dart';
import '../../studio/studio_service.dart';
import '../../studio/templates/templates.dart';
import 'studio_common.dart';

class TemplatesTab extends StatefulWidget {
  const TemplatesTab({super.key});

  @override
  State<TemplatesTab> createState() => _TemplatesTabState();
}

class _TemplatesTabState extends State<TemplatesTab> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _footer = TextEditingController();
  ui.Image? _bg;
  String? _bgPath;

  @override
  void initState() {
    super.initState();
    final t = context.read<StudioUiState>().template;
    _title.text = t.title;
    _body.text = t.kind == TemplateKind.list ? t.items.join('\n') : t.body;
    _footer.text = t.footer;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _footer.dispose();
    _bg?.dispose();
    super.dispose();
  }

  Future<void> _syncBackground(String? path) async {
    if (path == _bgPath) return;
    _bgPath = path;
    final old = _bg;
    ui.Image? next;
    if (path != null) {
      try {
        next = await loadImageFile(path, maxSide: 1920);
      } on Object {
        next = null;
      }
    }
    if (!mounted || _bgPath != path) {
      next?.dispose();
      return;
    }
    setState(() => _bg = next);
    old?.dispose();
  }

  void _update(StudioUiState ui, TemplateData Function(TemplateData t) change) => ui.setTemplate(change(ui.template));

  TemplateData _current(StudioUiState ui) {
    final t = ui.template;
    return t.copyWith(
      title: _title.text,
      body: _body.text,
      items: t.kind == TemplateKind.list ? parseListItems(_body.text) : const [],
      footer: _footer.text,
    );
  }

  Future<void> _pickBackground(StudioUiState ui) async {
    final s = context.sRead;
    final studio = context.read<StudioService>();
    final recent = await studio.recentImages();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.hide_image_outlined), title: Text(s.t('tplNoBackground')), onTap: () => Navigator.pop(ctx, '')),
            if (studio.platform.canPickImage)
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(s.t('tplPickImage')),
                onTap: () async {
                  final p = await studio.importImage();
                  if (ctx.mounted) Navigator.pop(ctx, p);
                },
              ),
            if (recent.isNotEmpty) ...[
              ListTile(title: Text(s.t('tplPickRecent'))),
              SizedBox(
                height: 110,
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
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
    if (chosen == null) return;
    _update(ui, (t) => chosen.isEmpty ? t.copyWith(clearBackground: true) : t.copyWith(backgroundImagePath: chosen));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ui = context.watch<StudioUiState>();
    final studio = context.watch<StudioService>();
    final t = _current(ui);
    unawaited(_syncBackground(t.backgroundImagePath));
    final lang = s.languageCode;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<TemplateKind>(
          segments: [
            for (final k in TemplateKind.values) ButtonSegment(value: k, label: Text(s.t('tplKind_${k.key}'), maxLines: 1)),
          ],
          selected: {t.kind},
          showSelectedIcon: false,
          onSelectionChanged: (v) => _update(ui, (x) => x.copyWith(kind: v.first)),
        ),
        const SizedBox(height: 12),
        SegmentedButton<TemplateFormat>(
          segments: [for (final f in TemplateFormat.values) ButtonSegment(value: f, label: Text(s.t('tplFormat_${f.key}')))],
          selected: {t.format},
          onSelectionChanged: (v) => _update(ui, (x) => x.copyWith(format: v.first)),
        ),
        const SizedBox(height: 12),
        // Live preview (drawn with the same painter as the export).
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: AspectRatio(
              aspectRatio: t.format.width / t.format.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CustomPaint(painter: _TemplatePreviewPainter(t, _bg)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _title,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: s.t(t.kind == TemplateKind.quote ? 'tplAuthor' : 'tplTitle')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _body,
          minLines: 2,
          maxLines: 8,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: s.t(switch (t.kind) {
              TemplateKind.quote => 'tplQuote',
              TemplateKind.list => 'tplItems',
              _ => 'tplBody',
            }),
          ),
        ),
        if (t.kind == TemplateKind.carousel) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text(s.t('tplSlide', {'i': localizeDigits('${t.slideIndex}', lang), 'n': localizeDigits('${t.slideCount}', lang)}))),
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: () => _update(ui, (x) => x.copyWith(slideIndex: (x.slideIndex - 1).clamp(1, x.slideCount))),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _update(ui, (x) => x.copyWith(slideIndex: (x.slideIndex + 1).clamp(1, x.slideCount))),
              ),
              IconButton(
                icon: const Icon(Icons.exposure_plus_1),
                onPressed: () => _update(ui, (x) => x.copyWith(slideCount: (x.slideCount + 1).clamp(1, 20))),
              ),
              IconButton(
                icon: const Icon(Icons.exposure_minus_1),
                onPressed: () => _update(ui, (x) {
                  final c = (x.slideCount - 1).clamp(1, 20);
                  return x.copyWith(slideCount: c, slideIndex: x.slideIndex.clamp(1, c));
                }),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        TextField(controller: _footer, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: s.t('tplFooter'))),
        const SizedBox(height: 12),
        Text(s.t('tplPalette'), style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final p in templatePalettes)
              InkWell(
                onTap: () => _update(ui, (x) => x.copyWith(paletteId: p.id)),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [p.top, p.bottom]),
                    border: Border.all(width: t.paletteId == p.id ? 3 : 1, color: Theme.of(context).colorScheme.primary),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.wallpaper_outlined),
          title: Text(s.t('tplBackground')),
          subtitle: Text(t.backgroundImagePath == null ? s.t('tplNoBackground') : t.backgroundImagePath!.split('/').last),
          onTap: () => _pickBackground(ui),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: const Icon(Icons.image_outlined),
          label: Text(s.t('tplExport')),
          onPressed: studio.busy
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  ui.setTemplate(t);
                  final path = await runStudio(context, () => studio.exportTemplate(t));
                  if (path == null) return;
                  ui.setLastTemplate(path);
                  messenger.showSnackBar(SnackBar(
                    content: Text(s.t('tplExported', {'w': localizeDigits('${t.format.width}', lang), 'h': localizeDigits('${t.format.height}', lang)})),
                  ));
                },
        ),
        if (ui.lastTemplate != null) ...[
          const SizedBox(height: 16),
          FileImagePreview(path: ui.lastTemplate!, aspect: t.format.width / t.format.height),
          const SizedBox(height: 12),
          MediaActions(
            path: ui.lastTemplate!,
            title: t.title.isEmpty ? t.body : t.title,
            onAddToVideo: () {
              ui.addScene(ui.lastTemplate!);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('studioAddedToVideo'))));
            },
          ),
        ],
      ],
    );
  }
}

class _TemplatePreviewPainter extends CustomPainter {
  _TemplatePreviewPainter(this.data, this.background);
  final TemplateData data;
  final ui.Image? background;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Size(data.format.width.toDouble(), data.format.height.toDouble());
    canvas.save();
    canvas.scale(size.width / full.width);
    paintTemplate(canvas, full, data.backgroundImagePath == null ? data : data, data.backgroundImagePath == null ? null : background);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TemplatePreviewPainter old) => true;
}
