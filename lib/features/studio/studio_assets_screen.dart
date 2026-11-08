import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../studio/studio_assets.dart';
import '../../studio/studio_catalog.dart';
import '../../studio/studio_service.dart';

/// Image models, narrator voices, bundled music, and the heavy-work power rule.
class StudioAssetsScreen extends StatelessWidget {
  const StudioAssetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final settings = context.watch<SettingsController>();
    final studio = context.read<StudioService>();
    final lang = s.languageCode;
    final recommended = recommendedImageModel(studio.device);
    Widget header(String key) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 20, 16, 8),
          child: Text(s.t(key), style: Theme.of(context).textTheme.titleMedium),
        );
    return Scaffold(
      appBar: AppBar(title: Text(s.t('studioAssets'))),
      body: ListView(
        children: [
          header('heavyWorkTitle'),
          SwitchListTile(
            title: Text(s.t('heavyWorkRule', {'n': localizeDigits('${settings.heavyWorkMinBattery}', lang)})),
            subtitle: Text(s.t('heavyWorkRuleBody')),
            value: settings.heavyWorkPowerRule,
            onChanged: settings.setHeavyWorkPowerRule,
          ),
          if (settings.heavyWorkPowerRule)
            Slider(
              value: settings.heavyWorkMinBattery.toDouble(),
              min: 10,
              max: 90,
              divisions: 16,
              label: localizeDigits('${settings.heavyWorkMinBattery}٪', lang),
              onChanged: (v) => settings.setHeavyWorkMinBattery(v.round()),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextFormField(
              initialValue: settings.studioFooter,
              decoration: InputDecoration(labelText: s.t('studioFooterSetting')),
              onChanged: settings.setStudioFooter,
            ),
          ),
          header('assetsImageModels'),
          for (final m in imageModelCatalog) _AssetTile(spec: m, recommended: identical(m, recommended)),
          header('assetsVoices'),
          for (final v in voiceCatalog) _AssetTile(spec: v),
          header('assetsMusic'),
          for (final m in musicCatalog)
            ListTile(
              leading: const Icon(Icons.music_note_outlined),
              title: Text('${m.title} — ${m.author}'),
              subtitle: Text('${s.isFa ? m.moodFa : m.moodEn} · CC0'),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({required this.spec, this.recommended = false});
  final StudioAssetSpec spec;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final assets = context.watch<StudioAssetManager>();
    final settings = context.watch<SettingsController>();
    final installed = assets.isInstalled(spec);
    final p = assets.progress[spec.id];
    final lang = s.languageCode;
    final isImage = spec.kind == StudioAssetKind.imageModel;
    final inUse = isImage && settings.imageModelId == spec.id;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(spec.name, style: Theme.of(context).textTheme.titleSmall)),
                if (recommended) Chip(label: Text(s.t('assetsRecommended')), visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 4),
            Text(s.isFa ? spec.descriptionFa : spec.descriptionEn),
            const SizedBox(height: 4),
            Text(
              '${formatBytes(spec.totalBytes, languageCode: lang)} · ${s.t('assetsLicense', {'license': spec.license})}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (p != null && p.active) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: p.state == 'verifying' ? null : p.fraction),
              const SizedBox(height: 4),
              Text('${formatBytes(p.received, languageCode: lang)} / ${formatBytes(p.total, languageCode: lang)}', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (p != null && p.state == 'error')
              Text(s.t('dlErrGeneric', {'code': p.error ?? '?'}), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (installed) ...[
                  Chip(avatar: const Icon(Icons.check, size: 16), label: Text(s.t('assetsInstalled'))),
                  if (isImage)
                    inUse
                        ? Chip(label: Text(s.t('assetsInUse')))
                        : OutlinedButton(onPressed: () => settings.setImageModelId(spec.id), child: Text(s.t('assetsUse'))),
                  TextButton(onPressed: () => assets.delete(spec), child: Text(s.t('delete'))),
                ] else if (p != null && p.active)
                  TextButton(onPressed: () => assets.cancel(spec), child: Text(s.t('cancel')))
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: Text(s.t('download')),
                    onPressed: () async {
                      final ok = await assets.download(spec);
                      if (ok && isImage && !assets.isInstalled(studioAssetById(settings.imageModelId) ?? spec)) {
                        await settings.setImageModelId(spec.id);
                      }
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
