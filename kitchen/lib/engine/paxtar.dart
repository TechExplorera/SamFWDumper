// Genera un tar PAX con metadatos Android (uid/gid/modo, SELinux, capabilities)
// a partir de una carpeta extraída + fs_config + file_contexts.
// Se usa con `mkfs.erofs --tar=f`, que conserva esos metadatos sin necesitar
// libselinux ni libcutils (así funciona el mkfs.erofs oficial compilado para Android).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';
import 'fsmeta.dart';

class _Meta {
  final int uid, gid, mode, caps;
  _Meta(this.uid, this.gid, this.mode, this.caps);
}

Map<String, _Meta> _readFsConfig(String path) {
  final m = <String, _Meta>{};
  final f = File(path);
  if (!f.existsSync()) return m;
  for (final l in f.readAsLinesSync()) {
    final p = l.trim().split(RegExp(r'\s+'));
    if (p.length < 4) continue;
    var caps = 0;
    for (final extra in p.skip(4)) {
      if (extra.startsWith('capabilities=')) caps = int.parse(extra.substring(13).replaceFirst('0x', ''), radix: 16);
    }
    m[p[0].replaceAll(RegExp(r'/$'), '')] = _Meta(int.parse(p[1]), int.parse(p[2]), int.parse(p[3], radix: 8), caps);
  }
  return m;
}

Uint8List _paxRecord(String key, List<int> value) {
  final kv = [...utf8.encode(' $key='), ...value, 0x0a];
  var len = kv.length + 1;
  while ('$len'.length + kv.length != len) {
    len = '$len'.length + kv.length;
  }
  return Uint8List.fromList([...ascii.encode('$len'), ...kv]);
}

Uint8List _ustar(String name, int size, int mode, int uid, int gid, int type, {String link = '', int mtime = 0}) {
  final h = Uint8List(512);
  void put(int o, int len, List<int> v) => h.setRange(o, o + (v.length < len ? v.length : len), v);
  void oct(int o, int len, int v) => put(o, len, ascii.encode('${v.toRadixString(8).padLeft(len - 1, '0')}\x00'));
  put(0, 100, utf8.encode(name.length > 99 ? name.substring(0, 99) : name));
  oct(100, 8, mode & 0xFFF);
  oct(108, 8, uid);
  oct(116, 8, gid);
  oct(124, 12, size);
  oct(136, 12, mtime);
  h.fillRange(148, 156, 0x20);
  h[156] = type;
  put(157, 100, utf8.encode(link.length > 99 ? link.substring(0, 99) : link));
  put(257, 6, ascii.encode('ustar\x00'));
  put(263, 2, ascii.encode('00'));
  var sum = 0;
  for (final x in h) {
    sum += x;
  }
  put(148, 8, ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '));
  return h;
}

/// Escribe el tar en [sink] (p. ej. el stdin de mkfs.erofs).
/// [name]: partición (prefijo de rutas en fs_config / file_contexts).
Future<int> writeAndroidTar(IOSink sink, String srcDir, String configDir, String name,
    {int mtime = 1230768000, void Function(int files)? onProgress}) async {
  final cfg = _readFsConfig('$configDir/${name}_fs_config');
  final ctx = FileContexts('$configDir/${name}_file_contexts');
  var count = 0;

  Future<void> emit(String rel, FileSystemEntity e) async {
    final key = rel.isEmpty ? name : '$name/$rel';
    final st = e.statSync();
    final isDir = e is Directory, isLink = e is Link;
    final meta = cfg[key] ?? (rel.isEmpty ? cfg['/'] : null);
    final mode = meta?.mode ?? (isDir ? 0x1ED : (isLink ? 0x1FF : ((st.mode & 0x49) != 0 ? 0x1ED : 0x1A4)));
    final uid = meta?.uid ?? 0, gid = meta?.gid ?? 0;
    final c = ctx.lookup('/$key');
    final tarName = rel.isEmpty ? './' : (isDir ? '$rel/' : rel);
    final link = isLink ? e.targetSync() : '';
    final size = (!isDir && !isLink) ? st.size : 0;

    final pax = BytesBuilder();
    if (utf8.encode(tarName).length > 99) pax.add(_paxRecord('path', utf8.encode(tarName)));
    if (utf8.encode(link).length > 99) pax.add(_paxRecord('linkpath', utf8.encode(link)));
    if (c != null) pax.add(_paxRecord('SCHILY.xattr.security.selinux', [...utf8.encode(c), 0]));
    if (meta != null && meta.caps != 0) {
      // vfs_cap_data v2: magic | permitted lo | inheritable lo | permitted hi | inheritable hi
      final cap = ByteData(20)
        ..setUint32(0, 0x02000001, Endian.little)
        ..setUint32(4, meta.caps & 0xFFFFFFFF, Endian.little)
        ..setUint32(12, meta.caps >> 32, Endian.little);
      pax.add(_paxRecord('SCHILY.xattr.security.capability', cap.buffer.asUint8List()));
    }
    if (pax.isNotEmpty) {
      final data = pax.takeBytes();
      sink.add(_ustar('PaxHeaders/$count', data.length, 0x1A4, 0, 0, 0x78));
      sink.add(data);
      sink.add(Uint8List(alignUp(data.length, 512) - data.length));
    }
    sink.add(_ustar(tarName, size, mode, uid, gid, isDir ? 0x35 : (isLink ? 0x32 : 0x30), link: link, mtime: mtime));
    if (size > 0) {
      await sink.addStream(File(e.path).openRead());
      final pad = alignUp(size, 512) - size;
      if (pad > 0) sink.add(Uint8List(pad));
    }
    count++;
    if (count % 200 == 0) {
      onProgress?.call(count);
      await sink.flush();
    }
  }

  await emit('', Directory(srcDir));
  // Recorrido ordenado y determinista (carpetas antes que su contenido)
  Future<void> walk(String dir, String rel) async {
    final items = Directory(dir).listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
    for (final e in items) {
      final n = e.path.substring(dir.length + 1);
      final r = rel.isEmpty ? n : '$rel/$n';
      await emit(r, e);
      if (e is Directory) await walk(e.path, r);
    }
  }

  await walk(srcDir, '');
  sink.add(Uint8List(1024));
  await sink.flush();
  return count;
}
