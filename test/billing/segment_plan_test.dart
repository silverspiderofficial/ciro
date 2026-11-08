import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/billing/segment_plan.dart';

void main() {
  test('segment count is ceil(duration / 10s)', () {
    expect(planSegments('topic', const Duration(seconds: 10)), hasLength(1));
    expect(planSegments('topic', const Duration(seconds: 20)), hasLength(2));
    expect(planSegments('topic', const Duration(seconds: 25)), hasLength(3));
    expect(planSegments('topic', const Duration(minutes: 3)), hasLength(18));
    expect(planSegments('topic', const Duration(minutes: 10)), hasLength(60));
    expect(planSegments('topic', Duration.zero), isEmpty);
    expect(planSegments('   ', const Duration(seconds: 30)), isEmpty);
  });

  test('scenes are numbered, share the style suffix and sum to the target', () {
    final s = planSegments('  طلوع آفتاب   روی کوه ', const Duration(seconds: 25), styleSuffix: 'STYLE');
    expect([for (final x in s) x.index], [1, 2, 3]);
    expect(s.every((x) => x.total == 3 && x.prompt.endsWith('STYLE')), isTrue);
    expect(s.first.prompt, contains('Scene 1 of 3'));
    expect(s.first.prompt, contains('طلوع آفتاب روی کوه'));
    expect(s.first.beat, startsWith('opening'));
    expect(s.last.beat, startsWith('closing'));
    expect(s.fold<Duration>(Duration.zero, (a, x) => a + x.duration), const Duration(seconds: 25));
    expect(s.last.duration, const Duration(seconds: 5));
  });
}
