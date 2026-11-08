import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/native_bridge.dart';
import 'llm_backend.dart';

/// State of the on-device engine that lives in the ":ai" process.
enum EngineState { idle, loading, ready, error }

/// Owns the connection to the ":ai" LlmService: model load/unload, process-death recovery and
/// routing of streamed tokens to the right request.
class LocalEngine extends ChangeNotifier implements LlmBackend {
  LocalEngine(this._bridge) {
    _sub = _bridge.llmEvents.listen(_onEvent, onError: (Object _) {});
  }

  final NativeBridge _bridge;
  StreamSubscription<Map<Object?, Object?>>? _sub;
  final Map<int, StreamController<String>> _requests = {};
  int _nextId = 1;

  EngineState state = EngineState.idle;
  String? loadedPath;
  String? description;

  /// Last error code (see LlmException codes) for the UI to show; cleared on success.
  String? errorCode;
  int? lowRamAvail;
  int? lowRamNeed;

  /// True after the AI process died until a model is loaded again.
  bool processDied = false;

  /// Reloads the active model when a generation finds the engine empty (for example after
  /// the Studio ran an image model in the ":ai" process). Returns an error code or null.
  Future<String?> Function()? autoReload;

  /// The ":ai" process keeps one heavy model in memory: running an image model there unloads
  /// the chat model.
  void markUnloadedByStudio() {
    if (state != EngineState.ready) return;
    _set(() {
      state = EngineState.idle;
      loadedPath = null;
      description = null;
    });
  }

  bool get isReady => state == EngineState.ready && loadedPath != null;

  @override
  String get label => 'on-device';

  @override
  bool get isRemote => false;

  void _set(void Function() change) {
    change();
    notifyListeners();
  }

  Future<void> refreshStatus() async {
    try {
      final r = await _bridge.llmStatus();
      if (r['ok'] == true && r['loaded'] == true) {
        _set(() {
          state = EngineState.ready;
          loadedPath = r['path'] as String?;
          description = r['description'] as String?;
        });
      }
    } on MissingPluginException {
      // tests
    } on PlatformException {
      // service not reachable yet
    }
  }

  /// Loads a model; unloads any other model first (one heavy model at a time).
  /// Returns null on success or an error code.
  Future<String?> load(String path, {required int nCtx, required int threads, bool force = false}) async {
    _set(() {
      state = EngineState.loading;
      errorCode = null;
      lowRamAvail = null;
      lowRamNeed = null;
    });
    Map<Object?, Object?> r;
    try {
      r = await _bridge.llmLoad(path: path, nCtx: nCtx, threads: threads, force: force);
    } on MissingPluginException {
      r = const {'ok': false, 'code': 'unsupported'};
    } on PlatformException catch (e) {
      r = {'ok': false, 'code': e.code};
    }
    if (r['ok'] == true) {
      _set(() {
        state = EngineState.ready;
        loadedPath = path;
        description = r['description'] as String?;
        processDied = false;
      });
      return null;
    }
    final code = (r['code'] as String?) ?? 'load_failed';
    _set(() {
      state = EngineState.error;
      loadedPath = null;
      errorCode = code;
      if (code == 'low_ram') {
        lowRamAvail = (r['availBytes'] as num?)?.toInt();
        lowRamNeed = (r['needBytes'] as num?)?.toInt();
      }
    });
    return code;
  }

  Future<void> unload() async {
    try {
      await _bridge.llmUnload();
    } on MissingPluginException {
      // tests
    }
    _set(() {
      state = EngineState.idle;
      loadedPath = null;
      description = null;
    });
  }

  void clearError() => _set(() {
        errorCode = null;
        if (state == EngineState.error) state = EngineState.idle;
      });

  void _onEvent(Map<Object?, Object?> e) {
    final event = e['event'] as String?;
    final id = (e['id'] as num?)?.toInt();
    switch (event) {
      case 'token':
        final text = e['text'] as String?;
        if (id != null && text != null) _requests[id]?.add(text);
      case 'done':
        if (id != null) _requests.remove(id)?.close();
      case 'error':
        final code = (e['code'] as String?) ?? 'generate_failed';
        if (id != null) {
          final c = _requests.remove(id);
          c?.addError(LlmException(code, e['message'] as String?));
          c?.close();
        }
      case 'process_died':
        for (final c in _requests.values) {
          c.addError(const LlmException('process_died'));
          c.close();
        }
        _requests.clear();
        _set(() {
          processDied = true;
          state = EngineState.error;
          errorCode = 'process_died';
          loadedPath = null;
          description = null;
        });
      case 'connected':
        notifyListeners();
    }
  }

  @override
  Stream<String> generate(List<ChatMessage> messages, GenerationOptions options, {CancelToken? cancel}) {
    final id = _nextId++;
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () async {
        if (!isReady && !processDied && autoReload != null && state != EngineState.loading) {
          await autoReload!();
        }
        if (!isReady) {
          _requests.remove(id);
          controller.addError(LlmException(processDied ? 'process_died' : 'not_loaded'));
          await controller.close();
          return;
        }
        cancel?.onCancel(() {
          _bridge.llmCancel(id).catchError((Object _) {});
        });
        try {
          await _bridge.llmGenerate(
            id: id,
            messages: messages.map((m) => m.toMap()).toList(),
            maxTokens: options.maxTokens,
            temperature: options.temperature,
          );
        } on PlatformException catch (e) {
          _requests.remove(id);
          controller.addError(LlmException(e.code));
          await controller.close();
        }
      },
      onCancel: () {
        if (_requests.containsKey(id)) {
          _bridge.llmCancel(id).catchError((Object _) {});
          _requests.remove(id);
        }
      },
    );
    _requests[id] = controller;
    return controller.stream;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
