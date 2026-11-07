import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secrets live only here: Android Keystore-backed EncryptedSharedPreferences.
/// Nothing in this store is ever logged, exported or shown in full.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  static const apiKey = 'remote_api_key';
  static const pinHash = 'app_pin_hash';
}

class KeystoreSecureStore implements SecureStore {
  KeystoreSecureStore()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true, resetOnError: true),
        );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecureStore implements SecureStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

/// Salted, iterated SHA-256 for the app-lock PIN, stored as `v1:salt:hash` (base64url).
class PinHasher {
  static const _iterations = 20000;

  static String hash(String pin, {List<int>? salt}) {
    final s = salt ?? List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final digest = _derive(pin, s);
    return 'v1:${base64Url.encode(s)}:${base64Url.encode(digest)}';
  }

  static bool verify(String pin, String stored) {
    final parts = stored.split(':');
    if (parts.length != 3 || parts[0] != 'v1') return false;
    final salt = base64Url.decode(parts[1]);
    final expected = base64Url.decode(parts[2]);
    final actual = _derive(pin, salt);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }

  static List<int> _derive(String pin, List<int> salt) {
    var block = sha256.convert([...salt, ...utf8.encode(pin)]).bytes;
    for (var i = 0; i < _iterations; i++) {
      block = sha256.convert([...block, ...salt]).bytes;
    }
    return block;
  }
}
