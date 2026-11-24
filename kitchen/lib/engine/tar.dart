// Lectura/escritura de tar (ustar) en streaming, incluido el .tar.md5 de Odin.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bytes.dart';
import '../l10n/l10n.dart';

class TarEntry {
  final String name;
  final int size;
  final int dataOffset;
  final int type; // '0' regular, '5' dir...
  TarEntry(this.name, this.size, this.dataOffset, this.type);
  bool get isFile => type == 0x30 || type == 0;
}

int _octal(Uint8List b, int o, int len) {
  // Soporta extensión base-256 (bit alto) para archivos > 8 GB
  if (b[o] & 0x80 != 0) {
    var v = b[o] & 0x7f;
    for (var i = 1; i < len; i++) {
      v = (v << 8) | b[o + i];
    }
    return v;
  }
  final s = latin1.decode(b.sublist(o, o + len)).replaceAll('\x00', '').trim();
  return s.isEmpty ? 0 : int.parse(s, radix: 8);
}

/// Lista las entradas de un tar sin extraerlas.
List<TarEntry> tarList(String path) {
  final f = File(path).openSync();
  final entries = <TarEntry>[];
  try {
    final size = f.lengthSync();
    var pos = 0;
    String? longName;
    while (pos + 512 <= size) {
      final h = readAt(f, pos, 512);
      if (h.every((x) => x == 0)) break;
      var name = Buf(h).cstr(0, 100);
      final prefix = Buf(h).cstr(345, 155);
      if (prefix.isNotEmpty) name = '$prefix/$name';
      final sz = _octal(h, 124, 12);
      final type = h[156];
      final data = pos + 512;
      if (type == 0x4c) {
        // GNU long name
        longName = Buf(readAt(f, data, sz)).cstr(0, sz);
      } else {
        entries.add(TarEntry(longName ?? name, sz, data, type));
        longName = null;
      }
      pos = data + alignUp(sz, 512);
    }
  } finally {
    f.closeSync();
  }
  return entries;
}

/// Extrae una entrada a [outPath].
void tarExtract(String tarPath, TarEntry e, String outPath, {Progress? onProgress}) {
  final src = File(tarPath).openSync();
  final dst = File(outPath).openSync(mode: FileMode.write);
  try {
    src.setPositionSync(e.dataOffset);
    var done = 0;
    copyBytes(src, dst, e.size, onBytes: (n) {
      done += n;
      onProgress?.call(done, e.size);
    });
  } finally {
    src.closeSync();
    dst.closeSync();
  }
}

Uint8List _header(String name, int size) {
  final h = Uint8List(512);
  final n = utf8.encode(name);
  if (n.length > 100) throw ArgumentError(tr('nombre demasiado largo para tar: {0}', [name]));
  h.setAll(0, n);
  void oct(int o, int len, int v) => h.setAll(o, latin1.encode('${v.toRadixString(8).padLeft(len - 1, '0')}\x00'));
  oct(100, 8, 420); // 0644
  oct(108, 8, 0);
  oct(116, 8, 0);
  if (size >= 0x1FFFFFFFF) {
    // base-256
    h[124] = 0x80;
    for (var i = 0; i < 11; i++) {
      h[135 - i] = (size >> (8 * i)) & 0xff;
    }
  } else {
    oct(124, 12, size);
  }
  oct(136, 12, DateTime.now().millisecondsSinceEpoch ~/ 1000);
  h.fillRange(148, 156, 0x20);
  h[156] = 0x30;
  h.setAll(257, latin1.encode('ustar\x00'));
  h.setAll(263, latin1.encode('00'));
  var sum = 0;
  for (final x in h) {
    sum += x;
  }
  h.setAll(148, latin1.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '));
  return h;
}

/// Crea un tar con [files] (ruta en disco -> nombre dentro del tar).
/// Si [odinMd5] es true añade al final la línea MD5 como hace Odin (archivo .tar.md5).
void tarCreate(String outPath, Map<String, String> files, {bool odinMd5 = false, Progress? onProgress}) {
  final out = File(outPath).openSync(mode: FileMode.write);
  final total = files.keys.fold<int>(0, (a, p) => a + File(p).lengthSync());
  var done = 0;
  final digestSink = _DigestSink();
  final md5in = md5.startChunkedConversion(digestSink);
  void write(Uint8List b) {
    out.writeFromSync(b);
    if (odinMd5) md5in.add(b);
  }

  try {
    for (final e in files.entries) {
      final src = File(e.key).openSync();
      try {
        final size = src.lengthSync();
        write(_header(e.value, size));
        var left = size;
        while (left > 0) {
          final chunk = src.readSync(left < (4 << 20) ? left : (4 << 20));
          write(chunk);
          left -= chunk.length;
          done += chunk.length;
          onProgress?.call(done, total);
        }
        final pad = alignUp(size, 512) - size;
        if (pad > 0) write(Uint8List(pad));
      } finally {
        src.closeSync();
      }
    }
    write(Uint8List(1024));
    if (odinMd5) {
      md5in.close();
      final name = outPath.split('/').last.replaceAll(RegExp(r'\.md5$'), '');
      out.writeFromSync(utf8.encode('${digestSink.value}  $name\n'));
    }
  } finally {
    out.closeSync();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest d) => value = d;
  @override
  void close() {}
}
