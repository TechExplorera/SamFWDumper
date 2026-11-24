// Prueba de extremo a extremo con un firmware Samsung sintético.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fw_kitchen/engine/detect.dart';
import 'package:fw_kitchen/engine/lp.dart';
import 'package:fw_kitchen/engine/lz4.dart';
import 'package:fw_kitchen/engine/sparse.dart';
import 'package:fw_kitchen/engine/tar.dart';
import 'package:fw_kitchen/engine/tools.dart';
import 'package:fw_kitchen/engine/vbmeta.dart';
import 'package:fw_kitchen/kitchen/project.dart';
import 'package:fw_kitchen/kitchen/runner.dart';

final repo = Directory.current.parent.path;
final at = '$repo/tools/android-tools', et = '$repo/tools/erofs-utils';
final tb = ToolBox(searchDirs: [at, et]);

Future<void> sh(String bin, List<String> args, {Map<String, String>? env}) async {
  final r = await Process.run(bin, args, environment: env);
  if (r.exitCode != 0) throw StateError('$bin ${args.join(' ')}\n${r.stdout}${r.stderr}');
}

void main() {
  test('flujo completo: zip Samsung → ROM cocinada → AP para Odin', () async {
    if (!tb.has('e2fsdroid') || !tb.has('mkfs.erofs') || !File('$at/lpmake').existsSync()) return;
    final tmp = Directory.systemTemp.createTempSync('fwkpipe');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final w = '${tmp.path}/fw';
    Directory(w).createSync();

    // --- system (ext4, system-as-root) ---
    final sys = '$w/sysroot';
    Directory('$sys/system/app/Facebook').createSync(recursive: true);
    Directory('$sys/system/app/Calculator').createSync(recursive: true);
    Directory('$sys/system/priv-app/KnoxCore').createSync(recursive: true);
    Directory('$sys/system/bin').createSync(recursive: true);
    File('$sys/system/build.prop').writeAsStringSync('ro.product.model=SM-TEST\n');
    File('$sys/system/app/Facebook/Facebook.apk').writeAsBytesSync(Uint8List(200000));
    File('$sys/system/app/Calculator/Calculator.apk').writeAsBytesSync(List.generate(50000, (i) => i & 0xff));
    File('$sys/system/priv-app/KnoxCore/KnoxCore.apk').writeAsBytesSync(Uint8List(100000));
    File('$sys/system/bin/sh').writeAsBytesSync(List.generate(80000, (i) => (i * 7) & 0xff));
    Link('$sys/system/bin/ls').createSync('sh');
    File('$w/sys_fsc').writeAsStringSync([
      '/ 0 0 0755', 'system/ 0 0 0755', 'system/lost+found 0 0 0700', 'system/system 0 0 0755',
      'system/system/app 0 0 0755', 'system/system/app/Facebook 0 0 0755', 'system/system/app/Facebook/Facebook.apk 0 0 0644',
      'system/system/app/Calculator 0 0 0755', 'system/system/app/Calculator/Calculator.apk 0 0 0644',
      'system/system/priv-app 0 0 0755', 'system/system/priv-app/KnoxCore 0 0 0755', 'system/system/priv-app/KnoxCore/KnoxCore.apk 0 0 0644',
      'system/system/bin 0 2000 0751', 'system/system/bin/sh 0 2000 0755 capabilities=0x1000', 'system/system/bin/ls 0 2000 0755',
      'system/system/build.prop 0 0 0600', ''
    ].join('\n'));
    File('$w/sys_ctx').writeAsStringSync('/system u:object_r:rootfs:s0\n/system/lost\\+found u:object_r:rootfs:s0\n'
        '/system/system(/.*)? u:object_r:system_file:s0\n/system/system/bin/sh u:object_r:shell_exec:s0\n');
    await sh('$at/mke2fs.android', ['-O', '^has_journal', '-t', 'ext4', '-b', '4096', '-L', 'system', '-I', '256', '-M', '/', '-m', '0', '$w/system.img', '2048']);
    await sh('$at/e2fsdroid', ['-e', '-T', '0', '-C', '$w/sys_fsc', '-S', '$w/sys_ctx', '-f', sys, '-a', '/system', '$w/system.img']);

    // --- vendor (erofs) y product (ext4 vacío-ish) ---
    Directory('$w/vendor/etc').createSync(recursive: true);
    File('$w/vendor/etc/fstab.qcom').writeAsStringSync('/dev/block/by-name/userdata /data f2fs noatime wait,check,fileencryption=aes-256-xts\n');
    await sh('$et/mkfs.erofs', ['-zlz4hc', '--mount-point=/vendor', '$w/vendor.img', '$w/vendor']);
    Directory('$w/product/app/Netflix').createSync(recursive: true);
    File('$w/product/app/Netflix/Netflix.apk').writeAsBytesSync(Uint8List(30000));
    await sh('$at/mke2fs.android', ['-t', 'ext4', '-b', '4096', '-L', 'product', '-M', '/product', '-d', '$w/product', '$w/product.img', '512']);

    // --- super (sparse + lz4), boot, vbmeta ---
    await sh('$at/lpmake', [
      '--metadata-size', '65536', '--super-name', 'super', '--metadata-slots', '2', '--device', 'super:${96 << 20}',
      '--group', 'qti_dynamic_partitions:${90 << 20}',
      for (final n in ['system', 'vendor', 'product']) ...[
        '--partition', '$n:readonly:${File('$w/$n.img').lengthSync()}:qti_dynamic_partitions', '--image', '$n=$w/$n.img'
      ],
      '--partition', 'odm:readonly:0:qti_dynamic_partitions',
      '--sparse', '--output', '$w/super.img',
    ]);
    expect(detectImage('$w/super.img'), ImgType.sparse);
    lz4CompressFile('$w/super.img', '$w/super.img.lz4');
    Directory('$w/py/gki').createSync(recursive: true);
    File('$w/py/gki/__init__.py').writeAsStringSync('');
    File('$w/py/gki/generate_gki_certificate.py').writeAsStringSync('def generate_gki_certificate(*a, **k):\n    pass\n');
    File('$w/kernel').writeAsBytesSync(List.generate(70000, (i) => i & 0xff));
    File('$w/ramdisk').writeAsBytesSync(List.generate(30000, (i) => (i * 5) & 0xff));
    await sh('python3', ['$at/mkbootimg', '--kernel', '$w/kernel', '--ramdisk', '$w/ramdisk', '--header_version', '4', '--os_version', '14.0.0', '--os_patch_level', '2026-10', '--output', '$w/boot.img'],
        env: {'PYTHONPATH': '$w/py'});
    lz4CompressFile('$w/boot.img', '$w/boot.img.lz4');
    await sh('python3', ['$at/avbtool', 'make_vbmeta_image', '--output', '$w/vbmeta.img']);
    lz4CompressFile('$w/vbmeta.img', '$w/vbmeta.img.lz4');
    tarCreate('$w/AP_S918BXXU9ZZZ1_CL1_FAC.tar.md5',
        {'$w/boot.img.lz4': 'boot.img.lz4', '$w/vbmeta.img.lz4': 'vbmeta.img.lz4', '$w/super.img.lz4': 'super.img.lz4'},
        odinMd5: true);
    final zipPath = '$w/SM-S918B_EUX_S918BXXU9ZZZ1.zip';
    final enc = ZipFileEncoder()..create(zipPath);
    await enc.addFile(File('$w/AP_S918BXXU9ZZZ1_CL1_FAC.tar.md5'));
    await enc.close();

    // ================= La kitchen =================
    final logs = <String>[];
    final c = TaskCtx((l) {
      if (!l.startsWith('@progress')) logs.add(l);
    }, tb);
    final p = Project.create('${tmp.path}/ws', 'test_rom');
    await p.importFile(zipPath, c);
    final names = p.images().map((i) => '${i.name}:${i.type}').toSet();
    expect(names, containsAll(['boot:boot', 'vbmeta:vbmeta', 'system:ext4', 'vendor:erofs', 'product:ext4']), reason: logs.join('\n'));
    expect(File('${p.inputDir}/super.img').existsSync(), isTrue);

    // Extraer todas
    for (final n in ['system', 'vendor', 'product']) {
      await p.extractPartition(n, c);
    }
    expect(File('${p.extractedDir}/system/system/build.prop').readAsStringSync(), contains('SM-TEST'));
    expect(File('${p.extractedDir}/vendor/etc/fstab.qcom').existsSync(), isTrue);
    expect(File('${p.extractedDir}/config/system_fs_config').readAsStringSync(), contains('system/system/bin/sh 0 2000 0755 capabilities=0x1000'));

    // Debloat + un archivo nuevo (debe heredar metadatos)
    final removed = p.debloat(['system/system/app/Facebook', 'system/system/priv-app/KnoxCore', 'product/app/Netflix', 'system/no/existe'], c);
    expect(removed.length, 3);
    File('${p.extractedDir}/system/system/etc_new.conf').writeAsStringSync('nuevo');
    // Modificar fstab (típico: quitar cifrado)
    final fstab = File('${p.extractedDir}/vendor/etc/fstab.qcom');
    fstab.writeAsStringSync(fstab.readAsStringSync().replaceAll(',fileencryption=aes-256-xts', ''));

    // Reconstruir
    await p.buildPartition('system', 'ext4', c);
    await p.buildPartition('vendor', 'erofs', c);
    await p.buildPartition('product', 'erofs', c); // cambio de sistema de archivos
    for (final n in ['system', 'product']) {
      final fsck = n == 'system'
          ? await Process.run('e2fsck', ['-fn', '${p.outputDir}/$n.img'])
          : await Process.run('$et/fsck.erofs', ['${p.outputDir}/$n.img']);
      expect(fsck.exitCode, 0, reason: '$n: ${fsck.stdout}${fsck.stderr}');
    }
    // El system reconstruido contiene lo esperado
    final chk = Directory('${tmp.path}/chk')..createSync();
    final p2 = Project.create(chk.path, 'verify');
    File('${p.outputDir}/system.img').copySync('${p2.imagesDir}/system.img');
    await p2.extractPartition('system', c);
    expect(Directory('${p2.extractedDir}/system/system/app/Facebook').existsSync(), isFalse);
    expect(Directory('${p2.extractedDir}/system/system/app/Calculator').existsSync(), isTrue);
    expect(File('${p2.extractedDir}/system/system/etc_new.conf').readAsStringSync(), 'nuevo');
    final cfg2 = File('${p2.extractedDir}/config/system_fs_config').readAsStringSync();
    expect(cfg2, contains('system/system/bin/sh 0 2000 0755 capabilities=0x1000'));
    expect(cfg2, contains('system/system/etc_new.conf 0 0 0644'));
    expect(File('${p2.extractedDir}/config/system_file_contexts').readAsStringSync(), contains('/system/system/bin/sh u:object_r:shell_exec:s0'));

    // super, vbmeta, boot y Odin
    await p.buildSuper(c);
    final sup = '${p.outputDir}/super.img';
    expect(detectImage(sup), ImgType.sparse);
    final raw = '${tmp.path}/super.raw';
    await sh('$at/simg2img', [sup, raw]);
    final dump = await Process.run('$at/lpdump', [raw]);
    expect(dump.exitCode, 0, reason: '${dump.stdout}${dump.stderr}');
    expect(dump.stdout as String, contains('qti_dynamic_partitions'));
    final md = lpRead(raw);
    expect(md.partitions.map((x) => x.name), ['system', 'vendor', 'product', 'odm']);
    await sh('$at/lpunpack', [raw, '${tmp.path}/unp']);
    expect(detectImage('${tmp.path}/unp/product.img'), ImgType.erofs);

    p.patchVbmeta('vbmeta', c);
    expect(vbmetaFlags('${p.outputDir}/vbmeta.img'), 3);
    p.unpackBoot('boot', c);
    File('${p.bootDir}/boot/kernel').writeAsBytesSync(List.generate(70000, (i) => 255 - (i & 0xff)));
    p.repackBoot('boot', c);
    expect(detectImage('${p.outputDir}/boot.img'), ImgType.boot);

    final ap = await p.buildOdinTar(['boot.img', 'vbmeta.img', 'super.img'], c, name: 'AP_TEST.tar.md5');
    final entries = tarList(ap);
    expect(entries.map((e) => e.name), ['boot.img.lz4', 'vbmeta.img.lz4', 'super.img.lz4']);
    // El super dentro del AP se descomprime al mismo sparse
    tarExtract(ap, entries[2], '${tmp.path}/s.lz4');
    lz4DecompressFile('${tmp.path}/s.lz4', '${tmp.path}/s.img');
    sparseToRaw('${tmp.path}/s.img', '${tmp.path}/s.raw');
    expect(File('${tmp.path}/s.raw').lengthSync(), File(raw).lengthSync());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('runner: las tareas se ejecutan en un isolate', () async {
    final r = TaskRunner(tb);
    final tmp = Directory.systemTemp.createTempSync('fwklog');
    addTearDown(() => tmp.deleteSync(recursive: true));
    r.setLogFile('${tmp.path}/k.log'); // como en la app: con archivo de log abierto
    final v = await r.run('eco', taskEcho, {'v': 42});
    expect(v, 42);
    expect(r.logs, contains('echo 42'));
  });
}
