import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// A stored chat message. role: user | assistant | tool
class StoredMessage {
  const StoredMessage({
    this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.toolName,
    this.toolArgs,
    this.toolOk = true,
    required this.createdAt,
  });

  final int? id;
  final int conversationId;
  final String role;
  final String content;
  final String? toolName;
  final String? toolArgs;
  final bool toolOk;
  final DateTime createdAt;

  bool get isTool => role == 'tool';

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'conversation_id': conversationId,
        'role': role,
        'content': content,
        'tool_name': toolName,
        'tool_args': toolArgs,
        'tool_ok': toolOk ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory StoredMessage.fromRow(Map<String, Object?> r) => StoredMessage(
        id: r['id'] as int?,
        conversationId: r['conversation_id'] as int,
        role: r['role'] as String,
        content: (r['content'] as String?) ?? '',
        toolName: r['tool_name'] as String?,
        toolArgs: r['tool_args'] as String?,
        toolOk: (r['tool_ok'] as int? ?? 1) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  StoredMessage withId(int newId) => StoredMessage(
        id: newId,
        conversationId: conversationId,
        role: role,
        content: content,
        toolName: toolName,
        toolArgs: toolArgs,
        toolOk: toolOk,
        createdAt: createdAt,
      );
}

class Conversation {
  const Conversation({required this.id, required this.title, required this.updatedAt});
  final int id;
  final String title;
  final DateTime updatedAt;
}

class Draft {
  const Draft({
    this.id,
    required this.title,
    required this.content,
    this.caption = '',
    this.hashtags = '',
    this.mediaPath,
    this.mediaType,
    this.extra,
    required this.createdAt,
  });

  final int? id;
  final String title;
  final String content;
  final String caption;
  final String hashtags;

  /// Image or video file kept in the app's private Studio folder.
  final String? mediaPath;

  /// image | video
  final String? mediaType;

  /// JSON payload to reopen the work (e.g. the video project).
  final String? extra;
  final DateTime createdAt;

  bool get isImage => mediaType == 'image' && mediaPath != null;
  bool get isVideo => mediaType == 'video' && mediaPath != null;

  Draft withId(int newId) => Draft(
        id: newId,
        title: title,
        content: content,
        caption: caption,
        hashtags: hashtags,
        mediaPath: mediaPath,
        mediaType: mediaType,
        extra: extra,
        createdAt: createdAt,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'title': title,
        'content': content,
        'caption': caption,
        'hashtags': hashtags,
        'media_path': mediaPath,
        'media_type': mediaType,
        'extra': extra,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory Draft.fromRow(Map<String, Object?> r) => Draft(
        id: r['id'] as int?,
        title: (r['title'] as String?) ?? '',
        content: (r['content'] as String?) ?? '',
        caption: (r['caption'] as String?) ?? '',
        hashtags: (r['hashtags'] as String?) ?? '',
        mediaPath: r['media_path'] as String?,
        mediaType: r['media_type'] as String?,
        extra: r['extra'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  String get fullText {
    final parts = <String>[
      if (content.trim().isNotEmpty) content.trim(),
      if (caption.trim().isNotEmpty) caption.trim(),
      if (hashtags.trim().isNotEmpty) hashtags.trim(),
    ];
    return parts.join('\n\n');
  }
}

abstract class ChatRepository {
  Future<List<Conversation>> conversations();
  Future<int> createConversation(String title);
  Future<void> renameConversation(int id, String title);
  Future<void> deleteConversation(int id);
  Future<List<StoredMessage>> messages(int conversationId);
  Future<StoredMessage> addMessage(StoredMessage m);
}

abstract class DraftsRepository {
  Future<List<Draft>> all();
  Future<int> add(Draft d);
  Future<void> delete(int id);
}

/// SQLite storage for chats and drafts (app-private database, excluded from backups).
class KiroDatabase implements ChatRepository, DraftsRepository {
  KiroDatabase._(this._db);
  final Database _db;

  static Future<KiroDatabase> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'kiro.db'),
      version: 2,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            tool_name TEXT,
            tool_args TEXT,
            tool_ok INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL
          )''');
        await db.execute('CREATE INDEX idx_messages_conv ON messages(conversation_id, id)');
        await db.execute('''
          CREATE TABLE drafts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            caption TEXT NOT NULL DEFAULT '',
            hashtags TEXT NOT NULL DEFAULT '',
            media_path TEXT,
            media_type TEXT,
            extra TEXT,
            created_at INTEGER NOT NULL
          )''');
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          // Stage 2: drafts can hold an image or a video (Studio).
          await db.execute('ALTER TABLE drafts ADD COLUMN media_path TEXT');
          await db.execute('ALTER TABLE drafts ADD COLUMN media_type TEXT');
          await db.execute('ALTER TABLE drafts ADD COLUMN extra TEXT');
        }
      },
    );
    return KiroDatabase._(db);
  }

  @override
  Future<List<Conversation>> conversations() async {
    final rows = await _db.query('conversations', orderBy: 'updated_at DESC');
    return rows
        .map((r) => Conversation(
              id: r['id'] as int,
              title: r['title'] as String,
              updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
            ))
        .toList();
  }

  @override
  Future<int> createConversation(String title) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.insert('conversations', {'title': title, 'created_at': now, 'updated_at': now});
  }

  @override
  Future<void> renameConversation(int id, String title) async {
    await _db.update('conversations', {'title': title}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> deleteConversation(int id) async {
    await _db.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
    await _db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<StoredMessage>> messages(int conversationId) async {
    final rows = await _db.query('messages', where: 'conversation_id = ?', whereArgs: [conversationId], orderBy: 'id ASC');
    return rows.map(StoredMessage.fromRow).toList();
  }

  @override
  Future<StoredMessage> addMessage(StoredMessage m) async {
    final id = await _db.insert('messages', m.toRow());
    await _db.update(
      'conversations',
      {'updated_at': m.createdAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [m.conversationId],
    );
    return m.withId(id);
  }

  @override
  Future<List<Draft>> all() async {
    final rows = await _db.query('drafts', orderBy: 'created_at DESC');
    return rows.map(Draft.fromRow).toList();
  }

  @override
  Future<int> add(Draft d) => _db.insert('drafts', d.toRow());

  @override
  Future<void> delete(int id) async {
    await _db.delete('drafts', where: 'id = ?', whereArgs: [id]);
  }
}

/// In-memory implementation (tests and widget previews).
class MemoryRepository implements ChatRepository, DraftsRepository {
  final List<Conversation> _convs = [];
  final List<StoredMessage> _msgs = [];
  final List<Draft> _drafts = [];
  int _next = 1;

  @override
  Future<List<Conversation>> conversations() async => List.of(_convs.reversed);

  @override
  Future<int> createConversation(String title) async {
    final id = _next++;
    _convs.add(Conversation(id: id, title: title, updatedAt: DateTime.now()));
    return id;
  }

  @override
  Future<void> renameConversation(int id, String title) async {
    final i = _convs.indexWhere((c) => c.id == id);
    if (i >= 0) _convs[i] = Conversation(id: id, title: title, updatedAt: _convs[i].updatedAt);
  }

  @override
  Future<void> deleteConversation(int id) async {
    _convs.removeWhere((c) => c.id == id);
    _msgs.removeWhere((m) => m.conversationId == id);
  }

  @override
  Future<List<StoredMessage>> messages(int conversationId) async =>
      _msgs.where((m) => m.conversationId == conversationId).toList();

  @override
  Future<StoredMessage> addMessage(StoredMessage m) async {
    final stored = m.withId(_next++);
    _msgs.add(stored);
    return stored;
  }

  @override
  Future<List<Draft>> all() async => List.of(_drafts.reversed);

  @override
  Future<int> add(Draft d) async {
    final id = _next++;
    _drafts.add(d.withId(id));
    return id;
  }

  @override
  Future<void> delete(int id) async => _drafts.removeWhere((d) => d.id == id);
}
