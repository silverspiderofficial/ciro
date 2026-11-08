import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../billing/billing.dart';
import '../billing/billing_controller.dart';
import '../billing/paid_ui.dart';
import '../billing/pay_sheet.dart';

import '../../app/services.dart';
import '../../data/repositories.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../llm/local_backend.dart';
import '../../skills/skill_repository.dart';
import '../caption/caption_screen.dart';
import '../common/engine_banner.dart';
import '../drafts/drafts_screen.dart';
import 'chat_controller.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ChatController>(
      create: (ctx) => ChatController(ctx.read<AppServices>())..init(),
      child: const _ChatView(),
    );
  }
}

class _ChatView extends StatefulWidget {
  const _ChatView();

  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _ownKey = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshOwnKey();
  }

  /// Whether replies go through the user's own API key (free, no price shown).
  Future<void> _refreshOwnKey() async {
    final own = await context.read<AppServices>().usesOwnApiKey();
    if (mounted && own != _ownKey) setState(() => _ownKey = own);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(ChatController chat) async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    final sent = await chat.send(text);
    if (mounted) await _refreshOwnKey();
    // Not sent (e.g. not enough credit): give the text back so nothing is lost.
    if (!sent && mounted && _input.text.isEmpty) _input.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final chat = context.watch<ChatController>();
    final engine = context.watch<LocalEngine>();
    context.watch<SkillRepository>();
    final skill = chat.activeSkill;
    final billing = context.watch<BillingController>();
    context.watch<SettingsController>();

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('appName')),
        actions: [
          IconButton(
            tooltip: s.t('openCaptionTool'),
            icon: const Icon(Icons.tag),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CaptionScreen())),
          ),
          IconButton(
            tooltip: s.t('openDrafts'),
            icon: const Icon(Icons.drafts_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DraftsScreen())),
          ),
          IconButton(
            tooltip: s.t('newChat'),
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: chat.running ? null : chat.newConversation,
          ),
        ],
      ),
      drawer: _ConversationsDrawer(chat: chat),
      body: Column(
        children: [
          const EngineBanner(),
          Expanded(
            child: chat.messages.isEmpty && !chat.running
                ? _EmptyChat(onPick: (t) => _input.text = t)
                : _MessageList(chat: chat, controller: _scroll),
          ),
          if (chat.errorCode != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.error_outline),
                title: Text(errorMessage(s, chat.errorCode!, engine: engine)),
                trailing: chat.errorCode == 'process_died' || chat.errorCode == 'not_loaded'
                    ? TextButton(onPressed: () => loadActiveModel(context), child: Text(s.t('loadModel')))
                    : chat.errorCode == 'billing_insufficientFunds'
                        ? TextButton(
                            onPressed: () => showPaySheet(context, nanotons: billing.quote(PaidFeature.aiText).listPrice ?? 0),
                            child: Text(s.t('billAddCreditShort')),
                          )
                        : null,
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.psychology_outlined, size: 18),
                        label: Text(skill == null ? s.t('noSkill') : s.t('activeSkill', {'name': skill.name})),
                        onPressed: chat.running ? null : () => _pickSkill(context, chat),
                      ),
                      PriceLine(quote: billing.gate.quoteAiText(ownApiKey: _ownKey), labelKey: 'pricePerReply'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: s.t('chatHint'),
                            isDense: true,
                            border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      chat.running
                          ? IconButton.filledTonal(tooltip: s.t('stop'), onPressed: chat.stop, icon: const Icon(Icons.stop))
                          : IconButton.filled(
                              tooltip: s.t('send'),
                              onPressed: () => _send(chat),
                              icon: const Icon(Icons.send),
                            ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSkill(BuildContext context, ChatController chat) async {
    final skills = context.read<SkillRepository>().skills;
    final s = context.sRead;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(s.t('chooseSkill'), style: Theme.of(ctx).textTheme.titleMedium)),
            ListTile(
              leading: const Icon(Icons.block),
              title: Text(s.t('noSkill')),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final sk in skills)
              ListTile(
                leading: Icon(sk.id == chat.activeSkill?.id ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(sk.name),
                subtitle: Text(sk.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, sk.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final repo = context.mounted ? context.read<SkillRepository>() : null;
    await chat.setActiveSkill(picked.isEmpty ? null : repo?.byId(picked));
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        Icon(Icons.auto_awesome, size: 48, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text(s.t('emptyChatTitle'), textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(s.t('emptyChatBody'), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        for (final k in ['suggestion1', 'suggestion2', 'suggestion3'])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(onPressed: () => onPick(s.t(k)), child: Text(s.t(k), textAlign: TextAlign.center)),
          ),
      ],
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.chat, required this.controller});
  final ChatController chat;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final items = <Widget>[];
    var step = 0;
    for (final m in chat.messages) {
      if (m.isTool) {
        step++;
        items.add(_ToolStepCard(
          step: step,
          name: m.toolName ?? '',
          args: m.toolArgs ?? '{}',
          result: m.content,
          ok: m.toolOk,
          running: false,
        ));
      } else {
        if (m.role == 'user') step = 0;
        items.add(_Bubble(message: m, onSave: m.role == 'assistant' ? () => _save(context, m.content) : null));
      }
    }
    if (chat.running) {
      for (final live in chat.liveSteps) {
        step++;
        items.add(_ToolStepCard(
          step: step,
          name: live.call.name,
          args: jsonEncode(live.call.args),
          result: live.result?.toJson(),
          ok: live.result?.ok ?? true,
          running: live.result == null,
        ));
      }
      if (chat.liveSteps.isEmpty) {
        items.add(_LiveBubble(
          text: chat.liveIsTool ? s.t('usingTool') : (chat.liveText.isEmpty ? s.t('thinking') : chat.liveText),
          pending: chat.liveText.isEmpty || chat.liveIsTool,
        ));
      }
    }
    // reverse: newest at the bottom without manual scrolling.
    return ListView(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: items.reversed.toList(),
    );
  }

  Future<void> _save(BuildContext context, String content) async {
    final chat = context.read<ChatController>();
    final messenger = ScaffoldMessenger.of(context);
    final s = context.sRead;
    await chat.saveToDrafts(content);
    messenger.showSnackBar(SnackBar(content: Text(s.t('savedToDrafts'))));
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.onSave});
  final StoredMessage message;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final mine = message.role == 'user';
    return Align(
      alignment: mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        child: Card(
          color: mine ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(message.content),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      tooltip: s.t('copy'),
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: message.content));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('copied'))));
                      },
                    ),
                    if (onSave != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        tooltip: s.t('saveToDrafts'),
                        icon: const Icon(Icons.bookmark_add_outlined),
                        onPressed: onSave,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveBubble extends StatelessWidget {
  const _LiveBubble({required this.text, required this.pending});
  final String text;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Card(
        color: theme.colorScheme.surfaceContainerHighest,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pending) ...[
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
              ],
              Flexible(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolStepCard extends StatelessWidget {
  const _ToolStepCard({
    required this.step,
    required this.name,
    required this.args,
    required this.result,
    required this.ok,
    required this.running,
  });

  final int step;
  final String name;
  final String args;
  final String? result;
  final bool ok;
  final bool running;

  String _pretty(String json) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(json));
    } on FormatException {
      return json;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final label = S.fa.containsKey('tool_$name') ? s.t('tool_$name') : name;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: theme.colorScheme.surfaceContainerLow,
      child: ExpansionTile(
        dense: true,
        leading: running
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
                color: ok ? theme.colorScheme.primary : theme.colorScheme.error),
        title: Text(s.t('toolStep', {'n': '$step', 'tool': label})),
        subtitle: Text(running ? s.t('usingTool') : (ok ? s.t('toolDone') : s.t('toolFailed'))),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Directionality(
            textDirection: TextDirection.ltr,
            child: SelectableText(_pretty(args), style: theme.textTheme.bodySmall),
          ),
          if (result != null) ...[
            const Divider(),
            _ToolResultView(json: result!),
          ],
        ],
      ),
    );
  }
}

/// Shows text fields of a tool result readably (captions, text, hashtag sets) with copy.
class _ToolResultView extends StatelessWidget {
  const _ToolResultView({required this.json});
  final String json;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      data = null;
    }
    if (data is! Map<String, Object?>) return SelectableText(json);
    final entries = <MapEntry<String, String>>[];
    data.forEach((k, v) {
      if (v is String && v.trim().isNotEmpty) entries.add(MapEntry(k, v));
      if (v is List<Object?> && v.isNotEmpty) entries.add(MapEntry(k, v.map((e) => '$e').join('\n')));
      if (v is num || v is bool) entries.add(MapEntry(k, '$v'));
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.key, style: Theme.of(context).textTheme.labelSmall),
                      SelectableText(e.value),
                    ],
                  ),
                ),
                IconButton(
                  iconSize: 18,
                  tooltip: s.t('copy'),
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: e.value));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('copied'))));
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ConversationsDrawer extends StatelessWidget {
  const _ConversationsDrawer({required this.chat});
  final ChatController chat;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: Text(s.t('conversations'), style: Theme.of(context).textTheme.titleMedium),
              trailing: IconButton(
                icon: const Icon(Icons.add),
                tooltip: s.t('newChat'),
                onPressed: chat.running
                    ? null
                    : () {
                        chat.newConversation();
                        Navigator.pop(context);
                      },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: chat.conversations.isEmpty
                  ? Center(child: Text(s.t('noConversations')))
                  : ListView(
                      children: [
                        for (final c in chat.conversations)
                          ListTile(
                            selected: c.id == chat.conversationId,
                            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: chat.running
                                ? null
                                : () {
                                    chat.open(c.id);
                                    Navigator.pop(context);
                                  },
                            trailing: IconButton(
                              tooltip: s.t('deleteConversation'),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: chat.running ? null : () => _confirmDelete(context, c),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Conversation c) async {
    final s = context.sRead;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(s.t('deleteConfirm', {'name': c.title})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('delete'))),
        ],
      ),
    );
    if (ok == true) await chat.deleteConversation(c.id);
  }
}
