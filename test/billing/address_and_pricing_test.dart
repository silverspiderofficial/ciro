import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/billing_config.dart';
import 'package:kiro/billing/nanoton.dart';
import 'package:kiro/billing/payment_id.dart';
import 'package:kiro/billing/payment_links.dart';
import 'package:kiro/billing/price_table.dart';
import 'package:kiro/billing/ton_address.dart';

const receive = 'UQAFkuk0FEYPDTiu_d-Hz8ynT5VDFpmR9REXbkOxICwnWZO8';

void main() {
  group('TON address', () {
    test('receive address passes checksum and decodes', () {
      final a = TonAddress.tryParse(receive);
      expect(a, isNotNull);
      expect(a!.workchain, 0);
      expect(a.bounceable, isFalse);
      expect(a.testnet, isFalse);
      expect(a.raw, '0:0592e93414460f0d38aefddf87cfcca74f9543169991f511176e43b1202c2759');
    });

    test('tampered address fails', () {
      // One character of the account hash changed: CRC no longer matches.
      final tampered = '${receive.substring(0, 10)}${receive[10] == 'A' ? 'B' : 'A'}${receive.substring(11)}';
      expect(TonAddress.isValid(tampered), isFalse);
      // Checksum bytes changed.
      expect(TonAddress.isValid('${receive.substring(0, 46)}AA'), isFalse);
      expect(TonAddress.isValid(receive.substring(1)), isFalse);
      expect(TonAddress.isValid(''), isFalse);
    });

    test('bounceable and raw forms are the same account', () {
      expect(TonAddress.sameAccount(receive, '0:0592e93414460f0d38aefddf87cfcca74f9543169991f511176e43b1202c2759'), isTrue);
      expect(TonAddress.sameAccount(receive, '0:${'11' * 32}'), isFalse);
    });

    test('built-in address passes the runtime integrity check', () {
      final c = checkReceiveAddress();
      expect(c.ok, isTrue);
      expect(c.address, receive);
    });

    test('patched built-in address is detected', () {
      // A valid-looking but different address (dummy) swapped into the masked bytes.
      const other = 'UQAFkuk0FEYPDTiu_d-Hz8ynT5VDFpmR9REXbkOxICwnWZO9';
      final c = checkReceiveAddress(maskedOverride: maskAddressForTest(other));
      expect(c.ok, isFalse);
      expect(c.reason, 'digest');
    });
  });

  group('nanotons', () {
    test('parses decimals exactly', () {
      expect(parseTonToNanotons('0.3'), 300000000);
      expect(parseTonToNanotons('1.2'), 1200000000);
      expect(parseTonToNanotons('4.5'), 4500000000);
      expect(parseTonToNanotons('8'), 8000000000);
      expect(parseTonToNanotons('.5'), 500000000);
      expect(parseTonToNanotons('0.000000001'), 1);
      expect(parseTonToNanotons('۰٫۷'), 700000000);
      // 0.1 + 0.2 style float traps do not exist here.
      expect(parseTonToNanotons('0.1')! + parseTonToNanotons('0.2')!, parseTonToNanotons('0.3'));
    });

    test('rejects bad input', () {
      for (final s in ['', '.', '-1', '1e9', '0.0000000001', 'abc', '1.2.3', '1,000', ' ', '+1']) {
        expect(parseTonToNanotons(s), isNull, reason: s);
      }
    });

    test('formats', () {
      expect(formatNanotons(300000000), '0.3');
      expect(formatNanotons(8000000000), '8');
      expect(formatNanotons(1), '0.000000001');
    });
  });

  group('price table', () {
    final t = PriceTable.standard();

    test('standard tiers', () {
      expect(t.priceFor(const Duration(seconds: 10)), 300000000);
      expect(t.priceFor(const Duration(seconds: 20)), 500000000);
      expect(t.priceFor(const Duration(seconds: 30)), 700000000);
      expect(t.priceFor(const Duration(seconds: 60)), 1200000000);
      expect(t.priceFor(const Duration(minutes: 3)), 3000000000);
      expect(t.priceFor(const Duration(minutes: 5)), 4500000000);
      expect(t.priceFor(const Duration(minutes: 10)), 8000000000);
    });

    test('in-between durations round up to the next tier; out of range is null', () {
      expect(t.priceFor(const Duration(seconds: 15)), 500000000);
      expect(t.priceFor(const Duration(seconds: 61)), 3000000000);
      expect(t.priceFor(const Duration(minutes: 11)), isNull);
      expect(t.priceFor(Duration.zero), isNull);
    });

    test('segment counts', () {
      expect(segmentCount(const Duration(seconds: 10)), 1);
      expect(segmentCount(const Duration(seconds: 11)), 2);
      expect(segmentCount(const Duration(minutes: 3)), 18);
      expect(segmentCount(const Duration(minutes: 10)), 60);
      expect(t.tierFor(const Duration(minutes: 5))!.segments, 30);
    });

    test('rejects bad configs', () {
      expect(() => PriceTable(const []), throwsArgumentError);
      expect(
        () => PriceTable([PriceTier.ton(const Duration(seconds: 10), '1'), PriceTier.ton(const Duration(seconds: 20), '0.5')]),
        throwsArgumentError,
      );
      expect(() => PriceTier.ton(const Duration(seconds: 10), '0.1.1'), throwsArgumentError);
    });
  });

  group('payment id and links', () {
    test('recovery code parses, normalizes and derives a stable 8-char id', () {
      final c = RecoveryCode.tryParse('abcd efgh-jkmn-pqrs')!;
      expect(c.display, 'ABCD-EFGH-JKMN-PQRS');
      expect(c.paymentId, hasLength(8));
      expect(RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$').hasMatch(c.paymentId), isTrue);
      expect(RecoveryCode.tryParse('ABCD-EFGH-JKMN-PQRS')!.paymentId, c.paymentId);
      expect(RecoveryCode.tryParse('ABCD-EFGH-JKMN-PQR'), isNull);
      expect(RecoveryCode.tryParse('ABCD-EFGH-JKMN-PQR!'), isNull);
      // Crockford aliases: O→0, I/L→1.
      expect(RecoveryCode.tryParse('OOOO-IIII-LLLL-0000')!.value, '0000111111110000');
    });

    test('generated codes are well formed and differ', () {
      final a = RecoveryCode.generate();
      final b = RecoveryCode.generate();
      expect(a.value, hasLength(16));
      expect(a, isNot(b));
      expect(RecoveryCode.tryParse(a.display), a);
    });

    test('links use exact nanotons and the exact comment', () {
      final l = buildPaymentLinks(receiveAddress: receive, paymentId: 'ABCDEFGH', nanotons: parseTonToNanotons('0.7')!);
      expect(l.tonUri, 'ton://transfer/$receive?amount=700000000&text=kiro-ABCDEFGH');
      expect(l.httpsUri, 'https://app.tonkeeper.com/transfer/$receive?amount=700000000&text=kiro-ABCDEFGH');
      expect(l.qrData, l.tonUri);
      expect(l.tonText, '0.7');
      expect(() => buildPaymentLinks(receiveAddress: receive, paymentId: 'X', nanotons: 0), throwsArgumentError);
    });

    test('notices are present', () {
      expect(paymentNoticeFa, contains('TON'));
      expect(paymentNoticeEn, contains('Toncoin'));
    });
  });
}
