/// Settings → "Credit & recovery": balance, payment ID, recovery code (hidden until tapped,
/// with copy) and restore from a recovery code.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../billing/billing.dart';
import '../../core/format.dart';
import '../../l10n/strings.dart';
import 'billing_controller.dart';
import 'pay_sheet.dart';

class CreditTiles extends StatefulWidget {
  const CreditTiles({super.key});

  @override
  State<CreditTiles> createState() => _CreditTilesState();
}

class _CreditTilesState extends State<CreditTiles> {
  bool _showCode = false;

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.sRead.t('copied')), duration: const Duration(seconds: 1)));
  }

  Future<void> _restore() async {
    final s = context.sRead;
    final billing = context.read<BillingController>();
    final messenger = ScaffoldMessenger.of(context);
    final c = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('billRestore')),
        content: Directionality(
          textDirection: TextDirection.ltr,
          child: TextField(
            controller: c,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(hintText: s.t('billRestoreHint')),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(s.t('ok'))),
        ],
      ),
    );
    c.dispose();
    if (code == null || code.trim().isEmpty) return;
    final r = await billing.restore(code.trim());
    final ton = localizeDigits(formatNanotons(billing.balance.available), s.languageCode);
    final text = switch (r) {
      Ok() => s.t('billRestored', {'ton': ton}),
      // Restored, but the chain could not be read yet: say why; credit appears on the next check.
      Err(:final error) => s.t(billingErrorKey(error.code)),
    };
    messenger.showSnackBar(SnackBar(content: Text(text)));
    if (mounted) setState(() => _showCode = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final lang = s.languageCode;
    final theme = Theme.of(context);
    final billing = context.watch<BillingController>();
    final svc = billing.service;
    if (svc == null) {
      return ListTile(leading: const Icon(Icons.info_outline), subtitle: Text(s.t('billUnavailable')));
    }
    final balance = billing.balance;
    final mono = theme.textTheme.bodyLarge?.copyWith(fontFamily: 'monospace');
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.account_balance_wallet_outlined),
          title: Text(s.t('billBalance', {'ton': localizeDigits(formatNanotons(balance.available), lang)})),
          subtitle: Text(s.t('billHowTo')),
          trailing: billing.checking
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  tooltip: s.t('billCheck'),
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    final r = await billing.checkPayments();
                    if (context.mounted) showCheckResult(context, r, billing);
                  },
                ),
        ),
        if (balance.tampered)
          ListTile(leading: const Icon(Icons.restore), subtitle: Text(s.t('billRebuilt'))),
        ListTile(
          leading: const Icon(Icons.tag),
          title: Text(s.t('billPaymentId')),
          subtitle: Directionality(textDirection: TextDirection.ltr, child: Text(svc.paymentId, style: mono)),
          trailing: IconButton(tooltip: s.t('copy'), icon: const Icon(Icons.copy), onPressed: () => _copy(svc.paymentId)),
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: Text(s.t('billRecovery')),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_showCode)
                Directionality(textDirection: TextDirection.ltr, child: SelectableText(svc.recoveryCode, style: mono))
              else
                Text(s.t('billRecoveryHidden')),
              const SizedBox(height: 4),
              Text(s.t('billRecoveryNote'), style: theme.textTheme.bodySmall),
            ],
          ),
          onTap: () => setState(() => _showCode = !_showCode),
          trailing: _showCode
              ? IconButton(tooltip: s.t('copy'), icon: const Icon(Icons.copy), onPressed: () => _copy(svc.recoveryCode))
              : const Icon(Icons.visibility_outlined),
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: Text(s.t('billRestore')),
          enabled: !billing.checking,
          onTap: _restore,
        ),
      ],
    );
  }
}
