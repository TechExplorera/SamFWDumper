// Ajustes persistentes (JSON en el directorio de soporte de la app) e integración con la plataforma.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/tools.dart';
import '../l10n/l10n.dart';

const _channel = MethodChannel('fwkitchen/platform');

/// Patrones (regex, sin distinguir mayúsculas) que preseleccionan apps en Debloat.
/// Solo marcan carpetas que existan de verdad en la ROM extraída.
const defaultDebloatPatterns = [
  'knox',
  'klms',
  'facebook',
  r'^fb',
  'bixby',
  'netflix',
  'spotify',
  'linkedin',
  'onedrive',
  'office',
  'tiktok',
  'booking',
];

class AppSettings extends ChangeNotifier {
  late File _file;
  String workspace = '';
  /// 'system', 'es' o 'en'.
  String language = 'system';
  List<String> toolDirs = [];
  List<String> debloatPatterns = List.of(defaultDebloatPatterns);
  String? nativeLibDir;
  bool rootAvailable = false;

  static Future<AppSettings> load() async {
    final s = AppSettings();
    final support = await getApplicationSupportDirectory();
    s._file = File('${support.path}/settings.json');
    if (Platform.isAndroid) {
      try {
        s.nativeLibDir = await _channel.invokeMethod<String>('nativeLibDir');
      } catch (_) {}
    }
    var defaultWs = '${support.path}/workspace';
    if (Platform.isLinux) {
      defaultWs = '${Platform.environment['HOME'] ?? support.path}/FWKitchen';
    }
    s.workspace = defaultWs;
    if (s._file.existsSync()) {
      try {
        final j = jsonDecode(s._file.readAsStringSync()) as Map<String, dynamic>;
        s.workspace = j['workspace'] as String? ?? defaultWs;
        s.toolDirs = (j['toolDirs'] as List?)?.cast<String>() ?? [];
        s.debloatPatterns = (j['debloatPatterns'] as List?)?.cast<String>() ?? s.debloatPatterns;
        s.language = j['language'] as String? ?? 'system';
      } catch (_) {}
    }
    appLang = resolveLang(s.language);
    Directory(s.workspace).createSync(recursive: true);
    s.rootAvailable = await hasRoot();
    return s;
  }

  void save() {
    _file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'workspace': workspace,
      'toolDirs': toolDirs,
      'debloatPatterns': debloatPatterns,
      'language': language,
    }));
    notifyListeners();
  }

  ToolBox toolBox() => ToolBox(searchDirs: toolDirs, nativeLibDir: nativeLibDir);
}

/// Android 11+: permiso "Acceso a todos los archivos" (necesario para leer firmwares del almacenamiento).
Future<bool> hasAllFilesAccess() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> requestAllFilesAccess() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod('requestAllFilesAccess');
  } catch (_) {}
}

/// Abre una carpeta en el gestor de archivos del sistema (solo Linux).
Future<void> openFolder(String path) async {
  if (Platform.isLinux) await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
}

const kitchenTools = ['extract.erofs', 'fsck.erofs', 'mkfs.erofs', 'mke2fs.android', 'e2fsdroid'];

/// Capacidades según las herramientas encontradas (cada una tiene alternativas).
class ToolCaps {
  final bool extractErofs, buildErofs, buildExt4;
  ToolCaps(ToolBox t)
      : extractErofs = t.has('extract.erofs') || t.has('fsck.erofs'),
        buildErofs = t.has('mkfs.erofs'),
        buildExt4 = t.has('mke2fs.android') && t.has('e2fsdroid');
  List<String> get missing => [
        if (!extractErofs) tr('extraer EROFS'),
        if (!buildErofs) tr('construir EROFS'),
        if (!buildExt4) tr('construir ext4'),
      ];
}
