// Localiza y ejecuta binarios externos (mkfs.erofs, extract.erofs, mke2fs, e2fsdroid...).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef LogFn = void Function(String line);

class ToolBox {
  /// Directorios de búsqueda adicionales (configurables desde Ajustes).
  final List<String> searchDirs;

  /// En Android, directorio de librerías nativas de la app (binarios empaquetados como `lib<nombre>.so`).
  final String? nativeLibDir;

  ToolBox({this.searchDirs = const [], this.nativeLibDir});

  static final _cache = <String, String?>{};

  String? find(String name) {
    final key = '$name|${searchDirs.join(':')}|$nativeLibDir';
    if (_cache.containsKey(key)) return _cache[key];
    String? found;
    if (nativeLibDir != null) {
      final soName = 'lib${name.replaceAll('.', '_')}.so';
      if (File('$nativeLibDir/$soName').existsSync()) found = '$nativeLibDir/$soName';
    }
    found ??= [
      ...searchDirs,
      '${File(Platform.resolvedExecutable).parent.path}/tools',
      ...?Platform.environment['FWK_TOOLS']?.split(':'),
      ...?Platform.environment['PATH']?.split(':'),
    ].map((d) => '$d/$name').where((p) => File(p).existsSync()).firstOrNull;
    return _cache[key] = found;
  }

  bool has(String name) => find(name) != null;

  Map<String, bool> status(List<String> names) => {for (final n in names) n: has(n)};

  /// Ejecuta [name] con [args]; reenvía la salida línea a línea. Lanza si el código de salida != 0.
  Future<void> run(String name, List<String> args, {LogFn? log, String? workDir, bool asRoot = false}) async {
    final bin = find(name);
    if (bin == null) throw StateError('herramienta no encontrada: $name (configúrala en Ajustes → Herramientas)');
    await runRaw(bin, args, log: log, workDir: workDir, asRoot: asRoot);
  }

  static Future<void> runRaw(String bin, List<String> args, {LogFn? log, String? workDir, bool asRoot = false}) async {
    final Process p;
    if (asRoot) {
      final cmd = [bin, ...args].map(_shQuote).join(' ');
      log?.call('# su -c $cmd');
      p = await Process.start('su', ['-c', cmd], workingDirectory: workDir);
    } else {
      log?.call('\$ ${[bin.split('/').last, ...args].join(' ')}');
      p = await Process.start(bin, args, workingDirectory: workDir);
    }
    final done = <Future>[];
    for (final s in [p.stdout, p.stderr]) {
      done.add(s
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .map((l) => l.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '')) // quita colores ANSI
          .forEach((l) => log?.call(l)));
    }
    final code = await p.exitCode;
    await Future.wait(done);
    if (code != 0) throw ProcessException(bin, args, 'salió con código $code', code);
  }
}

String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Comprueba si hay root disponible (su).
Future<bool> hasRoot() async {
  try {
    final r = await Process.run('su', ['-c', 'id -u']).timeout(const Duration(seconds: 10));
    return r.exitCode == 0 && (r.stdout as String).trim() == '0';
  } catch (_) {
    return false;
  }
}
