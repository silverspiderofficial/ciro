import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing_result.dart';
import 'package:kiro/billing/ledger.dart';
import 'package:kiro/billing/secure_key_store.dart';
import 'package:kiro/billing/ton_verifier.dart';

const pid = 'TESTPID1';
final key = List<int>.generate(32, (i) => i);

IncomingPayment pay(int i, int n, {int lt = 1000, int ut = 1762600000}) =>
    IncomingPayment(txHash: (i.toRadixString(16).padLeft(2, '0')) * 32, lt: lt + i, utime: ut + i, nanotons: n);

void main() {
  late Directory dir;
  late MemorySecureKeyStore keys;
  var clock = DateTime.utc(2026, 11, 8, 12);

  Future<Ledger> openL() => Ledger.open(dir: dir, paymentId: pid, keys: keys, masterKey: key, now: () => clock, rng: Random(1));
  File ledgerFile() => File('${dir.path}/${Ledger.fileNameFor(pid)}');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kiro_billing_');
    keys = MemorySecureKeyStore();
    clock = DateTime.utc(2026, 11, 8, 12);
  });
  tearDown(() async => dir.delete(recursive: true));

  test('credits are deduped and persisted encrypted', () async {
    final l = await openL();
    expect((await l.addCredits([pay(1, 500), pay(1, 500), pay(2, 300)], cursorLt: 2000)).valueOrNull, 2);
    expect((await l.addCredits([pay(1, 500)])).valueOrNull, 0);
    expect(l.balance.credited, 800);
    expect(l.cursorLt, 2000);
    final text = await ledgerFile().readAsString();
    expect(text.contains('credit'), isFalse, reason: 'records must not be plaintext');
    final l2 = await openL();
    expect(l2.balance.credited, 800);
    expect(l2.tampered, isFalse);
  });

  test('reserve → commit spends; reserve → release refunds; insufficient funds', () async {
    final l = await openL();
    await l.addCredits([pay(1, 1000)]);
    final r1 = (await l.reserve(700, const Duration(seconds: 30))).valueOrNull!;
    expect(l.balance.available, 300);
    expect(await l.reserve(400, const Duration(seconds: 10)), isA<Err<Reservation>>());
    expect((await l.commit(r1.id)).isOk, isTrue);
    expect(l.balance.spent, 700);
    expect(l.balance.available, 300);
    expect((await l.commit(r1.id)).errorOrNull!.code, BillingErrorCode.unknownReservation);
    final r2 = (await l.reserve(300, const Duration(seconds: 10))).valueOrNull!;
    expect(l.balance.available, 0);
    await l.release(r2.id);
    expect(l.balance.available, 300);
    final l2 = await openL();
    expect(l2.balance.spent, 700);
    expect(l2.balance.available, 300);
  });

  test('crash recovery: open reservations are released on startup reconcile', () async {
    final l = await openL();
    await l.addCredits([pay(1, 1000)]);
    await l.reserve(500, const Duration(seconds: 20));
    // Simulate a crash: drop the object, reopen.
    final l2 = await openL();
    expect(l2.openReservations, hasLength(1));
    expect(l2.balance.available, 500);
    expect((await l2.reconcile()).valueOrNull, 1);
    expect(l2.balance.available, 1000);
    expect((await openL()).openReservations, isEmpty);
  });

  test('crash between file rename and head write is accepted', () async {
    final l = await openL();
    await l.addCredits([pay(1, 1000)]);
    final head = await keys.read(BillingKeys.ledgerHead(pid));
    await l.addCredits([pay(2, 100)]);
    await keys.write(BillingKeys.ledgerHead(pid), head!); // head one record behind
    final l2 = await openL();
    expect(l2.tampered, isFalse);
    expect(l2.balance.credited, 1100);
  });

  group('tamper detection', () {
    Future<Ledger> spentLedger() async {
      final l = await openL();
      await l.addCredits([pay(1, 1000)]);
      final r = (await l.reserve(700, const Duration(seconds: 30))).valueOrNull!;
      await l.commit(r.id);
      return l;
    }

    Future<void> expectTampered(Ledger l) async {
      expect(l.detectedTamperOnOpen, isTrue);
      expect(l.tampered, isTrue);
      expect(l.balance.available, 0);
      // Lenient: the ledger is rebuilt from the chain and the user is never locked out.
      await l.addCredits([pay(1, 1000)]);
      expect(l.balance.credited, 1000);
      expect(l.balance.forfeited, 0);
      expect(l.balance.available, 1000);
      expect((await l.reserve(300, const Duration(seconds: 10))).isOk, isTrue);
    }

    test('flipping a byte in a record', () async {
      await spentLedger();
      final lines = (await ledgerFile().readAsString()).trim().split('\n');
      final b = base64.decode(lines.last);
      b[20] ^= 1;
      lines[lines.length - 1] = base64.encode(b);
      await ledgerFile().writeAsString('${lines.join('\n')}\n');
      await expectTampered(await openL());
      expect(dir.listSync().any((e) => e.path.contains('.tampered-')), isTrue);
    });

    test('deleting the spend records (truncation)', () async {
      await spentLedger();
      final lines = (await ledgerFile().readAsString()).trim().split('\n');
      await ledgerFile().writeAsString('${lines.sublist(0, lines.length - 2).join('\n')}\n');
      await expectTampered(await openL());
    });

    test('restoring an older copy of the file (rollback)', () async {
      final l = await openL();
      await l.addCredits([pay(1, 1000)]);
      final old = await ledgerFile().readAsString();
      final r = (await l.reserve(700, const Duration(seconds: 30))).valueOrNull!;
      await l.commit(r.id);
      await l.addCredits([pay(2, 1)]);
      await ledgerFile().writeAsString(old);
      await expectTampered(await openL());
    });

    test('deleting the file while the head remains', () async {
      await spentLedger();
      await ledgerFile().delete();
      await expectTampered(await openL());
    });

    test('removing the tamper marker after an event is detected again', () async {
      await spentLedger();
      await ledgerFile().writeAsString('garbage\n');
      await openL(); // tamper #1
      await ledgerFile().delete();
      await keys.delete(BillingKeys.ledgerHead(pid));
      final l = await openL();
      expect(l.tampered, isTrue, reason: 'tamper marker in the key store survives');
    });

    test('a different key cannot read the ledger', () async {
      await spentLedger();
      final l = await Ledger.open(dir: dir, paymentId: pid, keys: keys, masterKey: List<int>.filled(32, 9), now: () => clock);
      expect(l.detectedTamperOnOpen, isTrue);
    });

    test('payments before and after a tamper event stay spendable', () async {
      await spentLedger();
      await ledgerFile().writeAsString('garbage\n');
      clock = clock.add(const Duration(hours: 1));
      final l = await openL();
      await l.addCredits([pay(1, 1000)], cursorLt: 1001);
      await l.setTamperBoundary(1001);
      // New payment: later lt and later utime than the event.
      await l.addCredits([pay(50, 600, lt: 5000, ut: clock.millisecondsSinceEpoch ~/ 1000 + 60)]);
      expect(l.balance.available, 1600);
      expect((await l.reserve(300, const Duration(seconds: 10))).isOk, isTrue);
    });
  });

  test('concurrent operations are serialized', () async {
    final l = await openL();
    await l.addCredits([pay(1, 1000)]);
    final rs = await Future.wait([for (var i = 0; i < 5; i++) l.reserve(300, const Duration(seconds: 10))]);
    expect(rs.where((r) => r.isOk), hasLength(3));
    expect(l.balance.available, 100);
    final l2 = await openL();
    expect(l2.openReservations, hasLength(3));
    expect(l2.tampered, isFalse);
  });
}
