import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../kitchen/project.dart';
import '../kitchen/runner.dart';
import '../kitchen/settings.dart';
import 'project_page.dart';
import 'settings_page.dart';
import '../l10n/l10n.dart';

class HomePage extends StatefulWidget {
  final AppSettings settings;
  final TaskRunner runner;
  const HomePage({super.key, required this.settings, required this.runner});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool filesOk = true;

  @override
  void initState() {
    super.initState();
    _checkPerm();
  }

  Future<void> _checkPerm() async {
    final ok = await hasAllFilesAccess();
    if (mounted) setState(() => filesOk = ok);
  }

  List<Directory> _projects() {
    final d = Directory(widget.settings.workspace);
    if (!d.existsSync()) return [];
    return d.listSync().whereType<Directory>().where((e) => File('${e.path}/project.json').existsSync()).toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  }

  Future<void> _newProject() async {
    final ctl = TextEditingController(text: 'rom_${DateTime.now().toIso8601String().substring(0, 10)}');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('Nuevo proyecto')),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(labelText: tr('Nombre'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text.trim()), child: Text(tr('Crear'))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    _open(Project.create(widget.settings.workspace, safe));
  }

  void _open(Project p) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProjectPage(project: p, runner: widget.runner, settings: widget.settings)),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final projects = _projects();
    return Scaffold(
      appBar: AppBar(
        title: const Text('FW Kitchen'),
        actions: [
          IconButton(
            tooltip: tr('Ajustes'),
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(settings: widget.settings)));
              widget.runner.tools = widget.settings.toolBox();
              _checkPerm();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newProject,
        icon: const Icon(Icons.add),
        label: Text(tr('Nuevo proyecto')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (!filesOk)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.folder_off),
                title: Text(tr('Falta el permiso de almacenamiento')),
                subtitle: Text(tr('Para leer firmwares de la memoria interna, concede "Acceso a todos los archivos".')),
                trailing: FilledButton(
                  onPressed: () async {
                    await requestAllFilesAccess();
                    await Future<void>.delayed(const Duration(seconds: 1));
                    _checkPerm();
                  },
                  child: Text(tr('Conceder')),
                ),
              ),
            ),
          Card(
            child: ListTile(
              leading: Icon(widget.settings.rootAvailable ? Icons.admin_panel_settings : Icons.person_outline),
              title: Text(widget.settings.rootAvailable ? tr('Root disponible') : tr('Modo sin root')),
              subtitle: Text(tr('Espacio de trabajo: {0}', [widget.settings.workspace])),
            ),
          ),
          const SizedBox(height: 8),
          Text(tr('Proyectos'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (projects.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Text(tr('Crea un proyecto para empezar a cocinar una ROM.'), textAlign: TextAlign.center),
            ),
          for (final d in projects)
            Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(d.path.split('/').last),
                subtitle: Text(_summary(Project(d.path))),
                onTap: () => _open(Project(d.path)),
                trailing: IconButton(
                  tooltip: tr('Borrar proyecto'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteProject(d),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _summary(Project p) {
    final imgs = p.images().length, ext = p.extractedPartitions().length, out = p.outputs().length;
    return tr('{0} imágenes · {1} extraídas · {2} en salida', [imgs, ext, out]);
  }

  Future<void> _deleteProject(Directory d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('¿Borrar proyecto?')),
        content: Text(tr('Se eliminará {0} con todos sus archivos.', [d.path])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Borrar'))),
        ],
      ),
    );
    if (ok == true) {
      await widget.runner.run(tr('Borrar proyecto'), taskDelete, {'root': d.path, 'paths': [d.path]});
      if (mounted) setState(() {});
    }
  }
}
