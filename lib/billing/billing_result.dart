/// Result type used by the billing module. Nothing in the public billing API throws to the UI:
/// every fallible call returns a [BillingResult].
library;

enum BillingErrorCode {
  /// No network, DNS failure, timeout.
  network,

  /// The explorer API rate-limited us (HTTP 429) after all retries.
  rateLimited,

  /// The explorer API answered with something we could not parse.
  badResponse,

  /// Not enough credit for the requested duration.
  insufficientFunds,

  /// The local ledger failed its integrity check. Not returned by spending calls: the ledger is
  /// rebuilt from the chain instead (lenient handling); kept for API stability.
  tampered,

  /// The built-in receive address failed its integrity check (patched binary).
  addressIntegrity,

  /// A recovery code that is malformed or has a bad check character.
  invalidCode,

  /// The duration is not sold (longer than the longest tier, or zero).
  unsupportedDuration,

  /// commit/release for a reservation id that is unknown or already settled.
  unknownReservation,

  /// Reading or writing the local ledger failed.
  storage,

  /// Billing could not be opened on this device (paid features are disabled with a message).
  unavailable,
}

/// Stable string key per code (used for message lookup). Explicit so it survives
/// `--obfuscate`, which may rename enum values.
extension BillingErrorCodeKey on BillingErrorCode {
  String get key => switch (this) {
        BillingErrorCode.network => 'network',
        BillingErrorCode.rateLimited => 'rateLimited',
        BillingErrorCode.badResponse => 'badResponse',
        BillingErrorCode.insufficientFunds => 'insufficientFunds',
        BillingErrorCode.tampered => 'tampered',
        BillingErrorCode.addressIntegrity => 'addressIntegrity',
        BillingErrorCode.invalidCode => 'invalidCode',
        BillingErrorCode.unsupportedDuration => 'unsupportedDuration',
        BillingErrorCode.unknownReservation => 'unknownReservation',
        BillingErrorCode.storage => 'storage',
        BillingErrorCode.unavailable => 'unavailable',
      };
}

class BillingError {
  const BillingError(this.code, [this.detail = '']);
  final BillingErrorCode code;

  /// Developer detail; never contains secrets. Not meant to be shown verbatim to users.
  final String detail;

  @override
  String toString() => 'BillingError(${code.key}${detail.isEmpty ? '' : ': $detail'})';
}

sealed class BillingResult<T> {
  const BillingResult();

  bool get isOk => this is Ok<T>;

  T? get valueOrNull => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>() => null,
      };

  BillingError? get errorOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final error) => error,
      };
}

final class Ok<T> extends BillingResult<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends BillingResult<T> {
  const Err(this.error);
  final BillingError error;
}
