/// Public facade of the pay-per-video credit module. No accounts: the device's recovery code
/// identifies its payments. Nothing here throws to the UI; every fallible call returns a
/// [BillingResult].
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'billing_config.dart';
import 'billing_result.dart';
import 'ledger.dart';
import 'paid_feature.dart';
import 'payment_id.dart';
import 'payment_links.dart';
import 'price_table.dart';
import 'secure_key_store.dart';
import 'ton_verifier.dart';

class BillingService {
  BillingService._({
    required this.receiveAddress,
    required this.prices,
    required SecureKeyStore keys,
    required Directory dir,
    required List<int> masterKey,
    required PaymentVerifier verifier,
    required RecoveryCode code,
    required Ledger ledger,
    required DateTime Function() now,
    required Random? rng,
    required this.pricing,
    required Set<String> deviceFreeUsed,
  })  : _deviceFreeUsed = deviceFreeUsed,
        _keys = keys,
        _dir = dir,
        _masterKey = masterKey,
        _verifier = verifier,
        _code = code,
        _ledger = ledger,
        _now = now,
        _rng = rng;

  /// Opens the service: verifies the built-in receive address, loads or creates the master key
  /// and recovery code, opens the ledger and releases reservations left by a crash.
  ///
  /// [verifier] overrides the explorer client (tests); otherwise [client] is used with
  /// toncenter + tonapi.
  static Future<BillingResult<BillingService>> open({
    required SecureKeyStore keys,
    required Directory dataDir,
    http.Client? client,
    PaymentVerifier Function(String receiveAddress)? verifier,
    PriceTable? prices,
    DateTime Function()? now,
    Random? rng,
  }) async {
    final check = checkReceiveAddress();
    if (!check.ok) return Err(BillingError(BillingErrorCode.addressIntegrity, check.reason));
    try {
      final master = await loadOrCreateMasterKey(keys, rng: rng);
      final dir = Directory('${dataDir.path}${Platform.pathSeparator}billing');
      await dir.create(recursive: true);
      var code = RecoveryCode.tryParse(await keys.read(BillingKeys.recoveryCode) ?? '');
      // Lenient: if the platform key store lost its data, fall back to the copy in the
      // app-private directory so the user keeps the same payment id and credit.
      code ??= await _readIdentityBackup(dir);
      if (code == null) {
        code = RecoveryCode.generate(rng);
        await keys.write(BillingKeys.recoveryCode, code.value);
      } else if ((await keys.read(BillingKeys.recoveryCode)) != code.value) {
        await keys.write(BillingKeys.recoveryCode, code.value);
      }
      await _writeIdentityBackup(dir, code);
      final ledger = await Ledger.open(dir: dir, paymentId: code.paymentId, keys: keys, masterKey: master, now: now, rng: rng);
      await ledger.reconcile();
      final table = prices ?? PriceTable.standard();
      return Ok(BillingService._(
        pricing: FeaturePricing(videoTable: table),
        deviceFreeUsed: await _readDeviceFreeUsed(keys),
        receiveAddress: check.address,
        prices: table,
        keys: keys,
        dir: dir,
        masterKey: master,
        verifier: verifier?.call(check.address) ??
            PaymentVerifier.standard(receiveAddress: check.address, client: client ?? http.Client()),
        code: code,
        ledger: ledger,
        now: now ?? DateTime.now,
        rng: rng,
      ));
    } on FileSystemException catch (e) {
      return Err(BillingError(BillingErrorCode.storage, e.osError?.message ?? 'fs'));
    } on Object catch (e) {
      return Err(BillingError(BillingErrorCode.storage, e.runtimeType.toString()));
    }
  }

  final String receiveAddress;
  final PriceTable prices;

  /// Prices of every paid feature (videos use [prices]).
  final FeaturePricing pricing;

  /// Features whose free first use was taken on this device (any recovery code). Lenient: if
  /// this record is lost, another free use may be granted.
  final Set<String> _deviceFreeUsed;
  final SecureKeyStore _keys;
  final Directory _dir;
  final List<int> _masterKey;
  final PaymentVerifier _verifier;
  final DateTime Function() _now;
  final Random? _rng;
  RecoveryCode _code;
  Ledger _ledger;
  Future<BillingResult<int>>? _refreshing;
  final StreamController<LedgerBalance> _changes = StreamController<LedgerBalance>.broadcast();

  /// Emits the balance after every change (credit, reserve, commit, release, restore).
  Stream<LedgerBalance> get changes => _changes.stream;

  /// 8-char public id used in the transfer comment `kiro-<id>`.
  String get paymentId => _code.paymentId;

  /// Exact transfer comment the payer must use.
  String get comment => paymentComment(paymentId);

  /// Secret backup code (`XXXX-XXXX-XXXX-XXXX`). Show it behind a tap, suggest saving it.
  String get recoveryCode => _code.display;

  LedgerBalance get balance => _ledger.balance;

  /// True when this device detected ledger tampering at some point for this payment id.
  bool get tampered => _ledger.tampered;

  String get noticeFa => paymentNoticeFa;
  String get noticeEn => paymentNoticeEn;

  /// The tier (duration, price, clip count) that covers [d], or null when not sold.
  PriceTier? priceFor(Duration d) => prices.tierFor(d);

  /// Links for paying [nanotons] (exact integer). For a tier use `priceFor(d)!.nanotons`.
  PaymentLinks paymentLinks(int nanotons) =>
      buildPaymentLinks(receiveAddress: receiveAddress, paymentId: paymentId, nanotons: nanotons);

  /// Checks the chain for new payments and credits them. Returns the number of new credits.
  /// Concurrent calls share one scan.
  Future<BillingResult<int>> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<BillingResult<int>> _refresh() async {
    final ledger = _ledger;
    final scan = await _verifier.scan(paymentId: ledger.paymentId, stopAtLt: ledger.cursorLt);
    switch (scan) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        final cursor = (value.complete || ledger.cursorLt == null) ? value.newestLt : null;
        final r = await ledger.addCredits(value.payments, cursorLt: cursor);
        if (ledger.needsTamperBoundary && value.newestLt != null) {
          await ledger.setTamperBoundary(value.newestLt!);
        }
        _emit();
        return r;
    }
  }

  /// Reserves the price of [d] before a render. Fails with insufficientFunds / tampered /
  /// unsupportedDuration.
  Future<BillingResult<Reservation>> reserve(Duration d) async {
    final tier = prices.tierFor(d);
    if (tier == null) return const Err(BillingError(BillingErrorCode.unsupportedDuration));
    final r = await _ledger.reserve(tier.nanotons, d);
    _emit();
    return r;
  }

  /// True when the next use of [f] is its free first use.
  bool isFirstUseFree(PaidFeature f) => !_deviceFreeUsed.contains(f.key) && !_ledger.freeUseTaken(f.key);

  /// Price of one use of [f] in nanotons (null when not sold), before the free first use.
  int? priceOf(PaidFeature f, {Duration? duration, int units = 1}) => pricing.priceFor(f, duration: duration, units: units);

  /// Reserves one use of [f]: its free first use when still available, otherwise its price.
  /// Commit on success, release on failure or cancel, exactly like [reserve].
  Future<BillingResult<Reservation>> reserveFeature(PaidFeature f, {Duration? duration, int units = 1}) async {
    final price = pricing.priceFor(f, duration: duration, units: units);
    if (price == null) return const Err(BillingError(BillingErrorCode.unsupportedDuration));
    final d = pricing.billedDuration(f, duration);
    if (isFirstUseFree(f)) {
      final r = await _ledger.reserve(0, d, feature: f.key, free: true);
      if (r.isOk) {
        _emit();
        return r;
      }
    }
    final r = await _ledger.reserve(price, d, feature: f.key);
    _emit();
    return r;
  }

  /// Render succeeded: the reserved credit is spent (or the free first use is used up).
  Future<BillingResult<void>> commit(String reservationId) async {
    Reservation? res;
    for (final x in _ledger.openReservations) {
      if (x.id == reservationId) res = x;
    }
    final r = await _ledger.commit(reservationId);
    if (r.isOk && res != null && res.free && res.feature != null) await _markDeviceFreeUsed(res.feature!);
    _emit();
    return r;
  }

  /// Test hook: marks the free first use of [f] as taken on this device.
  Future<void> markFreeUsedForTest(PaidFeature f) => _markDeviceFreeUsed(f.key);

  Future<void> _markDeviceFreeUsed(String feature) async {
    _deviceFreeUsed.add(feature);
    try {
      await _keys.write(BillingKeys.freeUsed(feature), '1');
    } on Object {
      // lenient: the ledger record still counts
    }
  }

  static Future<Set<String>> _readDeviceFreeUsed(SecureKeyStore keys) async {
    final out = <String>{};
    for (final f in PaidFeature.values) {
      try {
        if (await keys.read(BillingKeys.freeUsed(f.key)) != null) out.add(f.key);
      } on Object {
        // lenient
      }
    }
    return out;
  }

  /// Render failed or was cancelled: the reserved credit returns to the balance.
  Future<BillingResult<void>> release(String reservationId) async {
    final r = await _ledger.release(reservationId);
    _emit();
    return r;
  }

  /// Switches this device to the payment identity behind [code] (after a reinstall or on a
  /// second device) and re-derives its credits from the chain. Returns the refresh result.
  Future<BillingResult<int>> restoreFromRecoveryCode(String code) async {
    final parsed = RecoveryCode.tryParse(code);
    if (parsed == null) return const Err(BillingError(BillingErrorCode.invalidCode));
    if (parsed == _code) return refresh();
    try {
      await _refreshing;
      final ledger = await Ledger.open(dir: _dir, paymentId: parsed.paymentId, keys: _keys, masterKey: _masterKey, now: _now, rng: _rng);
      await ledger.reconcile();
      await _keys.write(BillingKeys.recoveryCode, parsed.value);
      await _writeIdentityBackup(_dir, parsed);
      _code = parsed;
      _ledger = ledger;
    } on FileSystemException catch (e) {
      return Err(BillingError(BillingErrorCode.storage, e.osError?.message ?? 'fs'));
    }
    _emit();
    return refresh();
  }

  static File _identityFile(Directory dir) => File('${dir.path}${Platform.pathSeparator}identity');

  static Future<RecoveryCode?> _readIdentityBackup(Directory dir) async {
    try {
      final f = _identityFile(dir);
      if (!await f.exists()) return null;
      return RecoveryCode.tryParse((await f.readAsString()).trim());
    } on Object {
      return null;
    }
  }

  /// Best effort; a failure here never blocks billing.
  static Future<void> _writeIdentityBackup(Directory dir, RecoveryCode code) async {
    try {
      final f = _identityFile(dir);
      if (await f.exists() && (await f.readAsString()).trim() == code.value) return;
      await f.writeAsString(code.value, flush: true);
    } on Object {
      // ignore
    }
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(_ledger.balance);
  }

  Future<void> dispose() => _changes.close();
}
