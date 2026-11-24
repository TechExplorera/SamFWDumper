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
  Future<void> run(String name, List<String> args,
      {LogFn? log, String? workDir, bool asRoot = false, Map<String, String>? env}) async {
    final bin = find(name);
    if (bin == null) throw StateError('herramienta no encontrada: $name (configúrala en Ajustes → Herramientas)');
    await runRaw(bin, args, log: log, workDir: workDir, asRoot: asRoot, env: env);
  }

  static Future<void> runRaw(String bin, List<String> args,
      {LogFn? log, String? workDir, bool asRoot = false, Map<String, String>? env}) async {
    final Process p;
    if (asRoot) {
      final cmd = [bin, ...args].map(_shQuote).join(' ');
      log?.call('# su -c $cmd');
      p = await Process.start('su', ['-c', cmd], workingDirectory: workDir, environment: env);
    } else {
      log?.call('\$ ${[bin.split('/').last, ...args].join(' ')}');
      p = await Process.start(bin, args, workingDirectory: workDir, environment: env);
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

/// mke2fs.conf estilo AOSP. Sin él, mke2fs.android lee /etc/mke2fs.conf del sistema,
/// que en distros modernas activa funciones (orphan_file, metadata_csum_seed...) que no conoce.
const _androidMke2fsConf = """[defaults]
\tbase_features = sparse_super,large_file,filetype,dir_index,ext_attr
\tdefault_mntopts = acl,user_xattr
\tenable_periodic_fsck = 0
\tblocksize = 4096
\tinode_size = 256
\tinode_ratio = 16384
\treserved_ratio = 1.0
\tlazy_itable_init = false
\tno_discard = true

[fs_types]
\text3 = {
\t\tfeatures = has_journal
\t}
\text4 = {
\t\tfeatures = has_journal,extent,huge_file,flex_bg,uninit_bg,dir_nlink,extra_isize
\t\tinode_size = 256
\t}
""";

/// Entorno para ejecutar mke2fs.android con la configuración de Android.
Map<String, String> androidMke2fsEnv() {
  final f = File('${Directory.systemTemp.path}/fwk_mke2fs.conf');
  if (!f.existsSync() || f.readAsStringSync() != _androidMke2fsConf) f.writeAsStringSync(_androidMke2fsConf);
  return {'MKE2FS_CONFIG': f.path};
}
