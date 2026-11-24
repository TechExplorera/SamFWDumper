import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../kitchen/settings.dart';
import 'file_browser.dart';

class SettingsPage extends StatefulWidget {
  final AppSettings settings;
  const SettingsPage({super.key, required this.settings});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get s => widget.settings;
  late final patternsCtl = TextEditingController(text: s.debloatPatterns.join('\n'));

  @override
  Widget build(BuildContext context) {
    final status = s.toolBox().status(kitchenTools);
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Espacio de trabajo', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.workspace),
            subtitle: Text(Platform.isAndroid
                ? 'En Android conviene dejarlo en el almacenamiento interno de la app: la memoria compartida (/sdcard) no admite enlaces simbólicos ni permisos, y la ROM reconstruida saldría mal.'
                : 'Carpeta donde se guardan los proyectos.'),
            trailing: OutlinedButton(
              onPressed: () async {
                final d = await browseFiles(context, pickFolder: true, start: s.workspace, title: 'Espacio de trabajo');
                if (d != null) {
                  setState(() => s.workspace = d.first);
                  s.save();
                }
              },
              child: const Text('Cambiar'),
            ),
          ),
          const Divider(),
          Text('Herramientas externas', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Las herramientas solo hacen falta para extraer EROFS y para construir imágenes EROFS/ext4. '
              'Importar, super.img, sparse, LZ4, boot, vbmeta, extracción de ext4 y Odin funcionan sin ellas.'),
          for (final e in status.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(e.value ? Icons.check_circle : Icons.cancel, color: e.value ? Colors.green : Colors.red),
              title: Text(e.key),
              subtitle: Text(s.toolBox().find(e.key) ?? 'no encontrada'),
            ),
          for (final d in s.toolDirs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder),
              title: Text(d),
              trailing: IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () {
                  setState(() => s.toolDirs.remove(d));
                  s.save();
                },
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Añadir carpeta de herramientas'),
              onPressed: () async {
                final d = await browseFiles(context, pickFolder: true, title: 'Carpeta con mkfs.erofs, extract.erofs…');
                if (d != null && !s.toolDirs.contains(d.first)) {
                  setState(() => s.toolDirs.add(d.first));
                  s.save();
                }
              },
            ),
          ),
          const Divider(),
          Text('Patrones de debloat', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Una expresión regular por línea (sin distinguir mayúsculas). '
              '"Marcar sugeridas" marca las carpetas de apps cuyo nombre coincida.'),
          const SizedBox(height: 8),
          TextField(
            controller: patternsCtl,
            maxLines: 10,
            minLines: 5,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton(
              onPressed: () {
                final pats = patternsCtl.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
                for (final x in pats) {
                  try {
                    RegExp(x);
                  } catch (_) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Patrón inválido: $x')));
                    return;
                  }
                }
                s.debloatPatterns = pats;
                s.save();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Patrones guardados')));
              },
              child: const Text('Guardar patrones'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() => patternsCtl.text = defaultDebloatPatterns.join('\n')),
              child: const Text('Restaurar'),
            ),
          ]),
        ],
      ),
    );
  }
}
