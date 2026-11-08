/// UI-facing state for pay-per-video credit: wraps the (optional) [BillingService], turns its
/// change stream into notifications and keeps the "checking payments" flag.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../billing/billing.dart';
import '../../data/secure_store.dart';

class BillingController extends ChangeNotifier {
  BillingController(this.service, {this.openError}) {
    _sub = service?.changes.listen((_) => notifyListeners());
  }

  /// Null when billing could not be opened; paid video is then disabled with a message.
  final BillingService? service;

  /// Why [service] is null (for logs; the UI shows a generic message).
  final BillingErrorCode? openError;

  StreamSubscription<LedgerBalance>? _sub;
  bool _checking = false;
  DateTime? _lastCheck;

  bool get available => service != null;
  bool get checking => _checking;
  LedgerBalance get balance => service?.balance ?? LedgerBalance.empty;

  /// Reads the chain for new payments. Never throws.
  Future<BillingResult<int>> checkPayments() async {
    final svc = service;
    if (svc == null) return const Err(BillingError(BillingErrorCode.storage, 'unavailable'));
    _checking = true;
    notifyListeners();
    try {
      final r = await svc.refresh();
      _lastCheck = DateTime.now();
      return r;
    } on Object catch (e) {
      return Err(BillingError(BillingErrorCode.network, e.runtimeType.toString()));
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// A quiet check when a screen opens, at most once a minute (the public API is rate-limited).
  Future<void> checkIfStale() async {
    if (service == null || _checking) return;
    final last = _lastCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) return;
    await checkPayments();
  }

  /// Switches to the identity behind a recovery code and rebuilds its credit. Never throws.
  Future<BillingResult<int>> restore(String code) async {
    final svc = service;
    if (svc == null) return const Err(BillingError(BillingErrorCode.storage, 'unavailable'));
    _checking = true;
    notifyListeners();
    try {
      return await svc.restoreFromRecoveryCode(code);
    } on Object catch (e) {
      return Err(BillingError(BillingErrorCode.storage, e.runtimeType.toString()));
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    service?.dispose();
    super.dispose();
  }
}

/// Localisation key for a billing error code.
String billingErrorKey(BillingErrorCode code) => 'billErr_${code.key}';

/// Opens billing for the app. Never throws: on failure returns a controller without a service.
Future<BillingController> openBilling({required SecureStore secure, required Directory supportDir}) async {
  try {
    final keys = FallbackKeyStore(secure, File(p.join(supportDir.path, 'billing', 'keys.json')));
    final r = await BillingService.open(keys: keys, dataDir: supportDir);
    return switch (r) {
      Ok(:final value) => BillingController(value),
      Err(:final error) => BillingController(null, openError: error.code),
    };
  } on Object {
    return BillingController(null, openError: BillingErrorCode.storage);
  }
}

/// Billing key store on the platform's secure storage. Lenient: when the secure storage throws
/// (some devices have a broken keystore), it falls back to a private file in the app's support
/// directory instead of disabling paid video.
class FallbackKeyStore implements SecureKeyStore {
  FallbackKeyStore(this._secure, this._file);
  final SecureStore _secure;
  final File _file;
  Map<String, String>? _cache;

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    try {
      if (await _file.exists()) {
        final m = jsonDecode(await _file.readAsString());
        if (m is Map) return _cache = {for (final e in m.entries) '${e.key}': '${e.value}'};
      }
    } on Object {
      // fall through
    }
    return _cache = {};
  }

  Future<void> _save() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_cache ?? {}), flush: true);
    } on Object {
      // best effort
    }
  }

  @override
  Future<String?> read(String key) async {
    try {
      final v = await _secure.read(key);
      if (v != null) return v;
    } on Object {
      // fall back
    }
    return (await _load())[key];
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _secure.write(key, value);
      final m = await _load();
      if (m.remove(key) != null) await _save();
      return;
    } on Object {
      // fall back
    }
    (await _load())[key] = value;
    await _save();
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _secure.delete(key);
    } on Object {
      // ignore
    }
    final m = await _load();
    if (m.remove(key) != null) await _save();
  }
}
