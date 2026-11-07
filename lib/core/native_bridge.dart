/// Thin wrappers over the platform channels implemented in MainActivity.kt.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../data/device_info.dart';

class NativeBridge {
  NativeBridge();

  static const _device = MethodChannel('kiro/device');
  static const _llm = MethodChannel('kiro/llm');
  static const _llmEvents = EventChannel('kiro/llm/events');
  static const _models = MethodChannel('kiro/models');
  static const _modelEvents = EventChannel('kiro/models/events');
  static const _files = MethodChannel('kiro/files');

  Stream<Map<Object?, Object?>>? _llmStream;
  Stream<Map<Object?, Object?>>? _modelStream;

  // ---- device / security ----
  Future<DeviceInfo?> deviceInfo() async {
    try {
      final m = await _device.invokeMapMethod<Object?, Object?>('info');
      return m == null ? null : DeviceInfo.fromMap(m);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<SecurityStatus> security() async {
    try {
      final m = await _device.invokeMapMethod<Object?, Object?>('security');
      return m == null ? SecurityStatus.clean : SecurityStatus.fromMap(m);
    } on MissingPluginException {
      return SecurityStatus.clean;
    } on PlatformException {
      return SecurityStatus.clean;
    }
  }

  Future<void> setSecureScreen(bool enabled) async {
    try {
      await _device.invokeMethod<void>('setSecure', {'enabled': enabled});
    } on MissingPluginException {
      // Not on Android (tests).
    }
  }

  Future<bool> requestNotifications() async {
    try {
      return await _device.invokeMethod<bool>('requestNotifications') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  // ---- llm ----
  Stream<Map<Object?, Object?>> get llmEvents =>
      _llmStream ??= _llmEvents.receiveBroadcastStream().map((e) => (e as Map<Object?, Object?>)).asBroadcastStream();

  Future<Map<Object?, Object?>> llmLoad({
    required String path,
    required int nCtx,
    required int threads,
    bool force = false,
  }) async {
    final r = await _llm.invokeMapMethod<Object?, Object?>(
      'load',
      {'path': path, 'nCtx': nCtx, 'threads': threads, 'force': force},
    );
    return r ?? const {'ok': false, 'code': 'unknown'};
  }

  Future<void> llmUnload() async => _llm.invokeMapMethod<Object?, Object?>('unload');

  Future<Map<Object?, Object?>> llmStatus() async =>
      await _llm.invokeMapMethod<Object?, Object?>('status') ?? const {'ok': false};

  Future<void> llmGenerate({
    required int id,
    required List<Map<String, String>> messages,
    required int maxTokens,
    required double temperature,
    double topP = 0.9,
    int topK = 40,
    double repeatPenalty = 1.1,
  }) async {
    await _llm.invokeMethod<bool>('generate', {
      'id': id,
      'messages': messages,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
      'topK': topK,
      'repeatPenalty': repeatPenalty,
    });
  }

  Future<void> llmCancel(int id) async => _llm.invokeMethod<bool>('cancel', {'id': id});

  // ---- models ----
  Stream<Map<Object?, Object?>> get modelEvents =>
      _modelStream ??= _modelEvents.receiveBroadcastStream().map((e) => (e as Map<Object?, Object?>)).asBroadcastStream();

  Future<String?> modelsDir() async {
    try {
      return await _models.invokeMethod<String>('dir');
    } on MissingPluginException {
      return null;
    }
  }

  Future<List<String>> activeDownloads() async {
    try {
      final r = await _models.invokeListMethod<String>('active');
      return r ?? const [];
    } on MissingPluginException {
      return const [];
    }
  }

  Future<void> startDownload({
    required String id,
    required String url,
    required String sha256,
    required int size,
    required String fileName,
    required String title,
  }) async {
    await _models.invokeMethod<bool>('download', {
      'id': id,
      'url': url,
      'sha256': sha256,
      'size': size,
      'fileName': fileName,
      'title': title,
    });
  }

  Future<void> cancelDownload(String id) async => _models.invokeMethod<bool>('cancel', {'id': id});

  Future<void> deletePartial(String fileName) async =>
      _models.invokeMethod<bool>('deletePart', {'fileName': fileName});

  /// Opens the system file picker and copies the chosen .gguf into app storage.
  /// Returns null when the user cancels. Throws PlatformException with a code on failure.
  Future<Map<Object?, Object?>?> importModel() async => _models.invokeMapMethod<Object?, Object?>('import');

  // ---- files ----
  Future<({String name, String content})?> openTextFile() async {
    final r = await _files.invokeMapMethod<Object?, Object?>('openText');
    if (r == null) return null;
    return (name: (r['name'] as String?) ?? 'file.md', content: (r['content'] as String?) ?? '');
  }

  Future<bool> saveTextFile(String name, String content) async =>
      await _files.invokeMethod<bool>('saveText', {'name': name, 'content': content}) ?? false;
}
