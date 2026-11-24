import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';

const sparseMagic = 0xED26FF3A;
const _chunkRaw = 0xCAC1, _chunkFill = 0xCAC2, _chunkDontCare = 0xCAC3, _chunkCrc = 0xCAC4;

bool isSparse(String path) {
  final f = File(path).openSync();
  try {
    final h = f.readSync(4);
    return h.length == 4 && Buf(h).u32(0) == sparseMagic;
  } finally {
    f.closeSync();
  }
}

/// Convierte una imagen sparse de Android a raw (equivalente a simg2img).
void sparseToRaw(String inPath, String outPath, {Progress? onProgress}) {
  final inF = File(inPath).openSync();
  final outF = File(outPath).openSync(mode: FileMode.write);
  try {
    final h = Buf(inF.readSync(28));
    if (h.u32(0) != sparseMagic) throw const FormatException('no es una imagen sparse');
    final fileHdr = h.u16(8), chunkHdr = h.u16(10);
    final blk = h.u32(12), totalBlocks = h.u32(16), chunks = h.u32(20);
    inF.setPositionSync(fileHdr);
    var outBlocks = 0;
    for (var i = 0; i < chunks; i++) {
      final c = Buf(inF.readSync(chunkHdr));
      final type = c.u16(0), nBlk = c.u32(4), total = c.u32(8);
      final dataLen = total - chunkHdr;
      switch (type) {
        case _chunkRaw:
          outF.setPositionSync(outBlocks * blk);
          copyBytes(inF, outF, dataLen);
          break;
        case _chunkFill:
          final fill = inF.readSync(4);
          final buf = Uint8List(blk * (nBlk < 1024 ? nBlk : 1024));
          for (var j = 0; j < buf.length; j += 4) {
            buf.setRange(j, j + 4, fill);
          }
          outF.setPositionSync(outBlocks * blk);
          var left = nBlk * blk;
          while (left > 0) {
            final n = left < buf.length ? left : buf.length;
            outF.writeFromSync(buf, 0, n);
            left -= n;
          }
          break;
        case _chunkDontCare:
          break;
        case _chunkCrc:
          inF.readSync(dataLen);
          break;
        default:
          throw FormatException('sparse: tipo de chunk desconocido 0x${type.toRadixString(16)}');
      }
      outBlocks += nBlk;
      onProgress?.call(outBlocks, totalBlocks);
    }
    outF.truncateSync(totalBlocks * blk);
  } finally {
    inF.closeSync();
    outF.closeSync();
  }
}

/// Convierte raw a sparse (equivalente a img2simg). Detecta bloques vacíos y rellenos.
void rawToSparse(String inPath, String outPath, {int blockSize = 4096, Progress? onProgress}) {
  final inF = File(inPath).openSync();
  final size = inF.lengthSync();
  if (size % blockSize != 0) {
    inF.closeSync();
    throw ArgumentError('el tamaño ($size) no es múltiplo de $blockSize');
  }
  final totalBlocks = size ~/ blockSize;
  final outF = File(outPath).openSync(mode: FileMode.write);
  try {
    outF.writeFromSync(Uint8List(28)); // cabecera provisional
    var chunks = 0;
    // Chunk RAW en curso
    var rawStart = -1, rawCount = 0;
    final rawBuf = BytesBuilder(copy: true);
    void flushRaw() {
      if (rawCount == 0) return;
      final o = Out()
        ..u16(_chunkRaw)
        ..u16(0)
        ..u32(rawCount)
        ..u32(12 + rawCount * blockSize);
      outF.writeFromSync(o.take());
      outF.writeFromSync(rawBuf.takeBytes());
      chunks++;
      rawCount = 0;
      rawStart = -1;
    }

    var fillVal = -1, fillCount = 0;
    void flushFill() {
      if (fillCount == 0) return;
      final o = Out()
        ..u16(fillVal == 0 ? _chunkDontCare : _chunkFill)
        ..u16(0)
        ..u32(fillCount)
        ..u32(fillVal == 0 ? 12 : 16);
      if (fillVal != 0) o.u32(fillVal);
      outF.writeFromSync(o.take());
      chunks++;
      fillCount = 0;
      fillVal = -1;
    }

    const batch = 1024;
    for (var b0 = 0; b0 < totalBlocks; b0 += batch) {
      final data = inF.readSync(blockSize * (totalBlocks - b0 < batch ? totalBlocks - b0 : batch));
      final bd = ByteData.sublistView(data);
      for (var o = 0; o < data.length; o += blockSize) {
        final v = bd.getUint32(o, Endian.little);
        var uniform = true;
        for (var j = o + 4; j < o + blockSize; j += 4) {
          if (bd.getUint32(j, Endian.little) != v) {
            uniform = false;
            break;
          }
        }
        if (uniform) {
          flushRaw();
          if (fillCount > 0 && fillVal != v) flushFill();
          fillVal = v;
          fillCount++;
        } else {
          flushFill();
          if (rawStart < 0) rawStart = b0 + o ~/ blockSize;
          rawBuf.add(Uint8List.sublistView(data, o, o + blockSize));
          rawCount++;
          if (rawCount >= 8192) flushRaw(); // chunks de máx. 32 MB
        }
      }
      onProgress?.call(b0 + data.length ~/ blockSize, totalBlocks);
    }
    flushRaw();
    flushFill();
    final h = Out()
      ..u32(sparseMagic)
      ..u16(1)
      ..u16(0)
      ..u16(28)
      ..u16(12)
      ..u32(blockSize)
      ..u32(totalBlocks)
      ..u32(chunks)
      ..u32(0);
    outF.setPositionSync(0);
    outF.writeFromSync(h.take());
  } finally {
    inF.closeSync();
    outF.closeSync();
  }
}
