import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fw_kitchen/engine/lp.dart';
import 'package:fw_kitchen/engine/lz4.dart';
import 'package:fw_kitchen/engine/sparse.dart';

// Pruebas cruzadas contra herramientas reales cuando están disponibles.
final tools = '${Directory.current.parent.path}/tools/android-tools';
bool hasTool(String t) => File('$tools/$t').existsSync();

String sha(String p) => sha256.convert(File(p).readAsBytesSync()).toString();

Uint8List sampleData(int size, int seed) {
  final r = Random(seed);
  final b = Uint8List(size);
  // Mezcla de texto repetitivo, ceros y ruido (parecido a una imagen real)
  final words = utf8.encode('android system vendor product lib64 framework ');
  for (var i = 0; i < size; i++) {
    final zone = (i ~/ 65536) % 4;
    b[i] = switch (zone) { 0 => words[(i * 7 + r.nextInt(3)) % words.length], 1 => 0, 2 => r.nextInt(256), _ => i & 0xff };
  }
  return b;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fwk'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('lz4: ida y vuelta + compatibilidad con python-lz4', () async {
    final src = '${tmp.path}/a.bin';
    File(src).writeAsBytesSync(sampleData(9 << 20, 1));
    lz4CompressFile(src, '${tmp.path}/a.lz4');
    lz4DecompressFile('${tmp.path}/a.lz4', '${tmp.path}/a.out');
    expect(sha('${tmp.path}/a.out'), sha(src));
    expect(File('${tmp.path}/a.lz4').lengthSync(), lessThan(File(src).lengthSync()));

    // Nuestro .lz4 lo lee la librería de referencia
    final py = await Process.run('python3', ['-c', '''
import lz4.frame,sys,hashlib
d=lz4.frame.decompress(open(sys.argv[1],'rb').read());print(hashlib.sha256(d).hexdigest())
''', '${tmp.path}/a.lz4']);
    if (py.exitCode == 0) expect((py.stdout as String).trim(), sha(src));

    // Y leemos .lz4 de referencia con bloques enlazados (como lz4 CLI por defecto)
    final py2 = await Process.run('python3', ['-c', '''
import lz4.frame,sys
d=open(sys.argv[1],'rb').read()
open(sys.argv[2],'wb').write(lz4.frame.compress(d,block_size=lz4.frame.BLOCKSIZE_MAX64KB,block_linked=True,content_checksum=True,store_size=True,compression_level=9))
''', src, '${tmp.path}/b.lz4']);
    if (py2.exitCode == 0) {
      lz4DecompressFile('${tmp.path}/b.lz4', '${tmp.path}/b.out');
      expect(sha('${tmp.path}/b.out'), sha(src));
    }
  });

  test('sparse: ida y vuelta + simg2img/img2simg', () async {
    final raw = '${tmp.path}/r.img';
    File(raw).writeAsBytesSync(sampleData(4096 * 3000, 2));
    rawToSparse(raw, '${tmp.path}/s.img');
    expect(isSparse('${tmp.path}/s.img'), isTrue);
    sparseToRaw('${tmp.path}/s.img', '${tmp.path}/r2.img');
    expect(sha('${tmp.path}/r2.img'), sha(raw));
    if (hasTool('simg2img')) {
      final r = await Process.run('$tools/simg2img', ['${tmp.path}/s.img', '${tmp.path}/r3.img']);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(sha('${tmp.path}/r3.img'), sha(raw));
      await Process.run('$tools/img2simg', [raw, '${tmp.path}/s2.img']);
      sparseToRaw('${tmp.path}/s2.img', '${tmp.path}/r4.img');
      expect(sha('${tmp.path}/r4.img'), sha(raw));
    }
  });

  test('super: lpmake real -> lpRead/lpUnpack, y lpBuild -> lpdump/lpunpack', () async {
    if (!hasTool('lpmake')) return;
    final a = '${tmp.path}/system.img', b = '${tmp.path}/vendor.img';
    File(a).writeAsBytesSync(sampleData(4096 * 700, 3));
    File(b).writeAsBytesSync(sampleData(4096 * 300, 4));
    final r = await Process.run('$tools/lpmake', [
      '--metadata-size', '65536', '--super-name', 'super', '--metadata-slots', '2',
      '--device', 'super:${64 << 20}', '--group', 'main:${40 << 20}',
      '--partition', 'system:readonly:${File(a).lengthSync()}:main', '--image', 'system=$a',
      '--partition', 'vendor:readonly:${File(b).lengthSync()}:main', '--image', 'vendor=$b',
      '--partition', 'odm:readonly:0:main',
      '--output', '${tmp.path}/super.img',
    ]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final sup = '${tmp.path}/super.img';
    expect(isSuperImage(sup), isTrue);
    final md = lpRead(sup);
    expect(md.partitions.map((p) => p.name), ['system', 'vendor', 'odm']);
    expect(md.groups.map((g) => g.name), contains('main'));
    expect(md.metadataMaxSize, 65536);
    expect(md.slotCount, 2);
    expect(md.logicalBlockSize, 4096);
    lpUnpack(sup, '${tmp.path}/out');
    expect(sha('${tmp.path}/out/system.img'), sha(a));
    expect(sha('${tmp.path}/out/vendor.img'), sha(b));

    // Nuestro build lo valida la herramienta oficial
    lpBuild(
      outPath: '${tmp.path}/super2.img',
      deviceSize: 64 << 20,
      metadataMaxSize: 65536,
      slotCount: 2,
      groups: [LpGroup('main', 0, 40 << 20)],
      partitions: [
        LpBuildPartition('system', a, 'main'),
        LpBuildPartition('vendor', b, 'main'),
        LpBuildPartition('odm', null, 'main'),
      ],
    );
    final d = await Process.run('$tools/lpdump', ['${tmp.path}/super2.img']);
    expect(d.exitCode, 0, reason: '${d.stdout}${d.stderr}');
    expect(d.stdout as String, contains('system'));
    final u = await Process.run('$tools/lpunpack', ['${tmp.path}/super2.img', '${tmp.path}/out2']);
    expect(u.exitCode, 0, reason: '${u.stdout}${u.stderr}');
    expect(sha('${tmp.path}/out2/system.img'), sha(a));
    expect(sha('${tmp.path}/out2/vendor.img'), sha(b));
  });
}
