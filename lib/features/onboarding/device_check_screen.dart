import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../core/format.dart';
import '../../data/device_info.dart';
import '../../data/model_catalog.dart';
import '../../l10n/strings.dart';
import '../models/model_manager_screen.dart';

/// First-run hardware check: RAM, CPU, SoC and the recommended models.
class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({super.key, this.firstRun = false, this.onDone});

  final bool firstRun;
  final VoidCallback? onDone;

  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen> {
  DeviceInfo? _info;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    context.read<AppServices>().bridge.deviceInfo().then((d) {
      if (mounted) {
        setState(() {
          _info = d;
          _loaded = true;
        });
      }
    });
  }

  void _goToModels() {
    widget.onDone?.call();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModelManagerScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final lang = s.languageCode;
    final info = _info;
    final theme = Theme.of(context);

    Widget row(String label, String value) => ListTile(
          dense: true,
          title: Text(label),
          trailing: Text(value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('deviceCheckTitle')),
        automaticallyImplyLeading: !widget.firstRun,
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (info == null)
                  Padding(padding: const EdgeInsets.all(24), child: Text(s.t('deviceUnavailable')))
                else ...[
                  if (!info.isArm64)
                    Material(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(padding: const EdgeInsets.all(16), child: Text(s.t('notArm64'))),
                    ),
                  Card(
                    margin: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        row(s.t('ramTotal'), formatBytes(info.totalRamBytes, languageCode: lang)),
                        row(s.t('ramFree'), formatBytes(info.availRamBytes, languageCode: lang)),
                        row(s.t('cpuCores'), localizeDigits('${info.cores}', lang)),
                        row(s.t('bigCores'), localizeDigits('${info.bigCores}', lang)),
                        row(s.t('soc'), [info.socManufacturer, info.soc].where((e) => e.isNotEmpty).join(' ')),
                        row(s.t('cpuFeatures'), [if (info.dotprod) 'dotprod', if (info.i8mm) 'i8mm'].join(' · ')),
                        row(s.t('storageFree'), formatBytes(info.freeStorageBytes, languageCode: lang)),
                        row(s.t('androidVersion'), localizeDigits('${info.release} (API ${info.sdkInt})', lang)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(s.t('deviceCheckIntro')),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      s.t('recommendedSettings', {
                        'threads': localizeDigits('${recommendedThreads(info)}', lang),
                        'ctx': localizeDigits('${recommendedContext(info)}', lang),
                      }),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  for (final r in recommendModels(info))
                    ListTile(
                      leading: Icon(
                        r.best
                            ? Icons.star
                            : r.fit == ModelFit.tooHeavy
                                ? Icons.block
                                : Icons.check,
                        color: r.fit == ModelFit.tooHeavy ? theme.colorScheme.error : theme.colorScheme.primary,
                      ),
                      title: Text(r.spec.name),
                      subtitle: Text(
                        '${formatBytes(r.spec.sizeBytes, languageCode: lang)} · '
                        '${switch (r.fit) {
                          ModelFit.recommended => s.t('fitRecommended'),
                          ModelFit.fits => s.t('fitFits'),
                          ModelFit.tooHeavy => s.t('fitTooHeavy'),
                        }}${r.best ? ' · ${s.t('bestPick')}' : ''}',
                      ),
                    ),
                ],
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: _goToModels,
                    icon: const Icon(Icons.download),
                    label: Text(s.t('goToModels')),
                  ),
                ),
                if (widget.firstRun)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextButton(onPressed: widget.onDone, child: Text(s.t('skip'))),
                  ),
              ],
            ),
    );
  }
}
