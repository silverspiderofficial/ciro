/// Video tab: paid AI video from a topic. Duration picker with TON price and clip count,
/// credit balance, pay sheet when the credit is short, and the render itself.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../billing/billing.dart';
import '../../core/format.dart';
import '../../l10n/strings.dart';
import '../../studio/studio_service.dart';
import '../billing/billing_controller.dart';
import '../billing/paid_ui.dart';
import '../billing/pay_sheet.dart';
import 'studio_assets_screen.dart';
import 'studio_common.dart';

/// "10 s", "1 min", "3 min" in the UI language.
String durationLabel(S s, Duration d) {
  final lang = s.languageCode;
  if (d.inSeconds < 60 || d.inSeconds % 60 != 0) return s.t('paidSeconds', {'n': localizeDigits('${d.inSeconds}', lang)});
  return s.t('paidMinutes', {'n': localizeDigits('${d.inMinutes}', lang)});
}

class PaidVideoCard extends StatefulWidget {
  const PaidVideoCard({super.key});

  @override
  State<PaidVideoCard> createState() => _PaidVideoCardState();
}

class _PaidVideoCardState extends State<PaidVideoCard> {
  final _topic = TextEditingController();
  Duration _duration = const Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<BillingController>().checkIfStale();
    });
  }

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  Future<void> _make(PriceTier tier) async {
    final s = context.sRead;
    final studio = context.read<StudioService>();
    final ui = context.read<StudioUiState>();
    final messenger = ScaffoldMessenger.of(context);
    if (_topic.text.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(s.t('studioErr_no_topic'))));
      return;
    }
    final q = studio.quote(PaidFeature.topicVideo, duration: tier.duration);
    if (!await prepareToPay(context, q, extraNote: s.t('paidLongNote')) || !mounted) return;
    final project = ui.project;
    final path = await runStudio(
      context,
      () => studio.renderTopicVideo(
        topic: _topic.text,
        duration: tier.duration,
        musicTrackId: project.musicTrackId,
        musicVolume: project.musicVolume,
      ),
    );
    if (path == null) return;
    ui.setLastVideo(path);
    messenger.showSnackBar(SnackBar(content: Text(s.t('paidDone'))));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final lang = s.languageCode;
    final theme = Theme.of(context);
    final billing = context.watch<BillingController>();
    final studio = context.watch<StudioService>();
    final svc = billing.service;

    if (!billing.usable) {
      return Card(
        child: ListTile(leading: const Icon(Icons.info_outline), title: Text(s.t('paidTitle')), subtitle: Text(s.t('billUnavailable'))),
      );
    }

    final tiers = studio.pricing.videoTable.tiers;
    final tier = studio.pricing.videoTable.tierFor(_duration) ?? tiers.first;
    final quote = studio.quote(PaidFeature.topicVideo, duration: tier.duration);
    final balance = billing.balance;
    final blocker = studio.paidVideoBlocker;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.t('paidTitle'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(s.t('paidSubtitle'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _topic,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(labelText: s.t('paidTopic'), hintText: s.t('paidTopicHint')),
            ),
            const SizedBox(height: 12),
            Text(s.t('paidDuration'), style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in tiers)
                  ChoiceChip(
                    label: Text(
                      s.t('paidTier', {
                        'd': durationLabel(s, t.duration),
                        'ton': localizeDigits(t.tonText, lang),
                        'n': localizeDigits('${t.segments}', lang),
                      }),
                    ),
                    selected: t.duration == tier.duration,
                    onSelected: (_) => setState(() => _duration = t.duration),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            PriceLine(quote: quote, labelKey: 'priceThisVideo'),
            const SizedBox(height: 8),
            if (svc != null)
              Row(
                children: [
                  const Icon(Icons.account_balance_wallet_outlined, size: 20),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: s.t('billBalance', {'ton': localizeDigits(formatNanotons(balance.available), lang)}),
                            style: theme.textTheme.titleSmall,
                          ),
                          if (balance.reserved > 0)
                            TextSpan(text: ' ${s.t('billReserved', {'ton': localizeDigits(formatNanotons(balance.reserved), lang)})}'),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: s.t('billCheck'),
                    icon: billing.checking
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    onPressed: billing.checking
                        ? null
                        : () async {
                            final r = await billing.checkPayments();
                            if (context.mounted) showCheckResult(context, r, billing);
                          },
                  ),
                ],
              ),
            if (blocker == 'no_model') ...[
              Text(s.t('paidNeedModel'), style: TextStyle(color: theme.colorScheme.error)),
              TextButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: Text(s.t('studioDownloadModel')),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StudioAssetsScreen())),
              ),
            ] else if (blocker == 'device_unsupported')
              Text(s.t('paidWeakDevice'), style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            Row(
              children: [
                if (svc != null && !billing.ownerUnlocked) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add_card_outlined),
                      label: Text(s.t('billAddCredit')),
                      onPressed: () => showPaySheet(context, nanotons: tier.nanotons),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(quote.charge == 0 ? s.t('paidConfirmGo') : s.t('paidMake', {'ton': localizeDigits(tier.tonText, lang)})),
                    onPressed: studio.busy || blocker != null ? null : () => _make(tier),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
