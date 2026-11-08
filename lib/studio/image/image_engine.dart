/// On-device image generation (stable-diffusion.cpp), behind one interface:
///   Android -> [AndroidImageEngine]: JNI inside the ":ai" process (one heavy model at a time,
///              RAM check, crash isolation), driven over platform channels.
///   Windows/Linux -> [FfiImageEngine] (ffi_image_engine.dart): the same kiro_sd C library
///              through dart:ffi on a background isolate.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'ffi_image_engine.dart';

class ImageRequest {
  const ImageRequest({
    required this.prompt,
    required this.modelPath,
    required this.outPath,
    this.negativePrompt = '',
    this.taesdPath = '',
    this.width = 512,
    this.height = 512,
    this.steps = 0,
    this.cfg = 0,
    this.seed = -1,
    this.threads = 4,
    this.force = false,
  });

  final String prompt;
  final String negativePrompt;
  final String modelPath;
  final String taesdPath;
  final String outPath;
  final int width;
  final int height;

  /// 0 = model default.
  final int steps;

  /// 0 = model default.
  final double cfg;

  /// -1 = random.
  final int seed;
  final int threads;

  /// Skip the free-RAM check.
  final bool force;

  Map<String, Object?> toMap() => {
        'prompt': prompt,
        'negative': negativePrompt,
        'model': modelPath,
        'taesd': taesdPath,
        'out': outPath,
        'width': width,
        'height': height,
        'steps': steps,
        'cfg': cfg,
        'seed': seed,
        'threads': threads,
        'force': force,
      };
}

sealed class ImageEvent {
  const ImageEvent();
}

/// phase: loading | sampling | decoding
class ImageProgress extends ImageEvent {
  const ImageProgress(this.phase, {this.step = 0, this.steps = 0});
  final String phase;
  final int step;
  final int steps;
  double? get fraction => steps > 0 ? (step / steps).clamp(0.0, 1.0) : null;
}

class ImageDone extends ImageEvent {
  const ImageDone({required this.path, required this.seed, required this.millis});
  final String path;
  final int seed;
  final int millis;
}

class ImageFailed extends ImageEvent {
  const ImageFailed(this.code, {this.availBytes, this.needBytes});

  /// low_ram | load_failed | generate_failed | cancelled | no_backend | not_found | process_died | busy | unsupported
  final String code;
  final int? availBytes;
  final int? needBytes;
}

abstract class ImageEngine {
  /// Generates one image; the stream ends after [ImageDone] or [ImageFailed].
  Stream<ImageEvent> generate(ImageRequest request);
  Future<void> cancel();

  /// Frees the model's memory.
  Future<void> unload();

  static ImageEngine create() => Platform.isAndroid ? AndroidImageEngine() : FfiImageEngine();
}

class AndroidImageEngine implements ImageEngine {
  static const _ch = MethodChannel('kiro/image');
  static const _events = EventChannel('kiro/image/events');
  Stream<Map<Object?, Object?>>? _stream;
  int _next = 1;
  int? _active;

  Stream<Map<Object?, Object?>> get _eventStream =>
      _stream ??= _events.receiveBroadcastStream().map((e) => e as Map<Object?, Object?>).asBroadcastStream();

  @override
  Stream<ImageEvent> generate(ImageRequest request) {
    final id = _next++;
    late StreamController<ImageEvent> c;
    StreamSubscription<Map<Object?, Object?>>? sub;
    c = StreamController<ImageEvent>(
      onListen: () async {
        sub = _eventStream.where((e) => (e['id'] as num?)?.toInt() == id).listen((e) {
          switch (e['event']) {
            case 'progress':
              c.add(ImageProgress(
                (e['phase'] as String?) ?? 'sampling',
                step: (e['step'] as num?)?.toInt() ?? 0,
                steps: (e['steps'] as num?)?.toInt() ?? 0,
              ));
            case 'done':
              c.add(ImageDone(
                path: (e['path'] as String?) ?? request.outPath,
                seed: (e['seed'] as num?)?.toInt() ?? request.seed,
                millis: (e['millis'] as num?)?.toInt() ?? 0,
              ));
              _finish(id, c, sub);
            case 'error':
              c.add(ImageFailed(
                (e['code'] as String?) ?? 'generate_failed',
                availBytes: (e['availBytes'] as num?)?.toInt(),
                needBytes: (e['needBytes'] as num?)?.toInt(),
              ));
              _finish(id, c, sub);
          }
        });
        _active = id;
        c.add(const ImageProgress('loading'));
        try {
          await _ch.invokeMethod<bool>('generate', {'id': id, ...request.toMap()});
        } on PlatformException catch (e) {
          c.add(ImageFailed(e.code));
          _finish(id, c, sub);
        } on MissingPluginException {
          c.add(const ImageFailed('unsupported'));
          _finish(id, c, sub);
        }
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  void _finish(int id, StreamController<ImageEvent> c, StreamSubscription<Object?>? sub) {
    if (_active == id) _active = null;
    sub?.cancel();
    if (!c.isClosed) c.close();
  }

  @override
  Future<void> cancel() async {
    final id = _active;
    if (id == null) return;
    try {
      await _ch.invokeMethod<void>('cancel', {'id': id});
    } on MissingPluginException {
      // tests
    }
  }

  @override
  Future<void> unload() async {
    try {
      await _ch.invokeMethod<void>('unload');
    } on MissingPluginException {
      // tests
    }
  }
}
