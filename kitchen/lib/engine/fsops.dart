// Extracción y construcción de sistemas de archivos (ext4 / erofs).
import 'dart:io';

import 'detect.dart';
import 'erofs.dart';
import 'ext4.dart';
import 'fsmeta.dart';
import 'paxtar.dart';
import 'tools.dart';

String defaultMountPoint(String part) => part == 'system' ? '/' : '/$part';

/// Extrae [img] a `<workDir>/<part>/` y metadatos a `<workDir>/config/`.
Future<void> extractFs(String img, String part, String workDir, ToolBox tools, {LogFn? log}) async {
  final type = detectImage(img);
  final outDir = '$workDir/$part';
  final cfgDir = '$workDir/config';
  Directory(cfgDir).createSync(recursive: true);
  if (Directory(outDir).existsSync()) Directory(outDir).deleteSync(recursive: true);
  switch (type) {
    case ImgType.ext4:
      final fs = Ext4Image(img);
      try {
        final mp = fs.lastMounted.startsWith('/') ? fs.lastMounted : defaultMountPoint(part);
        log?.call('ext4: extrayendo $part (punto de montaje $mp)…');
        var last = 0;
        final entries = fs.extractAll(outDir, onProgress: (n, p) {
          if (n - last >= 500) {
            last = n;
            log?.call('  $n entradas… $p');
          }
        });
        writeFsMeta(cfgDir, part, entries);
        File('$cfgDir/${part}_mount_point').writeAsStringSync(mp);
        log?.call('ext4: ${entries.length} entradas extraídas');
      } finally {
        fs.close();
      }
    case ImgType.erofs:
      if (!tools.has('extract.erofs')) {
        if (!tools.has('fsck.erofs')) {
          throw StateError('Para extraer EROFS hace falta extract.erofs o fsck.erofs (Ajustes → Herramientas).');
        }
        await _extractErofsUpstream(img, part, outDir, cfgDir, tools, log);
        break;
      }
      // extract.erofs nombra la salida según el archivo: lo enlazamos como <part>.img
      final tmp = '$workDir/.extract_$part';
      if (Directory(tmp).existsSync()) Directory(tmp).deleteSync(recursive: true);
      Directory('$tmp/in').createSync(recursive: true);
      final named = '$tmp/in/$part.img';
      try {
        Link(named).createSync(File(img).absolute.path);
      } on FileSystemException {
        File(img).copySync(named);
      }
      try {
        await tools.run('extract.erofs', ['-i', named, '-x', '-f', '-s', '-o', '$tmp/out'], log: log);
        Directory('$tmp/out/$part').renameSync(outDir);
        for (final f in Directory('$tmp/out/config').listSync().whereType<File>()) {
          f.renameSync('$cfgDir/${f.uri.pathSegments.last}');
        }
        File('$cfgDir/${part}_mount_point').writeAsStringSync(defaultMountPoint(part));
      } finally {
        if (Directory(tmp).existsSync()) Directory(tmp).deleteSync(recursive: true);
      }
    default:
      throw StateError('$part: tipo ${type.label} no se puede extraer como sistema de archivos');
  }
  File('$cfgDir/${part}_fs_type').writeAsStringSync(type.label);
}

/// EROFS con erofs-utils oficial: datos con fsck.erofs y metadatos con el lector en Dart.
Future<void> _extractErofsUpstream(String img, String part, String outDir, String cfgDir, ToolBox tools, LogFn? log) async {
  log?.call('erofs: leyendo metadatos de $part…');
  final fs = ErofsImage(img);
  final List<FsEntry> entries;
  try {
    entries = fs.walkMeta();
  } finally {
    fs.close();
  }
  log?.call('erofs: ${entries.length} entradas; extrayendo datos con fsck.erofs…');
  Directory(outDir).parent.createSync(recursive: true);
  await tools.run('fsck.erofs', ['--extract=$outDir', '--no-preserve', '--overwrite', img], log: log);
  writeFsMeta(cfgDir, part, entries);
  File('$cfgDir/${part}_mount_point').writeAsStringSync(defaultMountPoint(part));
}

/// ¿El mkfs.erofs disponible entiende fs_config/file_contexts (versión Android)?
/// Si no (erofs-utils oficial), se construye desde un tar PAX con los metadatos.
Future<bool> _mkfsHasAndroidOptions(ToolBox tools) async =>
    (await tools.helpText('mkfs.erofs')).contains('fs-config-file');

int _dirSize(String path) {
  var total = 0;
  for (final e in Directory(path).listSync(recursive: true, followLinks: false)) {
    if (e is File) {
      total += ((e.lengthSync() + 4095) ~/ 4096) * 4096;
    } else {
      total += 4096;
    }
  }
  return total;
}

/// Construye `<outImg>` desde `<workDir>/<part>/` usando los metadatos de `config/`.
Future<void> buildFs(String part, String workDir, String fsType, String outImg, ToolBox tools,
    {LogFn? log, int timestamp = 1230768000}) async {
  final src = '$workDir/$part';
  final cfg = '$workDir/config/${part}_fs_config';
  final ctx = '$workDir/config/${part}_file_contexts';
  final mpFile = File('$workDir/config/${part}_mount_point');
  final mp = mpFile.existsSync() ? mpFile.readAsStringSync().trim() : defaultMountPoint(part);
  if (!Directory(src).existsSync()) throw StateError('no existe la carpeta $src');
  if (File(outImg).existsSync()) File(outImg).deleteSync();
  final added = completeFsMeta('$workDir/config', part, src);
  if (added > 0) log?.call('metadatos: $added entradas nuevas añadidas a fs_config');
  final hasCtx = File(ctx).existsSync() && File(ctx).lengthSync() > 0;
  final cfgMount = '/$part'; // prefijo usado en fs_config / file_contexts

  if (fsType == 'erofs' && !await _mkfsHasAndroidOptions(tools)) {
    log?.call('erofs: construyendo desde tar con metadatos Android (mkfs.erofs --tar)…');
    var files = 0;
    await tools.run('mkfs.erofs', ['-zlz4hc,9', '-T', '$timestamp', '--tar=f', outImg], log: log, stdinFeed: (sink) async {
      files = await writeAndroidTar(sink, src, '$workDir/config', part, mtime: timestamp, onProgress: (n) {
        if (n % 2000 == 0) log?.call('  $n entradas…');
      });
    });
    log?.call('erofs: $files entradas empaquetadas');
  } else if (fsType == 'erofs') {
    await tools.run('mkfs.erofs', [
      '-zlz4hc,9',
      '-T', '$timestamp',
      '--mount-point=$cfgMount',
      if (File(cfg).existsSync()) '--fs-config-file=$cfg',
      if (hasCtx) '--file-contexts=$ctx',
      outImg,
      src,
    ], log: log);
  } else if (fsType == 'ext4') {
    if (!tools.has('mke2fs.android') || !tools.has('e2fsdroid')) {
      throw StateError('Construir ext4 requiere mke2fs.android y e2fsdroid'
          '${Platform.isAndroid ? '. En Android usa "Construir como EROFS" (kernel con EROFS: Samsung con Android 13+)' : ''}.');
    }
    var size = (_dirSize(src) * 1.15).ceil() + (16 << 20);
    for (var attempt = 0; attempt < 3; attempt++) {
      final blocks = (size + 4095) ~/ 4096;
      if (File(outImg).existsSync()) File(outImg).deleteSync();
      await tools.run('mke2fs.android', [
        '-O', '^has_journal', '-t', 'ext4', '-b', '4096', '-L', part, '-I', '256', '-M', mp, '-m', '0',
        outImg, '$blocks',
      ], log: log, env: androidMke2fsEnv());
      try {
        await tools.run('e2fsdroid', [
          '-e', '-T', '$timestamp',
          if (File(cfg).existsSync()) ...['-C', cfg],
          if (hasCtx) ...['-S', ctx],
          '-f', src, '-a', cfgMount, outImg,
        ], log: log);
        return;
      } on ProcessException {
        if (attempt == 2) rethrow;
        size = (size * 1.3).ceil();
        log?.call('e2fsdroid falló; reintentando con ${size >> 20} MB…');
      }
    }
  } else {
    throw StateError('tipo de sistema de archivos no soportado para construir: $fsType');
  }
}
