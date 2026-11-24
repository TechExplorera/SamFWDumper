import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fw_kitchen/l10n/en.dart';
import 'package:fw_kitchen/l10n/l10n.dart';

/// Claves tal como aparecen en el código fuente (literal entre comillas simples).
List<String> sourceKeys() {
  final re = RegExp(r"tr\('((?:[^'\\]|\\.)*)'");
  final keys = <String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart') || f.path.contains('/l10n/')) continue;
    for (final m in re.allMatches(f.readAsStringSync())) {
      // Evaluar escapes simples del literal (\n, \', \\)
      keys.add(m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (x) => switch (x[1]) { 'n' => '\n', _ => x[1]! }));
    }
  }
  return keys.toList();
}

void main() {
  test('todas las claves tr() tienen traducción al inglés', () {
    final keys = sourceKeys();
    expect(keys.length, greaterThan(150));
    final missing = keys.where((k) => !enStrings.containsKey(k)).toList();
    expect(missing, isEmpty, reason: 'Sin traducir:\n${missing.join('\n')}');
  });

  test('los marcadores {n} coinciden entre español e inglés', () {
    final ph = RegExp(r'\{\d+\}');
    for (final e in enStrings.entries) {
      final a = ph.allMatches(e.key).map((m) => m[0]).toSet();
      final b = ph.allMatches(e.value).map((m) => m[0]).toSet();
      expect(b, a, reason: e.key);
    }
  });

  test('tr() traduce y sustituye argumentos', () {
    appLang = 'en';
    expect(tr('Extraer todas ({0})', [3]), 'Extract all (3)');
    expect(tr('texto sin traducción'), 'texto sin traducción');
    appLang = 'es';
    expect(tr('Extraer todas ({0})', [3]), 'Extraer todas (3)');
  });
}
