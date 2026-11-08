/// One place every paid action goes through: owner access (free), the free first use, then
/// the price from the ledger. reserve → commit / release, exactly like the topic video.
/// Nothing here throws.
library;

import 'billing_result.dart';
import 'billing_service.dart';
import 'ledger.dart' show Reservation;
import 'owner_access.dart';
import 'paid_feature.dart';

enum FreeReason { none, firstUse, owner }

/// What one use of a feature costs right now.
class FeatureQuote {
  const FeatureQuote({required this.feature, required this.listPrice, required this.free, required this.available});

  final PaidFeature feature;

  /// Normal price in nanotons (null when not sold, e.g. too long).
  final int? listPrice;
  final FreeReason free;

  /// Billing is usable (or the owner unlock makes it unnecessary).
  final bool available;

  /// What this use will take from the credit.
  int get charge => free == FreeReason.none ? (listPrice ?? 0) : 0;
  bool get sold => free == FreeReason.owner || listPrice != null;
}

/// A started paid use. [reservation] is null for owner uses.
class PaidCharge {
  const PaidCharge(this.feature, this.free, this.reservation);
  final PaidFeature feature;
  final FreeReason free;
  final Reservation? reservation;
  int get nanotons => reservation?.nanotons ?? 0;
}

class PaidGate {
  PaidGate({this.billing, this.owner});

  /// Null when billing could not be opened.
  BillingService? billing;
  OwnerAccess? owner;

  bool get ownerUnlocked => owner?.unlocked ?? false;

  /// Paid features can run (owner, or billing open).
  bool get usable => ownerUnlocked || billing != null;

  FeatureQuote quote(PaidFeature f, {Duration? duration, int units = 1}) {
    final b = billing;
    int? price;
    try {
      price = b?.priceOf(f, duration: duration, units: units);
    } on Object {
      price = null;
    }
    if (ownerUnlocked) return FeatureQuote(feature: f, listPrice: price, free: FreeReason.owner, available: true);
    if (b == null) return FeatureQuote(feature: f, listPrice: null, free: FreeReason.none, available: false);
    var first = false;
    try {
      first = b.isFirstUseFree(f);
    } on Object {
      first = false;
    }
    return FeatureQuote(
      feature: f,
      listPrice: price,
      free: first && price != null ? FreeReason.firstUse : FreeReason.none,
      available: true,
    );
  }

  /// Starts a paid use. Errors: unavailable, insufficientFunds, unsupportedDuration, storage.
  Future<BillingResult<PaidCharge>> begin(PaidFeature f, {Duration? duration, int units = 1}) async {
    if (ownerUnlocked) return Ok(PaidCharge(f, FreeReason.owner, null));
    final b = billing;
    if (b == null) return const Err(BillingError(BillingErrorCode.unavailable));
    try {
      final r = await b.reserveFeature(f, duration: duration, units: units);
      return switch (r) {
        Ok(:final value) => Ok(PaidCharge(f, value.free ? FreeReason.firstUse : FreeReason.none, value)),
        Err(:final error) => Err(error),
      };
    } on Object catch (e) {
      return Err(BillingError(BillingErrorCode.storage, e.runtimeType.toString()));
    }
  }

  /// The work succeeded. Never throws (an unrecorded spend is released on the next start).
  Future<void> commit(PaidCharge c) async {
    final res = c.reservation;
    if (res == null) return;
    try {
      await billing?.commit(res.id);
    } on Object {
      // lenient
    }
  }

  /// The work failed or was cancelled. Never throws.
  Future<void> release(PaidCharge c) async {
    final res = c.reservation;
    if (res == null) return;
    try {
      await billing?.release(res.id);
    } on Object {
      // released on the next start by the ledger's reconcile
    }
  }

  /// Runs [work] as one paid use: begin, then commit on success or release on any error.
  /// A billing error is returned as [PaidGateException]; errors from [work] are rethrown.
  Future<T> run<T>(PaidFeature f, Future<T> Function() work, {Duration? duration, int units = 1}) async {
    final r = await begin(f, duration: duration, units: units);
    final charge = switch (r) {
      Ok(:final value) => value,
      Err(:final error) => throw PaidGateException(error.code),
    };
    var ok = false;
    try {
      final v = await work();
      ok = true;
      await commit(charge);
      return v;
    } finally {
      if (!ok) await release(charge);
    }
  }
}

class PaidGateException implements Exception {
  const PaidGateException(this.code);
  final BillingErrorCode code;
  @override
  String toString() => 'PaidGateException(${code.key})';
}
