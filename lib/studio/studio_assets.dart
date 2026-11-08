/// Downloads and tracks Studio assets (image models, voices). Android uses the existing
/// resumable foreground download service; desktop uses [HttpAssetDownloader] (same rules:
/// HTTPS to Hugging Face only, HTTP Range resume, SHA-256 check before the file is used).
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/native_bridge.dart';
import '../data/model_manager.dart' show DownloadProgress;
import 'studio_catalog.dart';

/// Moves one file to disk. Emits progress and completes with a final state.
abstract class AssetDownloader {
  Future<String> rootDir();
  Stream<MapEntry<String, DownloadProgress>> get events;
  Future<void> start({required String jobId, required StudioFile file, required String title});
  Future<void> cancel(String jobId);
}

class NativeAssetDownloader implements AssetDownloader {
  NativeAssetDownloader(this._bridge);
  final NativeBridge _bridge;

  @override
  Future<String> rootDir() async {
    final base = await _bridge.modelsDir();
    if (base == null) throw const FileSystemException('models dir unavailable');
    return p.join(base, studioSubdir);
  }

  @override
  Stream<MapEntry<String, DownloadProgress>> get events => _bridge.modelEvents
      .where((e) => (e['id'] as String? ?? '').startsWith('studio/'))
      .map((e) => MapEntry(
            e['id']! as String,
            DownloadProgress(
              state: (e['state'] as String?) ?? 'running',
              received: (e['received'] as num?)?.toInt() ?? 0,
              total: (e['total'] as num?)?.toInt() ?? 0,
              error: e['error'] as String?,
            ),
          ));

  @override
  Future<void> start({required String jobId, required StudioFile file, required String title}) async {
    await _bridge.requestNotifications();
    await _bridge.startDownload(
      id: jobId,
      url: file.url,
      sha256: file.sha256,
      size: file.sizeBytes,
      fileName: file.fileName,
      title: title,
      subdir: studioSubdir,
    );
  }

  @override
  Future<void> cancel(String jobId) => _bridge.cancelDownload(jobId);
}

const studioSubdir = 'studio';

/// Hosts a download may touch (same allow-list as the Android service).
bool isAllowedDownloadHost(String host) {
  final h = host.toLowerCase();
  return h == 'huggingface.co' || h.endsWith('.huggingface.co') || h.endsWith('.hf.co');
}

/// Pure-Dart resumable downloader for Windows/Linux.
class HttpAssetDownloader implements AssetDownloader {
  final _events = StreamController<MapEntry<String, DownloadProgress>>.broadcast();
  final Map<String, bool> _cancel = {};

  @override
  Future<String> rootDir() async {
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'models', studioSubdir);
  }

  @override
  Stream<MapEntry<String, DownloadProgress>> get events => _events.stream;

  void _emit(String id, String state, int received, int total, [String? error]) =>
      _events.add(MapEntry(id, DownloadProgress(state: state, received: received, total: total, error: error)));

  @override
  Future<void> cancel(String jobId) async => _cancel[jobId] = true;

  @override
  Future<void> start({required String jobId, required StudioFile file, required String title}) async {
    _cancel[jobId] = false;
    unawaited(_run(jobId, file));
  }

  Future<void> _run(String id, StudioFile f) async {
    final dir = Directory(await rootDir());
    await dir.create(recursive: true);
    final dest = File(p.join(dir.path, f.fileName));
    final part = File('${dest.path}.part');
    final client = HttpClient()..userAgent = 'Kiro/1.0';
    try {
      var offset = await part.exists() ? await part.length() : 0;
      if (offset > f.sizeBytes) {
        await part.delete();
        offset = 0;
      }
      if (offset < f.sizeBytes) {
        var uri = Uri.parse(f.url);
        HttpClientResponse? res;
        for (var hop = 0; hop < 8; hop++) {
          if (uri.scheme != 'https' || !isAllowedDownloadHost(uri.host)) {
            return _emit(id, 'error', offset, f.sizeBytes, 'blocked_host');
          }
          final req = await client.getUrl(uri);
          req.followRedirects = false;
          if (offset > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          res = await req.close();
          if (res.isRedirect) {
            final loc = res.headers.value(HttpHeaders.locationHeader);
            await res.drain<void>();
            if (loc == null) return _emit(id, 'error', offset, f.sizeBytes, 'network');
            uri = uri.resolve(loc);
            res = null;
            continue;
          }
          break;
        }
        if (res == null) return _emit(id, 'error', offset, f.sizeBytes, 'network');
        if (res.statusCode == HttpStatus.ok) {
          offset = 0;
        } else if (res.statusCode != HttpStatus.partialContent) {
          await res.drain<void>();
          return _emit(id, 'error', offset, f.sizeBytes, 'http_${res.statusCode}');
        }
        final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
        var received = offset;
        var last = DateTime.now();
        try {
          await for (final chunk in res) {
            if (_cancel[id] == true) {
              await sink.close();
              return _emit(id, 'cancelled', received, f.sizeBytes);
            }
            sink.add(chunk);
            received += chunk.length;
            if (DateTime.now().difference(last).inMilliseconds > 400) {
              last = DateTime.now();
              _emit(id, 'running', received, f.sizeBytes);
            }
          }
        } finally {
          await sink.close();
        }
      }
      if (await part.length() != f.sizeBytes) {
        await part.delete();
        return _emit(id, 'error', 0, f.sizeBytes, 'size_mismatch');
      }
      _emit(id, 'verifying', f.sizeBytes, f.sizeBytes);
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != f.sha256) {
        await part.delete();
        return _emit(id, 'error', 0, f.sizeBytes, 'checksum');
      }
      await part.rename(dest.path);
      _emit(id, 'done', f.sizeBytes, f.sizeBytes);
    } on IOException {
      _emit(id, 'error', await part.exists() ? await part.length() : 0, f.sizeBytes, 'network');
    } finally {
      client.close(force: true);
    }
  }
}

/// Aggregated state of one multi-file asset.
class AssetProgress {
  const AssetProgress({required this.state, this.received = 0, this.total = 0, this.error});
  final String state;
  final int received;
  final int total;
  final String? error;
  bool get active => state == 'queued' || state == 'running' || state == 'retrying' || state == 'verifying';
  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class StudioAssetManager extends ChangeNotifier {
  StudioAssetManager(this._downloader) {
    _sub = _downloader.events.listen(_onEvent, onError: (Object _) {});
  }

  final AssetDownloader _downloader;
  StreamSubscription<MapEntry<String, DownloadProgress>>? _sub;
  String? _root;
  final Set<String> _present = {};
  final Map<String, AssetProgress> progress = {};
  final Map<String, Completer<DownloadProgress>> _waiting = {};

  String? get root => _root;

  Future<void> init() async {
    try {
      _root = await _downloader.rootDir();
      await Directory(_root!).create(recursive: true);
    } on Object {
      _root = null;
    }
    await refresh();
  }

  Future<void> refresh() async {
    _present.clear();
    final r = _root;
    if (r != null) {
      for (final spec in studioCatalog) {
        for (final f in spec.files) {
          final file = File(p.join(r, f.fileName));
          if (await file.exists() && await file.length() == f.sizeBytes) _present.add(f.fileName);
        }
      }
    }
    notifyListeners();
  }

  bool isInstalled(StudioAssetSpec spec) => spec.files.every((f) => _present.contains(f.fileName));

  String? pathOf(StudioFile f) => _root == null || !_present.contains(f.fileName) ? null : p.join(_root!, f.fileName);

  /// Downloads every missing file of [spec], one after another.
  Future<bool> download(StudioAssetSpec spec) async {
    if (progress[spec.id]?.active ?? false) return false;
    final total = spec.totalBytes;
    var done = spec.files.where((f) => _present.contains(f.fileName)).fold<int>(0, (a, f) => a + f.sizeBytes);
    progress[spec.id] = AssetProgress(state: 'queued', received: done, total: total);
    notifyListeners();
    for (var i = 0; i < spec.files.length; i++) {
      final f = spec.files[i];
      if (_present.contains(f.fileName)) continue;
      final jobId = 'studio/${spec.id}/$i';
      final waiter = Completer<DownloadProgress>();
      _waiting[jobId] = waiter;
      _offsets[jobId] = (spec.id, done, total);
      await _downloader.start(jobId: jobId, file: f, title: spec.name);
      final result = await waiter.future;
      _offsets.remove(jobId);
      if (result.state != 'done') {
        progress[spec.id] = AssetProgress(state: result.state, received: done, total: total, error: result.error);
        notifyListeners();
        return false;
      }
      _present.add(f.fileName);
      done += f.sizeBytes;
    }
    progress[spec.id] = AssetProgress(state: 'done', received: total, total: total);
    await refresh();
    return true;
  }

  final Map<String, (String, int, int)> _offsets = {};

  Future<void> cancel(StudioAssetSpec spec) async {
    for (var i = 0; i < spec.files.length; i++) {
      await _downloader.cancel('studio/${spec.id}/$i');
    }
  }

  Future<void> delete(StudioAssetSpec spec) async {
    final r = _root;
    if (r == null) return;
    for (final f in spec.files) {
      // TAESD is shared by both image models: keep it while another installed model uses it.
      final sharedElsewhere = studioCatalog.any((o) => o.id != spec.id && isInstalled(o) && o.files.any((x) => x.fileName == f.fileName));
      if (sharedElsewhere) continue;
      for (final name in [f.fileName, '${f.fileName}.part']) {
        final file = File(p.join(r, name));
        if (await file.exists()) await file.delete();
      }
    }
    progress.remove(spec.id);
    await refresh();
  }

  void _onEvent(MapEntry<String, DownloadProgress> e) {
    final off = _offsets[e.key];
    final pg = e.value;
    if (off != null) {
      final (specId, done, total) = off;
      progress[specId] = AssetProgress(state: pg.active ? 'running' : pg.state, received: done + pg.received, total: total, error: pg.error);
      notifyListeners();
    }
    if (!pg.active) {
      _waiting.remove(e.key)?.complete(pg);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final w in _waiting.values) {
      if (!w.isCompleted) w.complete(const DownloadProgress(state: 'cancelled'));
    }
    super.dispose();
  }
}
