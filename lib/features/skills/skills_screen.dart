import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../skills/skill.dart';
import '../../skills/skill_repository.dart';
import 'skill_editor_screen.dart';

class SkillsScreen extends StatelessWidget {
  const SkillsScreen({super.key});

  Future<void> _import(BuildContext context) async {
    final services = context.read<AppServices>();
    final repo = context.read<SkillRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final s = context.sRead;
    try {
      final file = await services.bridge.openTextFile();
      if (file == null) return;
      final skill = await repo.importSource(file.content, fileName: file.name);
      messenger.showSnackBar(SnackBar(content: Text(s.t('skillImported', {'name': skill.name}))));
    } on SkillParseException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.t('skillImportError', {'error': e.message}))));
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.t('skillImportError', {'error': e.code}))));
    }
  }

  Future<void> _export(BuildContext context, Skill skill) async {
    final services = context.read<AppServices>();
    final messenger = ScaffoldMessenger.of(context);
    final s = context.sRead;
    try {
      final ok = await services.bridge.saveTextFile('${skill.id}.md', skill.toMarkdown());
      if (ok) messenger.showSnackBar(SnackBar(content: Text(s.t('skillExported'))));
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.t('errGeneric', {'code': e.code}))));
    }
  }

  Future<void> _delete(BuildContext context, Skill skill) async {
    final repo = context.read<SkillRepository>();
    final settings = context.read<SettingsController>();
    final s = context.sRead;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(s.t('deleteConfirm', {'name': skill.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    if (settings.activeSkillId == skill.id) await settings.setActiveSkillId(null);
    await repo.delete(skill.id);
  }

  void _edit(BuildContext context, Skill? skill) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SkillEditorScreen(skill: skill)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final repo = context.watch<SkillRepository>();
    final settings = context.watch<SettingsController>();
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('skillsTitle')),
        actions: [
          IconButton(tooltip: s.t('importSkill'), icon: const Icon(Icons.file_open_outlined), onPressed: () => _import(context)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'restore') repo.restoreBuiltIns();
            },
            itemBuilder: (_) => [PopupMenuItem(value: 'restore', child: Text(s.t('restoreBuiltIns')))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: Text(s.t('newSkill')),
      ),
      body: repo.skills.isEmpty
          ? Center(child: Text(s.t('noSkills')))
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                for (final skill in repo.skills)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: ListTile(
                      leading: IconButton(
                        tooltip: s.t('setActiveSkill'),
                        icon: Icon(settings.activeSkillId == skill.id ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                        onPressed: () => settings.setActiveSkillId(settings.activeSkillId == skill.id ? null : skill.id),
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text(skill.name, overflow: TextOverflow.ellipsis)),
                          if (skill.builtIn) ...[
                            const SizedBox(width: 6),
                            Chip(label: Text(s.t('builtIn')), visualDensity: VisualDensity.compact),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        skill.description.isNotEmpty ? skill.description : skill.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _edit(context, skill),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          switch (v) {
                            case 'edit':
                              _edit(context, skill);
                            case 'export':
                              _export(context, skill);
                            case 'delete':
                              _delete(context, skill);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'edit', child: Text(s.t('edit'))),
                          PopupMenuItem(value: 'export', child: Text(s.t('exportSkill'))),
                          PopupMenuItem(value: 'delete', child: Text(s.t('delete'))),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
