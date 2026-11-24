// Lector de ext4 en Dart puro: extrae archivos y metadatos (uid/gid/modo,
// contexto SELinux, capabilities) sin montar ni necesitar root.
import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';
import 'fsmeta.dart';

class Ext4Inode {
  final int number, mode, uid, gid, size, flags;
  final Uint8List iBlock;
  final Map<String, Uint8List> xattrs;
  Ext4Inode(this.number, this.mode, this.uid, this.gid, this.size, this.flags, this.iBlock, this.xattrs);
  bool get isDir => (mode & 0xF000) == 0x4000;
  bool get isFile => (mode & 0xF000) == 0x8000;
  bool get isLink => (mode & 0xF000) == 0xA000;
}

class Ext4Image {
  final RandomAccessFile f;
  late final int blockSize, inodesPerGroup, inodeSize, descSize, groupCount;
  late final bool is64;
  late final String lastMounted, volumeName;
  late final List<int> _inodeTables;

  Ext4Image(String path) : f = File(path).openSync() {
    final sb = Buf(readAt(f, 1024, 1024));
    if (sb.u16(56) != 0xEF53) throw const FormatException('no es ext4');
    blockSize = 1024 << sb.u32(24);
    final blocksPerGroup = sb.u32(32);
    inodesPerGroup = sb.u32(40);
    inodeSize = sb.u16(88);
    final incompat = sb.u32(96);
    is64 = (incompat & 0x80) != 0;
    descSize = is64 ? sb.u16(254) : 32;
    final blocks = sb.u32(4) + (is64 ? sb.u32(336) << 32 : 0);
    final firstData = sb.u32(20);
    groupCount = ((blocks - firstData) + blocksPerGroup - 1) ~/ blocksPerGroup;
    volumeName = sb.cstr(120, 16);
    lastMounted = sb.cstr(136, 64);
    final gdt = Buf(readAt(f, (firstData + 1) * blockSize, groupCount * descSize));
    _inodeTables = [
      for (var g = 0; g < groupCount; g++)
        gdt.u32(g * descSize + 8) + (is64 && descSize >= 64 ? gdt.u32(g * descSize + 0x28) << 32 : 0)
    ];
  }

  void close() => f.closeSync();

  Ext4Inode inode(int n) {
    final g = (n - 1) ~/ inodesPerGroup, idx = (n - 1) % inodesPerGroup;
    final raw = readAt(f, _inodeTables[g] * blockSize + idx * inodeSize, inodeSize);
    final b = Buf(raw);
    final mode = b.u16(0);
    final uid = b.u16(2) | (b.u16(120) << 16);
    final gid = b.u16(24) | (b.u16(122) << 16);
    final size = b.u32(4) | (b.u32(108) << 32);
    final flags = b.u32(32);
    final iBlock = Uint8List.fromList(raw.sublist(40, 100));
    final xattrs = <String, Uint8List>{};
    // xattrs dentro del inodo
    if (inodeSize > 128) {
      final extra = b.u16(128);
      final base = 128 + extra;
      if (base + 4 <= inodeSize && b.u32(base) == 0xEA020000) {
        _parseXattrs(raw, base + 4, base + 4, inodeSize, xattrs);
      }
    }
    // bloque de xattrs
    final acl = b.u32(104) | (b.u16(118) << 32);
    if (acl != 0) {
      final blk = readAt(f, acl * blockSize, blockSize);
      if (Buf(blk).u32(0) == 0xEA020000) _parseXattrs(blk, 32, 0, blockSize, xattrs);
    }
    return Ext4Inode(n, mode, uid, gid, size, flags, iBlock, xattrs);
  }

  static const _prefixes = {1: 'user.', 2: 'system.posix_acl_access', 3: 'system.posix_acl_default', 4: 'trusted.', 6: 'security.', 7: 'system.', 8: 'system.richacl'};

  void _parseXattrs(Uint8List raw, int start, int valueBase, int limit, Map<String, Uint8List> out) {
    final b = Buf(raw);
    var p = start;
    while (p + 16 <= limit) {
      final nameLen = raw[p];
      final idx = raw[p + 1];
      if (nameLen == 0 && idx == 0 && b.u16(p + 2) == 0 && b.u32(p + 4) == 0) break;
      final vOff = b.u16(p + 2), vInum = b.u32(p + 4), vSize = b.u32(p + 8);
      final name = (_prefixes[idx] ?? '') + b.cstr(p + 16, nameLen);
      if (vInum == 0 && valueBase + vOff + vSize <= raw.length) {
        out[name] = Uint8List.fromList(raw.sublist(valueBase + vOff, valueBase + vOff + vSize));
      }
      p += alignUp(16 + nameLen, 4);
    }
  }

  /// Lista de extents (bloque lógico, bloque físico, longitud, inicializado).
  List<(int, int, int, bool)> _extents(Uint8List node) {
    final b = Buf(node);
    if (b.u16(0) != 0xF30A) throw const FormatException('ext4: árbol de extents inválido (¿mapa indirecto?)');
    final entries = b.u16(2), depth = b.u16(6);
    final out = <(int, int, int, bool)>[];
    for (var i = 0; i < entries; i++) {
      final o = 12 + i * 12;
      if (depth == 0) {
        var len = b.u16(o + 4);
        final init = len <= 32768;
        if (!init) len -= 32768;
        out.add((b.u32(o), b.u32(o + 8) | (b.u16(o + 6) << 32), len, init));
      } else {
        final leaf = b.u32(o + 4) | (b.u16(o + 8) << 32);
        out.addAll(_extents(readAt(f, leaf * blockSize, blockSize)));
      }
    }
    return out;
  }

  /// Escribe el contenido del inodo en [sink] o lo devuelve si [sink] es null.
  Uint8List? readData(Ext4Inode ino, {RandomAccessFile? sink}) {
    final size = ino.size;
    if ((ino.flags & 0x10000000) != 0) {
      // inline data: primeros 60 bytes en i_block, resto en xattr system.data
      final extra = ino.xattrs['system.data'] ?? Uint8List(0);
      final all = Uint8List.fromList([...ino.iBlock, ...extra]);
      final d = Uint8List.sublistView(all, 0, size < all.length ? size : all.length);
      if (sink != null) {
        sink.writeFromSync(d);
        return null;
      }
      return Uint8List.fromList(d);
    }
    if ((ino.flags & 0x80000) == 0) {
      if (size == 0) return sink == null ? Uint8List(0) : null;
      throw const FormatException('ext4: archivos con bloques indirectos no soportados');
    }
    final result = sink == null ? BytesBuilder(copy: false) : null;
    var written = 0;
    final exts = _extents(ino.iBlock)..sort((a, b) => a.$1.compareTo(b.$1));
    void emit(Uint8List d) {
      if (sink != null) {
        sink.writeFromSync(d);
      } else {
        result!.add(d);
      }
      written += d.length;
    }

    for (final (lblk, pblk, len, init) in exts) {
      final start = lblk * blockSize;
      if (start >= size) break;
      if (start > written) emit(Uint8List(start - written)); // hueco
      var bytes = len * blockSize;
      if (start + bytes > size) bytes = size - start;
      if (!init) {
        emit(Uint8List(bytes));
        continue;
      }
      f.setPositionSync(pblk * blockSize);
      var left = bytes;
      while (left > 0) {
        final n = left < (4 << 20) ? left : (4 << 20);
        emit(f.readSync(n));
        left -= n;
      }
    }
    if (written < size) emit(Uint8List(size - written));
    return result?.takeBytes();
  }

  List<(String, int)> readDir(Ext4Inode dir) {
    final data = readData(dir)!;
    final b = Buf(data);
    final out = <(String, int)>[];
    var p = 0;
    while (p + 8 <= data.length) {
      final ino = b.u32(p), rec = b.u16(p + 4), nlen = data[p + 6];
      if (rec < 8) break;
      if (ino != 0 && nlen > 0) {
        final name = String.fromCharCodes(data, p + 8, p + 8 + nlen);
        if (name != '.' && name != '..') out.add((name, ino));
      }
      p += rec;
    }
    return out;
  }

  String linkTarget(Ext4Inode ino) {
    if (ino.size < 60 && (ino.flags & 0x80000) == 0 && (ino.flags & 0x10000000) == 0) {
      return String.fromCharCodes(ino.iBlock, 0, ino.size);
    }
    return String.fromCharCodes(readData(ino)!);
  }

  /// Extrae todo a [outDir]. Devuelve los metadatos de cada entrada (rutas relativas, "" = raíz).
  List<FsEntry> extractAll(String outDir, {void Function(int files, String path)? onProgress}) {
    final entries = <FsEntry>[];
    var count = 0;
    void walk(Ext4Inode dir, String rel) {
      for (final (name, n) in readDir(dir)) {
        if (rel.isEmpty && name == 'lost+found') continue;
        final ino = inode(n);
        final r = rel.isEmpty ? name : '$rel/$name';
        final path = '$outDir/$r';
        String? target;
        if (ino.isDir) {
          Directory(path).createSync(recursive: true);
        } else if (ino.isLink) {
          target = linkTarget(ino);
          try {
            Link(path).createSync(target);
          } on FileSystemException {
            // Almacenamiento sin soporte de symlinks: queda registrado en fs_config
          }
        } else if (ino.isFile) {
          final out = File(path).openSync(mode: FileMode.write);
          try {
            readData(ino, sink: out);
          } finally {
            out.closeSync();
          }
        } else {
          continue; // dispositivos/fifos: no aparecen en imágenes Android
        }
        entries.add(FsEntry.fromXattrs(r, ino.uid, ino.gid, ino.mode, ino.xattrs, linkTarget: target));
        onProgress?.call(++count, r);
        if (ino.isDir) walk(ino, r);
      }
    }

    Directory(outDir).createSync(recursive: true);
    final root = inode(2);
    entries.add(FsEntry.fromXattrs('', root.uid, root.gid, root.mode, root.xattrs));
    walk(root, '');
    return entries;
  }
}
