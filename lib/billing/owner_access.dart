/// Owner access: one secret owner code makes every paid feature free on the device, for good.
///
/// The app holds only a salted PBKDF2-HMAC-SHA256 hash of the code (light XOR masking so it is
/// not a searchable literal), never the code itself. Verification runs in a background isolate
/// so the UI never stalls. Once verified, a device-bound token (HMAC of the hash under the
/// billing master key) is kept in the key store; the code itself is never stored.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'payment_id.dart' show normalizeCrockford;
import 'secure_key_store.dart';

/// Length of an owner code (Crockford base32, shown in groups of 6).
const int ownerCodeLength = 30;

const List<int> _ownerSeed = [71, 106, 73, 236, 218, 170, 103, 134, 189, 165, 39, 74];
const List<int> _ownerMasked = [
  70, 116, 131, 237, 185, 116, 51, 103, 156, 152, 169, 131, 180, 232, 117, 250,
  100, 137, 195, 132, 100, 104, 178, 158, 103, 197, 231, 55, 60, 39, 189, 95,
  31, 194, 185, 30, 113, 220, 28, 239, 191, 189, 165, 2, 165, 215, 87, 140,
];
const int _ownerIterations = 210000;

/// Salt (16 bytes), hash (32 bytes) and iteration count of the built-in owner code.
class OwnerHash {
  const OwnerHash(this.salt, this.hash, this.iterations);
  final List<int> salt;
  final List<int> hash;
  final int iterations;

  static OwnerHash builtIn() {
    final mask = <int>[];
    var h = _ownerSeed;
    while (mask.length < _ownerMasked.length) {
      h = sha256.convert(h).bytes;
      mask.addAll(h);
    }
    final b = [for (var i = 0; i < _ownerMasked.length; i++) _ownerMasked[i] ^ mask[i] ^ ((i * 29 + 11) & 0xff)];
    return OwnerHash(b.sublist(0, 16), b.sublist(16), _ownerIterations);
  }

  /// Builds a hash for [code] (tests and tooling).
  static OwnerHash derive(String code, List<int> salt, int iterations) =>
      OwnerHash(salt, pbkdf2Sha256(utf8.encode(normalizeOwnerCode(code) ?? code), salt, iterations), iterations);
}

/// Normalizes typed input (any case, spaces/hyphens, Persian digits, O→0, I/L→1). Null when it
/// cannot be an owner code.
String? normalizeOwnerCode(String input) {
  final b = StringBuffer();
  for (final r in input.runes) {
    if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else {
      b.writeCharCode(r);
    }
  }
  final n = normalizeCrockford(b.toString().trim());
  if (n == null || n.length != ownerCodeLength) return null;
  return n;
}

/// PBKDF2-HMAC-SHA256 with a 32-byte output (one block).
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations, {int length = 32}) {
  final hmac = Hmac(sha256, password);
  final out = BytesBuilder(copy: false);
  var block = 1;
  while (out.length < length) {
    var u = hmac.convert([...salt, (block >> 24) & 0xff, (block >> 16) & 0xff, (block >> 8) & 0xff, block & 0xff]).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
    block++;
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

bool _constantTimeEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

/// Pure check (blocking; run it off the UI isolate).
bool checkOwnerCodeSync(String input, OwnerHash h) {
  final n = normalizeOwnerCode(input);
  if (n == null) return false;
  return _constantTimeEq(pbkdf2Sha256(utf8.encode(n), h.salt, h.iterations), h.hash);
}

/// Verifies [input] in a background isolate. Never throws.
Future<bool> verifyOwnerCode(String input, {OwnerHash? hash}) async {
  final h = hash ?? OwnerHash.builtIn();
  if (normalizeOwnerCode(input) == null) return false;
  final salt = List<int>.of(h.salt);
  final digest = List<int>.of(h.hash);
  final it = h.iterations;
  try {
    return await Isolate.run(() => checkOwnerCodeSync(input, OwnerHash(salt, digest, it)));
  } on Object {
    return false;
  }
}

/// Owner state of this device, persisted in the key store.
class OwnerAccess {
  OwnerAccess(this._keys, {OwnerHash? hash}) : _hash = hash ?? OwnerHash.builtIn();

  final SecureKeyStore _keys;
  final OwnerHash _hash;
  bool _unlocked = false;

  /// Every paid feature is free on this device.
  bool get unlocked => _unlocked;

  Future<String> _token() async {
    final master = await loadOrCreateMasterKey(_keys);
    return base64.encode(Hmac(sha256, master).convert([...utf8.encode('kiro-owner:v1:'), ..._hash.hash]).bytes);
  }

  /// Reads the saved state. Never throws (a broken key store just means "locked").
  Future<void> load() async {
    try {
      final saved = await _keys.read(BillingKeys.ownerToken);
      _unlocked = saved != null && saved == await _token();
    } on Object {
      _unlocked = false;
    }
  }

  /// Checks [code] (in an isolate) and, when right, unlocks this device for good.
  /// Returns false for a wrong code. Never throws.
  Future<bool> unlock(String code) async {
    final ok = await verifyOwnerCode(code, hash: _hash);
    if (!ok) return false;
    _unlocked = true;
    try {
      await _keys.write(BillingKeys.ownerToken, await _token());
    } on Object {
      // stays unlocked for this run; the user can enter the code again after a restart
    }
    return true;
  }
}
