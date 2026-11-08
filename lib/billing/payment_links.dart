/// Wallet deep links for a TON transfer to the receive address.
library;

import 'nanoton.dart';
import 'payment_id.dart';

class PaymentLinks {
  const PaymentLinks({
    required this.tonUri,
    required this.httpsUri,
    required this.qrData,
    required this.nanotons,
    required this.comment,
  });

  /// `ton://transfer/<addr>?amount=<nanotons>&text=kiro-<id>`: opens any installed TON wallet
  /// (Android intent / desktop URL handler).
  final String tonUri;

  /// Universal-link fallback through Tonkeeper's web handler (works without a registered
  /// `ton://` handler, e.g. on desktop browsers).
  final String httpsUri;

  /// What to encode in a QR code (scan with a phone wallet).
  final String qrData;

  final int nanotons;
  final String comment;

  String get tonText => formatNanotons(nanotons);
}

/// Builds the links. [nanotons] must be > 0 (exact integer, no floating point).
PaymentLinks buildPaymentLinks({
  required String receiveAddress,
  required String paymentId,
  required int nanotons,
}) {
  if (nanotons <= 0) throw ArgumentError.value(nanotons, 'nanotons');
  final comment = paymentComment(paymentId);
  final query = 'amount=$nanotons&text=${Uri.encodeQueryComponent(comment)}';
  final ton = 'ton://transfer/$receiveAddress?$query';
  return PaymentLinks(
    tonUri: ton,
    httpsUri: 'https://app.tonkeeper.com/transfer/$receiveAddress?$query',
    qrData: ton,
    nanotons: nanotons,
    comment: comment,
  );
}
