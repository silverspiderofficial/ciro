/// Desktop (Windows/Linux) image engine: the kiro_sd C API (native/kiro_sd) through dart:ffi.
/// The model lives in a long-running background isolate so the UI never blocks; cancel is
/// called from the UI isolate on the same native context (kiro_sd_cancel is thread-safe).
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'image_engine.dart';

typedef _LoadC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _LoadD = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _ProgressC = Void Function(Int32, Int32, Pointer<Void>);
typedef _GenC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32, Float, Int64,
    Pointer<Utf8>, Pointer<NativeFunction<_ProgressC>>, Pointer<Void>, Pointer<Int64>);
typedef _GenD = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, int, int, double, int, Pointer<Utf8>,
    Pointer<NativeFunction<_ProgressC>>, Pointer<Void>, Pointer<Int64>);
typedef _CtxC = Void Function(Pointer<Void>);
typedef _CtxD = void Function(Pointer<Void>);

String _libraryName() {
  if (Platform.isWindows) return 'kiro_sd.dll';
  if (Platform.isMacOS) return 'libkiro_sd.dylib';
  return 'libkiro_sd.so';
}

DynamicLibrary _open() {
  final beside = p.join(File(Platform.resolvedExecutable).parent.path, _libraryName());
  if (File(beside).existsSync()) return DynamicLibrary.open(beside);
  final inLib = p.join(File(Platform.resolvedExecutable).parent.path, 'lib', _libraryName());
  if (File(inLib).existsSync()) return DynamicLibrary.open(inLib);
  return DynamicLibrary.open(_libraryName());
}

class FfiImageEngine implements ImageEngine {
  SendPort? _worker;
  Isolate? _isolate;
  final _replies = ReceivePort();
  final Map<int, StreamController<ImageEvent>> _jobs = {};
  int _next = 1;
  int? _active;
  int _ctxAddress = 0;
  Completer<void>? _ready;

  Future<void> _ensureWorker() async {
    if (_worker != null) return;
    if (_ready != null) return _ready!.future;
    _ready = Completer<void>();
    _replies.listen(_onReply);
    _isolate = await Isolate.spawn(_workerMain, _replies.sendPort, debugName: 'kiro-image');
    return _ready!.future;
  }

  void _onReply(Object? msg) {
    if (msg is SendPort) {
      _worker = msg;
      _ready?.complete();
      return;
    }
    if (msg is! Map) return;
    final id = msg['id'] as int?;
    if (msg['ctx'] is int) _ctxAddress = msg['ctx'] as int;
    final c = id == null ? null : _jobs[id];
    if (c == null) return;
    switch (msg['event']) {
      case 'progress':
        c.add(ImageProgress(msg['phase'] as String, step: msg['step'] as int? ?? 0, steps: msg['steps'] as int? ?? 0));
      case 'done':
        c.add(ImageDone(path: msg['path'] as String, seed: msg['seed'] as int, millis: msg['millis'] as int));
        _close(id!);
      case 'error':
        c.add(ImageFailed(msg['code'] as String));
        _close(id!);
    }
  }

  void _close(int id) {
    if (_active == id) _active = null;
    _jobs.remove(id)?.close();
  }

  @override
  Stream<ImageEvent> generate(ImageRequest request) {
    final id = _next++;
    final c = StreamController<ImageEvent>();
    _jobs[id] = c;
    _active = id;
    () async {
      try {
        await _ensureWorker();
        _worker!.send({'cmd': 'generate', 'id': id, ...request.toMap()});
      } on Object {
        c.add(const ImageFailed('no_backend'));
        _close(id);
      }
    }();
    return c.stream;
  }

  @override
  Future<void> cancel() async {
    if (_active == null || _ctxAddress == 0) return;
    try {
      final lib = _open();
      lib.lookupFunction<_CtxC, _CtxD>('kiro_sd_cancel')(Pointer<Void>.fromAddress(_ctxAddress));
    } on Object {
      // library unavailable
    }
  }

  @override
  Future<void> unload() async {
    _worker?.send({'cmd': 'unload'});
    _ctxAddress = 0;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _replies.close();
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

SendPort? _out;
int _currentJob = 0;

void _progress(int step, int steps, Pointer<Void> _) {
  _out?.send({'id': _currentJob, 'event': 'progress', 'phase': step >= steps ? 'decoding' : 'sampling', 'step': step, 'steps': steps});
}

void _workerMain(SendPort out) {
  _out = out;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  DynamicLibrary? lib;
  Pointer<Void> ctx = nullptr;
  String loadedKey = '';
  inbox.listen((Object? raw) {
    final m = raw as Map;
    if (m['cmd'] == 'unload') {
      if (ctx != nullptr && lib != null) lib!.lookupFunction<_CtxC, _CtxD>('kiro_sd_free')(ctx);
      ctx = nullptr;
      loadedKey = '';
      return;
    }
    final id = m['id'] as int;
    _currentJob = id;
    try {
      lib ??= _open();
    } on Object {
      out.send({'id': id, 'event': 'error', 'code': 'no_backend'});
      return;
    }
    final l = lib!;
    final key = '${m['model']}|${m['taesd']}|${m['threads']}';
    final sw = Stopwatch()..start();
    if (ctx == nullptr || key != loadedKey) {
      if (ctx != nullptr) l.lookupFunction<_CtxC, _CtxD>('kiro_sd_free')(ctx);
      out.send({'id': id, 'event': 'progress', 'phase': 'loading'});
      final model = (m['model'] as String).toNativeUtf8();
      final taesd = (m['taesd'] as String).toNativeUtf8();
      ctx = l.lookupFunction<_LoadC, _LoadD>('kiro_sd_load')(model, taesd, m['threads'] as int);
      calloc
        ..free(model)
        ..free(taesd);
      if (ctx == nullptr) {
        loadedKey = '';
        out.send({'id': id, 'event': 'error', 'code': 'load_failed'});
        return;
      }
      loadedKey = key;
    }
    out.send({'id': id, 'ctx': ctx.address, 'event': 'progress', 'phase': 'sampling', 'step': 0, 'steps': m['steps'] as int});
    final prompt = (m['prompt'] as String).toNativeUtf8();
    final negative = (m['negative'] as String).toNativeUtf8();
    final outPath = (m['out'] as String).toNativeUtf8();
    final seedOut = calloc<Int64>();
    final rc = l.lookupFunction<_GenC, _GenD>('kiro_sd_txt2img')(
      ctx,
      prompt,
      negative,
      m['width'] as int,
      m['height'] as int,
      m['steps'] as int,
      (m['cfg'] as num).toDouble(),
      m['seed'] as int,
      outPath,
      Pointer.fromFunction<_ProgressC>(_progress),
      nullptr,
      seedOut,
    );
    final seed = seedOut.value;
    calloc
      ..free(prompt)
      ..free(negative)
      ..free(outPath)
      ..free(seedOut);
    if (rc == 0) {
      out.send({'id': id, 'event': 'done', 'path': m['out'], 'seed': seed, 'millis': sw.elapsedMilliseconds});
    } else {
      out.send({'id': id, 'event': 'error', 'code': rc == -3 ? 'cancelled' : 'generate_failed'});
    }
  });
}
