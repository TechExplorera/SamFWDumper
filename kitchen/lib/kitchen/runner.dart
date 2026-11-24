// Ejecuta tareas pesadas en un isolate aparte y recoge logs y progreso.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../engine/tools.dart';
import 'project.dart';
import '../l10n/l10n.dart';

/// Una tarea es una función top-level (enviable a un isolate) con argumentos simples.
typedef TaskFn = Future<Object?> Function(TaskCtx c, Map<String, Object?> args);

class TaskRunner extends ChangeNotifier {
  ToolBox tools;
  TaskRunner(this.tools);

  final List<String> logs = [];
  String? current;
  double? progress;
  String progressLabel = '';
  bool get busy => current != null;
  IOSink? _logFile;

  void setLogFile(String? path) {
    _logFile?.close();
    _logFile = path == null ? null : File(path).openWrite(mode: FileMode.append);
  }

  void log(String l) {
    if (l.startsWith('@progress ')) {
      final rest = l.substring(10);
      final sp = rest.indexOf(' ');
      progress = (double.tryParse(sp < 0 ? rest : rest.substring(0, sp)) ?? 0) / 100;
      progressLabel = sp < 0 ? '' : rest.substring(sp + 1);
      notifyListeners();
      return;
    }
    logs.add(l);
    if (logs.length > 5000) logs.removeRange(0, 1000);
    _logFile?.writeln(l);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  /// Ejecuta [fn] en un isolate. Devuelve su resultado o null si falló (el error queda en el log).
  Future<Object?> run(String title, TaskFn fn, Map<String, Object?> args) async {
    if (busy) {
      log(tr('⚠ Ya hay una tarea en curso: {0}', [current]));
      return null;
    }
    current = title;
    progress = null;
    progressLabel = '';
    log('▶ $title');
    notifyListeners();
    final port = ReceivePort();
    final sub = port.listen((m) => log(m as String));
    final send = port.sendPort;
    final tb = tools;
    final sw = Stopwatch()..start();
    try {
      final r = await _spawn(fn, args, send, tb);
      await Future<void>.delayed(const Duration(milliseconds: 50)); // vaciar mensajes
      log('■ $title — ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
      return r;
    } catch (e) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      log(tr('✖ Error: {0}', [e]));
      return null;
    } finally {
      await sub.cancel();
      port.close();
      current = null;
      progress = null;
      notifyListeners();
    }
  }
}

/// Top-level a propósito: un closure creado dentro de un método de [TaskRunner]
/// capturaría `this` (con su IOSink) y no se podría enviar al isolate.
Future<Object?> _spawn(TaskFn fn, Map<String, Object?> args, SendPort send, ToolBox tb) {
  final lang = appLang; // el isolate nuevo no comparte variables globales
  return Isolate.run(() {
    appLang = lang;
    return fn(TaskCtx(send.send, tb), args);
  });
}

// ---------------- Tareas (top-level para poder enviarse a un isolate) ----------------

Project _p(Map<String, Object?> a) => Project(a['root'] as String);

Future<Object?> taskImport(TaskCtx c, Map<String, Object?> a) async {
  final p = _p(a);
  for (final f in (a['files'] as List).cast<String>()) {
    await p.importFile(f, c, unpackSuper: a['unpackSuper'] as bool? ?? true);
  }
  return null;
}

Future<Object?> taskUnpackSuper(TaskCtx c, Map<String, Object?> a) async {
  await _p(a).unpackSuperImage(a['path'] as String, c);
  return null;
}

Future<Object?> taskExtract(TaskCtx c, Map<String, Object?> a) async {
  for (final n in (a['names'] as List).cast<String>()) {
    await _p(a).extractPartition(n, c);
  }
  return null;
}

Future<Object?> taskBuild(TaskCtx c, Map<String, Object?> a) async {
  final p = _p(a);
  for (final n in (a['names'] as List).cast<String>()) {
    final fs = (a['fsType'] as String?) ?? p.fsTypeOf(n) ?? 'erofs';
    await p.buildPartition(n, fs, c);
  }
  return null;
}

Future<Object?> taskDebloat(TaskCtx c, Map<String, Object?> a) async => _p(a).debloat((a['paths'] as List).cast<String>(), c);

Future<Object?> taskBuildSuper(TaskCtx c, Map<String, Object?> a) async {
  await _p(a).buildSuper(c, sparse: a['sparse'] as bool? ?? true);
  return null;
}

Future<Object?> taskVbmeta(TaskCtx c, Map<String, Object?> a) async {
  _p(a).patchVbmeta(a['name'] as String, c);
  return null;
}

Future<Object?> taskBootUnpack(TaskCtx c, Map<String, Object?> a) async {
  _p(a).unpackBoot(a['name'] as String, c);
  return null;
}

Future<Object?> taskBootRepack(TaskCtx c, Map<String, Object?> a) async {
  _p(a).repackBoot(a['name'] as String, c);
  return null;
}

Future<Object?> taskOdin(TaskCtx c, Map<String, Object?> a) async =>
    _p(a).buildOdinTar((a['files'] as List).cast<String>(), c, compress: a['compress'] as bool? ?? true, name: a['name'] as String);

Future<Object?> taskSparse(TaskCtx c, Map<String, Object?> a) async {
  _p(a).convertSparse(a['file'] as String, a['toSparse'] as bool, c);
  return null;
}

Future<Object?> taskExport(TaskCtx c, Map<String, Object?> a) async {
  final dest = a['dest'] as String;
  Directory(dest).createSync(recursive: true);
  for (final f in (a['files'] as List).cast<String>()) {
    final name = f.split('/').last;
    c.log(tr('Copiando {0} → {1}', [name, dest]));
    final src = File(f).openSync();
    final dst = File('$dest/$name').openSync(mode: FileMode.write);
    try {
      final total = src.lengthSync();
      var done = 0;
      while (true) {
        final b = src.readSync(8 << 20);
        if (b.isEmpty) break;
        dst.writeFromSync(b);
        done += b.length;
        c.progress(name, done, total);
      }
    } finally {
      src.closeSync();
      dst.closeSync();
    }
  }
  c.log(tr('✔ Exportado a {0}', [dest]));
  return null;
}

Future<Object?> taskDelete(TaskCtx c, Map<String, Object?> a) async {
  for (final f in (a['paths'] as List).cast<String>()) {
    final t = FileSystemEntity.typeSync(f, followLinks: false);
    if (t == FileSystemEntityType.directory) {
      Directory(f).deleteSync(recursive: true);
    } else if (t != FileSystemEntityType.notFound) {
      File(f).deleteSync();
    }
    c.log('  borrado ${f.split('/').last}');
  }
  return null;
}

@visibleForTesting
Future<Object?> taskEcho(TaskCtx c, Map<String, Object?> a) async {
  c.log('echo ${a['v']}');
  return a['v'];
}

// ---------------- Root (Android) ----------------

const _byNameDirs = ['/dev/block/by-name', '/dev/block/bootdevice/by-name'];

/// Lista las particiones del dispositivo (requiere root).
Future<List<String>> listDevicePartitions() async {
  for (final d in _byNameDirs) {
    final r = await Process.run('su', ['-c', 'ls $d']);
    if (r.exitCode == 0) {
      return (r.stdout as String).split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList()..sort();
    }
  }
  return [];
}

/// Copia particiones del dispositivo a images/ con dd (requiere root).
Future<Object?> taskDumpDevice(TaskCtx c, Map<String, Object?> a) async {
  final p = _p(a);
  String? dir;
  for (final d in _byNameDirs) {
    if ((await Process.run('su', ['-c', 'ls $d'])).exitCode == 0) {
      dir = d;
      break;
    }
  }
  if (dir == null) throw StateError(tr('no se encontró /dev/block/by-name (¿root concedido?)'));
  for (final n in (a['names'] as List).cast<String>()) {
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(n)) continue;
    final out = '${p.imagesDir}/$n.img';
    await ToolBox.runRaw('dd', ['if=$dir/$n', 'of=$out', 'bs=4M'], log: c.log, asRoot: true);
    // Que el archivo sea del usuario de la app y no de root
    final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
    await ToolBox.runRaw('chown', ['$uid:$uid', out], log: c.log, asRoot: true);
    c.log(tr('✔ {0}.img ({1} MB)', [n, File(out).lengthSync() >> 20]));
  }
  return null;
}
