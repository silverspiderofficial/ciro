/// Authenticated encryption for ledger records, built only on package:crypto.
///
/// Construction (encrypt-then-MAC):
/// - keys: encKey = HMAC-SHA256(master, "kiro.ledger.enc.v1|`paymentId`"),
///         macKey = HMAC-SHA256(master, "kiro.ledger.mac.v1|`paymentId`")
/// - keystream block i = HMAC-SHA256(encKey, nonce(16) || i as uint32 BE) (HMAC as a PRF in
///   counter mode), ciphertext = plaintext XOR keystream
/// - tag = HMAC-SHA256(macKey, prevTag || seq as uint64 BE || nonce || ciphertext)
///
/// The tag chains to the previous record, so deleting, reordering or replaying records breaks
/// verification. If package:cryptography is added later, [RecordCipher] can be re-implemented
/// with AES-256-GCM (keep the chained HMAC tag for ordering).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

abstract class RecordCipher {
  /// Returns `nonce || ciphertext || tag(32)`.
  Uint8List seal(List<int> plaintext, {required List<int> prevTag, required int seq});

  /// Returns the plaintext, or null when the tag does not verify.
  Uint8List? open(List<int> sealed, {required List<int> prevTag, required int seq});

  static Uint8List tagOf(List<int> sealed) => Uint8List.fromList(sealed.sublist(sealed.length - 32));
}

class HmacCtrCipher implements RecordCipher {
  HmacCtrCipher(List<int> masterKey, String context, {Random? rng})
      : _enc = Hmac(sha256, masterKey).convert(utf8.encode('kiro.ledger.enc.v1|$context')).bytes,
        _mac = Hmac(sha256, masterKey).convert(utf8.encode('kiro.ledger.mac.v1|$context')).bytes,
        _rng = rng ?? Random.secure();

  final List<int> _enc;
  final List<int> _mac;
  final Random _rng;

  static const nonceLength = 16;
  static const tagLength = 32;

  /// Genesis "previous tag" for the first record.
  static final Uint8List genesisTag = Uint8List(32);

  Uint8List _xor(List<int> nonce, List<int> data) {
    final out = Uint8List(data.length);
    final h = Hmac(sha256, _enc);
    for (var block = 0; block * 32 < data.length; block++) {
      final ks = h.convert([...nonce, (block >> 24) & 0xff, (block >> 16) & 0xff, (block >> 8) & 0xff, block & 0xff]).bytes;
      for (var j = 0; j < 32 && block * 32 + j < data.length; j++) {
        out[block * 32 + j] = data[block * 32 + j] ^ ks[j];
      }
    }
    return out;
  }

  List<int> _tag(List<int> prevTag, int seq, List<int> nonce, List<int> ct) {
    final seqBytes = ByteData(8)..setUint64(0, seq);
    return Hmac(sha256, _mac).convert([...prevTag, ...seqBytes.buffer.asUint8List(), ...nonce, ...ct]).bytes;
  }

  @override
  Uint8List seal(List<int> plaintext, {required List<int> prevTag, required int seq}) {
    final nonce = List<int>.generate(nonceLength, (_) => _rng.nextInt(256));
    final ct = _xor(nonce, plaintext);
    return Uint8List.fromList([...nonce, ...ct, ..._tag(prevTag, seq, nonce, ct)]);
  }

  @override
  Uint8List? open(List<int> sealed, {required List<int> prevTag, required int seq}) {
    if (sealed.length < nonceLength + tagLength) return null;
    final nonce = sealed.sublist(0, nonceLength);
    final ct = sealed.sublist(nonceLength, sealed.length - tagLength);
    final tag = sealed.sublist(sealed.length - tagLength);
    final expect = _tag(prevTag, seq, nonce, ct);
    var diff = 0;
    for (var i = 0; i < tagLength; i++) {
      diff |= tag[i] ^ expect[i];
    }
    if (diff != 0) return null;
    return _xor(nonce, ct);
  }
}
