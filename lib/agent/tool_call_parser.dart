import 'dart:convert';

/// A tool invocation requested by the model.
class ToolCall {
  const ToolCall(this.name, this.args);
  final String name;
  final Map<String, Object?> args;

  @override
  String toString() => 'ToolCall($name, $args)';
}

/// Extracts a JSON tool call from free-form model output.
///
/// Accepted shapes (small models are inconsistent, so all are tolerated):
/// - `{"tool": "write_caption", "args": {...}}` (Kiro's own protocol)
/// - `{"name": "...", "arguments": {...}}` / `"parameters"` (Qwen / Llama style)
/// - `{"function": {"name": "...", "arguments": "{...}"}}` (OpenAI style, args may be a string)
/// wrapped in ```json fences, `<tool_call>` tags or surrounded by short prose.
class ToolCallParser {
  static ToolCall? parse(String output) {
    final text = output.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    if (text.isEmpty) return null;

    final candidates = <String>[];
    final tagged = RegExp(r'<tool_call>\s*([\s\S]*?)\s*(?:</tool_call>|$)').firstMatch(text);
    if (tagged != null) candidates.add(tagged.group(1)!);
    for (final m in RegExp(r'```(?:json|JSON|tool|tool_call)?\s*\n?([\s\S]*?)```').allMatches(text)) {
      candidates.add(m.group(1)!);
    }
    candidates.add(text);

    for (final c in candidates) {
      for (final obj in _jsonObjects(c)) {
        final call = _toCall(obj);
        if (call != null) return call;
      }
    }
    return null;
  }

  /// True when a streaming buffer is probably the start of a tool call, so the UI can show
  /// "using a tool…" instead of raw JSON.
  static bool looksLikeToolCallStart(String buffer) {
    final t = buffer.trimLeft();
    if (t.isEmpty) return false;
    return t.startsWith('{') || t.startsWith('```') || t.startsWith('<tool_call>');
  }

  static ToolCall? _toCall(Object? decoded) {
    if (decoded is! Map<String, Object?>) return null;
    var m = decoded;
    if (m['function'] is Map<String, Object?>) m = m['function'] as Map<String, Object?>;
    final rawName = m['tool'] ?? m['name'] ?? m['tool_name'];
    if (rawName is! String || rawName.trim().isEmpty) return null;
    final rawArgs = m['args'] ?? m['arguments'] ?? m['parameters'] ?? m['input'];
    Map<String, Object?> args = const {};
    if (rawArgs is Map<String, Object?>) {
      args = rawArgs;
    } else if (rawArgs is String && rawArgs.trim().isNotEmpty) {
      final inner = _decodeLenient(rawArgs);
      if (inner is Map<String, Object?>) args = inner;
    } else if (rawArgs == null) {
      // Flat style: {"tool": "x", "topic": "..."}
      args = Map.of(m)
        ..remove('tool')
        ..remove('name')
        ..remove('tool_name');
    }
    return ToolCall(rawName.trim(), args);
  }

  /// Yields every balanced top-level JSON object found in [text].
  static Iterable<Object?> _jsonObjects(String text) sync* {
    var i = 0;
    while (i < text.length) {
      final start = text.indexOf('{', i);
      if (start < 0) return;
      final end = _matchBrace(text, start);
      if (end < 0) {
        // Unterminated (generation cut off): try to close it.
        final repaired = _decodeLenient('${text.substring(start)}}');
        if (repaired != null) yield repaired;
        return;
      }
      final decoded = _decodeLenient(text.substring(start, end + 1));
      if (decoded != null) {
        yield decoded;
        i = end + 1;
      } else {
        i = start + 1;
      }
    }
  }

  static int _matchBrace(String s, int start) {
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (c == r'\') {
          escape = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static Object? _decodeLenient(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      // Common small-model slips: trailing commas, smart quotes.
      final fixed = s
          .replaceAllMapped(RegExp(r',\s*([}\]])'), (m) => m.group(1)!)
          .replaceAll('“', '"')
          .replaceAll('”', '"');
      try {
        return jsonDecode(fixed);
      } on FormatException {
        return null;
      }
    }
  }
}

/// Reads a string argument, accepting a few common aliases.
String argString(Map<String, Object?> args, List<String> keys, {String fallback = ''}) {
  for (final k in keys) {
    final v = args[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is num) return v.toString();
    if (v is List<Object?>) return v.whereType<String>().join(' ');
  }
  return fallback;
}

int argInt(Map<String, Object?> args, List<String> keys, {required int fallback, int? min, int? max}) {
  for (final k in keys) {
    final v = args[k];
    int? n;
    if (v is num) n = v.toInt();
    if (v is String) n = int.tryParse(v.trim());
    if (n != null) {
      if (min != null && n < min) n = min;
      if (max != null && n > max) n = max;
      return n;
    }
  }
  return fallback;
}

List<String> argList(Map<String, Object?> args, List<String> keys) {
  for (final k in keys) {
    final v = args[k];
    if (v is List<Object?>) return v.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();
    if (v is String && v.trim().isNotEmpty) return v.split(RegExp(r'[\s,،]+')).where((e) => e.isNotEmpty).toList();
  }
  return const [];
}
