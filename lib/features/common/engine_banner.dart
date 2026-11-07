import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../core/format.dart';
import '../../data/model_manager.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../llm/local_backend.dart';
import '../models/model_manager_screen.dart';

/// Localised text for an error code (with the RAM numbers for low_ram).
String errorMessage(S s, String code, {LocalEngine? engine}) {
  if (code == 'low_ram' && engine != null) {
    return s.t('errLowRam', {
      'avail': formatBytes(engine.lowRamAvail ?? 0, languageCode: s.languageCode),
      'need': formatBytes(engine.lowRamNeed ?? 0, languageCode: s.languageCode),
    });
  }
  if (code.startsWith('http_') || code == 'api_error') return s.t('errGeneric', {'code': code});
  return s.t(S.errorKey(code), {'code': code});
}

/// Loads the active model, offering "load anyway" when the RAM check refuses.
Future<void> loadActiveModel(BuildContext context) async {
  final services = context.read<AppServices>();
  final messenger = ScaffoldMessenger.of(context);
  final s = context.sRead;
  final err = await services.ensureModelLoaded();
  if (err == null || !context.mounted) return;
  if (err == 'low_ram') {
    final force = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('error')),
        content: Text(errorMessage(s, err, engine: services.engine)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('loadAnyway'))),
        ],
      ),
    );
    if (force == true) {
      final again = await services.ensureModelLoaded(force: true);
      if (again != null) messenger.showSnackBar(SnackBar(content: Text(errorMessage(s, again, engine: services.engine))));
    }
    return;
  }
  if (err != 'no_model') {
    messenger.showSnackBar(SnackBar(content: Text(errorMessage(s, err, engine: services.engine))));
  }
}

/// Shows what the agent will run on and any engine problem, with the action that fixes it.
class EngineBanner extends StatelessWidget {
  const EngineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final settings = context.watch<SettingsController>();
    final engine = context.watch<LocalEngine>();
    final models = context.watch<ModelManager>();
    final security = context.watch<SecurityState>();
    final theme = Theme.of(context);

    if (settings.useRemote && security.apiAllowed) {
      return _bar(
        context,
        icon: Icons.cloud_outlined,
        text: '${s.t('engineRemote')} · ${settings.remoteModel}',
        color: theme.colorScheme.secondaryContainer,
      );
    }

    final file = models.fileFor(settings.activeModelFile);
    if (file == null) {
      return _bar(
        context,
        icon: Icons.download_outlined,
        text: s.t('noModelBody'),
        color: theme.colorScheme.tertiaryContainer,
        action: TextButton(onPressed: () => _openModels(context), child: Text(s.t('manageModels'))),
      );
    }
    if (engine.state == EngineState.loading) {
      return _bar(
        context,
        icon: Icons.memory,
        text: s.t('modelLoading'),
        color: theme.colorScheme.surfaceContainerHigh,
        progress: true,
      );
    }
    if (engine.errorCode != null && engine.state == EngineState.error) {
      return _bar(
        context,
        icon: Icons.error_outline,
        text: errorMessage(s, engine.errorCode!, engine: engine),
        color: theme.colorScheme.errorContainer,
        action: TextButton(onPressed: () => loadActiveModel(context), child: Text(s.t('loadModel'))),
      );
    }
    if (!engine.isReady || engine.loadedPath != file.path) {
      return _bar(
        context,
        icon: Icons.memory,
        text: s.t('modelNotLoaded', {'name': file.displayName}),
        color: theme.colorScheme.surfaceContainerHigh,
        action: TextButton(onPressed: () => loadActiveModel(context), child: Text(s.t('loadModel'))),
      );
    }
    return _bar(
      context,
      icon: Icons.offline_bolt_outlined,
      text: s.t('modelReady', {'name': file.displayName}),
      color: theme.colorScheme.surfaceContainerLow,
      dense: true,
    );
  }

  void _openModels(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModelManagerScreen()));
  }

  Widget _bar(
    BuildContext context, {
    required IconData icon,
    required String text,
    required Color color,
    Widget? action,
    bool progress = false,
    bool dense = false,
  }) {
    return Material(
      color: color,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(16, dense ? 4 : 8, 8, dense ? 4 : 8),
        child: Row(
          children: [
            if (progress)
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(icon, size: 18),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
            if (action != null) action,
          ],
        ),
      ),
    );
  }
}
