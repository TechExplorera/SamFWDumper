// Proyecto de la kitchen: estructura de carpetas y operaciones de alto nivel.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

import '../engine/bootimg.dart';
import '../engine/bytes.dart';
import '../engine/detect.dart';
import '../engine/fsops.dart';
import '../engine/lp.dart';
import '../engine/lz4.dart';
import '../engine/sparse.dart';
import '../engine/tar.dart';
import '../engine/tools.dart';
import '../engine/vbmeta.dart';
import '../l10n/l10n.dart';

/// Contexto de una tarea (logs + herramientas). Se puede crear dentro de un isolate.
class TaskCtx {
  final LogFn log;
  final ToolBox tools;
  TaskCtx(this.log, this.tools);
  void progress(String label, int done, int total) {
    if (total > 0) log('@progress ${(done * 100 / total).toStringAsFixed(0)} $label');
  }
}

class KImage {
  final String name, path, type;
  final int size;
  KImage(this.name, this.path, this.type, this.size);
}

class Project {
  final String root;
  Project(this.root);

  String get name => root.split('/').last;
  String get inputDir => '$root/input';
  String get imagesDir => '$root/images';
  String get extractedDir => '$root/extracted';
  String get bootDir => '$root/boot';
  String get outputDir => '$root/output';
  File get _metaFile => File('$root/project.json');

  static Project create(String workspace, String name) {
    final p = Project('$workspace/$name');
    for (final d in [p.inputDir, p.imagesDir, p.extractedDir, p.bootDir, p.outputDir]) {
      Directory(d).createSync(recursive: true);
    }
    if (!p._metaFile.existsSync()) p.saveMeta({'created': DateTime.now().toIso8601String()});
    return p;
  }

  Map<String, dynamic> loadMeta() =>
      _metaFile.existsSync() ? jsonDecode(_metaFile.readAsStringSync()) as Map<String, dynamic> : {};
  void saveMeta(Map<String, dynamic> m) => _metaFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(m));
  void updateMeta(void Function(Map<String, dynamic>) f) {
    final m = loadMeta();
    f(m);
    saveMeta(m);
  }

  List<KImage> images() {
    final d = Directory(imagesDir);
    if (!d.existsSync()) return [];
    final l = d.listSync().whereType<File>().where((f) => f.path.endsWith('.img')).map((f) {
      final n = f.uri.pathSegments.last.replaceAll(RegExp(r'\.img$'), '');
      return KImage(n, f.path, detectImage(f.path).label, f.lengthSync());
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return l;
  }

  List<String> extractedPartitions() {
    final d = Directory(extractedDir);
    if (!d.existsSync()) return [];
    return d.listSync().whereType<Directory>().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).where((n) => n != 'config' && !n.startsWith('.')).toList()..sort();
  }

  List<KImage> outputs() {
    final d = Directory(outputDir);
    if (!d.existsSync()) return [];
    return d.listSync().whereType<File>().map((f) => KImage(f.uri.pathSegments.last, f.path, detectImage(f.path).label, f.lengthSync())).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  // ------------------------------------------------------------------
  // Importación
  // ------------------------------------------------------------------

  /// Importa un firmware: .zip de Samsung, .tar / .tar.md5 (AP, BL, CSC…), .lz4 o .img.
  Future<void> importFile(String path, TaskCtx c, {bool unpackSuper = true}) async {
    final lower = path.toLowerCase();
    final type = detectImage(path);
    if (type == ImgType.zip) {
      await _importZip(path, c, unpackSuper: unpackSuper);
    } else if (type == ImgType.tar || lower.endsWith('.tar') || lower.endsWith('.tar.md5')) {
      await _importTar(path, c, unpackSuper: unpackSuper);
    } else if (type == ImgType.lz4) {
      final base = path.split('/').last.replaceAll(RegExp(r'\.lz4$'), '');
      final out = '$imagesDir/${base.endsWith('.img') ? base : '$base.img'}';
      c.log(tr('Descomprimiendo {0}…', [path.split('/').last]));
      lz4DecompressFile(path, out, onProgress: (d, t) => c.progress(base, d, t));
      await _normalize(out, c, unpackSuper: unpackSuper);
    } else {
      final base = path.split('/').last;
      final out = '$imagesDir/${base.endsWith('.img') ? base : '$base.img'}';
      c.log(tr('Copiando {0}…', [base]));
      File(path).copySync(out);
      await _normalize(out, c, unpackSuper: unpackSuper);
    }
    c.log(tr('✔ Importación terminada'));
  }

  Future<void> _importZip(String path, TaskCtx c, {required bool unpackSuper}) async {
    c.log(tr('Leyendo zip {0}…', [path.split('/').last]));
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final tars = archive.files.where((f) => f.isFile && RegExp(r'\.tar(\.md5)?$', caseSensitive: false).hasMatch(f.name)).toList();
      if (tars.isEmpty) throw StateError(tr('el zip no contiene archivos .tar/.tar.md5 de Samsung'));
      for (final f in tars) {
        final n = f.name.split('/').last;
        c.log(tr('Extrayendo {0} ({1})…', [n, humanSize(f.size)]));
        final out = OutputFileStream('$inputDir/$n');
        f.writeContent(out);
        await out.close();
      }
    } finally {
      await input.close();
    }
    // AP primero (contiene super/boot/vbmeta), luego el resto
    final files = Directory(inputDir).listSync().whereType<File>().map((f) => f.path).toList()
      ..sort((a, b) => _tarRank(a).compareTo(_tarRank(b)));
    for (final t in files) {
      await _importTar(t, c, unpackSuper: unpackSuper);
    }
  }

  int _tarRank(String p) {
    final n = p.split('/').last.toUpperCase();
    for (final (i, k) in ['AP_', 'BL_', 'CP_', 'CSC_', 'HOME_CSC_'].indexed) {
      if (n.startsWith(k)) return i;
    }
    return 9;
  }

  Future<void> _importTar(String path, TaskCtx c, {required bool unpackSuper}) async {
    final entries = tarList(path).where((e) => e.isFile).toList();
    c.log(tr('{0}: {1} archivos', [path.split('/').last, entries.length]));
    final tarName = path.split('/').last;
    updateMeta((m) => (m['tars'] ??= <String, dynamic>{})[tarName] = [for (final e in entries) e.name]);
    for (final e in entries) {
      final n = e.name.split('/').last;
      if (n == 'meta-data' || n.endsWith('.txt') || n.endsWith('.json')) continue;
      final isLz4 = n.endsWith('.lz4');
      final imgName = n.replaceAll(RegExp(r'\.lz4$'), '');
      final target = '$imagesDir/$imgName';
      if (isLz4) {
        final tmp = '$imagesDir/.$n.tmp';
        tarExtract(path, e, tmp, onProgress: (d, t) => c.progress('extrayendo $n', d, t));
        c.log(tr('Descomprimiendo {0}…', [n]));
        lz4DecompressFile(tmp, target, onProgress: (d, t) => c.progress('lz4 $imgName', d, t));
        File(tmp).deleteSync();
      } else {
        tarExtract(path, e, target, onProgress: (d, t) => c.progress('extrayendo $n', d, t));
      }
      if (target.endsWith('.img')) await _normalize(target, c, unpackSuper: unpackSuper);
    }
  }

  /// Convierte sparse → raw y desempaqueta super.img.
  Future<void> _normalize(String img, TaskCtx c, {required bool unpackSuper}) async {
    final name = img.split('/').last;
    if (detectImage(img) == ImgType.sparse) {
      c.log(tr('{0}: sparse → raw…', [name]));
      final raw = '$img.raw';
      sparseToRaw(img, raw, onProgress: (d, t) => c.progress('sparse $name', d, t));
      File(raw).renameSync(img);
    }
    if (unpackSuper && detectImage(img) == ImgType.superLp) {
      await unpackSuperImage(img, c);
    }
  }

  Future<void> unpackSuperImage(String img, TaskCtx c) async {
    final md = lpRead(img);
    c.log(tr('super: {0} particiones, {1} grupos, tamaño {2}', [md.partitions.length, md.groups.length, humanSize(md.blockDevices.first.size)]));
    updateMeta((m) => m['super'] = md.toJson());
    lpUnpack(img, imagesDir, onProgress: (n, d, t) => c.progress('super → $n', d, t));
    for (final p in md.partitions) {
      if (p.sizeBytes > 0) c.log('  · ${p.name} (${humanSize(p.sizeBytes)})');
    }
    // El super original ya no hace falta en images/ (se reconstruye desde las particiones)
    final keep = '$inputDir/super.img';
    if (File(keep).existsSync()) File(keep).deleteSync();
    File(img).renameSync(keep);
    c.log(tr('super.img original movido a input/'));
  }

  // ------------------------------------------------------------------
  // Sistemas de archivos
  // ------------------------------------------------------------------

  Future<void> extractPartition(String name, TaskCtx c) async {
    final img = '$imagesDir/$name.img';
    c.log(tr('Extrayendo {0}…', [name]));
    await extractFs(img, name, extractedDir, c.tools, log: c.log);
    c.log(tr('✔ {0} extraído en extracted/{1}', [name, name]));
  }

  Future<void> buildPartition(String name, String fsType, TaskCtx c) async {
    Directory(outputDir).createSync(recursive: true);
    final out = '$outputDir/$name.img';
    c.log(tr('Construyendo {0} ({1})…', [name, fsType]));
    await buildFs(name, extractedDir, fsType, out, c.tools, log: c.log);
    c.log(tr('✔ {0}.img: {1}', [name, humanSize(File(out).lengthSync())]));
  }

  String? fsTypeOf(String part) {
    final f = File('$extractedDir/config/${part}_fs_type');
    return f.existsSync() ? f.readAsStringSync().trim() : null;
  }

  /// Borra rutas (relativas a extracted/, p. ej. "system/system/app/Facebook").
  /// Devuelve las que existían.
  List<String> debloat(List<String> paths, TaskCtx c) {
    final removed = <String>[];
    for (final raw in paths) {
      final p = raw.trim();
      if (p.isEmpty || p.startsWith('#') || p.contains('..')) continue;
      final full = '$extractedDir/$p';
      final t = FileSystemEntity.typeSync(full, followLinks: false);
      if (t == FileSystemEntityType.notFound) continue;
      if (t == FileSystemEntityType.directory) {
        Directory(full).deleteSync(recursive: true);
      } else {
        File(full).deleteSync();
      }
      removed.add(p);
      c.log('  ✖ $p');
    }
    c.log(tr('✔ Debloat: {0} elementos eliminados', [removed.length]));
    return removed;
  }

  // ------------------------------------------------------------------
  // super / vbmeta / boot / Odin
  // ------------------------------------------------------------------

  Future<void> buildSuper(TaskCtx c, {bool sparse = true}) async {
    final meta = loadMeta()['super'] as Map<String, dynamic>?;
    if (meta == null) throw StateError(tr('No hay metadatos de super: importa un firmware con super.img primero.'));
    final groups = [
      for (final g in meta['groups'] as List)
        if (g['name'] != 'default') LpGroup(g['name'], g['flags'], g['max_size'])
    ];
    final parts = <LpBuildPartition>[];
    for (final p in meta['partitions'] as List) {
      final n = p['name'] as String;
      final built = '$outputDir/$n.img', orig = '$imagesDir/$n.img';
      final img = File(built).existsSync() ? built : (File(orig).existsSync() && File(orig).lengthSync() > 0 ? orig : null);
      c.log('  · $n ← ${img == null ? '(vacía)' : '${img.replaceFirst('$root/', '')} (${humanSize(File(img).lengthSync())})'}');
      parts.add(LpBuildPartition(n, img, p['group'], attributes: p['attributes']));
    }
    final dev = (meta['block_devices'] as List).first;
    final ver = (meta['version'] as String).split('.');
    final raw = '$outputDir/super.raw.img';
    c.log(tr('Construyendo super.img…'));
    lpBuild(
      outPath: raw,
      deviceSize: dev['size'],
      metadataMaxSize: meta['metadata_max_size'],
      slotCount: meta['slot_count'],
      groups: groups,
      partitions: parts,
      alignment: dev['alignment'] == 0 ? 1 << 20 : dev['alignment'],
      minor: int.parse(ver[1]),
      headerFlags: meta['header_flags'] ?? 0,
      blockDeviceName: dev['name'],
      blockDeviceFlags: dev['flags'],
      onProgress: (n, d, t) => c.progress('super ← $n', d, t),
    );
    if (sparse) {
      c.log(tr('Convirtiendo super a sparse…'));
      rawToSparse(raw, '$outputDir/super.img', onProgress: (d, t) => c.progress('sparse', d, t));
      File(raw).deleteSync();
    } else {
      File(raw).renameSync('$outputDir/super.img');
    }
    c.log(tr('✔ super.img: {0}', [humanSize(File('$outputDir/super.img').lengthSync())]));
  }

  void patchVbmeta(String name, TaskCtx c) {
    final src = File('$imagesDir/$name.img');
    final dst = '$outputDir/$name.img';
    Directory(outputDir).createSync(recursive: true);
    src.copySync(dst);
    vbmetaDisable(dst);
    c.log(tr('✔ {0}.img: verity y verificación desactivadas (flags={1})', [name, vbmetaFlags(dst)]));
  }

  void unpackBoot(String name, TaskCtx c) {
    final dir = '$bootDir/$name';
    if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
    bootUnpack('$imagesDir/$name.img', dir);
    final info = jsonDecode(File('$dir/boot_info.json').readAsStringSync());
    c.log(tr('✔ {0} desempaquetado (cabecera v{1}, {2}): {3}', [name, info['header_version'], info['os_version_str'], (info['parts'] as List).join(', ')]));
  }

  void repackBoot(String name, TaskCtx c) {
    Directory(outputDir).createSync(recursive: true);
    bootRepack('$bootDir/$name', '$outputDir/$name.img');
    c.log(tr('✔ {0}.img reempaquetado', [name]));
  }

  List<String> unpackedBoots() {
    final d = Directory(bootDir);
    if (!d.existsSync()) return [];
    return d.listSync().whereType<Directory>().where((e) => File('${e.path}/boot_info.json').existsSync()).map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList()..sort();
  }

  /// Crea un AP .tar.md5 para Odin con las imágenes elegidas de output/ (comprimidas en LZ4).
  Future<String> buildOdinTar(List<String> files, TaskCtx c, {bool compress = true, String name = 'AP_KITCHEN.tar.md5'}) async {
    final tmpDir = Directory('$outputDir/.odin')..createSync(recursive: true);
    final map = <String, String>{};
    try {
      for (final f in files) {
        final src = '$outputDir/$f';
        if (compress && !f.endsWith('.lz4')) {
          final dst = '${tmpDir.path}/$f.lz4';
          c.log(tr('Comprimiendo {0}…', [f]));
          lz4CompressFile(src, dst, onProgress: (d, t) => c.progress('lz4 $f', d, t));
          map[dst] = '$f.lz4';
        } else {
          map[src] = f;
        }
      }
      final out = '$outputDir/$name';
      c.log(tr('Creando {0}…', [name]));
      tarCreate(out, map, odinMd5: true, onProgress: (d, t) => c.progress('tar', d, t));
      c.log('✔ $name: ${humanSize(File(out).lengthSync())}');
      return out;
    } finally {
      tmpDir.deleteSync(recursive: true);
    }
  }

  void convertSparse(String file, bool toSparse, TaskCtx c) {
    final src = '$outputDir/$file';
    final tmp = '$src.tmp';
    if (toSparse) {
      rawToSparse(src, tmp, onProgress: (d, t) => c.progress('sparse', d, t));
    } else {
      sparseToRaw(src, tmp, onProgress: (d, t) => c.progress('raw', d, t));
    }
    File(tmp).renameSync(src);
    c.log(tr('✔ {0} convertido a {1}', [file, toSparse ? 'sparse' : 'raw']));
  }
}
