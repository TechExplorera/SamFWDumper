// Ajustes de ROM: build.prop, fstab y uso del super.
import 'dart:io';

import 'project.dart';

// ---------------------------------------------------------------- build.prop

/// Rutas (relativas a extracted/) de los build.prop de las particiones extraídas.
List<String> findBuildProps(Project p) {
  final out = <String>[];
  for (final part in p.extractedPartitions()) {
    for (final c in ['system/build.prop', 'build.prop', 'etc/build.prop', 'default.prop', 'system/etc/prop.default']) {
      if (File('${p.extractedDir}/$part/$c').existsSync()) out.add('$part/$c');
    }
  }
  return out;
}

class PropLine {
  final String raw;
  final String? key;
  final String? value;
  PropLine(this.raw, this.key, this.value);
}

List<PropLine> parseProps(String content) => [
      for (final l in content.split('\n'))
        () {
          final t = l.trim();
          final i = t.indexOf('=');
          if (t.isEmpty || t.startsWith('#') || i <= 0) return PropLine(l, null, null);
          return PropLine(l, t.substring(0, i).trim(), t.substring(i + 1));
        }()
    ];

Map<String, String> readProps(String path) {
  final f = File(path);
  if (!f.existsSync()) return {};
  return {for (final l in parseProps(f.readAsStringSync())) if (l.key != null) l.key!: l.value!};
}

/// Cambia (o añade al final) [key]; con [value] null la elimina.
void setProp(String path, String key, String? value) {
  final f = File(path);
  final lines = parseProps(f.readAsStringSync());
  var found = false;
  final out = <String>[];
  for (final l in lines) {
    if (l.key == key) {
      if (!found && value != null) out.add('$key=$value');
      found = true;
      continue;
    }
    out.add(l.raw);
  }
  if (!found && value != null) {
    if (out.isNotEmpty && out.last.isEmpty) out.removeLast();
    out.add('$key=$value');
    out.add('');
  }
  f.writeAsStringSync(out.join('\n'));
}

class RomInfo {
  final String model, android, patch, build, fingerprint;
  RomInfo(this.model, this.android, this.patch, this.build, this.fingerprint);
  bool get isEmpty => model.isEmpty && android.isEmpty && build.isEmpty;
}

RomInfo romInfo(Project p) {
  final all = <String, String>{};
  for (final bp in findBuildProps(p)) {
    all.addAll(readProps('${p.extractedDir}/$bp'));
  }
  String first(List<String> keys) => keys.map((k) => all[k]).firstWhere((v) => v != null && v.isNotEmpty, orElse: () => '') ?? '';
  return RomInfo(
    first(['ro.product.system.model', 'ro.product.model', 'ro.product.vendor.model', 'ro.product.product.model']),
    first(['ro.system.build.version.release', 'ro.build.version.release', 'ro.vendor.build.version.release']),
    first(['ro.build.version.security_patch', 'ro.vendor.build.security_patch']),
    first(['ro.build.display.id', 'ro.system.build.id', 'ro.build.id']),
    first(['ro.system.build.fingerprint', 'ro.build.fingerprint', 'ro.vendor.build.fingerprint']),
  );
}

// ---------------------------------------------------------------- fstab

List<String> findFstabs(Project p) {
  final out = <String>[];
  for (final part in p.extractedPartitions()) {
    for (final sub in ['etc', 'system/etc']) {
      final d = Directory('${p.extractedDir}/$part/$sub');
      if (!d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>()) {
        final n = f.uri.pathSegments.last;
        if (n.startsWith('fstab.') || n == 'fstab') out.add(f.path.substring(p.extractedDir.length + 1));
      }
    }
  }
  return out..sort();
}

/// Quita flags de cifrado forzado y/o de verificación AVB de la columna fs_mgr_flags.
/// Devuelve el contenido nuevo y la lista de cambios (vacía si no hay nada que tocar).
(String, List<String>) patchFstab(String content, {bool encryption = true, bool avb = true}) {
  bool drop(String flag) {
    final f = flag.trim();
    if (encryption &&
        (f.startsWith('fileencryption=') ||
            f.startsWith('forceencrypt=') ||
            f.startsWith('forcefdeorfbe=') ||
            f.startsWith('encryptable=') ||
            f.startsWith('metadata_encryption=') ||
            f == 'keydirectory' ||
            f.startsWith('keydirectory='))) {
      return true;
    }
    if (avb && (f == 'avb' || f.startsWith('avb=') || f.startsWith('avb_keys=') || f == 'verify' || f.startsWith('verify='))) {
      return true;
    }
    return false;
  }

  final changes = <String>[];
  final out = <String>[];
  for (final line in content.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) {
      out.add(line);
      continue;
    }
    final cols = t.split(RegExp(r'\s+'));
    if (cols.length < 5) {
      out.add(line);
      continue;
    }
    final flags = cols[4].split(',');
    final kept = flags.where((f) => !drop(f)).toList();
    if (kept.length == flags.length) {
      out.add(line);
      continue;
    }
    final removed = flags.where(drop).join(',');
    changes.add('${cols[1]}: −$removed');
    cols[4] = kept.isEmpty ? 'defaults' : kept.join(',');
    out.add(cols.join('  '));
  }
  return (out.join('\n'), changes);
}

// ---------------------------------------------------------------- super

class GroupUsage {
  final String name;
  final int maxSize;
  final Map<String, int> parts; // partición -> bytes (salida si existe; si no, original)
  GroupUsage(this.name, this.maxSize, this.parts);
  int get used => parts.values.fold(0, (a, b) => a + b);
  bool get fits => maxSize == 0 || used <= maxSize;
}

/// Uso de cada grupo del super con las imágenes actuales (null si no hay super).
(int deviceSize, List<GroupUsage>)? superUsage(Project p) {
  final meta = p.loadMeta()['super'] as Map<String, dynamic>?;
  if (meta == null) return null;
  final dev = (meta['block_devices'] as List).first as Map<String, dynamic>;
  final groups = <String, GroupUsage>{
    for (final g in meta['groups'] as List)
      if (g['name'] != 'default') g['name'] as String: GroupUsage(g['name'], g['max_size'], {})
  };
  for (final part in meta['partitions'] as List) {
    final n = part['name'] as String;
    final out = File('${p.outputDir}/$n.img'), orig = File('${p.imagesDir}/$n.img');
    final size = out.existsSync() ? out.lengthSync() : (orig.existsSync() ? orig.lengthSync() : 0);
    groups.putIfAbsent(part['group'] as String, () => GroupUsage(part['group'], 0, {})).parts[n] = size;
  }
  return (dev['size'] as int, groups.values.toList());
}
