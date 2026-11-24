import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../engine/bytes.dart';
import '../l10n/l10n.dart';

/// Explorador de archivos propio (rutas reales en Linux y Android).
/// Devuelve la lista de rutas elegidas, o la carpeta si [pickFolder] es true.
Future<List<String>?> browseFiles(BuildContext context,
    {String? start, bool pickFolder = false, bool multi = true, String? title}) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => _BrowserDialog(start: start, pickFolder: pickFolder, multi: multi, title: title ?? tr('Elegir archivo')),
  );
}

List<String> quickRoots() {
  final home = Platform.environment['HOME'];
  return [
    if (Platform.isAndroid) ...['/storage/emulated/0', '/storage/emulated/0/Download'],
    if (home != null) ...[home, '$home/Descargas', '$home/Downloads'],
    '/',
  ].where((p) => Directory(p).existsSync()).toList();
}

class _BrowserDialog extends StatefulWidget {
  final String? start;
  final bool pickFolder, multi;
  final String title;
  const _BrowserDialog({this.start, required this.pickFolder, required this.multi, required this.title});
  @override
  State<_BrowserDialog> createState() => _BrowserDialogState();
}

class _BrowserDialogState extends State<_BrowserDialog> {
  late String dir;
  final selected = <String>{};
  String? error;
  List<FileSystemEntity> items = [];

  @override
  void initState() {
    super.initState();
    final s = widget.start;
    dir = (s != null && Directory(s).existsSync()) ? s : (quickRoots().firstOrNull ?? '/');
    _load();
  }

  void _load() {
    try {
      items = Directory(dir).listSync(followLinks: false)
        ..removeWhere((e) => e.path.split('/').last.startsWith('.'))
        ..sort((a, b) {
          final da = a is Directory ? 0 : 1, db = b is Directory ? 0 : 1;
          return da != db ? da - db : a.path.toLowerCase().compareTo(b.path.toLowerCase());
        });
      error = null;
    } catch (e) {
      items = [];
      error = Platform.isAndroid ? tr('Sin acceso. Concede "Acceso a todos los archivos" en Ajustes.') : '$e';
    }
  }

  void _go(String d) => setState(() {
        dir = d;
        selected.clear();
        _load();
      });

  @override
  Widget build(BuildContext context) {
    final parent = Directory(dir).parent.path;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Column(
          children: [
            ListTile(
              title: Text(widget.title),
              subtitle: Text(dir, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                IconButton(
                  tooltip: tr('Subir'),
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: dir == '/' ? null : () => _go(parent),
                ),
                for (final r in quickRoots())
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(label: Text(r == '/' ? '/' : r.split('/').last), onPressed: () => _go(r)),
                  ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: error != null
                  ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(error!, textAlign: TextAlign.center)))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final e = items[i];
                        final name = e.path.split('/').last;
                        final isDir = e is Directory;
                        if (widget.pickFolder && !isDir) return const SizedBox.shrink();
                        final sel = selected.contains(e.path);
                        return ListTile(
                          dense: true,
                          leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file_outlined),
                          title: Text(name),
                          subtitle: isDir ? null : Text(_size(e)),
                          selected: sel,
                          trailing: (!isDir && !widget.pickFolder) ? Icon(sel ? Icons.check_box : Icons.check_box_outline_blank) : null,
                          onTap: () {
                            if (isDir) {
                              _go(e.path);
                            } else {
                              setState(() {
                                if (!widget.multi) selected.clear();
                                sel ? selected.remove(e.path) : selected.add(e.path);
                              });
                            }
                          },
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: Text(widget.pickFolder ? tr('Carpeta actual') : '${selected.length} seleccionado(s)')),
                TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancelar'))),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: widget.pickFolder
                      ? () => Navigator.pop(context, [dir])
                      : selected.isEmpty
                          ? null
                          : () => Navigator.pop(context, selected.toList()),
                  child: Text(widget.pickFolder ? tr('Usar esta carpeta') : tr('Aceptar')),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  String _size(FileSystemEntity e) {
    try {
      return humanSize((e as File).lengthSync());
    } catch (_) {
      return '';
    }
  }
}
