import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../engine/bytes.dart';
import '../kitchen/project.dart';
import '../kitchen/runner.dart';
import '../kitchen/settings.dart';
import '../kitchen/tweaks.dart';
import 'file_browser.dart';
import 'log_panel.dart';
import 'tweaks_tab.dart';
import '../l10n/l10n.dart';

class ProjectPage extends StatefulWidget {
  final Project project;
  final TaskRunner runner;
  final AppSettings settings;
  const ProjectPage({super.key, required this.project, required this.runner, required this.settings});
  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  int tab = 0;
  Project get p => widget.project;
  TaskRunner get r => widget.runner;
  Map<String, Object?> get base => {'root': p.root};

  @override
  void initState() {
    super.initState();
    r.setLogFile('${p.root}/kitchen.log');
    r.addListener(_onRunner);
  }

  @override
  void dispose() {
    r.removeListener(_onRunner);
    r.setLogFile(null);
    super.dispose();
  }

  bool _wasBusy = false;
  void _onRunner() {
    // Al terminar una tarea, refrescar listas
    if (_wasBusy && !r.busy && mounted) setState(() {});
    _wasBusy = r.busy;
  }

  Future<void> run(String title, TaskFn fn, [Map<String, Object?> extra = const {}]) async {
    await r.run(title, fn, {...base, ...extra});
    if (mounted) setState(() {});
  }

  static const _tabs = [
    (Icons.album_outlined, 'Imágenes'),
    (Icons.folder_open, 'ROM'),
    (Icons.cleaning_services_outlined, 'Debloat'),
    (Icons.tune, 'Ajustes ROM'),
    (Icons.outbox_outlined, 'Salida'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final pages = [_imagesTab(), _romTab(), _DebloatTab(state: this), TweaksTab(project: p, runner: r), _outputTab()];
    final body = IndexedStack(index: tab.clamp(0, pages.length - 1), children: pages);
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          ListenableBuilder(
            listenable: r,
            builder: (_, _) => r.busy
                ? const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(tooltip: tr('Actualizar'), icon: const Icon(Icons.refresh), onPressed: () => setState(() {})),
          ),
          if (Platform.isLinux)
            IconButton(tooltip: tr('Abrir carpeta del proyecto'), icon: const Icon(Icons.folder), onPressed: () => openFolder(p.root)),
        ],
      ),
      body: wide
          ? Row(children: [
              NavigationRail(
                selectedIndex: tab,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => setState(() => tab = i),
                destinations: [for (final (i, l) in _tabs) NavigationRailDestination(icon: Icon(i), label: Text(tr(l)))],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(children: [
                  Expanded(child: body),
                  const Divider(height: 1),
                  SizedBox(height: 230, child: LogPanel(runner: r)),
                ]),
              ),
            ])
          : (tab == _tabs.length ? LogPanel(runner: r) : body),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: [
                for (final (i, l) in _tabs) NavigationDestination(icon: Icon(i), label: tr(l)),
                ListenableBuilder(
                  listenable: r,
                  builder: (_, _) => NavigationDestination(
                    icon: Badge(isLabelVisible: r.busy, child: const Icon(Icons.terminal)),
                    label: tr('Registro'),
                  ),
                ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------- Imágenes

  Widget _imagesTab() {
    final imgs = p.images();
    final boots = p.unpackedBoots();
    final fsImgs = imgs.where((i) => i.type == 'ext4' || i.type == 'erofs').map((i) => i.name).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            icon: const Icon(Icons.file_open),
            label: Text(tr('Importar firmware')),
            onPressed: () async {
              final files = await browseFiles(context, title: tr('Firmware: .zip, AP .tar.md5, .img o .lz4'));
              if (files != null && files.isNotEmpty) await run(tr('Importar'), taskImport, {'files': files});
            },
          ),
          if (fsImgs.isNotEmpty)
            OutlinedButton.icon(
              icon: const Icon(Icons.unarchive_outlined),
              label: Text(tr('Extraer todas ({0})', [fsImgs.length])),
              onPressed: () => run(tr('Extraer particiones'), taskExtract, {'names': fsImgs}),
            ),
          if (Platform.isAndroid && widget.settings.rootAvailable)
            OutlinedButton.icon(
              icon: const Icon(Icons.phone_android),
              label: Text(tr('Copiar del dispositivo (root)')),
              onPressed: _dumpDevice,
            ),
        ]),
        const SizedBox(height: 16),
        if (imgs.isEmpty)
          _Empty(tr('Todavía no hay imágenes.\nImporta un firmware de Samsung (.zip o AP_*.tar.md5) o imágenes sueltas.')),
        for (final i in imgs) _imageTile(i),
        if (boots.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(tr('Boot desempaquetados'), style: Theme.of(context).textTheme.titleMedium),
          for (final b in boots)
            Card(
              child: ListTile(
                leading: const Icon(Icons.memory),
                title: Text(b),
                subtitle: Text(tr('boot/{0} · edita kernel / ramdisk / dtb y reempaqueta', [b])),
                trailing: Wrap(spacing: 4, children: [
                  if (Platform.isLinux)
                    IconButton(tooltip: tr('Abrir carpeta'), icon: const Icon(Icons.folder_open), onPressed: () => openFolder('${p.bootDir}/$b')),
                  FilledButton.tonal(onPressed: () => run(tr('Reempaquetar {0}', [b]), taskBootRepack, {'name': b}), child: Text(tr('Reempaquetar'))),
                ]),
              ),
            ),
        ],
      ],
    );
  }

  Widget _imageTile(KImage i) {
    final actions = <(String, IconData, VoidCallback)>[
      if (i.type == 'ext4' || i.type == 'erofs')
        (tr('Extraer archivos'), Icons.unarchive_outlined, () => run(tr('Extraer {0}', [i.name]), taskExtract, {'names': [i.name]})),
      if (i.type == 'super')
        (tr('Desempaquetar super'), Icons.call_split, () => run(tr('Desempaquetar super'), taskUnpackSuper, {'path': i.path})),
      if (i.type == 'boot')
        (tr('Desempaquetar boot'), Icons.memory, () => run(tr('Desempaquetar {0}', [i.name]), taskBootUnpack, {'name': i.name})),
      if (i.type == 'vbmeta')
        (tr('Desactivar verity → salida'), Icons.verified_user_outlined, () => run(tr('Parchear {0}', [i.name]), taskVbmeta, {'name': i.name})),
      (tr('Copiar a salida'), Icons.outbox_outlined, () => run(tr('Copiar {0}', [i.name]), taskExport, {'files': [i.path], 'dest': p.outputDir})),
      (tr('Borrar'), Icons.delete_outline, () => _confirmDelete([i.path], '${i.name}.img')),
    ];
    return Card(
      child: ListTile(
        leading: _TypeChip(i.type),
        title: Text(i.name),
        subtitle: Text(humanSize(i.size)),
        onTap: actions.length > 2 ? actions.first.$3 : null,
        trailing: PopupMenuButton<int>(
          tooltip: tr('Acciones'),
          itemBuilder: (_) => [
            for (final (k, a) in actions.indexed)
              PopupMenuItem(value: k, child: ListTile(dense: true, leading: Icon(a.$2), title: Text(a.$1))),
          ],
          onSelected: (k) => actions[k].$3(),
        ),
      ),
    );
  }

  Future<void> _dumpDevice() async {
    final parts = await listDevicePartitions();
    if (!mounted) return;
    if (parts.isEmpty) {
      _snack(tr('No se pudieron listar las particiones (root denegado o ruta desconocida).'));
      return;
    }
    final common = {'boot', 'init_boot', 'vendor_boot', 'vbmeta', 'vbmeta_system', 'dtbo', 'recovery'};
    final sel = <String>{...parts.where(common.contains)};
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setS) => AlertDialog(
          title: Text(tr('Copiar particiones del dispositivo')),
          content: SizedBox(
            width: 420,
            height: 420,
            child: ListView(children: [
              Text(tr('Se copian con dd a images/. "super" y "userdata" pueden ocupar muchos GB.')),
              for (final n in parts)
                CheckboxListTile(
                  dense: true,
                  value: sel.contains(n),
                  title: Text(n),
                  onChanged: (v) => setS(() => v! ? sel.add(n) : sel.remove(n)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Copiar'))),
          ],
        ),
      ),
    );
    if (ok == true && sel.isNotEmpty) await run(tr('Copiar del dispositivo'), taskDumpDevice, {'names': sel.toList()});
  }

  // ---------------------------------------------------------------- ROM

  Widget _romTab() {
    final parts = p.extractedPartitions();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (parts.isNotEmpty)
            FilledButton.icon(
              icon: const Icon(Icons.construction),
              label: Text(tr('Construir todas ({0})', [parts.length])),
              onPressed: () => run(tr('Construir particiones'), taskBuild, {'names': parts}),
            ),
          _ToolStatus(settings: widget.settings),
        ]),
        const SizedBox(height: 16),
        if (parts.isEmpty) _Empty(tr('No hay particiones extraídas.\nEn "Imágenes", usa "Extraer archivos" sobre system, vendor, product…')),
        for (final n in parts)
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder),
              title: Text(n),
              subtitle: Text('extracted/$n · ${p.fsTypeOf(n) ?? '?'}'),
              trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (Platform.isLinux)
                  IconButton(tooltip: tr('Abrir carpeta'), icon: const Icon(Icons.folder_open), onPressed: () => openFolder('${p.extractedDir}/$n')),
                PopupMenuButton<String>(
                  tooltip: tr('Construir'),
                  icon: const Icon(Icons.construction),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: p.fsTypeOf(n) ?? 'erofs', child: Text(tr('Construir ({0}, original)', [p.fsTypeOf(n) ?? 'erofs']))),
                    PopupMenuItem(value: 'erofs', child: Text(tr('Construir como EROFS'))),
                    PopupMenuItem(value: 'ext4', child: Text(tr('Construir como ext4'))),
                    PopupMenuItem(value: '_delete', child: Text(tr('Borrar carpeta extraída'))),
                  ],
                  onSelected: (v) => v == '_delete'
                      ? _confirmDelete(['${p.extractedDir}/$n'], 'extracted/$n')
                      : run(tr('Construir {0} ({1})', [n, v]), taskBuild, {'names': [n], 'fsType': v}),
                ),
              ]),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- Salida

  Widget _outputTab() {
    final outs = p.outputs();
    final hasSuper = p.loadMeta()['super'] != null;
    final usage = superUsage(p);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (hasSuper)
            FilledButton.icon(icon: const Icon(Icons.merge_type), label: Text(tr('Construir super.img')), onPressed: _buildSuperDialog),
          if (outs.isNotEmpty)
            FilledButton.tonalIcon(icon: const Icon(Icons.inventory_2_outlined), label: Text(tr('Crear AP para Odin')), onPressed: () => _odinDialog(outs)),
          if (outs.isNotEmpty)
            OutlinedButton.icon(
              icon: const Icon(Icons.drive_file_move_outline),
              label: Text(tr('Exportar…')),
              onPressed: () async {
                final dest = await browseFiles(context, pickFolder: true, title: tr('Carpeta de destino'));
                if (dest != null) await run(tr('Exportar'), taskExport, {'files': [for (final o in outs) o.path], 'dest': dest.first});
              },
            ),
        ]),
        const SizedBox(height: 16),
        if (usage != null) SuperUsageCard(usage: usage),
        if (outs.isEmpty) _Empty(tr('Aquí aparecen las imágenes construidas, super.img y el AP para Odin.')),
        for (final o in outs)
          Card(
            child: ListTile(
              leading: _TypeChip(o.type),
              title: Text(o.name),
              subtitle: Text(humanSize(o.size)),
              trailing: PopupMenuButton<String>(
                itemBuilder: (_) => [
                  if (o.name.endsWith('.img') && o.type != 'sparse') PopupMenuItem(value: 'sparse', child: Text(tr('Convertir a sparse'))),
                  if (o.type == 'sparse') PopupMenuItem(value: 'raw', child: Text(tr('Convertir a raw'))),
                  PopupMenuItem(value: 'export', child: Text(tr('Exportar…'))),
                  PopupMenuItem(value: 'delete', child: Text(tr('Borrar'))),
                ],
                onSelected: (v) async {
                  switch (v) {
                    case 'sparse':
                    case 'raw':
                      await run(tr('Convertir {0}', [o.name]), taskSparse, {'file': o.name, 'toSparse': v == 'sparse'});
                    case 'export':
                      final dest = await browseFiles(context, pickFolder: true, title: tr('Carpeta de destino'));
                      if (dest != null) await run(tr('Exportar {0}', [o.name]), taskExport, {'files': [o.path], 'dest': dest.first});
                    case 'delete':
                      await _confirmDelete([o.path], o.name);
                  }
                },
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _buildSuperDialog() async {
    var sparse = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setS) => AlertDialog(
          title: Text(tr('Construir super.img')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Usa las particiones de "Salida" si existen; si no, las originales de "Imágenes". Se respetan el tamaño, los grupos y la versión de metadatos del super original.')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: sparse,
              onChanged: (v) => setS(() => sparse = v),
              title: Text(tr('Formato sparse (recomendado para Odin/fastboot)')),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Construir'))),
          ],
        ),
      ),
    );
    if (ok == true) await run(tr('Construir super'), taskBuildSuper, {'sparse': sparse});
  }

  Future<void> _odinDialog(List<KImage> outs) async {
    final candidates = outs.where((o) => o.name.endsWith('.img')).toList();
    final sel = <String>{...candidates.map((o) => o.name)};
    var compress = true;
    final nameCtl = TextEditingController(text: 'AP_${p.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.tar.md5');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setS) => AlertDialog(
          title: Text(tr('Crear AP para Odin')),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtl, decoration: InputDecoration(labelText: tr('Nombre del archivo'))),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: compress,
                onChanged: (v) => setS(() => compress = v),
                title: Text(tr('Comprimir imágenes con LZ4')),
              ),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final o in candidates)
                    CheckboxListTile(
                      dense: true,
                      value: sel.contains(o.name),
                      title: Text(o.name),
                      subtitle: Text(humanSize(o.size)),
                      onChanged: (v) => setS(() => v! ? sel.add(o.name) : sel.remove(o.name)),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
            FilledButton(onPressed: sel.isEmpty ? null : () => Navigator.pop(context, true), child: Text(tr('Crear'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      var name = nameCtl.text.trim();
      if (!name.endsWith('.tar.md5')) name = '$name.tar.md5';
      await run(tr('Crear AP para Odin'), taskOdin, {'files': sel.toList(), 'compress': compress, 'name': name});
    }
  }

  Future<void> _confirmDelete(List<String> paths, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('¿Borrar?')),
        content: Text(label),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Borrar'))),
        ],
      ),
    );
    if (ok == true) await run(tr('Borrar {0}', [label]), taskDelete, {'paths': paths});
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
}

// ---------------------------------------------------------------- Debloat

class _DebloatTab extends StatefulWidget {
  final _ProjectPageState state;
  const _DebloatTab({required this.state});
  @override
  State<_DebloatTab> createState() => _DebloatTabState();
}

class _DebloatTabState extends State<_DebloatTab> {
  final selected = <String>{};
  String filter = '';
  List<String> apps = [];

  Project get p => widget.state.p;

  /// Busca carpetas de apps (app, priv-app) en todas las particiones extraídas.
  List<String> scan() {
    final out = <String>[];
    for (final part in p.extractedPartitions()) {
      for (final sub in ['app', 'priv-app', 'system/app', 'system/priv-app', 'preload', 'system/preload']) {
        final d = Directory('${p.extractedDir}/$part/$sub');
        if (!d.existsSync()) continue;
        for (final e in d.listSync().whereType<Directory>()) {
          out.add(e.path.substring(p.extractedDir.length + 1));
        }
      }
    }
    return out..sort((a, b) => a.split('/').last.toLowerCase().compareTo(b.split('/').last.toLowerCase()));
  }

  @override
  Widget build(BuildContext context) {
    apps = scan();
    selected.removeWhere((s) => !apps.contains(s));
    final shown = apps.where((a) => filter.isEmpty || a.toLowerCase().contains(filter.toLowerCase())).toList();
    if (apps.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        _Empty(tr('Extrae primero system / product / vendor para ver sus apps aquí.')),
      ]);
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 260,
            child: TextField(
              decoration: InputDecoration(prefixIcon: Icon(Icons.search), hintText: tr('Filtrar apps'), isDense: true),
              onChanged: (v) => setState(() => filter = v),
            ),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.auto_fix_high),
            label: Text(tr('Marcar sugeridas')),
            onPressed: () => setState(() {
              final res = widget.state.widget.settings.debloatPatterns.map((x) => RegExp(x, caseSensitive: false));
              for (final a in apps) {
                if (res.any((re) => re.hasMatch(a.split('/').last))) selected.add(a);
              }
            }),
          ),
          TextButton(onPressed: () => setState(selected.clear), child: Text(tr('Desmarcar'))),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            icon: const Icon(Icons.delete_forever),
            label: Text(tr('Eliminar ({0})', [selected.length])),
            onPressed: selected.isEmpty ? null : _apply,
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(tr('{0} apps encontradas · las sugeridas salen de los patrones de Ajustes. Revisa la lista: quitar apps del sistema puede impedir que arranque.', [apps.length]),
            style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: shown.length,
          itemBuilder: (_, i) {
            final a = shown[i];
            final parts = a.split('/');
            return CheckboxListTile(
              dense: true,
              value: selected.contains(a),
              title: Text(parts.last),
              subtitle: Text(parts.sublist(0, parts.length - 1).join('/')),
              onChanged: (v) => setState(() => v! ? selected.add(a) : selected.remove(a)),
            );
          },
        ),
      ),
    ]);
  }

  Future<void> _apply() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('Eliminar {0} apps', [selected.length])),
        content: SizedBox(width: 420, height: 300, child: ListView(children: [for (final s in selected) Text('· $s')])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Eliminar'))),
        ],
      ),
    );
    if (ok == true) {
      await widget.state.run('Debloat', taskDebloat, {'paths': selected.toList()});
      if (mounted) setState(selected.clear);
    }
  }
}

// ---------------------------------------------------------------- Widgets pequeños

class _TypeChip extends StatelessWidget {
  final String type;
  const _TypeChip(this.type);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = switch (type) {
      'ext4' || 'erofs' || 'f2fs' => cs.primaryContainer,
      'super' => cs.tertiaryContainer,
      'boot' || 'vendor_boot' => cs.secondaryContainer,
      _ => cs.surfaceContainerHighest,
    };
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8)),
      alignment: Alignment.center,
      child: Text(type, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      );
}

class _ToolStatus extends StatelessWidget {
  final AppSettings settings;
  const _ToolStatus({required this.settings});
  @override
  Widget build(BuildContext context) {
    final missing = ToolCaps(settings.toolBox()).missing;
    return Chip(
      avatar: Icon(missing.isEmpty ? Icons.check_circle : Icons.info_outline, size: 18, color: missing.isEmpty ? Colors.green : Colors.orange),
      label: Text(missing.isEmpty ? tr('Herramientas OK') : tr('Sin herramienta para: {0}', [missing.join(', ')])),
    );
  }
}
