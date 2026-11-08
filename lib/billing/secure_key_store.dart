/// Platform secret storage used by billing for its master key, recovery code and ledger head.
///
/// Implementations to wire later (see docs/BILLING.md):
/// - Android: Android Keystore via flutter_secure_storage (EncryptedSharedPreferences).
/// - Windows: DPAPI (flutter_secure_storage_windows / CryptProtectData).
/// - Linux: libsecret (flutter_secure_storage_linux).
/// The app's existing `SecureStore` (lib/data/secure_store.dart) already has the same shape and
/// can be adapted with [SecureKeyStoreAdapter].
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Adapts any object with read/write/delete (e.g. the app's SecureStore) without importing it.
class SecureKeyStoreAdapter implements SecureKeyStore {
  SecureKeyStoreAdapter({required this.onRead, required this.onWrite, required this.onDelete});
  final Future<String?> Function(String key) onRead;
  final Future<void> Function(String key, String value) onWrite;
  final Future<void> Function(String key) onDelete;

  @override
  Future<String?> read(String key) => onRead(key);
  @override
  Future<void> write(String key, String value) => onWrite(key, value);
  @override
  Future<void> delete(String key) => onDelete(key);
}

/// In-memory store for tests.
class MemorySecureKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Key names used by billing (namespaced so they never collide with other app secrets).
abstract final class BillingKeys {
  static const masterKey = 'billing.v1.master_key';
  static const recoveryCode = 'billing.v1.recovery_code';
  static String ledgerHead(String paymentId) => 'billing.v1.head.$paymentId';
  static String tamperedAt(String paymentId) => 'billing.v1.tampered_at.$paymentId';
  static String freeUsed(String feature) => 'billing.v1.free_used.$feature';
  static const ownerToken = 'billing.v1.owner';
}

/// Returns the 32-byte master key, creating it on first use.
Future<Uint8List> loadOrCreateMasterKey(SecureKeyStore store, {Random? rng}) async {
  final existing = await store.read(BillingKeys.masterKey);
  if (existing != null) {
    try {
      final b = base64.decode(existing);
      if (b.length == 32) return b;
    } on FormatException {
      // fall through and treat as missing
    }
  }
  final r = rng ?? Random.secure();
  final key = Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)));
  await store.write(BillingKeys.masterKey, base64.encode(key));
  return key;
}
