import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kiro/billing/billing.dart';
import 'package:kiro/billing/payment_id.dart';

const testRecovery = 'ABCD-EFGH-JKMN-PQRS';

String get testPaymentId => RecoveryCode.tryParse(testRecovery)!.paymentId;

/// Loads a fixture and fills the comment placeholders for [paymentId].
String loadFixture(String name, String paymentId) {
  final raw = File('test/billing/fixtures/$name').readAsStringSync();
  final comment = paymentComment(paymentId);
  String b64(String s) => base64.encode(utf8.encode(s));
  return raw
      .replaceAll('{{PID_B64}}', b64(comment))
      .replaceAll('{{UPPER_B64}}', b64(comment.toUpperCase()))
      .replaceAll('{{UPPER}}', comment.toUpperCase())
      .replaceAll('{{OTHER_B64}}', b64('kiro-ZZZZZZZZ'))
      .replaceAll('{{SPACE_B64}}', b64('$comment '))
      .replaceAll('{{COMMENT}}', comment);
}

/// A fake explorer: toncenter and tonapi each serve one page (the second request for an older
/// page returns an empty list). [toncenterStatus] lets a test force a failure.
class FakeExplorer {
  FakeExplorer(this.paymentId, {this.toncenterStatus = 200, this.tonapiStatus = 200});
  final String paymentId;
  int toncenterStatus;
  int tonapiStatus;
  final List<Uri> calls = [];
  String? toncenterOverride;

  http.Client get client => MockClient((req) async {
        calls.add(req.url);
        if (req.url.host == 'toncenter.com') {
          if (toncenterStatus != 200) return http.Response('{"ok":false,"code":$toncenterStatus}', toncenterStatus);
          if (req.url.queryParameters.containsKey('lt')) return http.Response('{"ok":true,"result":[]}', 200);
          return http.Response(toncenterOverride ?? loadFixture('toncenter_page.json', paymentId), 200);
        }
        if (req.url.host == 'tonapi.io') {
          if (tonapiStatus != 200) return http.Response('{}', tonapiStatus);
          if (req.url.queryParameters.containsKey('before_lt')) return http.Response('{"transactions":[]}', 200);
          return http.Response(loadFixture('tonapi_page.json', paymentId), 200);
        }
        return http.Response('not found', 404);
      });
}

Future<void> noSleep(Duration _) async {}

/// A test-only owner code with a cheap hash (the real one is never in the repo).
const testOwnerCode = 'TEST00-OWNER0-CODE00-KIR000-ABCDEF';

OwnerHash testOwnerHash({int iterations = 1000}) => OwnerHash.derive(testOwnerCode, List<int>.generate(16, (i) => i * 7), iterations);

/// An owner state that is already unlocked (every paid feature free).
Future<OwnerAccess> unlockedOwner([SecureKeyStore? keys]) async {
  final o = OwnerAccess(keys ?? MemorySecureKeyStore(), hash: testOwnerHash());
  await o.unlock(testOwnerCode);
  return o;
}
