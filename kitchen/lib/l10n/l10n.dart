// Localización mínima: el texto en español del código es la clave y
// `en.dart` tiene su traducción. Marcadores {0}, {1}… para valores.
import 'dart:io';

import 'en.dart';

/// Idioma activo: 'es' o 'en'. Cada isolate tiene el suyo (se pasa al lanzar tareas).
String appLang = 'es';

/// Resuelve el ajuste ('system', 'es', 'en') a un idioma concreto.
String resolveLang(String setting) {
  if (setting == 'es' || setting == 'en') return setting;
  final l = Platform.localeName.toLowerCase();
  return l.startsWith('es') ? 'es' : 'en';
}

/// Traduce [es] al idioma activo y sustituye {0}, {1}… por [args].
String tr(String es, [List<Object?> args = const []]) {
  var s = appLang == 'en' ? (enStrings[es] ?? es) : es;
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}
