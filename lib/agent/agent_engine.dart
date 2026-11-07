import 'dart:async';
import 'dart:convert';

import '../llm/llm_backend.dart';
import '../skills/skill.dart';
import 'tool_call_parser.dart';
import 'tools.dart';

sealed class AgentEvent {
  const AgentEvent();
}

/// Streaming text of the current step (may turn out to be a tool call).
class AgentDelta extends AgentEvent {
  const AgentDelta(this.step, this.buffer);
  final int step;
  final String buffer;
}

class AgentToolStarted extends AgentEvent {
  const AgentToolStarted(this.step, this.call);
  final int step;
  final ToolCall call;
}

class AgentToolFinished extends AgentEvent {
  const AgentToolFinished(this.step, this.call, this.result);
  final int step;
  final ToolCall call;
  final ToolResult result;
}

class AgentFinal extends AgentEvent {
  const AgentFinal(this.text);
  final String text;
}

class AgentFailed extends AgentEvent {
  const AgentFailed(this.error);
  final LlmException error;
}

/// Builds the system prompt: identity, tool protocol, tool list and the active skill.
String buildSystemPrompt({required Iterable<AgentTool> tools, Skill? skill, required String language}) {
  final b = StringBuffer()
    ..writeln('You are Kiro (کیرو), an Instagram content assistant that runs on the user\'s phone.')
    ..writeln(language == 'en'
        ? 'Reply in the language the user writes in (English by default).'
        : 'Reply in the language the user writes in (Persian/Farsi by default).')
    ..writeln()
    ..writeln('TOOLS. To use a tool, reply with ONLY one JSON object and nothing else, exactly like:')
    ..writeln('{"tool": "write_caption", "args": {"topic": "...", "language": "fa"}}')
    ..writeln('After a TOOL_RESULT message you may call another tool or give the final answer.')
    ..writeln('The final answer is normal text for the user (never JSON). Show the content the tools produced.')
    ..writeln('Use tools only when they help; answer simple questions directly.')
    ..writeln('Available tools:');
  for (final t in tools) {
    b.writeln('- ${t.usage}');
  }
  if (skill != null) {
    b
      ..writeln()
      ..writeln(skill.toPromptBlock());
  }
  return b.toString().trim();
}

/// Multi-step agent: generate → maybe call a tool → feed the result back → repeat.
class AgentEngine {
  AgentEngine({
    required this.backend,
    required this.registry,
    required this.options,
    this.maxSteps = 4,
    this.historyBudgetChars = 6000,
  });

  final LlmBackend backend;
  final ToolRegistry registry;
  final GenerationOptions options;
  final int maxSteps;
  final int historyBudgetChars;

  Stream<AgentEvent> run({
    required List<ChatMessage> history,
    required String userMessage,
    required ToolContext context,
    CancelToken? cancel,
  }) async* {
    final convo = <ChatMessage>[...trimHistory(history, historyBudgetChars), ChatMessage.user(userMessage)];
    var budget = historyBudgetChars;
    var lastToolOutput = '';

    for (var step = 1; step <= maxSteps; step++) {
      final system = buildSystemPrompt(tools: registry.tools, skill: context.activeSkill, language: context.language);
      final buffer = StringBuffer();
      try {
        await for (final chunk in backend.generate([ChatMessage.system(system), ...convo], options, cancel: cancel)) {
          buffer.write(chunk);
          yield AgentDelta(step, buffer.toString());
        }
      } on LlmException catch (e) {
        if (e.code == 'prompt_too_long' && convo.length > 1 && budget > 800) {
          // Drop older turns and retry this step once with a smaller window.
          budget = budget ~/ 2;
          final trimmed = trimHistory(convo, budget);
          convo
            ..clear()
            ..addAll(trimmed);
          step--;
          continue;
        }
        yield AgentFailed(e);
        return;
      }
      if (cancel?.isCancelled ?? false) {
        yield AgentFinal(buffer.toString().trim());
        return;
      }

      final output = buffer.toString();
      final call = ToolCallParser.parse(output);
      if (call == null) {
        yield AgentFinal(output.trim());
        return;
      }

      yield AgentToolStarted(step, call);
      final tool = registry[call.name];
      ToolResult result;
      if (tool == null) {
        result = ToolResult(false, {
          'error': 'unknown tool "${call.name}"',
          'available': registry.tools.map((t) => t.name).toList(),
        });
      } else {
        try {
          result = await tool.run(call.args, context);
        } on LlmException catch (e) {
          if (cancel?.isCancelled ?? false) {
            yield const AgentFinal('');
            return;
          }
          result = ToolResult(false, {'error': e.code});
        }
      }
      yield AgentToolFinished(step, call, result);
      lastToolOutput = result.toJson();

      convo
        ..add(ChatMessage.assistant(jsonEncode({'tool': call.name, 'args': call.args})))
        ..add(ChatMessage.user('TOOL_RESULT ${call.name}: $lastToolOutput\n'
            'Continue: call another tool if needed, otherwise write the final answer for the user.'));
    }

    // Step budget exhausted: ask once for a plain final answer.
    final buffer = StringBuffer();
    try {
      final system = buildSystemPrompt(tools: const [], skill: context.activeSkill, language: context.language);
      convo.add(const ChatMessage.user('Now write the final answer for the user as plain text. Do not call tools.'));
      await for (final chunk in backend.generate([ChatMessage.system(system), ...convo], options, cancel: cancel)) {
        buffer.write(chunk);
        yield AgentDelta(maxSteps + 1, buffer.toString());
      }
    } on LlmException catch (e) {
      yield AgentFailed(e);
      return;
    }
    final text = buffer.toString().trim();
    yield AgentFinal(ToolCallParser.parse(text) == null ? text : lastToolOutput);
  }
}
