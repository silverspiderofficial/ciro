import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../skills/skill.dart';
import '../../skills/skill_repository.dart';

class SkillEditorScreen extends StatefulWidget {
  const SkillEditorScreen({super.key, this.skill});
  final Skill? skill;

  @override
  State<SkillEditorScreen> createState() => _SkillEditorScreenState();
}

class _SkillEditorScreenState extends State<SkillEditorScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _pageStyle;
  late final TextEditingController _audience;
  late final TextEditingController _tone;
  late final TextEditingController _topics;
  late final TextEditingController _body;
  late String _format;
  late String _language;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final sk = widget.skill;
    _name = TextEditingController(text: sk?.name ?? '');
    _description = TextEditingController(text: sk?.description ?? '');
    _pageStyle = TextEditingController(text: sk?.pageStyle ?? '');
    _audience = TextEditingController(text: sk?.audience ?? '');
    _tone = TextEditingController(text: sk?.tone ?? '');
    _topics = TextEditingController(text: sk?.topics.join('، ') ?? '');
    _body = TextEditingController(text: sk?.body ?? '');
    _format = sk?.postFormat ?? 'mixed';
    _language = sk?.language ?? 'fa';
  }

  @override
  void dispose() {
    for (final c in [_name, _description, _pageStyle, _audience, _tone, _topics, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final repo = context.read<SkillRepository>();
    final navigator = Navigator.of(context);
    final base = widget.skill;
    final skill = Skill(
      id: base?.id ?? '',
      name: _name.text.trim(),
      description: _description.text.trim(),
      pageStyle: _pageStyle.text.trim(),
      audience: _audience.text.trim(),
      tone: _tone.text.trim(),
      topics: _topics.text.split(RegExp(r'[,،\n]')).map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      postFormat: _format,
      language: _language,
      body: _body.text,
      builtIn: base?.builtIn ?? false,
    );
    var toSave = skill;
    if (base == null) {
      // New skill: make sure the id does not overwrite an existing one.
      var id = slugify(skill.name);
      var n = 2;
      while (repo.byId(id) != null) {
        id = '${slugify(skill.name)}-$n';
        n++;
      }
      toSave = skill.copyWith(id: id);
    }
    await repo.save(toSave);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    InputDecoration deco(String key) => InputDecoration(labelText: s.t(key));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.skill == null ? s.t('newSkill') : widget.skill!.name),
        actions: [
          IconButton(tooltip: s.t('save'), onPressed: _saving ? null : _save, icon: const Icon(Icons.check)),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: deco('skillName'),
              validator: (v) => (v == null || v.trim().isEmpty) ? s.t('nameRequired') : null,
            ),
            const SizedBox(height: 12),
            TextFormField(controller: _description, decoration: deco('skillDescription')),
            const SizedBox(height: 12),
            TextFormField(controller: _pageStyle, decoration: deco('skillPageStyle')),
            const SizedBox(height: 12),
            TextFormField(controller: _audience, decoration: deco('skillAudience')),
            const SizedBox(height: 12),
            TextFormField(controller: _tone, decoration: deco('skillTone')),
            const SizedBox(height: 12),
            TextFormField(controller: _topics, decoration: deco('skillTopics')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _format,
              decoration: deco('skillFormat'),
              items: [
                for (final f in Skill.postFormats) DropdownMenuItem(value: f, child: Text(s.t('format_$f'))),
              ],
              onChanged: (v) => setState(() => _format = v ?? 'mixed'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _language,
              decoration: deco('skillLanguage'),
              items: [
                DropdownMenuItem(value: 'fa', child: Text(s.t('langFa'))),
                DropdownMenuItem(value: 'en', child: Text(s.t('langEn'))),
                DropdownMenuItem(value: 'both', child: Text(s.t('langBoth'))),
              ],
              onChanged: (v) => setState(() => _language = v ?? 'fa'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _body,
              decoration: deco('skillBody').copyWith(alignLabelWithHint: true),
              minLines: 8,
              maxLines: 30,
              keyboardType: TextInputType.multiline,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _saving ? null : _save, child: Text(s.t('save'))),
          ],
        ),
      ),
    );
  }
}
