import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/content/content_helpers.dart';

void main() {
  group('HashtagHelper', () {
    test('normalize', () {
      expect(HashtagHelper.normalize('Food Photo'), '#Food_Photo');
      expect(HashtagHelper.normalize('##عکاسی غذا'), '#عکاسی_غذا');
      expect(HashtagHelper.normalize('می\u200cخوام'), '#می_خوام');
      expect(HashtagHelper.normalize('#coffee!!'), '#coffee');
      expect(HashtagHelper.normalize('   '), isNull);
      expect(HashtagHelper.normalize('#2024'), isNull);
    });

    test('extract from hashtag text, lists and dedupes case-insensitively', () {
      expect(HashtagHelper.extract('#Coffee #coffee #قهوه, #latte_art'), ['#Coffee', '#قهوه', '#latte_art']);
      expect(HashtagHelper.extract('1. coffee\n2. latte art\n- قهوه'), ['#coffee', '#latte_art', '#قهوه']);
      expect(HashtagHelper.extract('["a1", "b2"]'), ['#a1', '#b2']);
      expect(HashtagHelper.extract('#a #b #c', max: 2), hasLength(2));
    });

    test('fromKeywords builds tags from topic words', () {
      final tags = HashtagHelper.fromKeywords('عکاسی غذا', ['کافه']);
      expect(tags, containsAll(['#عکاسی_غذا', '#عکاسی', '#کافه']));
    });

    test('sets never exceed the Instagram limit of 5', () {
      final tags = List.generate(14, (i) => '#tag${'x' * i}');
      final sets = HashtagHelper.buildSets(tags);
      expect(sets, isNotEmpty);
      expect(sets.length, lessThanOrEqualTo(3));
      for (final s in sets) {
        expect(s.length, lessThanOrEqualTo(instagramHashtagLimit));
        expect(s.toSet().length, s.length);
      }
      expect(sets.first.first, tags.last); // most specific first
      expect(HashtagHelper.buildSets(const []), isEmpty);
    });
  });

  group('CaptionHelper', () {
    test('clean strips labels, quotes, fences and markdown', () {
      expect(CaptionHelper.clean('Caption: "Hello **world**"'), 'Hello world');
      expect(CaptionHelper.clean('کپشن: «سلام دنیا»'), 'سلام دنیا');
      expect(CaptionHelper.clean('```\n## Title\nline\n\n\n\nnext\n```'), 'Title\nline\n\nnext');
    });

    test('truncate respects the 2200 limit at a word boundary', () {
      final long = List.filled(600, 'word').join(' ');
      final t = CaptionHelper.truncate(long);
      expect(t.runes.length, lessThanOrEqualTo(instagramCaptionLimit));
      expect(t.endsWith('…'), isTrue);
      expect(CaptionHelper.truncate('short'), 'short');
    });

    test('splitHashtags separates a trailing tag block', () {
      final r = CaptionHelper.splitHashtags('یک کپشن\nخط دوم\n\n#قهوه #کافه\n#latte');
      expect(r.body, 'یک کپشن\nخط دوم');
      expect(r.hashtags, ['#قهوه', '#کافه', '#latte']);
    });

    test('hook and compose', () {
      expect(CaptionHelper.hook('\n  اولین خط \nدوم'), 'اولین خط');
      final c = CaptionHelper.compose('body', ['#1a', '#b', '#c', '#d', '#e', '#f']);
      expect(c, 'body\n\n#1a #b #c #d #e');
    });
  });
}
