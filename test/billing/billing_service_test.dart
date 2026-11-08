import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/ton_verifier.dart';

import 'billing_test_utils.dart';

void main() {
  late Directory dir;
  late MemorySecureKeyStore keys;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kiro_billing_svc_');
    keys = MemorySecureKeyStore();
  });
  tearDown(() async => dir.delete(recursive: true));

  Future<BillingService> openSvc(FakeExplorer ex) async {
    final r = await BillingService.open(
      keys: keys,
      dataDir: dir,
      verifier: (addr) => PaymentVerifier.standard(receiveAddress: addr, client: ex.client, sleep: noSleep),
      rng: Random(7),
    );
    return r.valueOrNull!;
  }

  test('fresh device: recovery code, links, refresh, reserve/commit', () async {
    // The fake explorer serves payments for the test recovery code, so restore it first.
    final ex = FakeExplorer(testPaymentId);
    final svc = await openSvc(ex);
    expect(svc.paymentId, hasLength(8));
    expect(svc.recoveryCode, matches(RegExp(r'^[0-9A-Z]{4}(-[0-9A-Z]{4}){3}$')));
    expect(svc.balance.available, 0);

    final restored = await svc.restoreFromRecoveryCode('abcd-efgh-jkmn-pqrs');
    expect(restored.valueOrNull, 2);
    expect(svc.paymentId, testPaymentId);
    expect(svc.balance.available, 800000000); // 0.5 + 0.3 TON

    final tier = svc.priceFor(const Duration(seconds: 20))!;
    final links = svc.paymentLinks(tier.nanotons);
    expect(links.tonUri, contains('amount=500000000&text=kiro-$testPaymentId'));

    final res = (await svc.reserve(const Duration(seconds: 20))).valueOrNull!;
    expect(svc.balance.available, 300000000);
    expect((await svc.commit(res.id)).isOk, isTrue);
    expect((await svc.reserve(const Duration(seconds: 30))).errorOrNull!.code, BillingErrorCode.insufficientFunds);
    expect((await svc.reserve(const Duration(minutes: 11))).errorOrNull!.code, BillingErrorCode.unsupportedDuration);

    // Refresh again: nothing new, no double credit.
    expect((await svc.refresh()).valueOrNull, 0);
    expect(svc.balance.available, 300000000);
  });

  test('persisted identity and crash reconcile across restarts', () async {
    final ex = FakeExplorer(testPaymentId);
    final svc = await openSvc(ex);
    await svc.restoreFromRecoveryCode(testRecovery);
    await svc.reserve(const Duration(seconds: 30)); // app killed mid-render
    final svc2 = await openSvc(ex);
    expect(svc2.paymentId, testPaymentId);
    expect(svc2.balance.reserved, 0);
    expect(svc2.balance.available, 800000000);
  });

  test('invalid recovery code and offline refresh return Err', () async {
    final ex = FakeExplorer(testPaymentId, toncenterStatus: 500, tonapiStatus: 500);
    final svc = await openSvc(ex);
    expect((await svc.restoreFromRecoveryCode('nope')).errorOrNull!.code, BillingErrorCode.invalidCode);
    expect((await svc.refresh()).isOk, isFalse);
  });

  test('tampered ledger is rebuilt from the chain without locking the user out', () async {
    final ex = FakeExplorer(testPaymentId);
    final svc = await openSvc(ex);
    await svc.restoreFromRecoveryCode(testRecovery);
    final r = (await svc.reserve(const Duration(seconds: 30))).valueOrNull!;
    await svc.commit(r.id);
    final f = File('${dir.path}/billing/ledger_$testPaymentId.bin');
    final text = await f.readAsString();
    await f.writeAsString(text.replaceRange(5, 6, text[5] == 'A' ? 'B' : 'A'));
    final svc2 = await openSvc(ex);
    expect(svc2.tampered, isTrue);
    await svc2.refresh();
    expect(svc2.balance.credited, 800000000);
    expect(svc2.balance.available, 800000000);
    expect((await svc2.reserve(const Duration(seconds: 30))).isOk, isTrue);
  });
}
