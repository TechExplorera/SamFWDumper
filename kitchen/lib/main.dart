import 'package:material_ui/material_ui.dart';

import 'kitchen/runner.dart';
import 'kitchen/settings.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final runner = TaskRunner(settings.toolBox());
  runApp(KitchenApp(settings: settings, runner: runner));
}

class KitchenApp extends StatelessWidget {
  final AppSettings settings;
  final TaskRunner runner;
  const KitchenApp({super.key, required this.settings, required this.runner});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E9F8E), brightness: b),
          useMaterial3: true,
          visualDensity: VisualDensity.standard,
        );
    return MaterialApp(
      title: 'FW Kitchen',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: HomePage(settings: settings, runner: runner),
    );
  }
}
