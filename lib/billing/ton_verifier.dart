/// Serverless payment verification: reads the receive address's transaction history from
/// public explorer APIs (toncenter v2, tonapi.io as fallback) and returns the incoming native
/// TON transfers whose text comment equals `kiro-<paymentId>` exactly.
///
/// Rejected: external messages, bounced messages, zero-value messages, any message whose body
/// is not a plain text comment (jetton transfer notifications, NFT, encrypted comments, raw
/// payloads), comments that differ in any way (case, whitespace, suffix), and transactions to
/// a different account.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HttpException;

import 'package:http/http.dart' as http;

import 'billing_config.dart';
import 'billing_result.dart';
import 'nanoton.dart';
import 'ton_address.dart';

/// One transaction of the receive account, normalized across providers.
class ChainTx {
  const ChainTx({
    required this.hashHex,
    required this.lt,
    required this.utime,
    required this.isInternal,
    required this.bounced,
    required this.aborted,
    required this.nanotons,
    required this.textComment,
    required this.destination,
    this.rawHash,
  });

  /// Transaction hash, lowercase hex (64 chars). Same value from every provider, so it is the
  /// dedupe key.
  final String hashHex;
  final int lt;
  final int utime;
  final bool isInternal;
  final bool bounced;
  final bool aborted;

  /// Value carried by the inbound message (0 when none).
  final int nanotons;

  /// Set only when the inbound body is a plain text comment (op 0); null otherwise.
  final String? textComment;
  final String? destination;

  /// Provider-native hash (toncenter: base64) for paging.
  final String? rawHash;
}

/// An accepted payment.
class IncomingPayment {
  const IncomingPayment({required this.txHash, required this.lt, required this.utime, required this.nanotons});
  final String txHash;
  final int lt;
  final int utime;
  final int nanotons;
}

/// Pure acceptance rule shared by all providers.
bool acceptsPayment(ChainTx tx, {required String expectedComment, required String receiveAddress}) {
  if (!tx.isInternal || tx.bounced || tx.aborted) return false;
  if (tx.nanotons <= 0) return false;
  if (tx.textComment == null || tx.textComment != expectedComment) return false;
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(tx.hashHex)) return false;
  final dest = tx.destination;
  if (dest != null && dest.isNotEmpty && !TonAddress.sameAccount(dest, receiveAddress)) return false;
  return true;
}

class TxPage {
  const TxPage(this.txs, {required this.hasMore});
  final List<ChainTx> txs;
  final bool hasMore;
}

/// A source of the receive account's transactions, newest first.
abstract class TxProvider {
  String get name;

  /// Returns up to [limit] transactions strictly older than [before] (or the newest when null).
  Future<BillingResult<TxPage>> page({required String address, ChainTx? before, int limit = 50});
}

typedef Sleep = Future<void> Function(Duration);

/// HTTP GET returning decoded JSON with timeout + retries (network errors, 429, 5xx) and
/// exponential backoff. Never throws.
class JsonFetcher {
  JsonFetcher(this.client, {this.timeout = const Duration(seconds: 15), this.retries = 3, Sleep? sleep, this.headers = const {}})
      : sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final http.Client client;
  final Duration timeout;
  final int retries;
  final Sleep sleep;
  final Map<String, String> headers;

  Future<BillingResult<Object?>> get(Uri uri) async {
    BillingError last = const BillingError(BillingErrorCode.network);
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) await sleep(Duration(milliseconds: 1000 * (1 << (attempt - 1))));
      try {
        final res = await client.get(uri, headers: {'Accept': 'application/json', ...headers}).timeout(timeout);
        if (res.statusCode == 429) {
          last = const BillingError(BillingErrorCode.rateLimited, '429');
          continue;
        }
        if (res.statusCode >= 500) {
          last = BillingError(BillingErrorCode.network, 'http ${res.statusCode}');
          continue;
        }
        if (res.statusCode != 200) {
          return Err(BillingError(BillingErrorCode.badResponse, 'http ${res.statusCode}'));
        }
        try {
          return Ok(jsonDecode(utf8.decode(res.bodyBytes)));
        } on FormatException {
          return const Err(BillingError(BillingErrorCode.badResponse, 'json'));
        }
      } on TimeoutException {
        last = const BillingError(BillingErrorCode.network, 'timeout');
      } on SocketException {
        last = const BillingError(BillingErrorCode.network, 'socket');
      } on HttpException {
        last = const BillingError(BillingErrorCode.network, 'http');
      } on http.ClientException {
        last = const BillingError(BillingErrorCode.network, 'client');
      } on Object {
        last = const BillingError(BillingErrorCode.network, 'unknown');
      }
    }
    return Err(last);
  }
}

String? _b64ToHex(String? b64) {
  if (b64 == null) return null;
  try {
    final bytes = base64.decode(base64.normalize(b64.replaceAll('-', '+').replaceAll('_', '/')));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  } on FormatException {
    return null;
  }
}

/// toncenter.com API v2 `getTransactions`.
class ToncenterProvider implements TxProvider {
  ToncenterProvider(this.fetcher, {this.baseUrl = toncenterBase});
  final JsonFetcher fetcher;
  final String baseUrl;

  @override
  String get name => 'toncenter';

  @override
  Future<BillingResult<TxPage>> page({required String address, ChainTx? before, int limit = 50}) async {
    final q = <String, String>{'address': address, 'limit': '${before == null ? limit : limit + 1}', 'archival': 'true'};
    if (before != null && before.rawHash != null) {
      q['lt'] = '${before.lt}';
      q['hash'] = before.rawHash!;
    }
    final r = await fetcher.get(Uri.parse('$baseUrl/getTransactions').replace(queryParameters: q));
    switch (r) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        if (value is! Map<String, Object?>) return const Err(BillingError(BillingErrorCode.badResponse, 'shape'));
        if (value['ok'] != true) {
          final code = value['code'];
          return Err(BillingError(code == 429 ? BillingErrorCode.rateLimited : BillingErrorCode.badResponse, 'ok=false'));
        }
        final list = value['result'];
        if (list is! List<Object?>) return const Err(BillingError(BillingErrorCode.badResponse, 'result'));
        final txs = <ChainTx>[];
        for (final item in list) {
          final tx = item is Map<String, Object?> ? parseToncenterTx(item) : null;
          if (tx == null) continue;
          if (before != null && tx.lt >= before.lt) continue; // the paging cursor is inclusive
          txs.add(tx);
        }
        return Ok(TxPage(txs, hasMore: list.length >= (before == null ? limit : limit + 1)));
    }
  }

  /// Parses one `raw.transaction`. Returns null when the item is malformed.
  static ChainTx? parseToncenterTx(Map<String, Object?> t) {
    final id = t['transaction_id'];
    if (id is! Map<String, Object?>) return null;
    final lt = int.tryParse('${id['lt']}');
    final rawHash = id['hash'];
    final hex = _b64ToHex(rawHash is String ? rawHash : null);
    if (lt == null || hex == null || hex.length != 64) return null;
    final utime = t['utime'] is int ? t['utime']! as int : 0;
    final inMsg = t['in_msg'];
    if (inMsg is! Map<String, Object?>) {
      return ChainTx(
          hashHex: hex, lt: lt, utime: utime, isInternal: false, bounced: false, aborted: false, nanotons: 0, textComment: null, destination: null, rawHash: rawHash as String);
    }
    final source = inMsg['source'];
    final internal = source is String && source.isNotEmpty;
    final value = parseNanotonValue(inMsg['value']) ?? 0;
    String? comment;
    final data = inMsg['msg_data'];
    if (data is Map<String, Object?> && data['@type'] == 'msg.dataText') {
      final text = data['text'];
      if (text is String) {
        try {
          comment = utf8.decode(base64.decode(base64.normalize(text)));
        } on FormatException {
          final m = inMsg['message'];
          comment = m is String ? m : null;
        }
      }
    }
    final dest = inMsg['destination'];
    return ChainTx(
      hashHex: hex,
      lt: lt,
      utime: utime,
      isInternal: internal,
      bounced: inMsg['bounced'] == true,
      aborted: false,
      nanotons: value,
      textComment: comment,
      destination: dest is String ? dest : null,
      rawHash: rawHash as String,
    );
  }
}

/// tonapi.io `GET /v2/blockchain/accounts/{id}/transactions` (fallback).
class TonapiProvider implements TxProvider {
  TonapiProvider(this.fetcher, {this.baseUrl = tonapiBase});
  final JsonFetcher fetcher;
  final String baseUrl;

  @override
  String get name => 'tonapi';

  @override
  Future<BillingResult<TxPage>> page({required String address, ChainTx? before, int limit = 50}) async {
    final q = <String, String>{'limit': '$limit', 'sort_order': 'desc'};
    if (before != null) q['before_lt'] = '${before.lt}';
    final uri = Uri.parse('$baseUrl/blockchain/accounts/${Uri.encodeComponent(address)}/transactions').replace(queryParameters: q);
    final r = await fetcher.get(uri);
    switch (r) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        if (value is! Map<String, Object?>) return const Err(BillingError(BillingErrorCode.badResponse, 'shape'));
        final list = value['transactions'];
        if (list is! List<Object?>) return const Err(BillingError(BillingErrorCode.badResponse, 'transactions'));
        final txs = <ChainTx>[];
        for (final item in list) {
          final tx = item is Map<String, Object?> ? parseTonapiTx(item) : null;
          if (tx != null && (before == null || tx.lt < before.lt)) txs.add(tx);
        }
        return Ok(TxPage(txs, hasMore: list.length >= limit));
    }
  }

  static ChainTx? parseTonapiTx(Map<String, Object?> t) {
    final hash = t['hash'];
    final lt = int.tryParse('${t['lt']}');
    if (hash is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash) || lt == null) return null;
    final utime = t['utime'] is int ? t['utime']! as int : 0;
    final aborted = t['aborted'] == true;
    final inMsg = t['in_msg'];
    if (inMsg is! Map<String, Object?>) {
      return ChainTx(
          hashHex: hash.toLowerCase(), lt: lt, utime: utime, isInternal: false, bounced: false, aborted: aborted, nanotons: 0, textComment: null, destination: null);
    }
    final internal = inMsg['msg_type'] == 'int_msg';
    String? comment;
    if (inMsg['decoded_op_name'] == 'text_comment') {
      final body = inMsg['decoded_body'];
      if (body is Map<String, Object?> && body['text'] is String) comment = body['text']! as String;
    }
    final dest = inMsg['destination'];
    return ChainTx(
      hashHex: hash.toLowerCase(),
      lt: lt,
      utime: utime,
      isInternal: internal,
      bounced: inMsg['bounced'] == true,
      aborted: aborted,
      nanotons: parseNanotonValue(inMsg['value']) ?? 0,
      textComment: comment,
      destination: dest is Map<String, Object?> && dest['address'] is String ? dest['address']! as String : null,
    );
  }
}

class ScanResult {
  const ScanResult({required this.payments, required this.newestLt, required this.complete, required this.provider});

  /// Accepted payments, deduped by tx hash.
  final List<IncomingPayment> payments;

  /// Newest lt seen in this scan (store it as the next scan's stop point), or null when the
  /// account had no transactions.
  final int? newestLt;

  /// True when the scan reached [PaymentVerifier.scan]'s stop point or the start of history.
  final bool complete;
  final String provider;
}

/// Pages through history with the primary provider and falls back to the next one when a
/// page fails after its retries.
class PaymentVerifier {
  PaymentVerifier({required this.receiveAddress, required this.providers, this.pageSize = 50, this.maxPages = 40});

  factory PaymentVerifier.standard({required String receiveAddress, required http.Client client, Sleep? sleep}) {
    final f = JsonFetcher(client, sleep: sleep);
    return PaymentVerifier(receiveAddress: receiveAddress, providers: [ToncenterProvider(f), TonapiProvider(f)]);
  }

  final String receiveAddress;
  final List<TxProvider> providers;
  final int pageSize;
  final int maxPages;

  /// Scans newest → older until a tx with lt <= [stopAtLt], a tx older than [notBeforeUtime],
  /// the start of history, or [maxPages].
  Future<BillingResult<ScanResult>> scan({required String paymentId, int? stopAtLt, int? notBeforeUtime}) async {
    BillingError? lastError;
    for (final p in providers) {
      final r = await _scanWith(p, paymentComment: '$paymentCommentPrefix$paymentId', stopAtLt: stopAtLt, notBefore: notBeforeUtime);
      if (r case Ok()) return r;
      lastError = r.errorOrNull;
    }
    return Err(lastError ?? const BillingError(BillingErrorCode.network));
  }

  Future<BillingResult<ScanResult>> _scanWith(TxProvider p, {required String paymentComment, int? stopAtLt, int? notBefore}) async {
    final seen = <String>{};
    final out = <IncomingPayment>[];
    int? newest;
    ChainTx? cursor;
    for (var page = 0; page < maxPages; page++) {
      final r = await p.page(address: receiveAddress, before: cursor, limit: pageSize);
      if (r case Err(:final error)) return Err(error);
      final pg = r.valueOrNull!;
      for (final tx in pg.txs) {
        newest ??= tx.lt;
        if (stopAtLt != null && tx.lt <= stopAtLt) {
          return Ok(ScanResult(payments: out, newestLt: newest, complete: true, provider: p.name));
        }
        if (notBefore != null && tx.utime > 0 && tx.utime < notBefore) {
          return Ok(ScanResult(payments: out, newestLt: newest, complete: true, provider: p.name));
        }
        if (seen.add(tx.hashHex) && acceptsPayment(tx, expectedComment: paymentComment, receiveAddress: receiveAddress)) {
          out.add(IncomingPayment(txHash: tx.hashHex, lt: tx.lt, utime: tx.utime, nanotons: tx.nanotons));
        }
      }
      if (!pg.hasMore || pg.txs.isEmpty) {
        return Ok(ScanResult(payments: out, newestLt: newest ?? stopAtLt, complete: true, provider: p.name));
      }
      cursor = pg.txs.last;
    }
    return Ok(ScanResult(payments: out, newestLt: newest, complete: false, provider: p.name));
  }
}
