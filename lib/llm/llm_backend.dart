/// Common types for the on-device and the optional remote model backends.
library;

class ChatMessage {
  const ChatMessage(this.role, this.content);
  const ChatMessage.system(this.content) : role = 'system';
  const ChatMessage.user(this.content) : role = 'user';
  const ChatMessage.assistant(this.content) : role = 'assistant';

  /// system | user | assistant
  final String role;
  final String content;

  Map<String, String> toMap() => {'role': role, 'content': content};

  @override
  String toString() => '$role: $content';
}

class GenerationOptions {
  const GenerationOptions({this.maxTokens = 512, this.temperature = 0.7});
  final int maxTokens;
  final double temperature;

  GenerationOptions copyWith({int? maxTokens, double? temperature}) =>
      GenerationOptions(maxTokens: maxTokens ?? this.maxTokens, temperature: temperature ?? this.temperature);
}

/// Error codes surfaced to the UI (localised there).
class LlmException implements Exception {
  const LlmException(this.code, [this.detail]);

  /// e.g. no_model, not_loaded, process_died, prompt_too_long, low_ram, network, auth, http_429 ...
  final String code;
  final String? detail;

  @override
  String toString() => 'LlmException($code${detail == null ? '' : ': $detail'})';
}

/// Lets the caller stop a generation in flight.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

abstract class LlmBackend {
  /// Short label for the UI ("on-device", "Gemini", ...).
  String get label;
  bool get isRemote;

  /// Streams text chunks. Completes when generation ends; errors with [LlmException].
  Stream<String> generate(List<ChatMessage> messages, GenerationOptions options, {CancelToken? cancel});
}

/// Collects a whole generation into one string.
Future<String> generateText(
  LlmBackend backend,
  List<ChatMessage> messages,
  GenerationOptions options, {
  CancelToken? cancel,
}) async {
  final b = StringBuffer();
  await for (final chunk in backend.generate(messages, options, cancel: cancel)) {
    b.write(chunk);
  }
  return b.toString();
}

/// Keeps the newest messages that fit in [budgetChars]; never drops the last message.
List<ChatMessage> trimHistory(List<ChatMessage> history, int budgetChars) {
  if (history.isEmpty) return history;
  final kept = <ChatMessage>[];
  var used = 0;
  for (var i = history.length - 1; i >= 0; i--) {
    final m = history[i];
    final cost = m.content.length + 16;
    if (kept.isNotEmpty && used + cost > budgetChars) break;
    kept.insert(0, m);
    used += cost;
  }
  // Templates expect the conversation to start with a user turn.
  while (kept.length > 1 && kept.first.role != 'user') {
    kept.removeAt(0);
  }
  return kept;
}
