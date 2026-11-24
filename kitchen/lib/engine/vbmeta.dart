import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../l10n/l10n.dart';

const avbFlagHashtreeDisabled = 1, avbFlagVerificationDisabled = 2;

bool isVbmeta(String path) {
  final f = File(path).openSync();
  try {
    return latin1.decode(f.readSync(4), allowInvalid: true) == 'AVB0';
  } finally {
    f.closeSync();
  }
}

int vbmetaFlags(String path) {
  final f = File(path).openSync();
  try {
    f.setPositionSync(120);
    return ByteData.sublistView(f.readSync(4)).getUint32(0, Endian.big);
  } finally {
    f.closeSync();
  }
}

/// Desactiva dm-verity y la verificación AVB (como `fastboot --disable-verity --disable-verification`).
void vbmetaDisable(String path, {bool verity = true, bool verification = true}) {
  if (!isVbmeta(path)) throw FormatException(tr('no es una imagen vbmeta (falta AVB0)'));
  final data = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(data);
  var flags = bd.getUint32(120, Endian.big);
  if (verity) flags |= avbFlagHashtreeDisabled;
  if (verification) flags |= avbFlagVerificationDisabled;
  bd.setUint32(120, flags, Endian.big);
  File(path).writeAsBytesSync(data);
}
