import 'dart:async';

import 'package:kiro/core/native_bridge.dart';
import 'package:kiro/data/device_info.dart';
import 'package:kiro/llm/llm_backend.dart';

/// Backend that replays scripted replies (one per generate call) and records prompts.
class ScriptedBackend implements LlmBackend {
  ScriptedBackend(this.replies);
  final List<String> replies;
  final List<List<ChatMessage>> prompts = [];
  int calls = 0;

  @override
  String get label => 'fake';
  @override
  bool get isRemote => false;

  @override
  Stream<String> generate(List<ChatMessage> messages, GenerationOptions options, {CancelToken? cancel}) async* {
    prompts.add(List.of(messages));
    final reply = calls < replies.length ? replies[calls] : 'done';
    calls++;
    // stream in small chunks like the real engine
    for (var i = 0; i < reply.length; i += 7) {
      yield reply.substring(i, i + 7 > reply.length ? reply.length : i + 7);
    }
  }
}

class FailingBackend implements LlmBackend {
  FailingBackend(this.code);
  final String code;
  @override
  String get label => 'fail';
  @override
  bool get isRemote => false;
  @override
  Stream<String> generate(List<ChatMessage> messages, GenerationOptions options, {CancelToken? cancel}) =>
      Stream<String>.error(LlmException(code));
}

/// Platform bridge stand-in for widget tests (no method channels).
class FakeBridge extends NativeBridge {
  @override
  Stream<Map<Object?, Object?>> get llmEvents => const Stream.empty();
  @override
  Stream<Map<Object?, Object?>> get modelEvents => const Stream.empty();
  @override
  Future<DeviceInfo?> deviceInfo() async => const DeviceInfo(
        totalRamBytes: 8 * 1024 * 1024 * 1024,
        availRamBytes: 3 * 1024 * 1024 * 1024,
        cores: 8,
        bigCores: 4,
        maxFreqMhz: 3000,
        soc: 'SM8550',
        socManufacturer: 'QTI',
        manufacturer: 'Test',
        model: 'Phone',
        sdkInt: 34,
        release: '14',
        abis: ['arm64-v8a'],
        dotprod: true,
        i8mm: true,
        freeStorageBytes: 50 * 1024 * 1024 * 1024,
      );
  @override
  Future<SecurityStatus> security() async => SecurityStatus.clean;
  @override
  Future<void> setSecureScreen(bool enabled) async {}
  @override
  Future<String?> modelsDir() async => null;
  @override
  Future<List<String>> activeDownloads() async => const [];
  @override
  Future<Map<Object?, Object?>> llmStatus() async => const {'ok': false};
}
