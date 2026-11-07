import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/settings.dart';
import 'llm_backend.dart';

/// Optional cloud backend using the user's own API key (never bundled with the app).
/// Gemini: Google AI Studio REST (generativelanguage.googleapis.com).
/// OpenAI-compatible: any HTTPS base URL exposing POST /chat/completions with SSE streaming.
class RemoteBackend implements LlmBackend {
  RemoteBackend({
    required this.provider,
    required this.apiKey,
    required this.model,
    this.baseUrl = '',
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final RemoteProvider provider;
  final String apiKey;
  final String model;
  final String baseUrl;
  final http.Client Function() _clientFactory;

  static const geminiHost = 'generativelanguage.googleapis.com';

  @override
  String get label => provider == RemoteProvider.gemini ? 'Gemini' : 'API';

  @override
  bool get isRemote => true;

  /// Validates an OpenAI-compatible base URL: HTTPS only, no credentials in the URL.
  static String? validateBaseUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) return 'invalid_url';
    if (u.scheme != 'https') return 'https_only';
    if (u.userInfo.isNotEmpty) return 'invalid_url';
    return null;
  }

  Uri _endpoint() {
    if (provider == RemoteProvider.gemini) {
      final m = Uri.encodeComponent(model.isEmpty ? SettingsController.defaultGeminiModel : model);
      return Uri.https(geminiHost, '/v1beta/models/$m:streamGenerateContent', {'alt': 'sse'});
    }
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse('$base/chat/completions');
  }

  Map<String, Object?> _body(List<ChatMessage> messages, GenerationOptions o) {
    if (provider == RemoteProvider.gemini) {
      final system = messages.where((m) => m.role == 'system').map((m) => m.content).join('\n\n');
      final contents = messages
          .where((m) => m.role != 'system')
          .map((m) => {
                'role': m.role == 'assistant' ? 'model' : 'user',
                'parts': [
                  {'text': m.content},
                ],
              })
          .toList();
      return {
        if (system.isNotEmpty)
          'systemInstruction': {
            'parts': [
              {'text': system},
            ],
          },
        'contents': contents,
        'generationConfig': {'temperature': o.temperature, 'maxOutputTokens': o.maxTokens},
      };
    }
    return {
      'model': model,
      'messages': messages.map((m) => m.toMap()).toList(),
      'stream': true,
      'temperature': o.temperature,
      'max_tokens': o.maxTokens,
    };
  }

  Map<String, String> _headers() => provider == RemoteProvider.gemini
      ? {'Content-Type': 'application/json', 'x-goog-api-key': apiKey, 'Accept': 'text/event-stream'}
      : {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey', 'Accept': 'text/event-stream'};

  @override
  Stream<String> generate(List<ChatMessage> messages, GenerationOptions options, {CancelToken? cancel}) async* {
    if (apiKey.isEmpty) throw const LlmException('no_api_key');
    if (provider == RemoteProvider.openAiCompatible) {
      final err = validateBaseUrl(baseUrl);
      if (err != null) throw LlmException(err);
    }
    final client = _clientFactory();
    cancel?.onCancel(client.close);
    try {
      final req = http.Request('POST', _endpoint())
        ..headers.addAll(_headers())
        ..body = jsonEncode(_body(messages, options));
      final http.StreamedResponse resp;
      try {
        resp = await client.send(req).timeout(const Duration(seconds: 60));
      } on TimeoutException {
        throw const LlmException('timeout');
      } on http.ClientException {
        if (cancel?.isCancelled ?? false) return;
        throw const LlmException('network');
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw LlmException('auth', '${resp.statusCode}');
      }
      if (resp.statusCode != 200) {
        throw LlmException('http_${resp.statusCode}');
      }
      final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      try {
        await for (final line in lines) {
          if (cancel?.isCancelled ?? false) return;
          final event = parseSseLine(line, provider);
          if (event == null) continue;
          if (event.done) return;
          if (event.text.isNotEmpty) yield event.text;
        }
      } on http.ClientException {
        if (cancel?.isCancelled ?? false) return;
        throw const LlmException('network');
      }
    } finally {
      client.close();
    }
  }
}

class SseEvent {
  const SseEvent(this.text, {this.done = false});
  final String text;
  final bool done;
}

/// Parses one Server-Sent-Events line from Gemini or an OpenAI-compatible stream.
/// Returns null for comments, blank lines and non-data fields.
SseEvent? parseSseLine(String line, RemoteProvider provider) {
  final l = line.trim();
  if (!l.startsWith('data:')) return null;
  final payload = l.substring(5).trim();
  if (payload.isEmpty) return null;
  if (payload == '[DONE]') return const SseEvent('', done: true);
  Object? json;
  try {
    json = jsonDecode(payload);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, Object?>) return null;
  if (json['error'] is Map) {
    final err = json['error'] as Map<Object?, Object?>;
    throw LlmException('api_error', err['message']?.toString());
  }
  if (provider == RemoteProvider.gemini) {
    final candidates = json['candidates'];
    if (candidates is! List<Object?> || candidates.isEmpty) return const SseEvent('');
    final first = candidates.first;
    if (first is! Map<String, Object?>) return const SseEvent('');
    final content = first['content'];
    final b = StringBuffer();
    if (content is Map<String, Object?>) {
      final parts = content['parts'];
      if (parts is List<Object?>) {
        for (final p in parts) {
          if (p is Map<String, Object?> && p['thought'] != true && p['text'] is String) b.write(p['text']);
        }
      }
    }
    return SseEvent(b.toString());
  }
  final choices = json['choices'];
  if (choices is! List<Object?> || choices.isEmpty) return const SseEvent('');
  final c = choices.first;
  if (c is! Map<String, Object?>) return const SseEvent('');
  final delta = c['delta'];
  if (delta is Map<String, Object?> && delta['content'] is String) return SseEvent(delta['content'] as String);
  return const SseEvent('');
}
