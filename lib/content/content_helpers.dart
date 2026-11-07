/// Pure helpers for Instagram captions and hashtags (no I/O, fully unit-tested).
library;

/// Instagram limits: 2,200 caption characters; 5 hashtags per post or Reel
/// (limit announced by Instagram on 2025-12-18, down from 30).
const int instagramCaptionLimit = 2200;
const int instagramHashtagLimit = 5;

class HashtagHelper {
  static final _invalid = RegExp(r'[^\p{L}\p{M}\p{N}_]', unicode: true);
  static final _sep = RegExp(r'[\s\u200c\u200f\u200e\-–—.·/\\]+');

  /// Normalises one hashtag: "#Food Photo" → "#Food_Photo", "عکاسی غذا" → "#عکاسی_غذا".
  /// Returns null if nothing usable remains.
  static String? normalize(String raw) {
    var t = raw.trim();
    while (t.startsWith('#') || t.startsWith('＃')) {
      t = t.substring(1);
    }
    t = t.replaceAll(_sep, '_');
    t = t.replaceAll(_invalid, '');
    t = t.replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (t.isEmpty || t.length > 60) return null;
    if (RegExp(r'^[0-9_]+$').hasMatch(t)) return null; // Instagram ignores digits-only tags
    return '#$t';
  }

  /// Extracts hashtags from free model output: "#a #b", "a, b", numbered lists, JSON-ish arrays.
  static List<String> extract(String text, {int max = 30}) {
    final found = <String>[];
    final seen = <String>{};
    void add(String raw) {
      final n = normalize(raw);
      if (n == null) return;
      final key = n.toLowerCase();
      if (seen.add(key)) found.add(n);
    }

    final explicit = RegExp(r'#[^\s#,،"\]\[]+').allMatches(text).map((m) => m.group(0)!).toList();
    if (explicit.isNotEmpty) {
      explicit.forEach(add);
    } else {
      final cleaned = text.replaceAll(RegExp(r'[\[\]"`]'), ' ');
      for (final line in cleaned.split(RegExp(r'[\n,،;]'))) {
        final item = line.replaceFirst(RegExp(r'^\s*(?:[-*•]|\d+[.)])\s*'), '').trim();
        if (item.isEmpty || item.split(RegExp(r'\s+')).length > 4) continue;
        add(item);
      }
    }
    return found.length > max ? found.sublist(0, max) : found;
  }

  /// Fallback tags built from the topic and skill topics when no model output is available.
  static List<String> fromKeywords(String topic, List<String> extra) {
    final words = <String>[topic, ...extra];
    final tags = <String>[];
    final seen = <String>{};
    for (final w in words) {
      final whole = normalize(w);
      if (whole != null && seen.add(whole.toLowerCase())) tags.add(whole);
      for (final part in w.split(RegExp(r'\s+'))) {
        if (part.runes.length < 3) continue;
        final n = normalize(part);
        if (n != null && seen.add(n.toLowerCase())) tags.add(n);
      }
    }
    return tags;
  }

  /// Splits candidates into ready-to-paste sets of at most [perSet] tags.
  /// Set 1 favours specific (longer) tags, set 2 broad (shorter) ones, set 3 a mix.
  static List<List<String>> buildSets(List<String> tags, {int perSet = instagramHashtagLimit, int sets = 3}) {
    if (tags.isEmpty) return const [];
    final specific = List.of(tags)..sort((a, b) => b.runes.length.compareTo(a.runes.length));
    final broad = List.of(tags)..sort((a, b) => a.runes.length.compareTo(b.runes.length));
    final result = <List<String>>[];
    final used = <String>{};
    List<String> take(List<String> source, {bool allowReuse = false}) {
      final out = <String>[];
      for (final t in source) {
        if (out.length >= perSet) break;
        if (!allowReuse && used.contains(t)) continue;
        if (!out.contains(t)) out.add(t);
      }
      used.addAll(out);
      return out;
    }

    result.add(take(specific));
    if (sets > 1) {
      final b = take(broad);
      if (b.isNotEmpty) result.add(b);
    }
    if (sets > 2) {
      final mixed = <String>[];
      for (var i = 0; i < tags.length && mixed.length < perSet; i++) {
        final t = i.isEven ? specific[i ~/ 2] : broad[i ~/ 2];
        if (!mixed.contains(t)) mixed.add(t);
      }
      if (mixed.isNotEmpty && !_sameSet(mixed, result.first)) result.add(mixed);
    }
    return result.where((s) => s.isNotEmpty).toList();
  }

  static bool _sameSet(List<String> a, List<String> b) => a.toSet().containsAll(b) && b.toSet().containsAll(a);
}

class CaptionHelper {
  static final _labelPrefix = RegExp(
    r'^\s*(?:caption|instagram caption|کپشن(?:\s+اینستاگرام)?|متن کپشن)\s*[:：\-–]\s*',
    caseSensitive: false,
  );

  /// Cleans model output into a postable caption.
  static String clean(String raw, {int limit = instagramCaptionLimit}) {
    var t = raw.replaceAll('\r\n', '\n').trim();
    // Strip code fences and surrounding quotes.
    t = t.replaceAll(RegExp(r'^```[a-zA-Z]*\n?|```$', multiLine: true), '').trim();
    t = t.replaceFirst(_labelPrefix, '');
    if (t.length >= 2 &&
        ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith('«') && t.endsWith('»')) || (t.startsWith('“') && t.endsWith('”')))) {
      t = t.substring(1, t.length - 1).trim();
    }
    // Markdown emphasis is not rendered by Instagram.
    t = t.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*|__(.+?)__'), (m) => m.group(1) ?? m.group(2) ?? '');
    t = t.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    t = t.replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return truncate(t, limit: limit);
  }

  /// Truncates at a word boundary and appends an ellipsis when over [limit] characters.
  static String truncate(String text, {int limit = instagramCaptionLimit}) {
    final runes = text.runes.toList();
    if (runes.length <= limit) return text;
    var cut = String.fromCharCodes(runes.sublist(0, limit - 1));
    final lastSpace = cut.lastIndexOf(RegExp(r'\s'));
    if (lastSpace > limit * 0.6) cut = cut.substring(0, lastSpace);
    return '${cut.trimRight()}…';
  }

  /// Separates a trailing hashtag block from the caption body.
  static ({String body, List<String> hashtags}) splitHashtags(String caption) {
    final lines = caption.trimRight().split('\n');
    final tags = <String>[];
    while (lines.isNotEmpty) {
      final last = lines.last.trim();
      if (last.isEmpty) {
        lines.removeLast();
        continue;
      }
      final words = last.split(RegExp(r'\s+'));
      if (words.every((w) => w.startsWith('#'))) {
        tags.insertAll(0, HashtagHelper.extract(last));
        lines.removeLast();
      } else {
        break;
      }
    }
    return (body: lines.join('\n').trim(), hashtags: tags);
  }

  /// The hook is the first non-empty line.
  static String hook(String caption) =>
      caption.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');

  /// Caption + up to 5 hashtags, ready to paste into Instagram.
  static String compose(String body, List<String> hashtags) {
    final tags = hashtags.take(instagramHashtagLimit).join(' ');
    final text = tags.isEmpty ? body.trim() : '${body.trim()}\n\n$tags';
    return truncate(text);
  }
}
