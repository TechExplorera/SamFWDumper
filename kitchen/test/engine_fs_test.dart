import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fw_kitchen/engine/bootimg.dart';
import 'package:fw_kitchen/engine/detect.dart';
import 'package:fw_kitchen/engine/fsops.dart';
import 'package:fw_kitchen/engine/tar.dart';
import 'package:fw_kitchen/engine/tools.dart';
import 'package:fw_kitchen/engine/vbmeta.dart';

final repoTools = Directory.current.parent.path;
final tb = ToolBox(searchDirs: ['$repoTools/tools/android-tools', '$repoTools/tools/erofs-utils']);
String sha(String p) => sha256.convert(File(p).readAsBytesSync()).toString();

void makeTree(String root) {
  Directory('$root/system/bin').createSync(recursive: true);
  Directory('$root/system/app/Bloat').createSync(recursive: true);
  File('$root/system/build.prop').writeAsStringSync('ro.build.version.release=14\n' * 50);
  File('$root/system/bin/sh').writeAsBytesSync(List.generate(300000, (i) => (i * 31) & 0xff));
  File('$root/system/app/Bloat/Bloat.apk').writeAsBytesSync(Uint8List(5000));
  File('$root/system/bin/[weird+name].txt').writeAsStringSync('x');
  Link('$root/system/bin/ls').createSync('sh');
}

String fsConfig() => '''
/ 0 0 0755
system/ 0 0 0755
system/system 0 0 0755
system/system/bin 0 2000 0751
system/system/bin/sh 0 2000 0755 capabilities=0x1000
system/system/bin/ls 0 2000 0755
system/system/bin/[weird+name].txt 1000 1000 0640
system/system/build.prop 0 0 0600
system/system/app 0 0 0755
system/system/app/Bloat 0 0 0755
system/system/app/Bloat/Bloat.apk 0 0 0644
''';

String fileContexts() => r'''
/system u:object_r:rootfs:s0
/system/lost\+found u:object_r:rootfs:s0
/system/system(/.*)? u:object_r:system_file:s0
/system/system/bin/sh u:object_r:shell_exec:s0
''';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fwkfs'));
  tearDown(() => tmp.deleteSync(recursive: true));

  for (final fsType in ['ext4', 'erofs']) {
    test('$fsType: construir con herramientas y extraer con la app', () async {
      if (!tb.has(fsType == 'ext4' ? 'e2fsdroid' : 'mkfs.erofs')) return;
      final w = tmp.path;
      makeTree('$w/system');
      Directory('$w/config').createSync();
      File('$w/config/system_fs_config').writeAsStringSync(fsConfig());
      File('$w/config/system_file_contexts').writeAsStringSync(fileContexts());
      File('$w/config/system_mount_point').writeAsStringSync('/');
      final logs = <String>[];
      await buildFs('system', w, fsType, '$w/system.img', tb, log: logs.add);
      expect(detectImage('$w/system.img').label, fsType);

      // Extraer en otro directorio
      final w2 = '$w/out';
      Directory(w2).createSync();
      await extractFs('$w/system.img', 'system', w2, tb, log: logs.add);
      expect(sha('$w2/system/system/bin/sh'), sha('$w/system/system/bin/sh'));
      expect(File('$w2/system/system/build.prop').readAsStringSync(), File('$w/system/system/build.prop').readAsStringSync());
      expect(Link('$w2/system/system/bin/ls').targetSync(), 'sh');
      final cfg = File('$w2/config/system_fs_config').readAsStringSync();
      expect(cfg, contains('system/system/bin 0 2000 0751'));
      expect(cfg, contains('system/system/bin/sh 0 2000 0755 capabilities=0x1000'));
      expect(cfg, contains('system/system/bin/[weird+name].txt 1000 1000 0640'));
      final ctx = File('$w2/config/system_file_contexts').readAsStringSync();
      expect(ctx, contains('/system/system/bin/sh u:object_r:shell_exec:s0'));

      // Reconstruir lo extraído (ciclo completo de la kitchen)
      await buildFs('system', w2, fsType, '$w2/system_new.img', tb, log: logs.add);
      expect(detectImage('$w2/system_new.img').label, fsType);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('boot.img v2 y v4: mkbootimg -> unpack -> repack idéntico', () async {
    final mk = '$repoTools/tools/android-tools/mkbootimg';
    if (!File(mk).existsSync()) return;
    final w = tmp.path;
    File('$w/kernel').writeAsBytesSync(List.generate(123457, (i) => i & 0xff));
    File('$w/ramdisk').writeAsBytesSync(List.generate(54321, (i) => (i * 3) & 0xff));
    File('$w/dtb').writeAsBytesSync(List.generate(2048, (i) => 7));
    for (final v in ['2', '4']) {
      final args = [
        mk, '--kernel', '$w/kernel', '--ramdisk', '$w/ramdisk', '--header_version', v,
        '--os_version', '14.0.0', '--os_patch_level', '2026-10', '--cmdline', 'console=ttyMSM0 androidboot.x=1',
        if (v == '2') ...['--dtb', '$w/dtb', '--pagesize', '4096', '--base', '0x10000000'],
        '--output', '$w/boot$v.img',
      ];
      // mkbootimg del repo importa el módulo gki (no incluido): stub para la prueba
      Directory('$w/py/gki').createSync(recursive: true);
      File('$w/py/gki/__init__.py').writeAsStringSync('');
      File('$w/py/gki/generate_gki_certificate.py').writeAsStringSync('def generate_gki_certificate(*a, **k):\n    pass\n');
      final r = await Process.run('python3', args, environment: {'PYTHONPATH': '$w/py'});
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      bootUnpack('$w/boot$v.img', '$w/b$v');
      expect(sha('$w/b$v/kernel'), sha('$w/kernel'));
      expect(sha('$w/b$v/ramdisk'), sha('$w/ramdisk'));
      bootRepack('$w/b$v', '$w/boot${v}_new.img');
      expect(sha('$w/boot${v}_new.img'), sha('$w/boot$v.img'), reason: 'v$v debe ser idéntico byte a byte');
    }
  });

  test('vbmeta: desactivar verity', () {
    final p = '${tmp.path}/vbmeta.img';
    final b = Uint8List(4096)..setAll(0, 'AVB0'.codeUnits);
    File(p).writeAsBytesSync(b);
    expect(vbmetaFlags(p), 0);
    vbmetaDisable(p);
    expect(vbmetaFlags(p), 3);
  });

  test('tar: crear .tar.md5 de Odin y volver a leerlo', () async {
    final w = tmp.path;
    File('$w/boot.img').writeAsBytesSync(List.generate(10000, (i) => i & 0xff));
    File('$w/vbmeta.img').writeAsBytesSync(Uint8List(4096));
    tarCreate('$w/AP_test.tar.md5', {'$w/boot.img': 'boot.img', '$w/vbmeta.img': 'vbmeta.img'}, odinMd5: true);
    final entries = tarList('$w/AP_test.tar.md5');
    expect(entries.map((e) => e.name), ['boot.img', 'vbmeta.img']);
    tarExtract('$w/AP_test.tar.md5', entries.first, '$w/x.img');
    expect(sha('$w/x.img'), sha('$w/boot.img'));
    // El tar de sistema lo lee y el md5 coincide con el contenido
    final t = await Process.run('tar', ['-tf', '$w/AP_test.tar.md5']);
    expect((t.stdout as String).trim().split('\n'), ['boot.img', 'vbmeta.img']);
    final bytes = File('$w/AP_test.tar.md5').readAsBytesSync();
    final text = String.fromCharCodes(bytes.sublist(bytes.length - 60));
    final md5line = text.substring(text.lastIndexOf(RegExp(r'[0-9a-f]{32}')));
    final tarLen = bytes.length - md5line.length;
    expect(md5line.trim(), '${md5.convert(bytes.sublist(0, tarLen))}  AP_test.tar');
  });
}
