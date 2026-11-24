import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';

const lz4FrameMagic = 0x184D2204;
const lz4LegacyMagic = 0x184C2102;

/// Descomprime un bloque LZ4 de [src] (desde [sp] hasta [send]) en [dst] desde [dp].
/// [dst] puede contener historial previo antes de [dp]. Devuelve el nuevo dp.
int lz4DecodeBlock(Uint8List src, int sp, int send, Uint8List dst, int dp) {
  while (sp < send) {
    final token = src[sp++];
    var lit = token >> 4;
    if (lit == 15) {
      int x;
      do {
        x = src[sp++];
        lit += x;
      } while (x == 255);
    }
    if (lit > 0) {
      dst.setRange(dp, dp + lit, src, sp);
      sp += lit;
      dp += lit;
    }
    if (sp >= send) break; // último literal
    final off = src[sp] | (src[sp + 1] << 8);
    sp += 2;
    if (off == 0) throw const FormatException('LZ4: offset 0 inválido');
    var ml = token & 15;
    if (ml == 15) {
      int x;
      do {
        x = src[sp++];
        ml += x;
      } while (x == 255);
    }
    ml += 4;
    var m = dp - off;
    if (m < 0) throw const FormatException('LZ4: offset fuera de rango');
    if (off >= ml) {
      dst.setRange(dp, dp + ml, dst, m);
      dp += ml;
    } else {
      final end = dp + ml;
      while (dp < end) {
        dst[dp++] = dst[m++];
      }
    }
  }
  return dp;
}

/// Lector secuencial con buffer para archivos grandes.
class _Reader {
  final RandomAccessFile f;
  final int size;
  _Reader(this.f) : size = f.lengthSync();
  int get pos => f.positionSync();
  bool get eof => pos >= size;
  Uint8List read(int n) {
    final r = f.readSync(n);
    if (r.length != n) throw const FormatException('LZ4: archivo truncado');
    return r;
  }

  int u32() => Buf(read(4)).u32(0);
  int u8() => read(1)[0];
}

/// Descomprime un archivo .lz4 (formato frame o legacy) a [outPath].
void lz4DecompressFile(String inPath, String outPath, {Progress? onProgress}) {
  final inF = File(inPath).openSync();
  final outF = File(outPath).openSync(mode: FileMode.write);
  try {
    final r = _Reader(inF);
    while (!r.eof) {
      final magic = r.u32();
      if (magic == lz4FrameMagic) {
        _decodeFrame(r, outF, onProgress);
      } else if (magic == lz4LegacyMagic) {
        _decodeLegacy(r, outF, onProgress);
      } else if ((magic & 0xFFFFFFF0) == 0x184D2A50) {
        final n = r.u32();
        inF.setPositionSync(r.pos + n); // frame saltable
      } else {
        throw FormatException('LZ4: magic desconocido 0x${magic.toRadixString(16)}');
      }
    }
  } finally {
    inF.closeSync();
    outF.closeSync();
  }
}

void _decodeFrame(_Reader r, RandomAccessFile out, Progress? onProgress) {
  final flg = r.u8();
  final bd = r.u8();
  if ((flg >> 6) != 1) throw const FormatException('LZ4: versión de frame no soportada');
  final indep = (flg & 0x20) != 0;
  final blockChecksum = (flg & 0x10) != 0;
  final hasSize = (flg & 0x08) != 0;
  final contentChecksum = (flg & 0x04) != 0;
  final hasDict = (flg & 0x01) != 0;
  if (hasSize) r.read(8);
  if (hasDict) r.read(4);
  r.u8(); // HC
  final maxBlock = const {4: 64 << 10, 5: 256 << 10, 6: 1 << 20, 7: 4 << 20}[(bd >> 4) & 7] ??
      (throw const FormatException('LZ4: tamaño de bloque inválido'));
  const hist = 64 << 10;
  final dst = Uint8List(hist + maxBlock);
  var histLen = 0;
  while (true) {
    final bsz = r.u32();
    if (bsz == 0) break;
    final raw = (bsz & 0x80000000) != 0;
    final len = bsz & 0x7FFFFFFF;
    final data = r.read(len);
    if (blockChecksum) r.read(4);
    int produced;
    if (raw) {
      dst.setRange(histLen, histLen + len, data);
      produced = len;
    } else {
      produced = lz4DecodeBlock(data, 0, len, dst, histLen) - histLen;
    }
    out.writeFromSync(dst, histLen, histLen + produced);
    onProgress?.call(r.pos, r.size);
    if (!indep) {
      final total = histLen + produced;
      final keep = total < hist ? total : hist;
      dst.setRange(0, keep, dst, total - keep);
      histLen = keep;
    }
  }
  if (contentChecksum) r.read(4);
}

void _decodeLegacy(_Reader r, RandomAccessFile out, Progress? onProgress) {
  final dst = Uint8List(8 << 20);
  while (!r.eof) {
    final start = r.pos;
    final len = r.u32();
    if (len == lz4LegacyMagic || len == lz4FrameMagic) {
      r.f.setPositionSync(start);
      return;
    }
    final data = r.read(len);
    final n = lz4DecodeBlock(data, 0, len, dst, 0);
    out.writeFromSync(dst, 0, n);
    onProgress?.call(r.pos, r.size);
  }
}

// ---------------- Compresión ----------------

/// Comprime un bloque. Devuelve null si no se reduce el tamaño.
Uint8List? lz4EncodeBlock(Uint8List src, int start, int end) {
  final n = end - start;
  if (n < 13) return null;
  final out = Uint8List(n + n ~/ 255 + 16);
  var op = 0;
  const hashLog = 16;
  final table = Int32List(1 << hashLog)..fillRange(0, 1 << hashLog, -1);
  int read32(int p) => src[p] | (src[p + 1] << 8) | (src[p + 2] << 16) | (src[p + 3] << 24);
  int hash(int v) => ((v * 2654435761) & 0xFFFFFFFF) >> (32 - hashLog);

  final mflimit = end - 12;
  final matchEnd = end - 5;
  var anchor = start;
  var ip = start;
  while (ip < mflimit) {
    final seq = read32(ip);
    final h = hash(seq);
    final ref = table[h];
    table[h] = ip;
    if (ref < start || ip - ref > 65535 || read32(ref) != seq) {
      ip++;
      continue;
    }
    var mlen = 4;
    while (ip + mlen < matchEnd && src[ref + mlen] == src[ip + mlen]) {
      mlen++;
    }
    final lit = ip - anchor;
    if (op + lit + lit ~/ 255 + 16 > out.length) return null;
    final tokenPos = op++;
    var token = (lit >= 15 ? 15 : lit) << 4;
    if (lit >= 15) {
      var l = lit - 15;
      while (l >= 255) {
        out[op++] = 255;
        l -= 255;
      }
      out[op++] = l;
    }
    out.setRange(op, op + lit, src, anchor);
    op += lit;
    final off = ip - ref;
    out[op++] = off & 0xff;
    out[op++] = off >> 8;
    final ml = mlen - 4;
    token |= ml >= 15 ? 15 : ml;
    if (ml >= 15) {
      var l = ml - 15;
      while (l >= 255) {
        if (op >= out.length) return null;
        out[op++] = 255;
        l -= 255;
      }
      out[op++] = l;
    }
    out[tokenPos] = token;
    ip += mlen;
    anchor = ip;
    if (ip < mflimit) table[hash(read32(ip - 2))] = ip - 2;
  }
  final lit = end - anchor;
  if (op + lit + lit ~/ 255 + 2 > out.length || op + lit + lit ~/ 255 + 2 >= n) return null;
  if (lit >= 15) {
    out[op++] = 0xF0;
    var l = lit - 15;
    while (l >= 255) {
      out[op++] = 255;
      l -= 255;
    }
    out[op++] = l;
  } else {
    out[op++] = lit << 4;
  }
  out.setRange(op, op + lit, src, anchor);
  op += lit;
  return Uint8List.sublistView(out, 0, op);
}

/// Comprime [inPath] a formato LZ4 frame (bloques independientes de 4 MB).
void lz4CompressFile(String inPath, String outPath, {Progress? onProgress}) {
  final inF = File(inPath).openSync();
  final outF = File(outPath).openSync(mode: FileMode.write);
  try {
    final total = inF.lengthSync();
    const flg = 0x60; // versión 01, bloques independientes
    const bd = 0x70; // 4 MB
    final hc = (xxh32(Uint8List.fromList([flg, bd]), 0) >> 8) & 0xff;
    final hdr = Out()
      ..u32(lz4FrameMagic)
      ..u8(flg)
      ..u8(bd)
      ..u8(hc);
    outF.writeFromSync(hdr.take());
    var done = 0;
    while (true) {
      final block = inF.readSync(4 << 20);
      if (block.isEmpty) break;
      final c = lz4EncodeBlock(block, 0, block.length);
      final o = Out();
      if (c == null) {
        o.u32(block.length | 0x80000000);
        outF.writeFromSync(o.take());
        outF.writeFromSync(block);
      } else {
        o.u32(c.length);
        outF.writeFromSync(o.take());
        outF.writeFromSync(c);
      }
      done += block.length;
      onProgress?.call(done, total);
    }
    outF.writeFromSync((Out()..u32(0)).take());
  } finally {
    inF.closeSync();
    outF.closeSync();
  }
}

/// xxHash32 (usado para el byte de checksum de cabecera LZ4).
int xxh32(Uint8List data, int seed) {
  const p1 = 2654435761, p2 = 2246822519, p3 = 3266489917, p4 = 668265263, p5 = 374761393;
  int rotl(int x, int r) => ((x << r) | (x >> (32 - r))) & 0xFFFFFFFF;
  int mul(int a, int b) => ((a & 0xFFFF) * b + (((a >> 16) * b & 0xFFFF) << 16)) & 0xFFFFFFFF;
  final bd = ByteData.sublistView(data);
  var i = 0;
  final len = data.length;
  int h;
  if (len >= 16) {
    var v1 = (seed + p1 + p2) & 0xFFFFFFFF, v2 = (seed + p2) & 0xFFFFFFFF, v3 = seed, v4 = (seed - p1) & 0xFFFFFFFF;
    int round(int acc, int input) => mul(rotl((acc + mul(input, p2)) & 0xFFFFFFFF, 13), p1);
    while (i <= len - 16) {
      v1 = round(v1, bd.getUint32(i, Endian.little));
      v2 = round(v2, bd.getUint32(i + 4, Endian.little));
      v3 = round(v3, bd.getUint32(i + 8, Endian.little));
      v4 = round(v4, bd.getUint32(i + 12, Endian.little));
      i += 16;
    }
    h = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & 0xFFFFFFFF;
  } else {
    h = (seed + p5) & 0xFFFFFFFF;
  }
  h = (h + len) & 0xFFFFFFFF;
  while (i + 4 <= len) {
    h = mul(rotl((h + mul(bd.getUint32(i, Endian.little), p3)) & 0xFFFFFFFF, 17), p4);
    i += 4;
  }
  while (i < len) {
    h = mul(rotl((h + mul(data[i], p5)) & 0xFFFFFFFF, 11), p1);
    i++;
  }
  h ^= h >> 15;
  h = mul(h, p2);
  h ^= h >> 13;
  h = mul(h, p3);
  h ^= h >> 16;
  return h;
}
