import 'dart:convert';
import 'dart:io';

import 'bytes.dart';

enum ImgType { sparse, lz4, superLp, ext4, erofs, f2fs, boot, vendorBoot, vbmeta, tar, zip, unknown }

extension ImgTypeLabel on ImgType {
  String get label => switch (this) {
        ImgType.sparse => 'sparse',
        ImgType.lz4 => 'lz4',
        ImgType.superLp => 'super',
        ImgType.ext4 => 'ext4',
        ImgType.erofs => 'erofs',
        ImgType.f2fs => 'f2fs',
        ImgType.boot => 'boot',
        ImgType.vendorBoot => 'vendor_boot',
        ImgType.vbmeta => 'vbmeta',
        ImgType.tar => 'tar',
        ImgType.zip => 'zip',
        ImgType.unknown => '?',
      };
  bool get isFilesystem => this == ImgType.ext4 || this == ImgType.erofs || this == ImgType.f2fs;
}

ImgType detectImage(String path) {
  final f = File(path).openSync();
  try {
    final len = f.lengthSync();
    final h = Buf(readAt(f, 0, 8192 > len ? len : 8192));
    if (h.b.length < 8) return ImgType.unknown;
    final m0 = h.u32(0);
    if (m0 == 0xED26FF3A) return ImgType.sparse;
    if (m0 == 0x184D2204 || m0 == 0x184C2102) return ImgType.lz4;
    if (m0 == 0x04034b50) return ImgType.zip;
    final s8 = latin1.decode(h.b.sublist(0, 8), allowInvalid: true);
    if (s8 == 'ANDROID!') return ImgType.boot;
    if (s8 == 'VNDRBOOT') return ImgType.vendorBoot;
    if (s8.startsWith('AVB0')) return ImgType.vbmeta;
    if (h.b.length >= 262 && latin1.decode(h.b.sublist(257, 262), allowInvalid: true) == 'ustar') return ImgType.tar;
    if (h.b.length >= 1028) {
      if (h.u32(1024) == 0xE0F5E1E2) return ImgType.erofs;
      if (h.u32(1024) == 0xF2F52010) return ImgType.f2fs;
      if (h.u16(1024 + 56) == 0xEF53) return ImgType.ext4;
    }
    if (h.b.length >= 4100 && h.u32(4096) == 0x616c4467) return ImgType.superLp;
    return ImgType.unknown;
  } finally {
    f.closeSync();
  }
}
