import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/data/settings.dart';
import 'package:kiro/llm/llm_backend.dart';
import 'package:kiro/llm/remote_backend.dart';

void main() {
  test('parses Gemini SSE chunks and skips thoughts', () {
    const line = 'data: {"candidates":[{"content":{"parts":[{"text":"think","thought":true},{"text":"سلام"}],"role":"model"}}]}';
    expect(parseSseLine(line, RemoteProvider.gemini)!.text, 'سلام');
  });

  test('parses OpenAI-compatible deltas and [DONE]', () {
    expect(parseSseLine('data: {"choices":[{"delta":{"content":"Hi"}}]}', RemoteProvider.openAiCompatible)!.text, 'Hi');
    expect(parseSseLine('data: [DONE]', RemoteProvider.openAiCompatible)!.done, isTrue);
    expect(parseSseLine(': keep-alive', RemoteProvider.openAiCompatible), isNull);
    expect(parseSseLine('', RemoteProvider.gemini), isNull);
  });

  test('API errors inside the stream throw', () {
    expect(
      () => parseSseLine('data: {"error":{"message":"quota"}}', RemoteProvider.gemini),
      throwsA(isA<LlmException>()),
    );
  });

  test('base URL validation is HTTPS-only', () {
    expect(RemoteBackend.validateBaseUrl('https://api.example.com/v1'), isNull);
    expect(RemoteBackend.validateBaseUrl('http://api.example.com/v1'), 'https_only');
    expect(RemoteBackend.validateBaseUrl('not a url'), 'invalid_url');
    expect(RemoteBackend.validateBaseUrl('https://user:pw@host.com'), 'invalid_url');
  });

  test('refuses to run without a key', () async {
    final b = RemoteBackend(provider: RemoteProvider.gemini, apiKey: '', model: 'm');
    expect(b.generate(const [ChatMessage.user('x')], const GenerationOptions()).toList(), throwsA(isA<LlmException>()));
  });
}
