// Lector de metadatos EROFS en Dart puro: árbol de directorios, uid/gid/modo,
// xattrs (SELinux, capabilities) y destinos de symlinks. Los datos de archivos
// comprimidos los extrae fsck.erofs; con esto se generan fs_config y file_contexts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';
import 'fsmeta.dart';
import '../l10n/l10n.dart';

class ErofsInode {
  final int nid, mode, uid, gid, size, layout, rawBlk;
  final int inodeSize, xattrSize;
  final Map<String, Uint8List> xattrs;
  ErofsInode(this.nid, this.mode, this.uid, this.gid, this.size, this.layout, this.rawBlk, this.inodeSize, this.xattrSize, this.xattrs);
  bool get isDir => (mode & 0xF000) == 0x4000;
  bool get isLink => (mode & 0xF000) == 0xA000;
  bool get isFile => (mode & 0xF000) == 0x8000;
}

class ErofsImage {
  final RandomAccessFile f;
  late final int blkBits, blockSize, rootNid, metaBlk, xattrBlk;
  ErofsImage(String path) : f = File(path).openSync() {
    final sb = Buf(readAt(f, 1024, 128));
    if (sb.u32(0) != 0xE0F5E1E2) throw FormatException(tr('no es EROFS'));
    blkBits = sb.u8(12);
    blockSize = 1 << blkBits;
    rootNid = sb.u16(14);
    metaBlk = sb.u32(40);
    xattrBlk = sb.u32(44);
  }
  void close() => f.closeSync();

  int _inodePos(int nid) => metaBlk * blockSize + nid * 32;

  static const _prefixes = {1: 'user.', 2: 'system.posix_acl_access', 3: 'system.posix_acl_default', 4: 'trusted.', 6: 'security.'};

  ErofsInode inode(int nid) {
    final pos = _inodePos(nid);
    final raw = readAt(f, pos, 64);
    final b = Buf(raw);
    final fmt = b.u16(0);
    final extended = (fmt & 1) != 0;
    final layout = (fmt >> 1) & 7;
    final icount = b.u16(2);
    final mode = b.u16(4);
    final int size, uid, gid;
    if (extended) {
      size = b.u64(8);
      uid = b.u32(24);
      gid = b.u32(28);
    } else {
      size = b.u32(8);
      uid = b.u16(24);
      gid = b.u16(26);
    }
    final rawBlk = b.u32(16);
    final isz = extended ? 64 : 32;
    final xsz = icount == 0 ? 0 : 12 + (icount - 1) * 4;
    final xattrs = <String, Uint8List>{};
    if (xsz > 0) {
      final xb = readAt(f, pos + isz, xsz);
      final x = Buf(xb);
      final shared = xb[4];
      var p = 12;
      for (var i = 0; i < shared; i++) {
        final id = x.u32(p);
        p += 4;
        final sp = xattrBlk * blockSize + id * 4;
        final head = readAt(f, sp, 4);
        final nl = head[0], vs = Buf(head).u16(2);
        final e = readAt(f, sp, 4 + nl + vs);
        _addXattr(xattrs, e, 0);
      }
      while (p + 4 <= xsz) {
        final nl = xb[p], vs = x.u16(p + 2);
        if (p + 4 + nl + vs > xsz) break;
        _addXattr(xattrs, xb, p);
        p += alignUp(4 + nl + vs, 4);
      }
    }
    return ErofsInode(nid, mode, uid, gid, size, layout, rawBlk, isz, xsz, xattrs);
  }

  void _addXattr(Map<String, Uint8List> out, Uint8List e, int p) {
    final nl = e[p], idx = e[p + 1], vs = Buf(e).u16(p + 2);
    final prefix = _prefixes[idx & 0x7f];
    if (prefix == null || (idx & 0x80) != 0) return; // prefijos largos: no usados por Android
    final name = prefix + latin1.decode(e.sublist(p + 4, p + 4 + nl));
    out[name] = Uint8List.fromList(e.sublist(p + 4 + nl, p + 4 + nl + vs));
  }

  /// Lee datos de inodos sin comprimir (directorios y symlinks).
  Uint8List readPlain(ErofsInode ino) {
    if (ino.layout == 0) return readAt(f, ino.rawBlk * blockSize, ino.size);
    if (ino.layout == 2) {
      final full = ino.size ~/ blockSize * blockSize;
      final tail = ino.size - full;
      final out = BytesBuilder();
      if (full > 0) out.add(readAt(f, ino.rawBlk * blockSize, full));
      if (tail > 0) out.add(readAt(f, _inodePos(ino.nid) + ino.inodeSize + ino.xattrSize, tail));
      return out.takeBytes();
    }
    throw FormatException(tr('EROFS: layout {0} no soportado para nid {1}', [ino.layout, ino.nid]));
  }

  List<(String, int)> readDir(ErofsInode dir) {
    final data = readPlain(dir);
    final out = <(String, int)>[];
    for (var blk = 0; blk < data.length; blk += blockSize) {
      final end = (blk + blockSize < data.length) ? blk + blockSize : data.length;
      final b = Buf(Uint8List.sublistView(data, blk, end));
      final n = b.u16(8) ~/ 12;
      for (var i = 0; i < n; i++) {
        final nid = b.u64(i * 12);
        final off = b.u16(i * 12 + 8);
        var nameEnd = i + 1 < n ? b.u16((i + 1) * 12 + 8) : end - blk;
        var name = utf8.decode(b.b.sublist(off, nameEnd), allowMalformed: true);
        final z = name.indexOf('\x00');
        if (z >= 0) name = name.substring(0, z);
        if (name != '.' && name != '..') out.add((name, nid));
      }
    }
    return out;
  }

  /// Recorre todo el árbol y devuelve los metadatos (rutas relativas a la raíz, "" = raíz).
  List<FsEntry> walkMeta() {
    final entries = <FsEntry>[];
    final root = inode(rootNid);
    entries.add(FsEntry.fromXattrs('', root.uid, root.gid, root.mode, root.xattrs));
    void walk(ErofsInode dir, String rel) {
      for (final (name, nid) in readDir(dir)) {
        if (rel.isEmpty && name == 'lost+found') continue;
        final ino = inode(nid);
        final r = rel.isEmpty ? name : '$rel/$name';
        String? target;
        if (ino.isLink) target = utf8.decode(readPlain(ino), allowMalformed: true);
        entries.add(FsEntry.fromXattrs(r, ino.uid, ino.gid, ino.mode, ino.xattrs, linkTarget: target));
        if (ino.isDir) walk(ino, r);
      }
    }

    walk(root, '');
    return entries;
  }
}
