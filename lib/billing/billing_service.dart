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
  })  : _keys = keys,
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
      var code = RecoveryCode.tryParse(await keys.read(BillingKeys.recoveryCode) ?? '');
      if (code == null) {
        code = RecoveryCode.generate(rng);
        await keys.write(BillingKeys.recoveryCode, code.value);
      }
      final dir = Directory('${dataDir.path}${Platform.pathSeparator}billing');
      final ledger = await Ledger.open(dir: dir, paymentId: code.paymentId, keys: keys, masterKey: master, now: now, rng: rng);
      await ledger.reconcile();
      return Ok(BillingService._(
        receiveAddress: check.address,
        prices: prices ?? PriceTable.standard(),
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

  /// Render succeeded: the reserved credit is spent.
  Future<BillingResult<void>> commit(String reservationId) async {
    final r = await _ledger.commit(reservationId);
    _emit();
    return r;
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
      _code = parsed;
      _ledger = ledger;
    } on FileSystemException catch (e) {
      return Err(BillingError(BillingErrorCode.storage, e.osError?.message ?? 'fs'));
    }
    _emit();
    return refresh();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(_ledger.balance);
  }

  Future<void> dispose() => _changes.close();
}
