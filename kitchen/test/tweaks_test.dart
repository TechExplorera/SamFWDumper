import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fw_kitchen/kitchen/project.dart';
import 'package:fw_kitchen/kitchen/tweaks.dart';

void main() {
  late Directory tmp;
  late Project p;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fwktw');
    p = Project.create(tmp.path, 'rom');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('build.prop: info, editar, añadir y borrar', () {
    Directory('${p.extractedDir}/system/system').createSync(recursive: true);
    Directory('${p.extractedDir}/vendor').createSync(recursive: true);
    final sys = '${p.extractedDir}/system/system/build.prop';
    File(sys).writeAsStringSync('# comentario\nro.product.system.model=SM-S918B\nro.build.version.release=14\n'
        'ro.build.display.id=UP1A.S918BXXU9\nro.build.version.security_patch=2026-10-01\nro.debuggable=0\n');
    File('${p.extractedDir}/vendor/build.prop').writeAsStringSync('ro.vendor.build.fingerprint=samsung/x\n');
    expect(findBuildProps(p), ['system/system/build.prop', 'vendor/build.prop']);
    final info = romInfo(p);
    expect(info.model, 'SM-S918B');
    expect(info.android, '14');
    expect(info.patch, '2026-10-01');
    expect(info.fingerprint, 'samsung/x');

    setProp(sys, 'ro.debuggable', '1');
    setProp(sys, 'ro.adb.secure', '0');
    setProp(sys, 'ro.build.display.id', null);
    final text = File(sys).readAsStringSync();
    expect(text, startsWith('# comentario\n'));
    expect(text, contains('ro.debuggable=1'));
    expect(text, isNot(contains('ro.debuggable=0')));
    expect(text, contains('ro.adb.secure=0'));
    expect(text, isNot(contains('ro.build.display.id')));
    expect(readProps(sys)['ro.adb.secure'], '0');
  });

  test('fstab: quitar cifrado forzado y AVB', () {
    const fstab = '''
# Android fstab
system   /system  erofs  ro  wait,logical,first_stage_mount,avb=vbmeta_system,avb_keys=/avb/q-gsi.avbpubkey
/dev/block/by-name/userdata  /data  f2fs  noatime,nosuid  latemount,wait,check,fileencryption=aes-256-xts:aes-256-cts:v2,keydirectory=/metadata/vold/metadata_encryption,quota
/dev/block/by-name/efs  /mnt/vendor/efs  ext4  noatime  wait,check
''';
    final (out, changes) = patchFstab(fstab);
    expect(changes.length, 2);
    expect(out, contains('wait,logical,first_stage_mount'));
    expect(out, isNot(contains('avb')));
    expect(out, isNot(contains('fileencryption')));
    expect(out, contains('latemount,wait,check,quota'));
    expect(out, contains('/dev/block/by-name/efs  /mnt/vendor/efs'));
    expect(out, startsWith('# Android fstab'));
    final (out2, changes2) = patchFstab(out);
    expect(changes2, isEmpty);
    expect(out2, out);
    // Solo AVB
    final (_, onlyAvb) = patchFstab(fstab, encryption: false);
    expect(onlyAvb, ['/system: −avb=vbmeta_system,avb_keys=/avb/q-gsi.avbpubkey']);
  });

  test('uso del super por grupo', () {
    p.saveMeta({
      'super': {
        'block_devices': [
          {'name': 'super', 'size': 100 << 20, 'alignment': 1 << 20, 'first_logical_sector': 2048, 'flags': 0}
        ],
        'groups': [
          {'name': 'default', 'max_size': 0, 'flags': 0},
          {'name': 'main', 'max_size': 10 << 20, 'flags': 0},
        ],
        'partitions': [
          {'name': 'system', 'group': 'main', 'attributes': 1, 'size': 0},
          {'name': 'vendor', 'group': 'main', 'attributes': 1, 'size': 0},
        ],
      }
    });
    File('${p.imagesDir}/system.img').writeAsBytesSync(List.filled(6 << 20, 0));
    File('${p.imagesDir}/vendor.img').writeAsBytesSync(List.filled(3 << 20, 0));
    var (dev, groups) = superUsage(p)!;
    expect(dev, 100 << 20);
    expect(groups.single.used, 9 << 20);
    expect(groups.single.fits, isTrue);
    File('${p.outputDir}/system.img').writeAsBytesSync(List.filled(8 << 20, 0)); // la de salida tiene prioridad
    (dev, groups) = superUsage(p)!;
    expect(groups.single.used, 11 << 20);
    expect(groups.single.fits, isFalse);
  });
}
