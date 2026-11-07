import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../caption/caption_screen.dart';
import '../drafts/drafts_screen.dart';

/// Studio / Queue / Schedules tabs in stage 1: a clear "next stage" notice.
class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
    this.showAvailableTools = false,
  });

  final String title;
  final IconData icon;
  final List<String> items;
  final bool showAvailableTools;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(s.t('comingSoonTitle'), textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(s.t('comingSoonBody'), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                for (final item in items)
                  ListTile(leading: const Icon(Icons.schedule_outlined), title: Text(item)),
              ],
            ),
          ),
          if (showAvailableTools) ...[
            const SizedBox(height: 24),
            Text(s.t('availableNow'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.tag),
                    title: Text(s.t('openCaptionTool')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CaptionScreen())),
                  ),
                  ListTile(
                    leading: const Icon(Icons.drafts_outlined),
                    title: Text(s.t('openDrafts')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DraftsScreen())),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
