/// Static billing configuration: the receive address (stored obfuscated and verified by
/// SHA-256 at runtime), user-facing payment notices, and explorer endpoints.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'ton_address.dart';

/// Prefix of the transfer comment: the comment must be exactly `kiro-<paymentId>`.
const String paymentCommentPrefix = 'kiro-';

/// Hosts contacted by the payment verifier (read-only public explorer APIs).
const String toncenterBase = 'https://toncenter.com/api/v2';
const String tonapiBase = 'https://tonapi.io/v2';

/// Shown next to every payment button.
const String paymentNoticeFa =
    'فقط تون‌کوین (TON) روی شبکهٔ TON واریز کنید. هیچ توکن یا ارز دیگری (USDT، Notcoin، Jetton و…) پذیرفته نمی‌شود و برگشت‌پذیر نیست.';
const String paymentNoticeEn =
    'Send only Toncoin (TON) on the TON network. No other token or currency (USDT, Notcoin, Jettons, etc.) is accepted, and such transfers cannot be refunded.';

// Receive address, XOR-masked so it is not a plain string literal in the binary. The mask is a
// SHA-256 chain over a fixed seed plus a position term. This only stops trivial string
// search/replace; the runtime SHA-256 check below is what detects a patched address.
const List<int> _addrMasked = [
  160, 88, 209, 162, 225, 67, 176, 122, 86, 233, 91, 160, 5, 55, 154, 101, //
  178, 199, 142, 155, 160, 107, 32, 178, 240, 102, 201, 66, 110, 167, 170, 227,
  133, 236, 111, 175, 197, 172, 47, 155, 142, 15, 175, 96, 26, 215, 22, 252,
];
const List<int> _maskSeed = [107, 105, 114, 111, 46, 98, 105, 108, 108, 105, 110, 103, 46, 118, 49];

// SHA-256 (hex) of the receive address, split so it is not one searchable literal.
const List<String> _addrDigestParts = [
  '30278cf6ef5b0a9c',
  '0c2751bd4da8776b',
  '2eac3b169bd7d4ae',
  '4fdb4f940b8313ba',
];

String _unmask(List<int> masked) {
  final mask = <int>[];
  var h = _maskSeed;
  while (mask.length < masked.length) {
    h = sha256.convert(h).bytes;
    mask.addAll(h);
  }
  final out = StringBuffer();
  for (var i = 0; i < masked.length; i++) {
    out.writeCharCode(masked[i] ^ mask[i] ^ ((i * 31 + 7) & 0xff));
  }
  return out.toString();
}

/// Outcome of the startup integrity check of the receive address.
class ReceiveAddressCheck {
  const ReceiveAddressCheck(this.address, this.ok, this.reason);
  final String address;
  final bool ok;
  final String reason;
}

/// Decodes the receive address and checks (1) its SHA-256 against the expected digest and
/// (2) that it is a valid friendly TON address (36 bytes, CRC16-XMODEM). Pure; call at startup.
ReceiveAddressCheck checkReceiveAddress({List<int>? maskedOverride, String? expectedDigestOverride}) {
  final addr = _unmask(maskedOverride ?? _addrMasked);
  final digest = sha256.convert(utf8.encode(addr)).toString();
  final expected = expectedDigestOverride ?? _addrDigestParts.join();
  if (!_constantTimeEquals(digest, expected)) {
    return ReceiveAddressCheck(addr, false, 'digest');
  }
  final parsed = TonAddress.tryParse(addr);
  if (parsed == null || parsed.testnet) return ReceiveAddressCheck(addr, false, 'format');
  return ReceiveAddressCheck(addr, true, '');
}

/// Test hook: masks an arbitrary address with the same scheme (used to prove a patched
/// address is rejected).
List<int> maskAddressForTest(String addr) {
  final mask = <int>[];
  var h = _maskSeed;
  while (mask.length < addr.length) {
    h = sha256.convert(h).bytes;
    mask.addAll(h);
  }
  return [for (var i = 0; i < addr.length; i++) addr.codeUnitAt(i) ^ mask[i] ^ ((i * 31 + 7) & 0xff)];
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}
