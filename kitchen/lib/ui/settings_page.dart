import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../engine/tools.dart';
import '../kitchen/settings.dart';
import 'file_browser.dart';
import '../l10n/l10n.dart';

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
      appBar: AppBar(title: Text(tr('Ajustes'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr('Idioma'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'system', label: Text(tr('Sistema'))),
              const ButtonSegment(value: 'es', label: Text('Español')),
              const ButtonSegment(value: 'en', label: Text('English')),
            ],
            selected: {s.language},
            onSelectionChanged: (v) {
              setState(() {
                s.language = v.first;
                appLang = resolveLang(s.language);
              });
              s.save();
            },
          ),
          const Divider(height: 32),
          Text(tr('Espacio de trabajo'), style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.workspace),
            subtitle: Text(Platform.isAndroid
                ? tr('En Android conviene dejarlo en el almacenamiento interno de la app: la memoria compartida (/sdcard) no admite enlaces simbólicos ni permisos, y la ROM reconstruida saldría mal.')
                : tr('Carpeta donde se guardan los proyectos.')),
            trailing: OutlinedButton(
              onPressed: () async {
                final d = await browseFiles(context, pickFolder: true, start: s.workspace, title: tr('Espacio de trabajo'));
                if (d != null) {
                  setState(() => s.workspace = d.first);
                  s.save();
                }
              },
              child: Text(tr('Cambiar')),
            ),
          ),
          const Divider(),
          Text(tr('Herramientas externas'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(tr('Solo hacen falta para EROFS y para construir ext4. Importar, super.img, sparse, LZ4, boot, vbmeta, extraer ext4 y Odin funcionan sin ellas.{0}', [Platform.isAndroid ? tr('\n\nLa app ya trae erofs-utils (mkfs.erofs, fsck.erofs) para ARM64. Puedes añadir una carpeta con otros binarios de Android (ARM64): Android solo permite ejecutarlos con root, así que se copian a /data/local/tmp y se ejecutan con su.') : ''])),
          const SizedBox(height: 8),
          Builder(builder: (_) {
            final caps = ToolCaps(s.toolBox());
            Widget row(String l, bool ok) => Row(children: [
                  Icon(ok ? Icons.check : Icons.close, size: 16, color: ok ? Colors.green : Colors.red),
                  const SizedBox(width: 6),
                  Text(l),
                ]);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              row(tr('Extraer EROFS'), caps.extractErofs),
              row(tr('Construir EROFS'), caps.buildErofs),
              row(tr('Construir ext4'), caps.buildExt4),
            ]);
          }),
          for (final e in status.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(e.value ? Icons.check_circle : Icons.cancel, color: e.value ? Colors.green : Colors.red),
              title: Text(e.key),
              subtitle: Text(s.toolBox().describe(e.key)),
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
                  ToolBox.clearCache();
                },
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(tr('Añadir carpeta de herramientas')),
              onPressed: () async {
                final d = await browseFiles(context, pickFolder: true, title: tr('Carpeta con mkfs.erofs, extract.erofs…'));
                if (d != null && !s.toolDirs.contains(d.first)) {
                  setState(() => s.toolDirs.add(d.first));
                  s.save();
                  ToolBox.clearCache();
                }
              },
            ),
          ),
          const Divider(),
          Text(tr('Patrones de debloat'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(tr('Una expresión regular por línea (sin distinguir mayúsculas). "Marcar sugeridas" marca las carpetas de apps cuyo nombre coincida.')),
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
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Patrón inválido: {0}', [x]))));
                    return;
                  }
                }
                s.debloatPatterns = pats;
                s.save();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Patrones guardados'))));
              },
              child: Text(tr('Guardar patrones')),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() => patternsCtl.text = defaultDebloatPatterns.join('\n')),
              child: Text(tr('Restaurar')),
            ),
          ]),
        ],
      ),
    );
  }
}
