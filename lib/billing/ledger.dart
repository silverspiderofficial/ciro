/// Append-only, encrypted, hash-chained credit ledger (one file per payment id).
///
/// balance = verified on-chain credits − committed spends − open reservations.
///
/// Integrity: every record is sealed by [RecordCipher] with a tag chained to the previous
/// record. The record count and last tag ("head") are kept in [SecureKeyStore], so truncating
/// the file, deleting it, or restoring an older copy is detected as well as editing it.
///
/// On tamper (or plain disk corruption): the bad file is quarantined, a new ledger is started
/// with a `tamper` marker, and credits are rebuilt from the chain on the next refresh. This is
/// deliberately lenient: the user is never locked out and keeps every on-chain payment; only the
/// local spend history of the damaged file is lost.
///
/// Writes are serialized by an in-process queue plus an OS file lock (`<file>.lock`) and are
/// atomic (write temp file, flush, rename), then the head is updated.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'billing_result.dart';
import 'sealed_box.dart';
import 'secure_key_store.dart';
import 'ton_verifier.dart' show IncomingPayment;

class Reservation {
  const Reservation(this.id, this.nanotons, this.duration);
  final String id;
  final int nanotons;
  final Duration duration;
}

class LedgerBalance {
  const LedgerBalance({
    required this.credited,
    required this.spent,
    required this.reserved,
    required this.forfeited,
    required this.tampered,
  });

  static const empty = LedgerBalance(credited: 0, spent: 0, reserved: 0, forfeited: 0, tampered: false);

  /// Sum of verified on-chain payments (nanotons).
  final int credited;

  /// Sum of committed spends.
  final int spent;

  /// Sum of open reservations (renders in progress).
  final int reserved;

  /// Credit made unspendable. Always 0: tamper handling is lenient (kept for API stability).
  final int forfeited;

  /// A tamper event was recorded for this payment id.
  final bool tampered;

  int get available => max(0, credited - spent - reserved - forfeited);
}

class _State {
  final Set<String> txHashes = {};
  final List<({String tx, int n, int ut, int lt})> credits = [];
  final Map<String, Reservation> open = {};
  final Set<String> settled = {};
  int spent = 0;
  int? cursorLt;
  int? tamperAt;

  /// Newest account lt seen by the first chain scan after a tamper event (the device clock is
  /// not trusted alone).
  int? tamperLt;

  LedgerBalance balance() {
    // Lenient by design: a tamper event never forfeits credit, the ledger is simply rebuilt
    // from the chain (see the library comment).
    final credited = credits.fold<int>(0, (s, c) => s + c.n);
    final reserved = open.values.fold<int>(0, (s, r) => s + r.nanotons);
    return LedgerBalance(credited: credited, spent: spent, reserved: reserved, forfeited: 0, tampered: tamperAt != null);
  }

  /// Applies one decoded record. Returns false for a record that does not make sense.
  bool apply(Map<String, Object?> r) {
    switch (r['t']) {
      case 'genesis':
        return true;
      case 'credit':
        final tx = r['tx'];
        final n = r['n'];
        final ut = r['ut'];
        final lt = r['lt'];
        if (tx is! String || n is! int || ut is! int || lt is! int || n <= 0) return false;
        if (!txHashes.add(tx)) return false;
        credits.add((tx: tx, n: n, ut: ut, lt: lt));
        return true;
      case 'cursor':
        final lt = r['lt'];
        if (lt is! int) return false;
        cursorLt = lt;
        return true;
      case 'reserve':
        final id = r['id'];
        final n = r['n'];
        final s = r['s'];
        if (id is! String || n is! int || s is! int || open.containsKey(id) || settled.contains(id)) return false;
        open[id] = Reservation(id, n, Duration(milliseconds: s));
        return true;
      case 'commit':
      case 'release':
        final id = r['id'];
        if (id is! String) return false;
        final res = open.remove(id);
        if (res == null) return false;
        settled.add(id);
        if (r['t'] == 'commit') spent += res.nanotons;
        return true;
      case 'tamper':
        final at = r['at'];
        if (at is! int) return false;
        tamperAt = at;
        return true;
      case 'tamper_lt':
        final lt = r['lt'];
        if (lt is! int || tamperAt == null) return false;
        tamperLt = max(tamperLt ?? 0, lt);
        return true;
      default:
        return false;
    }
  }
}

class Ledger {
  Ledger._(this.file, this.paymentId, this._keys, this._cipher, this._now, this._rng);

  final File file;
  final String paymentId;
  final SecureKeyStore _keys;
  final RecordCipher _cipher;
  final DateTime Function() _now;
  final Random _rng;

  final List<String> _lines = [];
  Uint8List _lastTag = HmacCtrCipher.genesisTag;
  _State _state = _State();
  Future<void> _queue = Future<void>.value();

  /// Set when this open detected tampering (and quarantined the old file).
  bool detectedTamperOnOpen = false;

  LedgerBalance get balance => _state.balance();
  int? get cursorLt => _state.cursorLt;
  bool get tampered => _state.tamperAt != null;

  /// True when a tamper event still needs its chain-time boundary (set by the next scan).
  bool get needsTamperBoundary => _state.tamperAt != null && _state.tamperLt == null;
  List<Reservation> get openReservations => List.unmodifiable(_state.open.values);

  static String fileNameFor(String paymentId) => 'ledger_$paymentId.bin';

  /// Opens (or creates) the ledger for [paymentId] in [dir]. Never throws for integrity
  /// problems: they are handled as tamper events. Throws [FileSystemException] only when the
  /// directory itself cannot be used; [BillingService] maps that to [BillingErrorCode.storage].
  static Future<Ledger> open({
    required Directory dir,
    required String paymentId,
    required SecureKeyStore keys,
    required List<int> masterKey,
    DateTime Function()? now,
    Random? rng,
  }) async {
    await dir.create(recursive: true);
    final l = Ledger._(
      File(p.join(dir.path, fileNameFor(paymentId))),
      paymentId,
      keys,
      HmacCtrCipher(masterKey, paymentId, rng: rng),
      now ?? DateTime.now,
      rng ?? Random.secure(),
    );
    await l._serial(l._load);
    return l;
  }

  Future<T> _serial<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await f());
      } on Object catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  ({int count, String tag})? _parseHead(String? h) {
    if (h == null) return null;
    final i = h.indexOf(':');
    if (i < 0) return null;
    final n = int.tryParse(h.substring(0, i));
    return n == null ? null : (count: n, tag: h.substring(i + 1));
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _load() async {
    final head = _parseHead(await _keys.read(BillingKeys.ledgerHead(paymentId)));
    final tamperKey = await _keys.read(BillingKeys.tamperedAt(paymentId));
    final exists = await file.exists();
    if (!exists) {
      if (head != null && head.count > 0) return _onTamper('missing');
      await _appendRaw([
        {'t': 'genesis', 'pid': paymentId, 'at': _nowSec()},
        if (tamperKey != null && int.tryParse(tamperKey) != null) {'t': 'tamper', 'at': int.parse(tamperKey)},
      ]);
      return;
    }
    final lines = (await file.readAsString()).split('\n').where((s) => s.isNotEmpty).toList();
    final st = _State();
    var prev = HmacCtrCipher.genesisTag;
    var seq = 0;
    final tags = <String>[];
    for (final line in lines) {
      final Uint8List sealed;
      try {
        sealed = base64.decode(line);
      } on FormatException {
        return _onTamper('b64');
      }
      final plain = _cipher.open(sealed, prevTag: prev, seq: seq);
      if (plain == null) return _onTamper('mac');
      final Object? rec;
      try {
        rec = jsonDecode(utf8.decode(plain));
      } on FormatException {
        return _onTamper('json');
      }
      if (rec is! Map<String, Object?> || !st.apply(rec)) return _onTamper('record');
      if (seq == 0 && (rec['t'] != 'genesis' || rec['pid'] != paymentId)) return _onTamper('genesis');
      prev = RecordCipher.tagOf(sealed);
      tags.add(_hex(prev));
      seq++;
    }
    if (head == null) {
      // Head lost but file valid: only acceptable for a brand-new single-record ledger
      // (crash between first write and head write).
      if (lines.length > 1) return _onTamper('head-missing');
    } else if (head.count == lines.length) {
      if (head.count > 0 && head.tag != tags.last) return _onTamper('head-tag');
    } else if (head.count + 1 == lines.length) {
      // Crash after rename, before head update: the earlier prefix must match the head.
      if (head.count > 0 && head.tag != tags[head.count - 1]) return _onTamper('head-tag');
    } else {
      return _onTamper('head-count');
    }
    if (tamperKey != null && st.tamperAt == null) return _onTamper('marker-removed');
    _lines
      ..clear()
      ..addAll(lines);
    _lastTag = prev;
    _state = st;
    await _writeHead();
  }

  int _nowSec() => _now().millisecondsSinceEpoch ~/ 1000;

  Future<void> _onTamper(String why) async {
    detectedTamperOnOpen = true;
    final at = _nowSec();
    if (await file.exists()) {
      try {
        await file.rename('${file.path}.tampered-$at');
      } on FileSystemException {
        await file.delete();
      }
    }
    final prior = int.tryParse(await _keys.read(BillingKeys.tamperedAt(paymentId)) ?? '');
    final mark = max(prior ?? 0, at);
    await _keys.write(BillingKeys.tamperedAt(paymentId), '$mark');
    await _keys.delete(BillingKeys.ledgerHead(paymentId));
    _lines.clear();
    _lastTag = HmacCtrCipher.genesisTag;
    _state = _State();
    await _appendRaw([
      {'t': 'genesis', 'pid': paymentId, 'at': at},
      {'t': 'tamper', 'at': mark, 'why': why},
    ]);
  }

  Future<void> _writeHead() =>
      _keys.write(BillingKeys.ledgerHead(paymentId), '${_lines.length}:${_lines.isEmpty ? '' : _hex(_lastTag)}');

  /// Seals and appends records, then atomically replaces the file and updates the head.
  Future<void> _appendRaw(List<Map<String, Object?>> records) async {
    final newLines = <String>[];
    var prev = _lastTag;
    var seq = _lines.length;
    for (final r in records) {
      final sealed = _cipher.seal(utf8.encode(jsonEncode(r)), prevTag: prev, seq: seq);
      newLines.add(base64.encode(sealed));
      prev = RecordCipher.tagOf(sealed);
      seq++;
    }
    final all = [..._lines, ...newLines];
    final lock = await File('${file.path}.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final tmp = File('${file.path}.tmp');
      final raf = await tmp.open(mode: FileMode.write);
      try {
        await raf.writeString('${all.join('\n')}\n');
        await raf.flush();
      } finally {
        await raf.close();
      }
      await tmp.rename(file.path);
    } finally {
      try {
        await lock.unlock();
      } on FileSystemException {
        // ignore
      }
      await lock.close();
    }
    _lines
      ..clear()
      ..addAll(all);
    _lastTag = prev;
    for (final r in records) {
      _state.apply(r);
    }
    await _writeHead();
  }

  Future<BillingResult<T>> _guard<T>(Future<BillingResult<T>> Function() f) => _serial(() async {
        try {
          return await f();
        } on FileSystemException catch (e) {
          return Err(BillingError(BillingErrorCode.storage, e.osError?.message ?? 'fs'));
        }
      });

  /// Adds payments not seen before (dedupe by tx hash) and optionally advances the scan cursor.
  /// Returns the number of new credits.
  Future<BillingResult<int>> addCredits(List<IncomingPayment> payments, {int? cursorLt}) => _guard(() async {
        final seen = <String>{};
        final recs = <Map<String, Object?>>[];
        for (final pmt in payments) {
          if (pmt.nanotons <= 0 || _state.txHashes.contains(pmt.txHash) || !seen.add(pmt.txHash)) continue;
          recs.add({'t': 'credit', 'tx': pmt.txHash, 'n': pmt.nanotons, 'lt': pmt.lt, 'ut': pmt.utime});
        }
        if (cursorLt != null && cursorLt != _state.cursorLt && (_state.cursorLt == null || cursorLt > _state.cursorLt!)) {
          recs.add({'t': 'cursor', 'lt': cursorLt});
        }
        if (recs.isNotEmpty) await _appendRaw(recs);
        return Ok(recs.where((r) => r['t'] == 'credit').length);
      });

  /// Records the newest chain lt seen after a tamper event (informational only).
  Future<BillingResult<void>> setTamperBoundary(int lt) => _guard(() async {
        if (!needsTamperBoundary) return const Ok(null);
        await _appendRaw([
          {'t': 'tamper_lt', 'lt': lt},
        ]);
        return const Ok(null);
      });

  /// Holds [nanotons] for a render of [duration]. Persisted before returning.
  Future<BillingResult<Reservation>> reserve(int nanotons, Duration duration) => _guard(() async {
        if (nanotons <= 0) return const Err(BillingError(BillingErrorCode.unsupportedDuration));
        final b = _state.balance();
        if (b.available < nanotons) {
          return Err(BillingError(BillingErrorCode.insufficientFunds, '${b.available}<$nanotons'));
        }
        final id = List<int>.generate(8, (_) => _rng.nextInt(256)).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
        await _appendRaw([
          {'t': 'reserve', 'id': id, 'n': nanotons, 's': duration.inMilliseconds, 'at': _nowSec()},
        ]);
        return Ok(Reservation(id, nanotons, duration));
      });

  Future<BillingResult<void>> commit(String id) => _settle(id, 'commit');

  Future<BillingResult<void>> release(String id) => _settle(id, 'release');

  Future<BillingResult<void>> _settle(String id, String kind) => _guard(() async {
        if (!_state.open.containsKey(id)) return const Err(BillingError(BillingErrorCode.unknownReservation));
        await _appendRaw([
          {'t': kind, 'id': id},
        ]);
        return const Ok(null);
      });

  /// Startup reconcile: releases every reservation left open by a crash or kill (the render
  /// did not report success, so the user is refunded). Returns how many were released.
  Future<BillingResult<int>> reconcile() => _guard(() async {
        final ids = _state.open.keys.toList();
        if (ids.isEmpty) return const Ok(0);
        await _appendRaw([
          for (final id in ids) {'t': 'release', 'id': id, 'reason': 'reconcile'},
        ]);
        return Ok(ids.length);
      });
}
