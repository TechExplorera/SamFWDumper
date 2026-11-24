// Formato "liblp" de particiones dinámicas (super.img).
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bytes.dart';

const lpGeometryMagic = 0x616c4467;
const lpHeaderMagic = 0x414C5030;
const lpReserved = 4096;
const lpGeometrySize = 4096;
const lpSector = 512;

const lpAttrReadonly = 1, lpAttrSlotSuffixed = 2, lpAttrUpdated = 4, lpAttrDisabled = 8;

class LpPartition {
  String name;
  int attributes;
  int groupIndex;
  List<LpExtent> extents;
  LpPartition(this.name, this.attributes, this.groupIndex, this.extents);
  int get sizeBytes => extents.fold(0, (a, e) => a + e.numSectors * lpSector);
}

class LpExtent {
  final int numSectors, targetType, targetData, targetSource;
  LpExtent(this.numSectors, this.targetType, this.targetData, this.targetSource);
}

class LpGroup {
  String name;
  int flags;
  int maxSize;
  LpGroup(this.name, this.flags, this.maxSize);
}

class LpBlockDevice {
  int firstLogicalSector, alignment, alignmentOffset, size, flags;
  String name;
  LpBlockDevice(this.firstLogicalSector, this.alignment, this.alignmentOffset, this.size, this.name, this.flags);
}

class LpMetadata {
  int metadataMaxSize, slotCount, logicalBlockSize;
  int major, minor, headerFlags;
  List<LpPartition> partitions;
  List<LpGroup> groups;
  List<LpBlockDevice> blockDevices;
  LpMetadata({
    required this.metadataMaxSize,
    required this.slotCount,
    required this.logicalBlockSize,
    required this.major,
    required this.minor,
    required this.headerFlags,
    required this.partitions,
    required this.groups,
    required this.blockDevices,
  });

  Map<String, dynamic> toJson() => {
        'metadata_max_size': metadataMaxSize,
        'slot_count': slotCount,
        'logical_block_size': logicalBlockSize,
        'version': '$major.$minor',
        'header_flags': headerFlags,
        'block_devices': [
          for (final b in blockDevices)
            {'name': b.name, 'size': b.size, 'alignment': b.alignment, 'first_logical_sector': b.firstLogicalSector, 'flags': b.flags}
        ],
        'groups': [for (final g in groups) {'name': g.name, 'max_size': g.maxSize, 'flags': g.flags}],
        'partitions': [
          for (final p in partitions)
            {'name': p.name, 'group': groups[p.groupIndex].name, 'attributes': p.attributes, 'size': p.sizeBytes}
        ],
      };
}

bool isSuperImage(String path) {
  final f = File(path).openSync();
  try {
    if (f.lengthSync() < lpReserved + 4) return false;
    final b = readAt(f, lpReserved, 4);
    return Buf(b).u32(0) == lpGeometryMagic;
  } finally {
    f.closeSync();
  }
}

/// Lee los metadatos del slot [slot] de un super.img en formato raw.
LpMetadata lpRead(String path, {int slot = 0}) {
  final f = File(path).openSync();
  try {
    final g = Buf(readAt(f, lpReserved, 52));
    if (g.u32(0) != lpGeometryMagic) throw const FormatException('no es un super.img (falta geometría LP)');
    final maxSize = g.u32(36), slots = g.u32(40), lbs = g.u32(44);
    final mdOff = lpReserved + 2 * lpGeometrySize + slot * maxSize;
    final raw = readAt(f, mdOff, maxSize);
    final h = Buf(raw);
    if (h.u32(0) != lpHeaderMagic) throw const FormatException('cabecera de metadatos LP inválida');
    final major = h.u16(4), minor = h.u16(6), headerSize = h.u32(8);
    final tablesSize = h.u32(44);
    int desc(int i, int k) => h.u32(80 + i * 12 + k * 4);
    final flags = minor >= 2 ? h.u32(128) : 0;
    final t = Buf(Uint8List.sublistView(raw, headerSize, headerSize + tablesSize));

    final parts = <LpPartition>[];
    final extents = <LpExtent>[];
    for (var i = 0; i < desc(1, 1); i++) {
      final o = desc(1, 0) + i * desc(1, 2);
      extents.add(LpExtent(t.u64(o), t.u32(o + 8), t.u64(o + 12), t.u32(o + 20)));
    }
    for (var i = 0; i < desc(0, 1); i++) {
      final o = desc(0, 0) + i * desc(0, 2);
      final first = t.u32(o + 40), n = t.u32(o + 44);
      parts.add(LpPartition(t.cstr(o, 36), t.u32(o + 36), t.u32(o + 48), extents.sublist(first, first + n)));
    }
    final groups = <LpGroup>[];
    for (var i = 0; i < desc(2, 1); i++) {
      final o = desc(2, 0) + i * desc(2, 2);
      groups.add(LpGroup(t.cstr(o, 36), t.u32(o + 36), t.u64(o + 40)));
    }
    final devs = <LpBlockDevice>[];
    for (var i = 0; i < desc(3, 1); i++) {
      final o = desc(3, 0) + i * desc(3, 2);
      devs.add(LpBlockDevice(t.u64(o), t.u32(o + 8), t.u32(o + 12), t.u64(o + 16), t.cstr(o + 24, 36), t.u32(o + 60)));
    }
    return LpMetadata(
      metadataMaxSize: maxSize,
      slotCount: slots,
      logicalBlockSize: lbs,
      major: major,
      minor: minor,
      headerFlags: flags,
      partitions: parts,
      groups: groups,
      blockDevices: devs,
    );
  } finally {
    f.closeSync();
  }
}

/// Extrae las particiones de un super.img raw a [outDir]. Devuelve las rutas creadas.
List<String> lpUnpack(String superPath, String outDir,
    {Set<String>? only, void Function(String name, int done, int total)? onProgress}) {
  final md = lpRead(superPath);
  Directory(outDir).createSync(recursive: true);
  final src = File(superPath).openSync();
  final created = <String>[];
  try {
    for (final p in md.partitions) {
      if (only != null && !only.contains(p.name)) continue;
      final outPath = '$outDir/${p.name}.img';
      final out = File(outPath).openSync(mode: FileMode.write);
      try {
        var done = 0;
        final total = p.sizeBytes;
        for (final e in p.extents) {
          final len = e.numSectors * lpSector;
          if (e.targetType == 0) {
            if (e.targetSource != 0) throw const FormatException('super multi-dispositivo no soportado');
            src.setPositionSync(e.targetData * lpSector);
            copyBytes(src, out, len, onBytes: (n) {
              done += n;
              onProgress?.call(p.name, done, total);
            });
          } else {
            out.setPositionSync(out.positionSync() + len);
            out.truncateSync(out.positionSync());
            done += len;
          }
        }
      } finally {
        out.closeSync();
      }
      created.add(outPath);
    }
  } finally {
    src.closeSync();
  }
  return created;
}

class LpBuildPartition {
  final String name;
  final String? imagePath; // null = partición vacía
  final String group;
  final int attributes;
  LpBuildPartition(this.name, this.imagePath, this.group, {this.attributes = lpAttrReadonly});
}

/// Construye un super.img raw (equivalente básico a lpmake).
void lpBuild({
  required String outPath,
  required int deviceSize,
  required int metadataMaxSize,
  required int slotCount,
  required List<LpGroup> groups,
  required List<LpBuildPartition> partitions,
  int alignment = 1 << 20,
  int minor = 0,
  int headerFlags = 0,
  String blockDeviceName = 'super',
  int blockDeviceFlags = 0,
  void Function(String name, int done, int total)? onProgress,
}) {
  const lbs = 4096;
  final allGroups = [
    if (groups.isEmpty || groups.first.name != 'default') LpGroup('default', 0, 0),
    ...groups,
  ];
  int groupIndex(String n) {
    final i = allGroups.indexWhere((g) => g.name == n);
    if (i < 0) throw ArgumentError('grupo desconocido: $n');
    return i;
  }

  final metaEnd = lpReserved + 2 * lpGeometrySize + 2 * slotCount * metadataMaxSize;
  final firstSector = alignUp(metaEnd, alignment) ~/ lpSector;
  var cursor = firstSector * lpSector;
  final parts = <LpPartition>[];
  final extents = <LpExtent>[];
  final groupUse = <int, int>{};
  final placements = <(String, int, int)>[]; // imagen, offset, tamaño
  for (final bp in partitions) {
    final gi = groupIndex(bp.group);
    var size = 0;
    if (bp.imagePath != null) {
      size = alignUp(File(bp.imagePath!).lengthSync(), lbs);
    }
    final exts = <LpExtent>[];
    if (size > 0) {
      cursor = alignUp(cursor, alignment);
      exts.add(LpExtent(size ~/ lpSector, 0, cursor ~/ lpSector, 0));
      placements.add((bp.imagePath!, cursor, size));
      cursor += size;
    }
    groupUse[gi] = (groupUse[gi] ?? 0) + size;
    parts.add(LpPartition(bp.name, bp.attributes, gi, exts));
    extents.addAll(exts);
  }
  if (cursor > deviceSize) {
    throw StateError('las particiones (${humanSize(cursor)}) no caben en super (${humanSize(deviceSize)})');
  }
  for (final e in groupUse.entries) {
    final g = allGroups[e.key];
    if (g.maxSize > 0 && e.value > g.maxSize) {
      throw StateError('el grupo ${g.name} usa ${humanSize(e.value)} y su máximo es ${humanSize(g.maxSize)}');
    }
  }

  // ---- Tablas ----
  final t = Out();
  final partOff = 0;
  var extIndex = 0;
  for (final p in parts) {
    t.fixedStr(p.name, 36);
    t.u32(p.attributes);
    t.u32(p.extents.isEmpty ? 0 : extIndex);
    t.u32(p.extents.length);
    t.u32(p.groupIndex);
    extIndex += p.extents.length;
  }
  final extOff = t.length;
  for (final e in extents) {
    t.u64(e.numSectors);
    t.u32(e.targetType);
    t.u64(e.targetData);
    t.u32(e.targetSource);
  }
  final grpOff = t.length;
  for (final g in allGroups) {
    t.fixedStr(g.name, 36);
    t.u32(g.flags);
    t.u64(g.maxSize);
  }
  final devOff = t.length;
  t.u64(firstSector);
  t.u32(alignment);
  t.u32(0);
  t.u64(deviceSize);
  t.fixedStr(blockDeviceName, 36);
  t.u32(blockDeviceFlags);
  final tables = t.take();

  final headerSize = minor >= 2 ? 256 : 128;
  Uint8List header(Uint8List headerChecksum) {
    final h = Out()
      ..u32(lpHeaderMagic)
      ..u16(10)
      ..u16(minor)
      ..u32(headerSize)
      ..bytes(headerChecksum)
      ..u32(tables.length)
      ..bytes(sha256.convert(tables).bytes)
      ..u32(partOff)
      ..u32(parts.length)
      ..u32(52)
      ..u32(extOff)
      ..u32(extents.length)
      ..u32(24)
      ..u32(grpOff)
      ..u32(allGroups.length)
      ..u32(48)
      ..u32(devOff)
      ..u32(1)
      ..u32(64);
    if (minor >= 2) {
      h.u32(headerFlags);
      h.zeros(124);
    }
    return h.take();
  }

  final h0 = header(Uint8List(32));
  final hdr = header(Uint8List.fromList(sha256.convert(h0).bytes));
  final metadata = Uint8List(metadataMaxSize);
  if (hdr.length + tables.length > metadataMaxSize) throw StateError('metadatos mayores que metadata_max_size');
  metadata.setRange(0, hdr.length, hdr);
  metadata.setRange(hdr.length, hdr.length + tables.length, tables);

  Uint8List geometry() {
    Uint8List g(List<int> cs) => (Out()
          ..u32(lpGeometryMagic)
          ..u32(52)
          ..bytes(cs)
          ..u32(metadataMaxSize)
          ..u32(slotCount)
          ..u32(lbs))
        .take();
    final full = Uint8List(lpGeometrySize);
    full.setAll(0, g(sha256.convert(g(Uint8List(32))).bytes));
    return full;
  }

  // ---- Escritura ----
  final out = File(outPath).openSync(mode: FileMode.write);
  try {
    out.writeFromSync(Uint8List(lpReserved));
    final geo = geometry();
    out.writeFromSync(geo);
    out.writeFromSync(geo);
    for (var copy = 0; copy < 2; copy++) {
      for (var s = 0; s < slotCount; s++) {
        out.writeFromSync(metadata);
      }
    }
    for (final (img, offset, size) in placements) {
      final name = parts.firstWhere((p) => p.extents.isNotEmpty && p.extents.first.targetData * lpSector == offset).name;
      final src = File(img).openSync();
      try {
        out.setPositionSync(offset);
        var done = 0;
        copyBytes(src, out, src.lengthSync(), onBytes: (n) {
          done += n;
          onProgress?.call(name, done, size);
        });
      } finally {
        src.closeSync();
      }
    }
    out.truncateSync(deviceSize);
  } finally {
    out.closeSync();
  }
}
