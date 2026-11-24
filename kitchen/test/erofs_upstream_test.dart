// Camino "Android": erofs-utils oficial (sin opciones fs_config/file_contexts).
// Requiere FWK_UPSTREAM_EROFS=<carpeta con mkfs.erofs y fsck.erofs oficiales> (lo prepara CI).
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fw_kitchen/engine/detect.dart';
import 'package:fw_kitchen/engine/erofs.dart';
import 'package:fw_kitchen/engine/fsops.dart';
import 'package:fw_kitchen/engine/tools.dart';

final upstream = Platform.environment['FWK_UPSTREAM_EROFS'];
final repoTools = '${Directory.current.parent.path}/tools';
String sha(String p) => sha256.convert(File(p).readAsBytesSync()).toString();

void main() {
  test('EROFS oficial: construir desde tar PAX y extraer con fsck.erofs + lector Dart', () async {
    if (upstream == null || !File('$upstream/mkfs.erofs').existsSync()) {
      markTestSkipped('FWK_UPSTREAM_EROFS no definido');
      return;
    }
    // Solo las herramientas oficiales: nada de extract.erofs ni de mkfs con fs_config
    final tb = ToolBox(searchDirs: [upstream!]);
    expect(tb.has('extract.erofs'), isFalse);
    final tmp = Directory.systemTemp.createTempSync('fwkup');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final w = tmp.path;

    final longDir = 'system/${'d' * 60}/${'e' * 60}';
    Directory('$w/system/$longDir').createSync(recursive: true);
    Directory('$w/system/system/bin').createSync(recursive: true);
    File('$w/system/system/bin/sh').writeAsBytesSync(List.generate(300000, (i) => (i * 13) & 0xff));
    File('$w/system/system/build.prop').writeAsStringSync('ro.x=1\n' * 2000);
    File('$w/system/$longDir/${'f' * 80}.txt').writeAsStringSync('largo');
    File('$w/system/system/empty').writeAsBytesSync(Uint8List(0));
    Link('$w/system/system/bin/ls').createSync('sh');
    Directory('$w/config').createSync();
    File('$w/config/system_fs_config').writeAsStringSync('''
/ 0 0 0755
system/ 0 0 0755
system/system 0 0 0755
system/system/bin 0 2000 0751
system/system/bin/sh 0 2000 0755 capabilities=0x3000000000
system/system/bin/ls 0 2000 0755
system/system/build.prop 0 0 0600
''');
    File('$w/config/system_file_contexts').writeAsStringSync(r'''
/system u:object_r:rootfs:s0
/system/system(/.*)? u:object_r:system_file:s0
/system/system/bin/sh u:object_r:shell_exec:s0
''');
    File('$w/config/system_mount_point').writeAsStringSync('/');
    final logs = <String>[];
    await buildFs('system', w, 'erofs', '$w/system.img', tb, log: logs.add);
    expect(logs.join('\n'), contains('--tar'));
    expect(detectImage('$w/system.img'), ImgType.erofs);
    final fsck = await Process.run('$upstream/fsck.erofs', ['$w/system.img']);
    expect(fsck.exitCode, 0, reason: '${fsck.stdout}${fsck.stderr}');

    // 1) Verificación independiente con extract.erofs (sekaiacg) del repo
    final sek = '$repoTools/erofs-utils/extract.erofs';
    if (File(sek).existsSync()) {
      Directory('$w/chk/in').createSync(recursive: true);
      File('$w/system.img').copySync('$w/chk/in/system.img');
      await Process.run(sek, ['-i', '$w/chk/in/system.img', '-x', '-f', '-s', '-o', '$w/chk/out']);
      final cfg = File('$w/chk/out/config/system_fs_config').readAsStringSync();
      expect(cfg, contains('system/system/bin 0 2000 0751'));
      expect(cfg, contains('system/system/bin/sh 0 2000 0755 capabilities=0x3000000000'));
      expect(cfg, contains('system/system/build.prop 0 0 0600'));
      final ctx = File('$w/chk/out/config/system_file_contexts').readAsStringSync();
      expect(ctx, contains('/system/system/bin/sh u:object_r:shell_exec:s0'));
      expect(ctx, contains('/system/system/build\\.prop u:object_r:system_file:s0'));
    }

    // 2) Extraer con el camino oficial (fsck.erofs + lector Dart)
    final w2 = '$w/x';
    Directory(w2).createSync();
    await extractFs('$w/system.img', 'system', w2, tb, log: logs.add);
    expect(sha('$w2/system/system/bin/sh'), sha('$w/system/system/bin/sh'));
    expect(File('$w2/system/$longDir/${'f' * 80}.txt').readAsStringSync(), 'largo');
    expect(File('$w2/system/system/empty').lengthSync(), 0);
    expect(Link('$w2/system/system/bin/ls').targetSync(), 'sh');
    final cfg2 = File('$w2/config/system_fs_config').readAsStringSync();
    expect(cfg2, contains('system/system/bin/sh 0 2000 0755 capabilities=0x3000000000'));
    expect(cfg2, contains('system/system/build.prop 0 0 0600'));
    expect(File('$w2/config/system_file_contexts').readAsStringSync(), contains('/system/system/bin/sh u:object_r:shell_exec:s0'));

    // 3) Ciclo completo: reconstruir lo extraído
    await buildFs('system', w2, 'erofs', '$w2/again.img', tb, log: logs.add);
    final m = ErofsImage('$w2/again.img');
    final entries = m.walkMeta();
    m.close();
    expect(entries.firstWhere((e) => e.rel == 'system/bin/sh').capabilities, 0x3000000000);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('lector EROFS sobre imagen de mkfs.erofs Android (sekaiacg)', () async {
    final mk = '$repoTools/erofs-utils/mkfs.erofs';
    if (!File(mk).existsSync()) return;
    final tmp = Directory.systemTemp.createTempSync('fwkrd');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final w = tmp.path;
    Directory('$w/v/etc/init').createSync(recursive: true);
    for (var i = 0; i < 400; i++) {
      File('$w/v/etc/init/file_$i.rc').writeAsStringSync('service x$i /vendor/bin/x\n');
    }
    File('$w/fsc').writeAsStringSync('/ 0 2000 0755\nvendor/ 0 2000 0755\nvendor/etc 0 2000 0755\nvendor/etc/init 0 0 0755\n'
        '${[for (var i = 0; i < 400; i++) 'vendor/etc/init/file_$i.rc 0 0 0644'].join('\n')}\n');
    File('$w/ctx').writeAsStringSync('/vendor(/.*)? u:object_r:vendor_file:s0\n/vendor/etc/init(/.*)? u:object_r:vendor_configs_file:s0\n');
    final r = await Process.run(mk, ['-zlz4hc', '--mount-point=/vendor', '--fs-config-file=$w/fsc', '--file-contexts=$w/ctx', '$w/vendor.img', '$w/v']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final m = ErofsImage('$w/vendor.img');
    final e = m.walkMeta();
    m.close();
    expect(e.where((x) => x.rel.startsWith('etc/init/file_')).length, 400); // directorio de varios bloques
    expect(e.firstWhere((x) => x.rel == 'etc').gid, 2000);
    expect(e.firstWhere((x) => x.rel == 'etc/init/file_7.rc').context, 'u:object_r:vendor_configs_file:s0');
  });
}
