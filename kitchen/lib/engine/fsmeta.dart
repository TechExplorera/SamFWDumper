// Metadatos de sistema de archivos Android: fs_config y file_contexts.
// Convención (igual que extract.erofs): las rutas llevan el nombre de la partición
// como prefijo ("system/bin/sh", "/system/bin/sh") y se reconstruye con --mount-point=/<partición>.
import 'dart:io';
import 'dart:typed_data';

class FsEntry {
  final String rel; // ruta relativa a la raíz de la imagen ("" = raíz)
  final int uid, gid, mode;
  final String? context;
  final int capabilities;
  final String? linkTarget;
  FsEntry(this.rel, this.uid, this.gid, this.mode, this.context, this.capabilities, {this.linkTarget});

  factory FsEntry.fromXattrs(String rel, int uid, int gid, int mode, Map<String, Uint8List> x, {String? linkTarget}) {
    String? ctx;
    final s = x['security.selinux'];
    if (s != null) {
      var end = s.length;
      while (end > 0 && s[end - 1] == 0) {
        end--;
      }
      ctx = String.fromCharCodes(s, 0, end);
    }
    var caps = 0;
    final c = x['security.capability'];
    if (c != null && c.length >= 12) {
      final bd = ByteData.sublistView(c);
      caps = bd.getUint32(4, Endian.little);
      if (c.length >= 20) caps |= bd.getUint32(12, Endian.little) << 32;
    }
    return FsEntry(rel, uid, gid, mode, ctx, caps, linkTarget: linkTarget);
  }
}

String escapeContextPath(String p) => p.replaceAllMapped(RegExp(r'[.+*?^$|()\[\]{}\\]'), (m) => '\\${m[0]}');
String unescapeContextPath(String p) => p.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);

String _perm(int mode) => (mode & 0xFFF).toRadixString(8).padLeft(4, '0');

/// Escribe `<name>_fs_config` y `<name>_file_contexts` en [configDir].
void writeFsMeta(String configDir, String name, List<FsEntry> entries) {
  Directory(configDir).createSync(recursive: true);
  final cfg = StringBuffer();
  final ctx = StringBuffer();
  for (final e in entries) {
    final caps = e.capabilities != 0 ? ' capabilities=0x${e.capabilities.toRadixString(16)}' : '';
    if (e.rel.isEmpty) {
      cfg.writeln('/ ${e.uid} ${e.gid} ${_perm(e.mode)}');
      cfg.writeln('$name/ ${e.uid} ${e.gid} ${_perm(e.mode)}');
      if (e.context != null) {
        ctx.writeln('/ ${e.context}');
        ctx.writeln('/$name ${e.context}');
        ctx.writeln('/${escapeContextPath('$name/lost+found')} ${e.context}');
      }
      cfg.writeln('$name/lost+found 0 0 0700');
      continue;
    }
    cfg.writeln('$name/${e.rel} ${e.uid} ${e.gid} ${_perm(e.mode)}$caps');
    if (e.context != null) ctx.writeln('/${escapeContextPath('$name/${e.rel}')} ${e.context}');
  }
  File('$configDir/${name}_fs_config').writeAsStringSync(cfg.toString());
  File('$configDir/${name}_file_contexts').writeAsStringSync(ctx.toString());
}

/// Antes de reconstruir: añade entradas para archivos nuevos (que el usuario haya
/// añadido) heredando uid/gid y contexto SELinux de su carpeta padre.
/// Devuelve cuántas entradas se añadieron.
int completeFsMeta(String configDir, String name, String srcDir) {
  final cfgFile = File('$configDir/${name}_fs_config');
  final ctxFile = File('$configDir/${name}_file_contexts');
  final cfg = <String, List<String>>{};
  if (cfgFile.existsSync()) {
    for (final l in cfgFile.readAsLinesSync()) {
      final parts = l.trim().split(RegExp(r'\s+'));
      if (parts.length >= 4) cfg[parts[0].replaceAll(RegExp(r'/$'), '')] = parts;
    }
  }
  final ctx = <String, String>{};
  if (ctxFile.existsSync()) {
    for (final l in ctxFile.readAsLinesSync()) {
      final i = l.trim().lastIndexOf(RegExp(r'\s'));
      if (i > 0) ctx[unescapeContextPath(l.substring(0, i).trim())] = l.substring(i + 1).trim();
    }
  }
  final addCfg = StringBuffer(), addCtx = StringBuffer();
  var added = 0;
  final entities = Directory(srcDir).listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.length.compareTo(b.path.length));
  for (final e in entities) {
    final rel = e.path.substring(srcDir.length + 1);
    final key = '$name/$rel';
    final parentKey = key.contains('/') ? key.substring(0, key.lastIndexOf('/')) : name;
    if (!cfg.containsKey(key)) {
      final parent = cfg[parentKey];
      final uid = parent?[1] ?? '0', gid = parent?[2] ?? '0';
      final isDir = e is Directory;
      var mode = isDir ? '0755' : '0644';
      if (e is File && (e.statSync().mode & 0x49) != 0) mode = '0755';
      final line = [key, uid, gid, mode];
      cfg[key] = line;
      addCfg.writeln(line.join(' '));
      added++;
    }
    if (ctx.isNotEmpty && !ctx.containsKey('/$key')) {
      final pc = ctx['/$parentKey'];
      if (pc != null) {
        ctx['/$key'] = pc;
        addCtx.writeln('/${escapeContextPath(key)} $pc');
      }
    }
  }
  if (addCfg.isNotEmpty) cfgFile.writeAsStringSync(addCfg.toString(), mode: FileMode.append);
  if (addCtx.isNotEmpty) ctxFile.writeAsStringSync(addCtx.toString(), mode: FileMode.append);
  return added;
}
