import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/secure_key_store.dart' show BillingKeys;
import 'package:kiro/billing/ton_verifier.dart';

import 'billing_test_utils.dart';

int ton(String t) => parseTonToNanotons(t)!;

Future<(BillingService, MemorySecureKeyStore, Directory)> _open({MemorySecureKeyStore? keys, Directory? dir}) async {
  final k = keys ?? MemorySecureKeyStore();
  final d = dir ?? await Directory.systemTemp.createTemp('kiro_feat');
  final ex = FakeExplorer(testPaymentId);
  final svc = (await BillingService.open(
    keys: k,
    dataDir: d,
    verifier: (addr) => PaymentVerifier.standard(receiveAddress: addr, client: ex.client, sleep: noSleep),
    rng: Random(11),
  ))
      .valueOrNull!;
  return (svc, k, d);
}

void main() {
  group('prices', () {
    final p = FeaturePricing();
    test('editor export by length', () {
      expect(p.priceFor(PaidFeature.editorExport, duration: const Duration(seconds: 1)), ton('0.2'));
      expect(p.priceFor(PaidFeature.editorExport, duration: const Duration(minutes: 1)), ton('0.2'));
      expect(p.priceFor(PaidFeature.editorExport, duration: const Duration(seconds: 61)), ton('0.5'));
      expect(p.priceFor(PaidFeature.editorExport, duration: const Duration(minutes: 5)), ton('0.5'));
      expect(p.priceFor(PaidFeature.editorExport, duration: const Duration(minutes: 10)), ton('1'));
      expect(p.priceFor(PaidFeature.editorExport, duration: const Duration(minutes: 25)), ton('1.5'));
      expect(p.priceFor(PaidFeature.editorExport, duration: Duration.zero), isNull);
    });
    test('images, AI text, and both video kinds', () {
      expect(p.priceFor(PaidFeature.image), ton('0.1'));
      expect(p.priceFor(PaidFeature.image, units: 3), ton('0.3'));
      expect(p.priceFor(PaidFeature.aiText), ton('0.02'));
      expect(p.priceFor(PaidFeature.topicVideo, duration: const Duration(seconds: 10)), ton('0.3'));
      expect(p.priceFor(PaidFeature.scenesVideo, duration: const Duration(seconds: 25)), ton('0.7'));
      expect(p.priceFor(PaidFeature.scenesVideo, duration: const Duration(minutes: 10)), ton('8'));
      expect(p.priceFor(PaidFeature.scenesVideo, duration: const Duration(minutes: 11)), isNull);
    });
    test('feature keys are stable', () {
      expect(PaidFeature.values.map((f) => f.key), ['topic_video', 'scenes_video', 'editor_export', 'image', 'ai_text']);
      for (final f in PaidFeature.values) {
        expect(PaidFeatureKey.fromKey(f.key), f);
      }
    });
  });

  group('first use free', () {
    test('the first use of each feature is free, the next is charged', () async {
      final (svc, _, _) = await _open();
      await svc.restoreFromRecoveryCode(testRecovery); // 0.8 TON
      for (final f in [PaidFeature.image, PaidFeature.aiText]) {
        expect(svc.isFirstUseFree(f), isTrue);
        final r = (await svc.reserveFeature(f)).valueOrNull!;
        expect(r.free, isTrue);
        expect(r.nanotons, 0);
        expect(svc.isFirstUseFree(f), isFalse, reason: 'reserved free use blocks a second free one');
        await svc.commit(r.id);
        expect(svc.isFirstUseFree(f), isFalse);
      }
      expect(svc.balance.available, ton('0.8'));
      final paid = (await svc.reserveFeature(PaidFeature.image)).valueOrNull!;
      expect(paid.free, isFalse);
      expect(paid.nanotons, ton('0.1'));
      await svc.commit(paid.id);
      expect(svc.balance.available, ton('0.7'));
      expect(svc.isFirstUseFree(PaidFeature.editorExport), isTrue, reason: 'features are counted separately');
    });

    test('a released free use is still available', () async {
      final (svc, _, _) = await _open();
      final r = (await svc.reserveFeature(PaidFeature.editorExport, duration: const Duration(seconds: 30))).valueOrNull!;
      expect(r.free, isTrue);
      await svc.release(r.id);
      expect(svc.isFirstUseFree(PaidFeature.editorExport), isTrue);
    });

    test('without credit, a used free use gives insufficientFunds; unsold lengths are refused', () async {
      final (svc, _, _) = await _open();
      final r = (await svc.reserveFeature(PaidFeature.aiText)).valueOrNull!;
      await svc.commit(r.id);
      expect((await svc.reserveFeature(PaidFeature.aiText)).errorOrNull?.code, BillingErrorCode.insufficientFunds);
      expect((await svc.reserveFeature(PaidFeature.topicVideo, duration: const Duration(minutes: 11))).errorOrNull?.code,
          BillingErrorCode.unsupportedDuration);
    });

    test('kept after reopening, after switching recovery code on the device, and from the ledger alone', () async {
      final (svc, keys, dir) = await _open();
      final r = (await svc.reserveFeature(PaidFeature.image)).valueOrNull!;
      await svc.commit(r.id);
      await svc.dispose();

      final (again, _, _) = await _open(keys: keys, dir: dir);
      expect(again.isFirstUseFree(PaidFeature.image), isFalse);
      // Another recovery code on the same device: still used (device record).
      await again.restoreFromRecoveryCode(testRecovery);
      expect(again.isFirstUseFree(PaidFeature.image), isFalse);
      await again.dispose();

      // Device record lost, ledger intact (same recovery code): still used.
      final (svc2, keys2, dir2) = await _open();
      final r2 = (await svc2.reserveFeature(PaidFeature.aiText)).valueOrNull!;
      await svc2.commit(r2.id);
      await svc2.dispose();
      await keys2.delete(BillingKeys.freeUsed(PaidFeature.aiText.key));
      final (svc3, _, _) = await _open(keys: keys2, dir: dir2);
      expect(svc3.isFirstUseFree(PaidFeature.aiText), isFalse);
    });

    test('an open free reservation from a crash is released on start (still free)', () async {
      final (svc, keys, dir) = await _open();
      final r = (await svc.reserveFeature(PaidFeature.image)).valueOrNull!;
      expect(r.free, isTrue);
      await svc.dispose();
      final (again, _, _) = await _open(keys: keys, dir: dir);
      expect(again.isFirstUseFree(PaidFeature.image), isTrue);
    });
  });

  group('paid gate', () {
    test('owner: everything free, nothing reserved, even without billing', () async {
      final gate = PaidGate(owner: await unlockedOwner());
      final q = gate.quote(PaidFeature.editorExport, duration: const Duration(minutes: 3));
      expect(q.free, FreeReason.owner);
      expect(q.charge, 0);
      expect(q.available, isTrue);
      final c = (await gate.begin(PaidFeature.topicVideo, duration: const Duration(minutes: 10))).valueOrNull!;
      expect(c.free, FreeReason.owner);
      expect(c.reservation, isNull);
      await gate.commit(c);
      await gate.release(c);
    });

    test('no billing and no owner: unavailable, never throws', () async {
      final gate = PaidGate();
      expect(gate.usable, isFalse);
      expect(gate.quote(PaidFeature.image).available, isFalse);
      expect((await gate.begin(PaidFeature.image)).errorOrNull?.code, BillingErrorCode.unavailable);
      await expectLater(gate.run(PaidFeature.image, () async => 1), throwsA(isA<PaidGateException>()));
    });

    test('run commits on success and releases on failure', () async {
      final (svc, _, _) = await _open();
      await svc.restoreFromRecoveryCode(testRecovery);
      final gate = PaidGate(billing: svc);
      expect(gate.quote(PaidFeature.image).free, FreeReason.firstUse);
      await expectLater(gate.run(PaidFeature.image, () async => throw StateError('x')), throwsStateError);
      expect(gate.quote(PaidFeature.image).free, FreeReason.firstUse);
      expect(await gate.run(PaidFeature.image, () async => 'ok'), 'ok');
      expect(gate.quote(PaidFeature.image).free, FreeReason.none);
      expect(gate.quote(PaidFeature.image).charge, ton('0.1'));
      await gate.run(PaidFeature.image, () async => 'ok');
      expect(svc.balance.spent, ton('0.1'));
      expect(svc.balance.reserved, 0);
    });
  });
  group("AI text through the user's own API key", () {
    test('quote: free, no price, no charge; on-device stays 0.02', () async {
      final (svc, _, _) = await _open();
      await svc.restoreFromRecoveryCode(testRecovery);
      final gate = PaidGate(billing: svc);
      final own = gate.quoteAiText(ownApiKey: true);
      expect(own.free, FreeReason.ownApiKey);
      expect(own.charge, 0);
      expect(own.listPrice, isNull);
      expect(own.sold, isTrue);
      expect(own.available, isTrue);
      final local = gate.quoteAiText(ownApiKey: false);
      expect(local.listPrice, ton('0.02'));
      expect(local.free, FreeReason.firstUse);
    });

    test('begin: nothing reserved and first use not consumed', () async {
      final (svc, _, _) = await _open();
      await svc.restoreFromRecoveryCode(testRecovery);
      final gate = PaidGate(billing: svc);
      for (var i = 0; i < 3; i++) {
        final c = (await gate.beginAiText(ownApiKey: true)).valueOrNull!;
        expect(c.free, FreeReason.ownApiKey);
        expect(c.reservation, isNull);
        expect(c.nanotons, 0);
        await gate.commit(c);
      }
      expect(svc.balance.spent, 0);
      expect(svc.balance.reserved, 0);
      expect(svc.isFirstUseFree(PaidFeature.aiText), isTrue);
      final local = (await gate.beginAiText(ownApiKey: false)).valueOrNull!;
      expect(local.free, FreeReason.firstUse);
      expect(local.reservation, isNotNull);
      await gate.release(local);
    });

    test('works even when billing is unavailable', () async {
      final gate = PaidGate();
      expect(gate.quoteAiText(ownApiKey: true).available, isTrue);
      expect((await gate.beginAiText(ownApiKey: true)).valueOrNull?.free, FreeReason.ownApiKey);
      expect((await gate.beginAiText(ownApiKey: false)).errorOrNull?.code, BillingErrorCode.unavailable);
    });
  });
}
