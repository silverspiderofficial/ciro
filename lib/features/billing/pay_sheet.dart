/// Bottom sheet for paying video credit in Toncoin: TON-only notice, wallet deep link
/// (ton:// then the https fallback), QR code, address and comment with copy buttons, and
/// "I paid, check now".
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../billing/billing.dart';
import '../../core/format.dart';
import '../../l10n/strings.dart';
import 'billing_controller.dart';

/// Opens a TON wallet for [links]: the `ton://` link first, then the https fallback.
/// Returns false when neither could be opened. Never throws.
Future<bool> openWallet(PaymentLinks links) async {
  for (final url in [links.tonUri, links.httpsUri]) {
    try {
      if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return true;
    } on Object {
      // try the next link
    }
  }
  return false;
}

/// Text for the result of a payment check.
String checkResultText(S s, BillingResult<int> r, BillingController billing) {
  final ton = localizeDigits(formatNanotons(billing.balance.available), s.languageCode);
  return switch (r) {
    Ok(:final value) => value > 0 ? s.t('billCredited', {'ton': ton}) : s.t('billNothingYet'),
    Err(:final error) => s.t(billingErrorKey(error.code)),
  };
}

/// Shows the result of a payment check as a snackbar.
void showCheckResult(BuildContext context, BillingResult<int> r, BillingController billing) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(checkResultText(context.sRead, r, billing))));
}

Future<void> showPaySheet(BuildContext context, {required int nanotons}) {
  final billing = context.read<BillingController>();
  if (billing.service == null || nanotons <= 0) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => ChangeNotifierProvider<BillingController>.value(
      value: billing,
      child: _PaySheet(nanotons: nanotons),
    ),
  );
}

class _PaySheet extends StatefulWidget {
  const _PaySheet({required this.nanotons});
  final int nanotons;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  /// Inline status (snackbars would sit behind the sheet).
  String? _status;

  void _say(String text) {
    if (mounted) setState(() => _status = text);
  }

  @override
  Widget build(BuildContext context) {
    final nanotons = widget.nanotons;
    final s = context.s;
    final lang = s.languageCode;
    final billing = context.watch<BillingController>();
    final svc = billing.service!;
    final links = svc.paymentLinks(nanotons);
    final theme = Theme.of(context);
    void copy(String text) {
      Clipboard.setData(ClipboardData(text: text));
      _say(s.t('copied'));
    }

    Widget copyRow(String label, String value, {String? note}) => Card(
          margin: const EdgeInsets.only(top: 8),
          child: ListTile(
            title: Text(label, style: theme.textTheme.labelMedium),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: SelectableText(value, style: theme.textTheme.bodyLarge?.copyWith(fontFamily: 'monospace')),
                ),
                if (note != null) Text(note, style: theme.textTheme.bodySmall),
              ],
            ),
            trailing: IconButton(tooltip: s.t('copy'), icon: const Icon(Icons.copy), onPressed: () => copy(value)),
          ),
        );

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.t('billPayTitle'), style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(s.t('billPayAmount', {'ton': localizeDigits(links.tonText, lang)}), style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Material(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.isFa ? svc.noticeFa : svc.noticeEn,
                        style: TextStyle(color: theme.colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text(s.t('billPayWallet'), style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onPrimary)),
                onPressed: () async {
                  final ok = await openWallet(links);
                  if (!ok) _say(s.t('billNoWallet'));
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(s.t('billPayWalletNote'), textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(
                leading: const Icon(Icons.qr_code_2),
                title: Text(s.t('billManual')),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  Text(s.t('billScanQr'), textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(data: links.qrData, size: 200, backgroundColor: Colors.white),
                    ),
                  ),
                  copyRow(s.t('billComment'), links.comment, note: s.t('billCommentNote')),
                  copyRow(s.t('billAddress'), svc.receiveAddress),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: billing.checking
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: Text(s.t('billPaidCheck')),
              onPressed: billing.checking
                  ? null
                  : () async {
                      final r = await billing.checkPayments();
                      if (mounted) _say(checkResultText(s, r, billing));
                    },
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary)),
            ],
            const SizedBox(height: 8),
            Text(
              s.t('billBalance', {'ton': localizeDigits(formatNanotons(billing.balance.available), lang)}),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
