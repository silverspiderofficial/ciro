import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/agent/tool_call_parser.dart';

void main() {
  group('ToolCallParser', () {
    test('parses the Kiro protocol', () {
      final c = ToolCallParser.parse('{"tool": "write_caption", "args": {"topic": "قهوه", "language": "fa"}}');
      expect(c, isNotNull);
      expect(c!.name, 'write_caption');
      expect(c.args['topic'], 'قهوه');
      expect(c.args['language'], 'fa');
    });

    test('parses fenced JSON with surrounding prose', () {
      const out = 'Sure! I will create hashtags.\n```json\n{"tool":"generate_hashtags","args":{"topic":"food","count":10}}\n```';
      final c = ToolCallParser.parse(out)!;
      expect(c.name, 'generate_hashtags');
      expect(c.args['count'], 10);
    });

    test('parses Qwen <tool_call> tags with name/arguments', () {
      const out = '<tool_call>\n{"name": "save_to_drafts", "arguments": {"content": "متن", "title": "t"}}\n</tool_call>';
      final c = ToolCallParser.parse(out)!;
      expect(c.name, 'save_to_drafts');
      expect(c.args['content'], 'متن');
    });

    test('parses OpenAI function style with string arguments', () {
      const out = '{"function": {"name": "apply_skill", "arguments": "{\\"name\\": \\"viral\\"}"}}';
      final c = ToolCallParser.parse(out)!;
      expect(c.name, 'apply_skill');
      expect(c.args['name'], 'viral');
    });

    test('accepts flat arguments and trailing commas', () {
      final c = ToolCallParser.parse('{"tool": "write_text", "topic": "یوگا", "length": "short",}')!;
      expect(c.name, 'write_text');
      expect(c.args['topic'], 'یوگا');
      expect(c.args.containsKey('tool'), isFalse);
    });

    test('handles braces inside strings', () {
      final c = ToolCallParser.parse('{"tool":"write_text","args":{"topic":"use {curly} braces"}}')!;
      expect(c.args['topic'], 'use {curly} braces');
    });

    test('repairs a call cut off before the final brace', () {
      final c = ToolCallParser.parse('{"tool": "write_caption", "args": {"topic": "x"}')!;
      expect(c.name, 'write_caption');
    });

    test('ignores think blocks', () {
      final c = ToolCallParser.parse('<think>{"tool":"nope"}</think>{"tool":"write_text","args":{"topic":"a"}}')!;
      expect(c.name, 'write_text');
    });

    test('returns null for plain answers and non-tool JSON', () {
      expect(ToolCallParser.parse('این یک پاسخ عادی است.'), isNull);
      expect(ToolCallParser.parse('{"caption": "hello"}'), isNull);
      expect(ToolCallParser.parse(''), isNull);
    });

    test('detects tool-call-like stream starts', () {
      expect(ToolCallParser.looksLikeToolCallStart('  {"to'), isTrue);
      expect(ToolCallParser.looksLikeToolCallStart('```json'), isTrue);
      expect(ToolCallParser.looksLikeToolCallStart('سلام'), isFalse);
    });

    test('argument helpers', () {
      final args = <String, Object?>{'topic': ' x ', 'count': '50', 'tags': ['#a', '#b']};
      expect(argString(args, ['subject', 'topic']), 'x');
      expect(argInt(args, ['count'], fallback: 5, max: 30), 30);
      expect(argInt(args, ['missing'], fallback: 7), 7);
      expect(argList(args, ['tags']), ['#a', '#b']);
    });
  });
}
