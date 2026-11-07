import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/native_bridge.dart';
import 'model_catalog.dart';

class DownloadProgress {
  const DownloadProgress({required this.state, this.received = 0, this.total = 0, this.error});

  /// queued | running | retrying | verifying | done | error | cancelled
  final String state;
  final int received;
  final int total;
  final String? error;

  bool get active => state == 'queued' || state == 'running' || state == 'retrying' || state == 'verifying';
  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class LocalModelFile {
  const LocalModelFile({required this.fileName, required this.path, required this.sizeBytes, this.spec});
  final String fileName;
  final String path;
  final int sizeBytes;
  final ModelSpec? spec;

  String get displayName => spec?.name ?? fileName.replaceAll(RegExp(r'\.gguf$'), '');
}

/// Tracks model files on disk, downloads (via the foreground service) and SAF imports.
class ModelManager extends ChangeNotifier {
  ModelManager(this._bridge) {
    _sub = _bridge.modelEvents.listen(_onEvent, onError: (Object _) {});
  }

  final NativeBridge _bridge;
  StreamSubscription<Map<Object?, Object?>>? _sub;

  String? modelsDir;
  final Map<String, LocalModelFile> _files = {};
  final Map<String, int> _partials = {};
  final Map<String, DownloadProgress> progress = {};
  DownloadProgress? importProgress;

  /// Last finished download event per id, for one-off UI messages (snackbars).
  final StreamController<MapEntry<String, DownloadProgress>> _finished = StreamController.broadcast();
  Stream<MapEntry<String, DownloadProgress>> get finished => _finished.stream;

  List<LocalModelFile> get files => _files.values.toList()..sort((a, b) => a.displayName.compareTo(b.displayName));
  List<LocalModelFile> get importedFiles => files.where((f) => f.spec == null).toList();

  LocalModelFile? fileFor(String? fileName) => fileName == null ? null : _files[fileName];
  bool isDownloaded(ModelSpec spec) => _files.containsKey(spec.fileName);
  int partialBytes(ModelSpec spec) => _partials[spec.fileName] ?? 0;

  Future<void> init() async {
    modelsDir = await _bridge.modelsDir();
    for (final id in await _bridge.activeDownloads()) {
      progress[id] = const DownloadProgress(state: 'running');
    }
    await refresh();
  }

  Future<void> refresh() async {
    final dir = modelsDir;
    _files.clear();
    _partials.clear();
    if (dir != null) {
      final d = Directory(dir);
      if (await d.exists()) {
        await for (final e in d.list()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (name.endsWith('.gguf')) {
            _files[name] = LocalModelFile(
              fileName: name,
              path: e.path,
              sizeBytes: await e.length(),
              spec: catalogByFileName(name),
            );
          } else if (name.endsWith('.gguf.part')) {
            _partials[name.substring(0, name.length - 5)] = await e.length();
          }
        }
      }
    }
    notifyListeners();
  }

  Future<void> download(ModelSpec spec) async {
    await _bridge.requestNotifications();
    progress[spec.id] = DownloadProgress(state: 'queued', received: partialBytes(spec), total: spec.sizeBytes);
    notifyListeners();
    await _bridge.startDownload(
      id: spec.id,
      url: spec.url,
      sha256: spec.sha256,
      size: spec.sizeBytes,
      fileName: spec.fileName,
      title: spec.name,
    );
  }

  Future<void> cancel(ModelSpec spec) => _bridge.cancelDownload(spec.id);

  Future<void> deleteFile(String fileName) async {
    final f = _files[fileName];
    if (f != null) {
      final file = File(f.path);
      if (await file.exists()) await file.delete();
    }
    if (_partials.containsKey(fileName)) await _bridge.deletePartial(fileName);
    await refresh();
  }

  Future<void> deletePartial(ModelSpec spec) async {
    await _bridge.deletePartial(spec.fileName);
    progress.remove(spec.id);
    await refresh();
  }

  /// Returns the imported file name, null if cancelled. Throws PlatformException(code).
  Future<String?> importFromStorage() async {
    importProgress = const DownloadProgress(state: 'running');
    notifyListeners();
    try {
      final r = await _bridge.importModel();
      await refresh();
      return r?['fileName'] as String?;
    } on PlatformException {
      rethrow;
    } finally {
      importProgress = null;
      notifyListeners();
    }
  }

  void _onEvent(Map<Object?, Object?> e) {
    final id = e['id'] as String?;
    if (id == null) return;
    final pgs = DownloadProgress(
      state: (e['state'] as String?) ?? 'running',
      received: (e['received'] as num?)?.toInt() ?? 0,
      total: (e['total'] as num?)?.toInt() ?? 0,
      error: e['error'] as String?,
    );
    if (id == 'import') {
      importProgress = pgs;
      notifyListeners();
      return;
    }
    progress[id] = pgs;
    if (!pgs.active) {
      _finished.add(MapEntry(id, pgs));
      unawaited(refresh());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _finished.close();
    super.dispose();
  }
}
