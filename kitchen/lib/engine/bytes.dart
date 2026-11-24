import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Lectura little/big-endian sobre un buffer.
class Buf {
  final Uint8List b;
  final ByteData d;
  Buf(this.b) : d = ByteData.sublistView(b);

  int u8(int o) => b[o];
  int u16(int o) => d.getUint16(o, Endian.little);
  int u32(int o) => d.getUint32(o, Endian.little);
  int u64(int o) => d.getUint64(o, Endian.little);
  int be32(int o) => d.getUint32(o, Endian.big);
  int be64(int o) => d.getUint64(o, Endian.big);

  /// Cadena terminada en NUL.
  String cstr(int o, int len) {
    var end = o;
    while (end < o + len && b[end] != 0) {
      end++;
    }
    return latin1.decode(b.sublist(o, end), allowInvalid: true);
  }
}

/// Escritura little-endian incremental.
class Out {
  final BytesBuilder _bb = BytesBuilder(copy: false);
  int get length => _bb.length;

  void u8(int v) => _bb.addByte(v & 0xff);
  void u16(int v) => _bb.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  void u32(int v) => _bb.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(int v) => _bb.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void be32(int v) => _bb.add((ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List());
  void bytes(List<int> v) => _bb.add(v);
  void zeros(int n) => _bb.add(Uint8List(n));

  /// Cadena fija de [len] bytes rellenada con NUL.
  void fixedStr(String s, int len) {
    final e = latin1.encode(s);
    if (e.length > len) throw ArgumentError('cadena demasiado larga: $s');
    _bb.add(e);
    zeros(len - e.length);
  }

  Uint8List take() => _bb.takeBytes();
}

/// Lee [len] bytes en [offset] (menos si el archivo es más corto).
Uint8List readAt(RandomAccessFile f, int offset, int len) {
  f.setPositionSync(offset);
  return f.readSync(len);
}

int alignUp(int v, int a) => a == 0 ? v : ((v + a - 1) ~/ a) * a;

/// Copia [len] bytes de [src] (desde su posición actual) a [dst].
void copyBytes(RandomAccessFile src, RandomAccessFile dst, int len,
    {void Function(int)? onBytes}) {
  const chunk = 4 << 20;
  var left = len;
  while (left > 0) {
    final n = left < chunk ? left : chunk;
    final data = src.readSync(n);
    if (data.isEmpty) throw const FormatException('fin de archivo inesperado');
    dst.writeFromSync(data);
    left -= data.length;
    onBytes?.call(data.length);
  }
}

String humanSize(int n) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = n.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

/// Callback de progreso: hechos / total (total puede ser 0 si es desconocido).
typedef Progress = void Function(int done, int total);
