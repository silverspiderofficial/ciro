/// Payment identity without accounts.
///
/// The device holds a secret *recovery code* (16 Crockford base32 chars = 80 random bits,
/// shown as `XXXX-XXXX-XXXX-XXXX`). The *payment id* placed in the public transfer comment is
/// 8 Crockford chars derived from it with SHA-256. Because transfer comments are public on
/// chain, the comment never reveals the recovery code: seeing someone's `kiro-<id>` on an
/// explorer does not let another device claim that credit.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const String crockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const int recoveryCodeLength = 16;
const int paymentIdLength = 8;

/// Encodes bytes as Crockford base32 (no padding), taking the first [length] symbols.
String crockfordEncode(List<int> bytes, int length) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | (b & 0xff);
    bits += 8;
    while (bits >= 5 && out.length < length) {
      bits -= 5;
      out.write(crockfordAlphabet[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
    if (out.length >= length) break;
  }
  if (out.length < length) throw ArgumentError('not enough bytes');
  return out.toString();
}

/// Normalizes user input per Crockford rules: uppercase, drop spaces/hyphens, O→0, I/L→1.
/// Returns null when a character is outside the alphabet.
String? normalizeCrockford(String input) {
  final out = StringBuffer();
  for (final ch in input.toUpperCase().split('')) {
    if (ch == '-' || ch == ' ' || ch == '\u200c') continue;
    final c = switch (ch) { 'O' => '0', 'I' || 'L' => '1', _ => ch };
    if (!crockfordAlphabet.contains(c)) return null;
    out.write(c);
  }
  return out.toString();
}

class RecoveryCode {
  RecoveryCode._(this.value);

  /// 16 normalized Crockford chars.
  final String value;

  static RecoveryCode generate([Random? rng]) {
    final r = rng ?? Random.secure();
    final bytes = List<int>.generate(10, (_) => r.nextInt(256));
    return RecoveryCode._(crockfordEncode(bytes, recoveryCodeLength));
  }

  /// Parses typed input (any case, with or without hyphens, Persian digits allowed).
  static RecoveryCode? tryParse(String input) {
    final n = normalizeCrockford(_asciiDigits(input));
    if (n == null || n.length != recoveryCodeLength) return null;
    return RecoveryCode._(n);
  }

  /// `XXXX-XXXX-XXXX-XXXX` for display and backup.
  String get display => [for (var i = 0; i < value.length; i += 4) value.substring(i, i + 4)].join('-');

  /// The 8-char public id used in the transfer comment.
  String get paymentId {
    final d = sha256.convert(utf8.encode('kiro.payment-id.v1:$value')).bytes;
    return crockfordEncode(d, paymentIdLength);
  }

  @override
  bool operator ==(Object other) => other is RecoveryCode && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// The exact transfer comment for [paymentId].
String paymentComment(String paymentId) => 'kiro-$paymentId';

String _asciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}
