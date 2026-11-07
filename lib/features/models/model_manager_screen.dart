import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../core/format.dart';
import '../../data/device_info.dart';
import '../../data/model_catalog.dart';
import '../../data/model_manager.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../llm/local_backend.dart';
import '../common/engine_banner.dart';

class ModelManagerScreen extends StatefulWidget {
  const ModelManagerScreen({super.key});

  @override
  State<ModelManagerScreen> createState() => _ModelManagerScreenState();
}

class _ModelManagerScreenState extends State<ModelManagerScreen> {
  DeviceInfo? _device;
  StreamSubscription<MapEntry<String, DownloadProgress>>? _sub;

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    services.bridge.deviceInfo().then((d) {
      if (mounted) setState(() => _device = d);
    });
    _sub = services.models.finished.listen(_onFinished);
    unawaited(services.models.refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onFinished(MapEntry<String, DownloadProgress> e) {
    if (!mounted) return;
    final s = context.sRead;
    final settings = context.read<SettingsController>();
    final p = e.value;
    String? msg;
    if (p.state == 'done') {
      final spec = catalogById(e.key);
      if (spec != null && settings.activeModelFile == null) unawaited(settings.setActiveModelFile(spec.fileName));
      msg = '${spec?.name ?? e.key}: ${s.t('downloaded')}';
    } else if (p.state == 'cancelled') {
      msg = s.t('dlCancelled');
    } else if (p.state == 'error') {
      msg = switch (p.error) {
        'checksum' => s.t('dlErrChecksum'),
        'no_space' => s.t('dlErrNoSpace'),
        'network' => s.t('dlErrNetwork'),
        _ => s.t('dlErrGeneric', {'code': p.error ?? '?'}),
      };
    }
    if (msg != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _import() async {
    final models = context.read<ModelManager>();
    final settings = context.read<SettingsController>();
    final messenger = ScaffoldMessenger.of(context);
    final s = context.sRead;
    try {
      final name = await models.importFromStorage();
      if (name == null) return;
      settings.activeModelFile ?? await settings.setActiveModelFile(name);
      messenger.showSnackBar(SnackBar(content: Text(s.t('importDone', {'name': name}))));
    } on PlatformException catch (e) {
      final msg = switch (e.code) {
        'exists' => s.t('importExists'),
        'no_space' => s.t('importNoSpace'),
        'bad_file' => s.t('errBadFile'),
        _ => s.t('errGeneric', {'code': e.code}),
      };
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _activate(String fileName, ModelFit? fit) async {
    final settings = context.read<SettingsController>();
    final engine = context.read<LocalEngine>();
    final s = context.sRead;
    if (fit == ModelFit.tooHeavy) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(s.t('heavyWarning')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('continue'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    await settings.setActiveModelFile(fileName);
    if (engine.isReady) await engine.unload();
    if (mounted) await loadActiveModel(context);
  }

  Future<void> _delete(LocalModelFile file) async {
    final models = context.read<ModelManager>();
    final settings = context.read<SettingsController>();
    final engine = context.read<LocalEngine>();
    final s = context.sRead;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(s.t('deleteConfirm', {'name': file.displayName})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    if (engine.loadedPath == file.path) await engine.unload();
    if (settings.activeModelFile == file.fileName) await settings.setActiveModelFile(null);
    await models.deleteFile(file.fileName);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final models = context.watch<ModelManager>();
    final settings = context.watch<SettingsController>();
    final engine = context.watch<LocalEngine>();
    final device = _device;
    final recs = device == null
        ? [for (final m in modelCatalog) ModelRecommendation(m, ModelFit.fits)]
        : recommendModels(device);
    final importing = models.importProgress;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('modelsTitle'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const EngineBanner(),
          if (engine.isReady)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: engine.unload,
                  icon: const Icon(Icons.eject_outlined),
                  label: Text(s.t('unloadModel')),
                ),
              ),
            ),
          _SectionTitle(s.t('catalog')),
          for (final r in recs)
            _CatalogTile(
              rec: r,
              progress: models.progress[r.spec.id],
              downloaded: models.isDownloaded(r.spec),
              partial: models.partialBytes(r.spec),
              active: settings.activeModelFile == r.spec.fileName,
              onDownload: () => models.download(r.spec),
              onCancel: () => models.cancel(r.spec),
              onDeletePartial: () => models.deletePartial(r.spec),
              onActivate: () => _activate(r.spec.fileName, r.fit),
              onDelete: () {
                final f = models.fileFor(r.spec.fileName);
                if (f != null) _delete(f);
              },
            ),
          _SectionTitle(s.t('importedModels')),
          for (final f in models.importedFiles)
            ListTile(
              leading: Icon(settings.activeModelFile == f.fileName ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(f.displayName),
              subtitle: Text(formatBytes(f.sizeBytes, languageCode: s.languageCode)),
              onTap: () => _activate(f.fileName, null),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: s.t('deleteModel'), onPressed: () => _delete(f)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: importing != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.t('importing', {
                        'percent': importing.fraction == null
                            ? ''
                            : localizeDigits('${(importing.fraction! * 100).round()}%', s.languageCode),
                      })),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: importing.fraction),
                    ],
                  )
                : OutlinedButton.icon(
                    onPressed: _import,
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text(s.t('importGguf')),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 20, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.rec,
    required this.progress,
    required this.downloaded,
    required this.partial,
    required this.active,
    required this.onDownload,
    required this.onCancel,
    required this.onDeletePartial,
    required this.onActivate,
    required this.onDelete,
  });

  final ModelRecommendation rec;
  final DownloadProgress? progress;
  final bool downloaded;
  final int partial;
  final bool active;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDeletePartial;
  final VoidCallback onActivate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final spec = rec.spec;
    final lang = s.languageCode;
    final p = progress;
    final busy = p != null && p.active && !downloaded;

    final fitLabel = switch (rec.fit) {
      ModelFit.recommended => s.t('fitRecommended'),
      ModelFit.fits => s.t('fitFits'),
      ModelFit.tooHeavy => s.t('fitTooHeavy'),
    };
    final fitColor = switch (rec.fit) {
      ModelFit.recommended => theme.colorScheme.primaryContainer,
      ModelFit.fits => theme.colorScheme.secondaryContainer,
      ModelFit.tooHeavy => theme.colorScheme.errorContainer,
    };

    Widget status;
    if (downloaded) {
      status = Row(
        children: [
          Icon(Icons.check_circle, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(active ? s.t('activeModel') : s.t('downloaded')),
        ],
      );
    } else if (busy) {
      final pct = p.fraction == null ? '' : localizeDigits('${(p.fraction! * 100).toStringAsFixed(1)}%', lang);
      final label = switch (p.state) {
        'verifying' => s.t('verifying'),
        'queued' => s.t('queued'),
        'retrying' => s.t('retrying'),
        _ => s.t('downloading', {'percent': pct}),
      };
      status = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: p.state == 'verifying' ? null : p.fraction),
          if (p.total > 0)
            Text(
              '${formatBytes(p.received, languageCode: lang)} / ${formatBytes(p.total, languageCode: lang)}',
              style: theme.textTheme.bodySmall,
            ),
        ],
      );
    } else if (partial > 0) {
      status = Text(s.t('partial', {'size': formatBytes(partial, languageCode: lang)}));
    } else {
      status = const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(spec.name, style: theme.textTheme.titleMedium)),
                if (rec.best)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: Chip(label: Text(s.t('bestPick')), visualDensity: VisualDensity.compact),
                  ),
                Chip(label: Text(fitLabel), backgroundColor: fitColor, visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 4),
            Text(s.isFa ? spec.descriptionFa : spec.descriptionEn),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              children: [
                Text(s.t('size', {'size': formatBytes(spec.sizeBytes, languageCode: lang)}), style: theme.textTheme.bodySmall),
                Text('${s.t('persianQuality')}: ${'★' * spec.persianQuality}${'☆' * (3 - spec.persianQuality)}',
                    style: theme.textTheme.bodySmall),
                Text(s.t('license', {'license': spec.license}), style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            status,
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                if (!downloaded && !busy)
                  FilledButton.tonalIcon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download),
                    label: Text(partial > 0 ? s.t('resume') : s.t('download')),
                  ),
                if (busy) OutlinedButton.icon(onPressed: onCancel, icon: const Icon(Icons.close), label: Text(s.t('cancel'))),
                if (!downloaded && !busy && partial > 0)
                  TextButton(onPressed: onDeletePartial, child: Text(s.t('delete'))),
                if (downloaded && !active)
                  FilledButton.icon(onPressed: onActivate, icon: const Icon(Icons.play_arrow), label: Text(s.t('setActive'))),
                if (downloaded)
                  IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline), tooltip: s.t('deleteModel')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
