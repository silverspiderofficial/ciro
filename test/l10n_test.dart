import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/l10n/strings.dart';

void main() {
  test('Persian and English have the same keys', () {
    expect(S.fa.keys.toSet().difference(S.en.keys.toSet()), isEmpty, reason: 'missing in en');
    expect(S.en.keys.toSet().difference(S.fa.keys.toSet()), isEmpty, reason: 'missing in fa');
  });

  test('every literal key used in lib/ exists', () {
    final used = <String>{};
    final pattern = RegExp(r"""\.t\('([A-Za-z0-9_]+)'""");
    final deco = RegExp(r"""deco\('([A-Za-z0-9_]+)'\)""");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      used.addAll(pattern.allMatches(src).map((m) => m.group(1)!));
      used.addAll(deco.allMatches(src).map((m) => m.group(1)!));
    }
    expect(used, isNotEmpty);
    final missing = used.where((k) => !S.fa.containsKey(k)).toList();
    expect(missing, isEmpty);
  });

  test('error codes map to existing keys', () {
    for (final code in ['process_died', 'low_ram', 'prompt_too_long', 'network', 'whatever']) {
      expect(S.fa.containsKey(S.errorKey(code)), isTrue, reason: code);
    }
  });

  test('parameters are substituted', () {
    expect(S('en').t('modelReady', {'name': 'X'}), 'Ready: X');
    expect(S('fa').t('tabChat'), 'گفتگو');
    expect(S('fa').t('unknown_key'), 'unknown_key');
  });
}
