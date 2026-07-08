import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'screens/upload_screen.dart';
import 'screens/topic_screen.dart';
import 'screens/processing_screen.dart';
import 'screens/export_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const DecksmithApp(),
    ),
  );
}

class DecksmithApp extends StatelessWidget {
  const DecksmithApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Decksmith',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A6CF7), brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A6CF7), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  SidebarPage _page = SidebarPage.upload;

  static const _navItems = [
    (SidebarPage.upload,   Icons.upload_file_rounded,   'Upload'),
    (SidebarPage.topic,    Icons.auto_awesome_rounded,  'Topic'),
    (SidebarPage.history,  Icons.history_rounded,       'History'),
    (SidebarPage.settings, Icons.settings_rounded,      'Settings'),
  ];

  Widget _pageWidget(AppState state) {
    if (state.phase == AppPhase.processing) return const ProcessingScreen();
    if (state.phase == AppPhase.exporting)  return const ExportScreen();
    return switch (_page) {
      SidebarPage.upload   => const UploadScreen(),
      SidebarPage.topic    => const TopicScreen(),
      SidebarPage.history  => const HistoryScreen(),
      SidebarPage.settings => const SettingsScreen(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final wide = MediaQuery.of(context).size.width >= 600;
    final body = _pageWidget(state);

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _page.index,
              onDestinationSelected: (i) => setState(() => _page = SidebarPage.values[i]),
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 16),
                child: Column(
                  children: [
                    Icon(Icons.layers_rounded, size: 28, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 4),
                    Text('Decksmith',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              destinations: _navItems.map((item) => NavigationRailDestination(
                icon: Icon(item.$2),
                label: Text(item.$3),
              )).toList(),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.layers_rounded, size: 22),
            SizedBox(width: 8),
            Text('Decksmith'),
          ],
        ),
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page.index,
        onDestinationSelected: (i) => setState(() => _page = SidebarPage.values[i]),
        destinations: _navItems.map((item) => NavigationDestination(
          icon: Icon(item.$2),
          label: item.$3,
        )).toList(),
      ),
    );
  }
}
