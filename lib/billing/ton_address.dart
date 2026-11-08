/// TON "user-friendly" address parsing and validation (48 chars of base64 or base64url that
/// decode to 36 bytes: flags, workchain, 32-byte account hash, CRC16-XMODEM big-endian).
library;

import 'dart:convert';
import 'dart:typed_data';

/// CRC16-XMODEM (poly 0x1021, init 0x0000, no reflection, no final xor).
int crc16Xmodem(List<int> data) {
  var crc = 0;
  for (final b in data) {
    crc ^= (b & 0xff) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xffff;
    }
  }
  return crc;
}

class TonAddress {
  const TonAddress._({
    required this.workchain,
    required this.hash,
    required this.bounceable,
    required this.testnet,
  });

  final int workchain;

  /// 32-byte account id.
  final Uint8List hash;
  final bool bounceable;
  final bool testnet;

  /// Raw form `wc:hex`, used to compare addresses regardless of their friendly encoding.
  String get raw => '$workchain:${hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  static const _flagBounceable = 0x11;
  static const _flagNonBounceable = 0x51;
  static const _flagTestOnly = 0x80;

  /// Parses a friendly address (base64 or base64url) or a raw `wc:hex64` address.
  /// Returns null when the input is malformed or the checksum does not match.
  static TonAddress? tryParse(String input) {
    final s = input.trim();
    if (s.contains(':')) return _tryParseRaw(s);
    if (s.length != 48) return null;
    if (!RegExp(r'^[A-Za-z0-9_\-+/]{48}$').hasMatch(s)) return null;
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(s.replaceAll('+', '-').replaceAll('/', '_'));
    } on FormatException {
      return null;
    }
    if (bytes.length != 36) return null;
    final crc = (bytes[34] << 8) | bytes[35];
    if (crc16Xmodem(bytes.sublist(0, 34)) != crc) return null;
    var flags = bytes[0];
    final testnet = (flags & _flagTestOnly) != 0;
    flags &= ~_flagTestOnly;
    if (flags != _flagBounceable && flags != _flagNonBounceable) return null;
    final wc = bytes[1] == 0xff ? -1 : bytes[1];
    if (wc != 0 && wc != -1) return null;
    return TonAddress._(
      workchain: wc,
      hash: Uint8List.fromList(bytes.sublist(2, 34)),
      bounceable: flags == _flagBounceable,
      testnet: testnet,
    );
  }

  static TonAddress? _tryParseRaw(String s) {
    final m = RegExp(r'^(-?\d+):([0-9a-fA-F]{64})$').firstMatch(s);
    if (m == null) return null;
    final wc = int.parse(m.group(1)!);
    if (wc != 0 && wc != -1) return null;
    final hex = m.group(2)!;
    final hash = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      hash[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return TonAddress._(workchain: wc, hash: hash, bounceable: true, testnet: false);
  }

  static bool isValid(String input) => tryParse(input) != null;

  /// True when both strings name the same account (any encoding / flag variant).
  static bool sameAccount(String a, String b) {
    final x = tryParse(a);
    final y = tryParse(b);
    return x != null && y != null && x.raw == y.raw;
  }
}
