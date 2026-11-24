// Desempaquetado / reempaquetado de boot.img (cabeceras v0 a v4).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';

const bootMagic = 'ANDROID!';

class BootImage {
  int headerVersion = 0;
  int pageSize = 4096;
  int kernelAddr = 0, ramdiskAddr = 0, secondAddr = 0, tagsAddr = 0;
  int osVersion = 0;
  String name = '';
  String cmdline = '';
  String extraCmdline = '';
  int dtbAddr = 0;
  Uint8List id = Uint8List(32);
  // Componentes (nombre de archivo -> bytes)
  final Map<String, Uint8List> parts = {};
  // AVB footer original (si existe), para conservar el tamaño de partición
  Uint8List? avbTail; // vbmeta embebido
  int originalSize = 0;
  int avbVbmetaOffset = 0;

  Map<String, dynamic> toJson() => {
        'header_version': headerVersion,
        'page_size': pageSize,
        'kernel_addr': kernelAddr,
        'ramdisk_addr': ramdiskAddr,
        'second_addr': secondAddr,
        'tags_addr': tagsAddr,
        'dtb_addr': dtbAddr,
        'os_version': osVersion,
        'os_version_str': osVersionString,
        'name': name,
        'cmdline': cmdline,
        'extra_cmdline': extraCmdline,
        'id': base64.encode(id),
        'original_size': originalSize,
        'avb_vbmeta_offset': avbVbmetaOffset,
        'parts': parts.keys.toList(),
      };

  void loadJson(Map<String, dynamic> j) {
    headerVersion = j['header_version'];
    pageSize = j['page_size'];
    kernelAddr = j['kernel_addr'];
    ramdiskAddr = j['ramdisk_addr'];
    secondAddr = j['second_addr'];
    tagsAddr = j['tags_addr'];
    dtbAddr = j['dtb_addr'] ?? 0;
    osVersion = j['os_version'];
    name = j['name'];
    cmdline = j['cmdline'];
    extraCmdline = j['extra_cmdline'] ?? '';
    id = base64.decode(j['id']);
    originalSize = j['original_size'] ?? 0;
    avbVbmetaOffset = j['avb_vbmeta_offset'] ?? 0;
  }

  String get osVersionString {
    if (osVersion == 0) return '-';
    final v = osVersion >> 11, lvl = osVersion & 0x7ff;
    final a = (v >> 14) & 0x7f, b = (v >> 7) & 0x7f, c = v & 0x7f;
    final y = (lvl >> 4) + 2000, m = lvl & 0xf;
    return 'Android $a.$b.$c, parche $y-${m.toString().padLeft(2, '0')}';
  }
}

bool isBootImage(String path) {
  final f = File(path).openSync();
  try {
    return latin1.decode(f.readSync(8), allowInvalid: true) == bootMagic;
  } finally {
    f.closeSync();
  }
}

BootImage bootParse(Uint8List data) {
  final b = Buf(data);
  if (latin1.decode(data.sublist(0, 8)) != bootMagic) throw const FormatException('no es un boot.img (falta ANDROID!)');
  final img = BootImage()..originalSize = data.length;
  final ver = b.u32(40);
  img.headerVersion = ver;
  var off = 0;
  Uint8List take(int size, int page) {
    final r = Uint8List.sublistView(data, off, off + size);
    off += alignUp(size, page);
    return Uint8List.fromList(r);
  }

  if (ver >= 3) {
    img.pageSize = 4096;
    final kSize = b.u32(8), rSize = b.u32(12);
    img.osVersion = b.u32(16);
    final hSize = b.u32(20);
    img.cmdline = b.cstr(44, 1536);
    off = alignUp(hSize, 4096);
    if (kSize > 0) img.parts['kernel'] = take(kSize, 4096);
    if (rSize > 0) img.parts['ramdisk'] = take(rSize, 4096);
    if (ver >= 4) {
      final sSize = b.u32(1580);
      if (sSize > 0) img.parts['boot_signature'] = take(sSize, 4096);
    }
  } else {
    final page = b.u32(36);
    img.pageSize = page;
    final kSize = b.u32(8), rSize = b.u32(16), sSize = b.u32(24);
    img.kernelAddr = b.u32(12);
    img.ramdiskAddr = b.u32(20);
    img.secondAddr = b.u32(28);
    img.tagsAddr = b.u32(32);
    img.osVersion = b.u32(44);
    img.name = b.cstr(48, 16);
    img.cmdline = b.cstr(64, 512);
    img.id = Uint8List.fromList(data.sublist(576, 608));
    img.extraCmdline = b.cstr(608, 1024);
    off = page;
    if (kSize > 0) img.parts['kernel'] = take(kSize, page);
    if (rSize > 0) img.parts['ramdisk'] = take(rSize, page);
    if (sSize > 0) img.parts['second'] = take(sSize, page);
    if (ver >= 1) {
      final rdSize = b.u32(1632);
      if (rdSize > 0) img.parts['recovery_dtbo'] = take(rdSize, page);
    }
    if (ver >= 2) {
      final dSize = b.u32(1648);
      img.dtbAddr = b.u64(1652);
      if (dSize > 0) img.parts['dtb'] = take(dSize, page);
    }
  }
  // AVB footer: últimos 64 bytes "AVBf"
  if (data.length >= 64 && latin1.decode(data.sublist(data.length - 64, data.length - 60)) == 'AVBf') {
    final f = Buf(Uint8List.sublistView(data, data.length - 64));
    final vbOff = f.be64(20), vbSize = f.be64(28);
    img.avbVbmetaOffset = vbOff;
    img.avbTail = Uint8List.fromList(data.sublist(vbOff, vbOff + vbSize));
  }
  return img;
}

Uint8List bootBuild(BootImage img) {
  final o = Out();
  final p = img.parts;
  int sz(String k) => p[k]?.length ?? 0;
  if (img.headerVersion >= 3) {
    o.bytes(latin1.encode(bootMagic));
    o.u32(sz('kernel'));
    o.u32(sz('ramdisk'));
    o.u32(img.osVersion);
    o.u32(img.headerVersion >= 4 ? 1584 : 1580);
    o.zeros(16);
    o.u32(img.headerVersion);
    o.fixedStr(img.cmdline, 1536);
    if (img.headerVersion >= 4) o.u32(sz('boot_signature'));
  } else {
    o.bytes(latin1.encode(bootMagic));
    o.u32(sz('kernel'));
    o.u32(img.kernelAddr);
    o.u32(sz('ramdisk'));
    o.u32(img.ramdiskAddr);
    o.u32(sz('second'));
    o.u32(img.secondAddr);
    o.u32(img.tagsAddr);
    o.u32(img.pageSize);
    o.u32(img.headerVersion);
    o.u32(img.osVersion);
    o.fixedStr(img.name, 16);
    o.fixedStr(img.cmdline, 512);
    o.bytes(img.id);
    o.fixedStr(img.extraCmdline, 1024);
    if (img.headerVersion >= 1) {
      o.u32(sz('recovery_dtbo'));
      // offset de recovery_dtbo
      final page = img.pageSize;
      final rdOff = page + alignUp(sz('kernel'), page) + alignUp(sz('ramdisk'), page) + alignUp(sz('second'), page);
      o.u64(sz('recovery_dtbo') > 0 ? rdOff : 0);
      o.u32(img.headerVersion >= 2 ? 1660 : 1648);
    }
    if (img.headerVersion >= 2) {
      o.u32(sz('dtb'));
      o.u64(img.dtbAddr);
    }
  }
  final page = img.headerVersion >= 3 ? 4096 : img.pageSize;
  void pad() => o.zeros(alignUp(o.length, page) - o.length);
  pad();
  final order = img.headerVersion >= 3
      ? ['kernel', 'ramdisk', 'boot_signature']
      : ['kernel', 'ramdisk', 'second', 'recovery_dtbo', 'dtb'];
  for (final k in order) {
    if (p[k] != null && p[k]!.isNotEmpty) {
      o.bytes(p[k]!);
      pad();
    }
  }
  var body = o.take();
  // Conserva el vbmeta embebido y el tamaño de partición si había AVB footer
  if (img.avbTail != null && img.originalSize > 0) {
    final vbOff = alignUp(body.length, 4096);
    final total = img.originalSize;
    if (vbOff + img.avbTail!.length + 64 > total) {
      throw StateError('el boot nuevo (${humanSize(body.length)}) no cabe en la partición (${humanSize(total)})');
    }
    final out = Uint8List(total);
    out.setAll(0, body);
    out.setAll(vbOff, img.avbTail!);
    final footer = ByteData(64);
    footer.buffer.asUint8List().setAll(0, latin1.encode('AVBf'));
    footer.setUint32(4, 1, Endian.big);
    footer.setUint32(8, 0, Endian.big);
    footer.setUint64(12, body.length, Endian.big);
    footer.setUint64(20, vbOff, Endian.big);
    footer.setUint64(28, img.avbTail!.length, Endian.big);
    out.setAll(total - 64, footer.buffer.asUint8List());
    body = out;
  }
  return body;
}

/// Desempaqueta [imgPath] en [outDir] (un archivo por componente + boot_info.json).
void bootUnpack(String imgPath, String outDir) {
  final img = bootParse(File(imgPath).readAsBytesSync());
  Directory(outDir).createSync(recursive: true);
  img.parts.forEach((k, v) => File('$outDir/$k').writeAsBytesSync(v));
  if (img.avbTail != null) File('$outDir/avb_vbmeta.bin').writeAsBytesSync(img.avbTail!);
  File('$outDir/boot_info.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(img.toJson()));
}

/// Reempaqueta desde [dir] (creado por [bootUnpack]) a [outPath].
void bootRepack(String dir, String outPath) {
  final img = BootImage()..loadJson(jsonDecode(File('$dir/boot_info.json').readAsStringSync()));
  for (final k in ['kernel', 'ramdisk', 'second', 'recovery_dtbo', 'dtb', 'boot_signature']) {
    final f = File('$dir/$k');
    if (f.existsSync()) img.parts[k] = f.readAsBytesSync();
  }
  final avb = File('$dir/avb_vbmeta.bin');
  if (avb.existsSync()) img.avbTail = avb.readAsBytesSync();
  File(outPath).writeAsBytesSync(bootBuild(img));
}
