import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/secure_key_store.dart' show BillingKeys;

import 'billing_test_utils.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('PBKDF2-HMAC-SHA256 matches the published test vectors', () {
    expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 1)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 2)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
    expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 4096)),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
  });

  test('the built-in owner hash: 16-byte salt, 32-byte hash, at least 200k iterations, no code in the app', () {
    final h = OwnerHash.builtIn();
    expect(h.salt, hasLength(16));
    expect(h.hash, hasLength(32));
    expect(h.iterations, greaterThanOrEqualTo(200000));
  });

  test('owner codes are normalized (case, hyphens, spaces, Persian digits, O/I/L)', () {
    expect(normalizeOwnerCode(testOwnerCode.toLowerCase()), normalizeOwnerCode(testOwnerCode));
    expect(normalizeOwnerCode(testOwnerCode.replaceAll('-', ' ')), normalizeOwnerCode(testOwnerCode));
    expect(normalizeOwnerCode('۱۲۳۴۵۶${'A' * 24}'), '123456${'A' * 24}');
    expect(normalizeOwnerCode('short'), isNull);
    expect(normalizeOwnerCode('${'A' * 29}U'), isNull); // U is not in the alphabet
  });

  test('the correct code unlocks; the state survives a restart', () async {
    final keys = MemorySecureKeyStore();
    final o = OwnerAccess(keys, hash: testOwnerHash());
    await o.load();
    expect(o.unlocked, isFalse);
    expect(await o.unlock(testOwnerCode.toLowerCase()), isTrue);
    expect(o.unlocked, isTrue);
    expect(keys.data[BillingKeys.ownerToken], isNotNull);
    expect(keys.data.values.join(), isNot(contains(normalizeOwnerCode(testOwnerCode))), reason: 'the code itself is never stored');

    final restarted = OwnerAccess(keys, hash: testOwnerHash());
    await restarted.load();
    expect(restarted.unlocked, isTrue);
  });

  test('a wrong or malformed code is rejected', () async {
    final o = OwnerAccess(MemorySecureKeyStore(), hash: testOwnerHash());
    expect(await o.unlock('TEST00-OWNER0-CODE00-KIR000-ABCDEG'), isFalse);
    expect(await o.unlock(''), isFalse);
    expect(await o.unlock('not a code'), isFalse);
    expect(o.unlocked, isFalse);
  });

  test('a copied or forged token does not unlock (bound to the device key and the hash)', () async {
    final keys = MemorySecureKeyStore();
    await (OwnerAccess(keys, hash: testOwnerHash())).unlock(testOwnerCode);
    final token = keys.data[BillingKeys.ownerToken]!;
    final other = MemorySecureKeyStore()..data[BillingKeys.ownerToken] = token;
    final o = OwnerAccess(other, hash: testOwnerHash());
    await o.load();
    expect(o.unlocked, isFalse);
    final forged = MemorySecureKeyStore()..data[BillingKeys.ownerToken] = 'true';
    final f = OwnerAccess(forged, hash: testOwnerHash());
    await f.load();
    expect(f.unlocked, isFalse);
  });

  test('a wrong code against the built-in hash is rejected, and checking it does not block the UI isolate', () async {
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
    final sw = Stopwatch()..start();
    final ok = await verifyOwnerCode('ZZZZZZ-ZZZZZZ-ZZZZZZ-ZZZZZZ-ZZZZZZ');
    sw.stop();
    timer.cancel();
    expect(ok, isFalse);
    // The main isolate kept running its timer while the 200k-iteration hash ran elsewhere.
    expect(sw.elapsedMilliseconds, greaterThan(50));
    expect(ticks, greaterThanOrEqualTo(sw.elapsedMilliseconds ~/ 40));
  });

  test('the gate makes every feature free once the owner unlocked', () async {
    final keys = MemorySecureKeyStore();
    final owner = OwnerAccess(keys, hash: testOwnerHash());
    final gate = PaidGate(owner: owner);
    expect(gate.usable, isFalse);
    await owner.unlock(testOwnerCode);
    for (final f in PaidFeature.values) {
      expect(gate.quote(f, duration: const Duration(seconds: 30)).free, FreeReason.owner);
    }
  });
}
