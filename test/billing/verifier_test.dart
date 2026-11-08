import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kiro/billing/billing_result.dart';
import 'package:kiro/billing/ton_verifier.dart';

import 'billing_test_utils.dart';

const receive = 'UQAFkuk0FEYPDTiu_d-Hz8ynT5VDFpmR9REXbkOxICwnWZO8';

PaymentVerifier verifierFor(http.Client c) => PaymentVerifier.standard(receiveAddress: receive, client: c, sleep: noSleep);

void main() {
  final pid = testPaymentId;

  test('toncenter: accepts only plain-comment native TON with the exact comment, deduped', () async {
    final ex = FakeExplorer(pid);
    final r = await verifierFor(ex.client).scan(paymentId: pid);
    final s = r.valueOrNull!;
    expect(s.provider, 'toncenter');
    expect(s.complete, isTrue);
    expect(s.newestLt, 9000);
    // Valid: 0.5 (tx 1, duplicated in the page) and 0.3 (tx 8). Rejected: jetton notifications
    // (even with a comment-looking `message`), wrong case, zero value, external, other id,
    // trailing space.
    expect(s.payments.map((p) => p.nanotons).toList(), [500000000, 300000000]);
    expect(s.payments.map((p) => p.txHash).toSet(), hasLength(2));
    expect(s.payments.every((p) => RegExp(r'^[0-9a-f]{64}$').hasMatch(p.txHash)), isTrue);
  });

  test('jetton transfer notification is rejected on its own', () {
    final page = jsonDecode(loadFixture('toncenter_page.json', pid)) as Map<String, Object?>;
    final list = (page['result']! as List<Object?>).cast<Map<String, Object?>>();
    final jetton = list.firstWhere((t) => ((t['in_msg']! as Map<String, Object?>)['msg_data']! as Map<String, Object?>)['@type'] == 'msg.dataRaw');
    final tx = ToncenterProvider.parseToncenterTx(jetton)!;
    expect(tx.textComment, isNull);
    expect(acceptsPayment(tx, expectedComment: 'kiro-$pid', receiveAddress: receive), isFalse);
  });

  test('falls back to tonapi when toncenter keeps failing; same hashes as toncenter', () async {
    final ex = FakeExplorer(pid, toncenterStatus: 503);
    final r = await verifierFor(ex.client).scan(paymentId: pid);
    final s = r.valueOrNull!;
    expect(s.provider, 'tonapi');
    // tonapi fixture: valid 0.5, jetton_notify (rejected), valid 0.3, aborted (rejected).
    expect(s.payments.map((p) => p.nanotons).toList(), [500000000, 300000000]);
    final tc = (await verifierFor(FakeExplorer(pid).client).scan(paymentId: pid)).valueOrNull!;
    expect(s.payments.map((p) => p.txHash).toList(), tc.payments.map((p) => p.txHash).toList());
    // 1 try + 3 retries on toncenter before falling back.
    expect(ex.calls.where((u) => u.host == 'toncenter.com'), hasLength(4));
  });

  test('both providers down → Err, never throws', () async {
    final ex = FakeExplorer(pid, toncenterStatus: 429, tonapiStatus: 500);
    final r = await verifierFor(ex.client).scan(paymentId: pid);
    expect(r, isA<Err<ScanResult>>());
  });

  test('network exceptions become Err', () async {
    final c = MockClient((_) async => throw http.ClientException('offline'));
    final r = await verifierFor(c).scan(paymentId: pid);
    expect(r.errorOrNull!.code, isNotNull);
  });

  test('garbage JSON is a badResponse Err', () async {
    final c = MockClient((_) async => http.Response('<html>', 200));
    final r = await verifierFor(c).scan(paymentId: pid);
    expect(r.errorOrNull!.code, BillingErrorCode.badResponse);
  });

  test('stops at the stored cursor', () async {
    final ex = FakeExplorer(pid);
    final s = (await verifierFor(ex.client).scan(paymentId: pid, stopAtLt: 8950)).valueOrNull!;
    expect(s.payments.map((p) => p.nanotons).toList(), [500000000]);
    expect(s.complete, isTrue);
  });

  test('pages with lt+hash on toncenter', () async {
    // Page size 2: first page has 2 txs, second request must carry lt/hash of the last one.
    final ex = FakeExplorer(pid);
    final v = PaymentVerifier(
      receiveAddress: receive,
      providers: [ToncenterProvider(JsonFetcher(ex.client, sleep: noSleep))],
      pageSize: 2,
    );
    final s = (await v.scan(paymentId: pid)).valueOrNull!;
    expect(ex.calls.length, 2);
    expect(ex.calls[1].queryParameters['lt'], isNotNull);
    expect(ex.calls[1].queryParameters['hash'], isNotNull);
    expect(s.complete, isTrue);
  });
}
