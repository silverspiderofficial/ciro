/// Small shared pieces for paid actions: the price label (with the "first use free" and owner
/// badges) and the check that runs before a paid action (unavailable / not enough credit →
/// pay sheet / confirm the cost).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../billing/billing.dart';
import '../../core/format.dart';
import '../../l10n/strings.dart';
import 'billing_controller.dart';
import 'pay_sheet.dart';

/// "0.1 TON", "First use free" or "Free (owner)".
String priceText(S s, FeatureQuote q) => switch (q.free) {
      FreeReason.owner => s.t('priceOwner'),
      FreeReason.ownApiKey => '',
      FreeReason.firstUse => s.t('priceFirstFree'),
      FreeReason.none => q.listPrice == null
          ? s.t('priceNotSold')
          : s.t('priceTon', {'ton': localizeDigits(formatNanotons(q.listPrice!), s.languageCode)}),
    };

/// A compact price line: [labelKey] gets `{price}`; a badge marks a free use.
class PriceLine extends StatelessWidget {
  const PriceLine({super.key, required this.quote, required this.labelKey});
  final FeatureQuote quote;
  final String labelKey;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    if (!quote.available) {
      return Text(s.t('billErr_unavailable'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error));
    }
    // AI text through the user's own API key is free: no price is shown.
    if (quote.free == FreeReason.ownApiKey) return const SizedBox.shrink();
    final free = quote.free != FreeReason.none;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(free ? Icons.card_giftcard : Icons.toll_outlined, size: 16, color: free ? theme.colorScheme.primary : null),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            s.t(labelKey, {'price': priceText(s, quote)}),
            style: theme.textTheme.bodySmall?.copyWith(
              color: free ? theme.colorScheme.primary : null,
              fontWeight: free ? FontWeight.w600 : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// Runs before a paid action. False (with a friendly message, or the pay sheet when the credit
/// is short) when it should not start. With [confirm], a non-free use asks to confirm the cost.
Future<bool> prepareToPay(BuildContext context, FeatureQuote q, {bool confirm = true, String? extraNote}) async {
  final s = context.sRead;
  final messenger = ScaffoldMessenger.of(context);
  final billing = context.read<BillingController>();
  if (!q.available) {
    messenger.showSnackBar(SnackBar(content: Text(s.t('billErr_unavailable'))));
    return false;
  }
  if (!q.sold) {
    messenger.showSnackBar(SnackBar(content: Text(s.t('billErr_unsupportedDuration'))));
    return false;
  }
  final charge = q.charge;
  if (charge <= 0) return true;
  final ton = localizeDigits(formatNanotons(charge), s.languageCode);
  if (billing.balance.available < charge) {
    messenger.showSnackBar(SnackBar(content: Text(s.t('billShort', {'ton': ton}))));
    await showPaySheet(context, nanotons: charge);
    return false;
  }
  if (!confirm) return true;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.t('paidConfirmTitle2')),
      content: Text([s.t('paidConfirmGeneric', {'ton': ton}), ?extraNote].join('\n\n')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('ok'))),
      ],
    ),
  );
  return go == true;
}
