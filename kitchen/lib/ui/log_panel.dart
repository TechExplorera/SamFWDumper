import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../kitchen/runner.dart';

/// Consola de registro con progreso de la tarea actual.
class LogPanel extends StatefulWidget {
  final TaskRunner runner;
  final bool expanded;
  const LogPanel({super.key, required this.runner, this.expanded = false});
  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.runner,
      builder: (context, _) {
        final r = widget.runner;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: cs.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                Icon(r.busy ? Icons.sync : Icons.terminal, size: 18, color: r.busy ? cs.primary : null),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.busy ? '${r.current}${r.progressLabel.isNotEmpty ? ' · ${r.progressLabel}' : ''}' : 'Registro',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Copiar registro',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => Clipboard.setData(ClipboardData(text: r.logs.join('\n'))),
                ),
                IconButton(
                  tooltip: 'Limpiar',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  onPressed: r.busy ? null : r.clearLogs,
                ),
              ]),
            ),
            if (r.busy) LinearProgressIndicator(value: r.progress, minHeight: 3),
            Expanded(
              child: Container(
                color: cs.surfaceContainerLowest,
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  itemCount: r.logs.length,
                  itemBuilder: (_, i) {
                    final l = r.logs[i];
                    final color = l.startsWith('✖')
                        ? cs.error
                        : l.startsWith('✔')
                            ? Colors.green
                            : l.startsWith('▶') || l.startsWith('■')
                                ? cs.primary
                                : null;
                    return SelectableText(l, style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: color));
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
