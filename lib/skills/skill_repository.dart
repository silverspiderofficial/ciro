import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'builtin_skills.dart';
import 'skill.dart';

/// Stores skills as `<id>.md` files in the app's private support directory.
abstract class SkillStorage {
  Future<List<String>> listSources();
  Future<String?> read(String id);
  Future<void> write(String id, String content);
  Future<void> delete(String id);
}

class DirectorySkillStorage implements SkillStorage {
  DirectorySkillStorage(this.directory);
  final Directory directory;

  @override
  Future<List<String>> listSources() async {
    if (!await directory.exists()) return const [];
    final files = await directory
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.md'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return Future.wait(files.map((f) => f.readAsString()));
  }

  File _file(String id) => File(p.join(directory.path, '${slugify(id)}.md'));

  @override
  Future<String?> read(String id) async {
    final f = _file(id);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String id, String content) async {
    await directory.create(recursive: true);
    final f = _file(id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
  }
}

class MemorySkillStorage implements SkillStorage {
  final Map<String, String> files = {};

  @override
  Future<List<String>> listSources() async => files.values.toList();

  @override
  Future<String?> read(String id) async => files[slugify(id)];

  @override
  Future<void> write(String id, String content) async => files[slugify(id)] = content;

  @override
  Future<void> delete(String id) async => files.remove(slugify(id));
}

class SkillRepository extends ChangeNotifier {
  SkillRepository(this._storage);

  final SkillStorage _storage;
  List<Skill> _skills = const [];
  List<Skill> get skills => _skills;

  /// Loads all skills; installs the built-in ones on first run.
  Future<void> init({bool seedBuiltIns = true}) async {
    if (seedBuiltIns) {
      for (final s in builtInSkills) {
        if (await _storage.read(s.id) == null) await _storage.write(s.id, s.toMarkdown());
      }
    }
    await reload();
  }

  Future<void> reload() async {
    final sources = await _storage.listSources();
    final parsed = <Skill>[];
    for (final src in sources) {
      try {
        parsed.add(parseSkill(src));
      } on SkillParseException {
        // A damaged file is skipped rather than breaking the whole list.
      }
    }
    parsed.sort((a, b) {
      if (a.builtIn != b.builtIn) return a.builtIn ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    _skills = parsed;
    notifyListeners();
  }

  Skill? byId(String? id) {
    if (id == null) return null;
    for (final s in _skills) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Finds a skill by id or (case-insensitive, partial) name — used by the apply_skill tool.
  Skill? find(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final s in _skills) {
      if (s.id == q || s.name.toLowerCase() == q) return s;
    }
    for (final s in _skills) {
      if (s.name.toLowerCase().contains(q) || q.contains(s.name.toLowerCase())) return s;
    }
    return null;
  }

  Future<Skill> save(Skill skill) async {
    final id = skill.id.isEmpty ? slugify(skill.name) : slugify(skill.id);
    final toSave = skill.copyWith(id: id);
    await _storage.write(id, toSave.toMarkdown());
    await reload();
    return toSave;
  }

  /// Imports a skill file. A colliding id gets a numeric suffix so nothing is overwritten.
  Future<Skill> importSource(String source, {String? fileName}) async {
    final fallback = fileName == null ? null : p.basenameWithoutExtension(fileName);
    var skill = parseSkill(source, fallbackId: fallback).copyWith(builtIn: false);
    var id = skill.id;
    var n = 2;
    while (byId(id) != null) {
      id = '${skill.id}-$n';
      n++;
    }
    skill = skill.copyWith(id: id);
    await _storage.write(id, skill.toMarkdown());
    await reload();
    return skill;
  }

  Future<void> delete(String id) async {
    await _storage.delete(id);
    await reload();
  }

  Future<void> restoreBuiltIns() async {
    for (final s in builtInSkills) {
      await _storage.write(s.id, s.toMarkdown());
    }
    await reload();
  }
}
