import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/ton_verifier.dart';
import 'package:kiro/data/secure_store.dart';
import 'package:kiro/features/billing/billing_controller.dart';
import 'package:kiro/l10n/strings.dart';
import 'package:kiro/l10n/studio_strings.dart';

import 'billing/billing_test_utils.dart';

/// A secure store whose platform keystore is broken.
class _BrokenStore implements SecureStore {
  @override
  Future<String?> read(String key) async => throw Exception('keystore');
  @override
  Future<void> write(String key, String value) async => throw Exception('keystore');
  @override
  Future<void> delete(String key) async => throw Exception('keystore');
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('kiro_billing_app_'));
  tearDown(() async => dir.delete(recursive: true));

  test('a broken keystore falls back to a private file instead of disabling billing', () async {
    final c = await openBilling(secure: _BrokenStore(), supportDir: dir);
    expect(c.available, isTrue);
    final id = c.service!.paymentId;
    c.dispose();
    final again = await openBilling(secure: _BrokenStore(), supportDir: dir);
    expect(again.service!.paymentId, id, reason: 'same identity after a restart');
    again.dispose();
  });

  test('a working keystore is used and the file fallback stays empty', () async {
    final secure = MemorySecureStore();
    final keys = FallbackKeyStore(secure, File('${dir.path}/keys.json'));
    await keys.write('a', '1');
    expect(await secure.read('a'), '1');
    expect(await keys.read('a'), '1');
    expect(File('${dir.path}/keys.json').existsSync(), isFalse);
    await keys.delete('a');
    expect(await keys.read('a'), isNull);
  });

  test('a wiped key store keeps the same payment id (identity backup)', () async {
    final ex = FakeExplorer(testPaymentId);
    PaymentVerifier v(String addr) => PaymentVerifier.standard(receiveAddress: addr, client: ex.client, sleep: noSleep);
    final first = (await BillingService.open(keys: MemorySecureKeyStore(), dataDir: dir, verifier: v, rng: Random(1))).valueOrNull!;
    await first.restoreFromRecoveryCode(testRecovery);
    expect(first.balance.available, 800000000);
    await first.dispose();
    // New, empty key store (keystore reset): the identity comes back from the backup file and the
    // credit is rebuilt from the chain.
    final second = (await BillingService.open(keys: MemorySecureKeyStore(), dataDir: dir, verifier: v, rng: Random(2))).valueOrNull!;
    expect(second.paymentId, testPaymentId);
    await second.refresh();
    expect(second.balance.available, 800000000);
  });

  test('controller without a service reports unavailable and never throws', () async {
    final c = BillingController(null, openError: BillingErrorCode.addressIntegrity);
    expect(c.available, isFalse);
    expect(c.balance.available, 0);
    expect((await c.checkPayments()).isOk, isFalse);
    expect((await c.restore('x')).isOk, isFalse);
    await c.checkIfStale();
  });

  test('every billing error and paid-video code has a message', () {
    for (final code in BillingErrorCode.values) {
      expect(S.fa.containsKey(billingErrorKey(code)), isTrue, reason: code.name);
      expect(S.fa.containsKey(studioErrorKey('billing_${code.name}')), isTrue, reason: code.name);
      expect(studioErrorKey('billing_${code.name}'), isNot('studioErr_generic'));
    }
    for (final code in ['billing_unavailable', 'no_topic', 'render_failed']) {
      expect(studioErrorKey(code), isNot('studioErr_generic'), reason: code);
    }
    for (final phase in ['clip', 'stitch']) {
      expect(S.fa.containsKey('studioPhase_$phase'), isTrue);
      expect(S.en.containsKey('studioPhase_$phase'), isTrue);
    }
  });
}
