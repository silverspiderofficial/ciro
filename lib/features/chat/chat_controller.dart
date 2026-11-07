import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../agent/agent_engine.dart';
import '../../agent/content_generator.dart';
import '../../agent/tool_call_parser.dart';
import '../../agent/tools.dart';
import '../../app/services.dart';
import '../../data/repositories.dart';
import '../../llm/llm_backend.dart';
import '../../skills/skill.dart';

/// A tool step shown live while the agent runs.
class LiveStep {
  LiveStep(this.call);
  final ToolCall call;
  ToolResult? result;
}

/// Chat state: current conversation, persisted messages and the live agent run.
class ChatController extends ChangeNotifier {
  ChatController(this._services);

  final AppServices _services;

  int? conversationId;
  List<StoredMessage> messages = [];
  List<Conversation> conversations = [];

  bool running = false;
  String liveText = '';
  bool liveIsTool = false;
  final List<LiveStep> liveSteps = [];

  /// Error code of the last failed run (localised by the UI).
  String? errorCode;

  CancelToken? _cancel;
  bool _disposed = false;

  Skill? get activeSkill => _services.skills.byId(_services.settings.activeSkillId);

  Future<void> init() async {
    conversations = await _services.chats.conversations();
    if (conversations.isNotEmpty) {
      await open(conversations.first.id);
    } else {
      _notify();
    }
  }

  Future<void> open(int id) async {
    conversationId = id;
    messages = await _services.chats.messages(id);
    errorCode = null;
    _notify();
  }

  void newConversation() {
    if (running) return;
    conversationId = null;
    messages = [];
    errorCode = null;
    _notify();
  }

  Future<void> deleteConversation(int id) async {
    await _services.chats.deleteConversation(id);
    conversations = await _services.chats.conversations();
    if (conversationId == id) {
      conversationId = null;
      messages = [];
    }
    _notify();
  }

  Future<void> setActiveSkill(Skill? skill) async {
    await _services.settings.setActiveSkillId(skill?.id);
    _notify();
  }

  void stop() {
    _cancel?.cancel();
  }

  /// History sent to the model: user turns and final assistant answers (tool steps omitted).
  List<ChatMessage> _history() => messages
      .where((m) => m.role == 'user' || m.role == 'assistant')
      .where((m) => m.content.trim().isNotEmpty)
      .map((m) => ChatMessage(m.role, m.content))
      .toList();

  Future<void> send(String text) async {
    final input = text.trim();
    if (input.isEmpty || running) return;
    errorCode = null;

    final backend = await _services.resolveBackend();
    if (!backend.isRemote) {
      final err = await _services.ensureModelLoaded();
      if (err != null) {
        errorCode = err;
        _notify();
        return;
      }
    }

    var convId = conversationId;
    if (convId == null) {
      final title = input.length > 40 ? '${input.substring(0, 40)}…' : input;
      convId = await _services.chats.createConversation(title);
      conversationId = convId;
    }
    final history = _history();
    messages = [
      ...messages,
      await _services.chats.addMessage(StoredMessage(
        conversationId: convId,
        role: 'user',
        content: input,
        createdAt: DateTime.now(),
      )),
    ];

    running = true;
    liveText = '';
    liveIsTool = false;
    liveSteps.clear();
    _cancel = CancelToken();
    _notify();

    final options = _services.generationOptions;
    final contextChars = _services.settings.contextSize * 2;
    final engine = AgentEngine(
      backend: backend,
      registry: ToolRegistry.standard(),
      options: options,
      maxSteps: _services.settings.agentMaxSteps,
      historyBudgetChars: backend.isRemote ? 24000 : (contextChars - options.maxTokens * 3).clamp(1200, 24000),
    );
    final toolContext = ToolContext(
      generator: ContentGenerator(backend, options: options),
      skills: _services.skills,
      drafts: _services.drafts,
      activeSkill: activeSkill,
      onSkillApplied: (skill) => _services.settings.setActiveSkillId(skill.id),
      language: _services.settings.languageCode,
      cancel: _cancel,
    );

    try {
      await for (final event in engine.run(
        history: history,
        userMessage: input,
        context: toolContext,
        cancel: _cancel,
      )) {
        switch (event) {
          case AgentDelta(:final buffer):
            liveText = buffer;
            liveIsTool = ToolCallParser.looksLikeToolCallStart(buffer);
          case AgentToolStarted(:final call):
            liveText = '';
            liveIsTool = false;
            liveSteps.add(LiveStep(call));
          case AgentToolFinished(:final call, :final result):
            if (liveSteps.isNotEmpty) liveSteps.last.result = result;
            messages = [
              ...messages,
              await _services.chats.addMessage(StoredMessage(
                conversationId: convId,
                role: 'tool',
                content: result.toJson(),
                toolName: call.name,
                toolArgs: jsonEncode(call.args),
                toolOk: result.ok,
                createdAt: DateTime.now(),
              )),
            ];
            liveSteps.clear();
          case AgentFinal(:final text):
            final cancelled = _cancel?.isCancelled ?? false;
            final finalText = text.isEmpty && cancelled ? '' : text;
            if (finalText.isNotEmpty) {
              messages = [
                ...messages,
                await _services.chats.addMessage(StoredMessage(
                  conversationId: convId,
                  role: 'assistant',
                  content: finalText,
                  createdAt: DateTime.now(),
                )),
              ];
            }
          case AgentFailed(:final error):
            errorCode = error.code;
        }
        _notify();
      }
    } finally {
      running = false;
      liveText = '';
      liveIsTool = false;
      liveSteps.clear();
      _cancel = null;
      conversations = await _services.chats.conversations();
      _notify();
    }
  }

  Future<void> saveToDrafts(String content) async {
    final firstLine = content.trim().split('\n').first;
    await _services.drafts.add(Draft(
      title: firstLine.length > 60 ? '${firstLine.substring(0, 60)}…' : firstLine,
      content: content.trim(),
      createdAt: DateTime.now(),
    ));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
