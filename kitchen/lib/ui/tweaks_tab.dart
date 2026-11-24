import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../engine/bytes.dart';
import '../kitchen/project.dart';
import '../kitchen/runner.dart';
import '../kitchen/tweaks.dart';
import '../l10n/l10n.dart';

/// Pestaña "Ajustes ROM": información, build.prop, fstab y espacio del super.
class TweaksTab extends StatefulWidget {
  final Project project;
  final TaskRunner runner;
  const TweaksTab({super.key, required this.project, required this.runner});
  @override
  State<TweaksTab> createState() => _TweaksTabState();
}

class _TweaksTabState extends State<TweaksTab> {
  Project get p => widget.project;
  String? propFile;
  String filter = '';

  void _log(String l) => widget.runner.log(l);

  @override
  Widget build(BuildContext context) {
    final props = findBuildProps(p);
    if (propFile != null && !props.contains(propFile)) propFile = null;
    propFile ??= props.firstOrNull;
    final info = romInfo(p);
    final fstabs = findFstabs(p);
    final usage = superUsage(p);
    final tt = Theme.of(context).textTheme;

    if (props.isEmpty && fstabs.isEmpty && usage == null) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Text(tr('Extrae system / vendor / product para editar build.prop y fstab.'),
              textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ),
      ]);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!info.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ROM', style: tt.titleMedium),
                const SizedBox(height: 8),
                _kv(tr('Modelo'), info.model),
                _kv('Android', info.android),
                _kv(tr('Parche de seguridad'), info.patch),
                _kv('Build', info.build),
                _kv('Fingerprint', info.fingerprint),
              ]),
            ),
          ),
        if (usage != null) SuperUsageCard(usage: usage),
        if (fstabs.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('fstab', style: tt.titleMedium),
                const SizedBox(height: 4),
                Text(tr('{0} archivo(s): {1}', [fstabs.length, fstabs.join(', ')]), style: tt.bodySmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: Text(tr('Quitar cifrado forzado')),
                    onPressed: () => _patchFstab(fstabs, encryption: true, avb: false),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.gpp_maybe_outlined),
                    label: Text(tr('Quitar verificación AVB')),
                    onPressed: () => _patchFstab(fstabs, encryption: false, avb: true),
                  ),
                ]),
              ]),
            ),
          ),
        if (props.isNotEmpty) _propsCard(props, tt),
      ],
    );
  }

  Widget _kv(String k, String v) => v.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 150, child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.outline))),
            Expanded(child: SelectableText(v)),
          ]),
        );

  Future<void> _patchFstab(List<String> files, {required bool encryption, required bool avb}) async {
    final plan = <String, (String, List<String>)>{};
    for (final f in files) {
      final path = '${p.extractedDir}/$f';
      final r = patchFstab(File(path).readAsStringSync(), encryption: encryption, avb: avb);
      if (r.$2.isNotEmpty) plan[path] = r;
    }
    if (!mounted) return;
    if (plan.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('No hay nada que cambiar en los fstab.'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(encryption ? tr('Quitar cifrado forzado') : tr('Quitar verificación AVB')),
        content: SizedBox(
          width: 520,
          height: 320,
          child: ListView(children: [
            if (encryption)
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(tr('Tras flashear habrá que formatear /data (los datos cifrados existentes no se podrán leer).')),
              ),
            for (final e in plan.entries) ...[
              Text(e.key.substring(p.extractedDir.length + 1), style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final c in e.value.$2) Text('  $c', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 8),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Aplicar'))),
        ],
      ),
    );
    if (ok != true) return;
    for (final e in plan.entries) {
      File(e.key).writeAsStringSync(e.value.$1);
      for (final c in e.value.$2) {
        _log('fstab ${e.key.substring(p.extractedDir.length + 1)}: $c');
      }
    }
    _log(tr('✔ fstab modificado ({0} archivo(s)). Reconstruye la partición para aplicarlo.', [plan.length]));
    setState(() {});
  }

  Widget _propsCard(List<String> files, TextTheme tt) {
    final path = '${p.extractedDir}/$propFile';
    final entries = readProps(path).entries.where((e) => filter.isEmpty || e.key.contains(filter) || e.value.contains(filter)).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('build.prop', style: tt.titleMedium),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String>(
              value: propFile,
              items: [for (final f in files) DropdownMenuItem(value: f, child: Text(f))],
              onChanged: (v) => setState(() => propFile = v),
            ),
            SizedBox(
              width: 240,
              child: TextField(
                decoration: InputDecoration(prefixIcon: Icon(Icons.search), hintText: tr('Buscar'), isDense: true),
                onChanged: (v) => setState(() => filter = v),
              ),
            ),
            FilledButton.tonalIcon(icon: const Icon(Icons.add), label: Text(tr('Añadir')), onPressed: () => _editProp(path, null, null)),
          ]),
          const SizedBox(height: 8),
          Text(tr('{0} propiedades', [entries.length]), style: tt.bodySmall),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final e = entries[i];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.key, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  subtitle: Text(e.value.isEmpty ? tr('(vacío)') : e.value, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => _editProp(path, e.key, e.value),
                  trailing: IconButton(
                    tooltip: tr('Eliminar'),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () {
                      setProp(path, e.key, null);
                      _log('build.prop $propFile: − ${e.key}');
                      setState(() {});
                    },
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _editProp(String path, String? key, String? value) async {
    final k = TextEditingController(text: key ?? ''), v = TextEditingController(text: value ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(key == null ? tr('Nueva propiedad') : tr('Editar propiedad')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: k, enabled: key == null, decoration: InputDecoration(labelText: tr('Clave'))),
            TextField(controller: v, decoration: InputDecoration(labelText: tr('Valor'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Guardar'))),
        ],
      ),
    );
    final kk = k.text.trim();
    if (ok == true && kk.isNotEmpty && !kk.contains('=') && !kk.contains(' ')) {
      setProp(path, kk, v.text);
      _log('build.prop $propFile: $kk=${v.text}');
      setState(() {});
    }
  }
}

/// Barra de ocupación de cada grupo del super.
class SuperUsageCard extends StatelessWidget {
  final (int, List<GroupUsage>) usage;
  const SuperUsageCard({super.key, required this.usage});
  @override
  Widget build(BuildContext context) {
    final (dev, groups) = usage;
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Espacio del super ({0})', [humanSize(dev)]), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(tr('Cuenta las imágenes de Salida si existen; si no, las originales.'), style: Theme.of(context).textTheme.bodySmall),
          for (final g in groups) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600))),
              Text('${humanSize(g.used)} / ${g.maxSize == 0 ? 'sin límite' : humanSize(g.maxSize)}',
                  style: TextStyle(color: g.fits ? null : cs.error)),
            ]),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: g.maxSize == 0 ? 0 : (g.used / g.maxSize).clamp(0, 1).toDouble(),
              color: g.fits ? null : cs.error,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 4),
            Text(g.parts.entries.where((e) => e.value > 0).map((e) => '${e.key} ${humanSize(e.value)}').join(' · '),
                style: Theme.of(context).textTheme.bodySmall),
            if (!g.fits) Text(tr('No cabe: reduce el tamaño (debloat, EROFS) antes de construir el super.'), style: TextStyle(color: cs.error)),
          ],
        ]),
      ),
    );
  }
}
