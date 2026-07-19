import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'screens/upload_screen.dart';
import 'screens/topic_screen.dart';
import 'screens/processing_screen.dart';
import 'screens/review_screen.dart';
import 'screens/export_screen.dart';
import 'screens/enhance_screen.dart';
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

const _seed = Color(0xFF4A6CF7);

class DecksmithApp extends StatelessWidget {
  const DecksmithApp({super.key});

  static ThemeData _theme(Brightness brightness) {
    final cs = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      fontFamily: 'SF Pro Display',   // macOS system font; falls back gracefully
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant.withOpacity(0.5)),
        ),
        color: cs.surfaceContainerLow,
      ),
      dividerTheme: DividerThemeData(color: cs.outlineVariant.withOpacity(0.5), space: 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Decksmith',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  SidebarPage _page = SidebarPage.upload;

  static const _navItems = [
    (SidebarPage.upload,   Icons.upload_file_rounded,      'Upload'),
    (SidebarPage.topic,    Icons.auto_awesome_rounded,     'Topic'),
    (SidebarPage.enhance,  Icons.brightness_auto_rounded,  'Enhance'),
    (SidebarPage.history,  Icons.history_rounded,          'History'),
    (SidebarPage.settings, Icons.settings_rounded,         'Settings'),
  ];

  Widget _pageWidget(AppState state) {
    if (state.phase == AppPhase.processing) return const ProcessingScreen();
    if (state.phase == AppPhase.review)     return const ReviewScreen();
    if (state.phase == AppPhase.exporting)  return const ExportScreen();
    return switch (_page) {
      SidebarPage.upload   => const UploadScreen(),
      SidebarPage.topic    => const TopicScreen(),
      SidebarPage.enhance  => const EnhanceScreen(),
      SidebarPage.history  => const HistoryScreen(),
      SidebarPage.settings => const SettingsScreen(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final body = _pageWidget(state);
    final mode = state.viewMode;
    final narrow = MediaQuery.of(context).size.width < 600;

    if (narrow) {
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _page.index,
          onDestinationSelected: (i) => setState(() => _page = SidebarPage.values[i]),
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          destinations: _navItems.map((item) => NavigationDestination(
            icon: Icon(item.$2), label: item.$3,
          )).toList(),
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            mode: mode,
            selected: _page,
            items: _navItems,
            onSelect: (p) => setState(() => _page = p),
          ),
          VerticalDivider(
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.4),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar — three modes
// ─────────────────────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final ViewMode mode;
  final SidebarPage selected;
  final List<(SidebarPage, IconData, String)> items;
  final ValueChanged<SidebarPage> onSelect;

  const _Sidebar({
    required this.mode,
    required this.selected,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      ViewMode.compact => _CompactSidebar(selected: selected, items: items, onSelect: onSelect),
      ViewMode.hybrid  => _HybridSidebar(selected: selected, items: items, onSelect: onSelect),
      ViewMode.full    => _FullSidebar(selected: selected, items: items, onSelect: onSelect),
    };
  }
}

// ── Compact: icon-only, 56px ──────────────────────────────────────────────────

class _CompactSidebar extends StatelessWidget {
  final SidebarPage selected;
  final List<(SidebarPage, IconData, String)> items;
  final ValueChanged<SidebarPage> onSelect;
  const _CompactSidebar({required this.selected, required this.items, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 56,
      color: cs.surfaceContainerLow.withOpacity(0.5),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Tooltip(
            message: 'Decksmith',
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.layers_rounded, size: 18, color: cs.onPrimaryContainer),
              ),
            ),
          ),
          Divider(indent: 8, endIndent: 8, height: 1, color: cs.outlineVariant.withOpacity(0.5)),
          const SizedBox(height: 8),
          ...items.map((item) {
            final active = item.$1 == selected;
            return Tooltip(
              message: item.$3,
              preferBelow: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onSelect(item.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: active ? cs.primaryContainer : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(item.$2, size: 20,
                      color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ── Hybrid: icon + label below, 72px ─────────────────────────────────────────

class _HybridSidebar extends StatelessWidget {
  final SidebarPage selected;
  final List<(SidebarPage, IconData, String)> items;
  final ValueChanged<SidebarPage> onSelect;
  const _HybridSidebar({required this.selected, required this.items, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      width: 72,
      color: cs.surfaceContainerLow.withOpacity(0.5),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.layers_rounded, size: 20, color: cs.onPrimaryContainer),
              ),
              const SizedBox(height: 4),
              Text('DECKSMITH', style: tt.labelSmall?.copyWith(
                fontWeight: FontWeight.w800, color: cs.primary, fontSize: 7.5, letterSpacing: 0.8)),
            ]),
          ),
          Divider(indent: 8, endIndent: 8, height: 1, color: cs.outlineVariant.withOpacity(0.5)),
          const SizedBox(height: 6),
          ...items.map((item) {
            final active = item.$1 == selected;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onSelect(item.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 60,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: active ? cs.primaryContainer : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(children: [
                    Icon(item.$2, size: 20,
                      color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                    const SizedBox(height: 3),
                    Text(item.$3, style: tt.labelSmall?.copyWith(
                      fontSize: 10,
                      color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    )),
                  ]),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ── Full: icon + label side-by-side, 200px ───────────────────────────────────

class _FullSidebar extends StatelessWidget {
  final SidebarPage selected;
  final List<(SidebarPage, IconData, String)> items;
  final ValueChanged<SidebarPage> onSelect;
  const _FullSidebar({required this.selected, required this.items, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      width: 200,
      color: cs.surfaceContainerLow.withOpacity(0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.layers_rounded, size: 17, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Decksmith', style: tt.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700, letterSpacing: 0.1)),
                Text('Anki deck builder', style: tt.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant, fontSize: 10)),
              ]),
            ]),
          ),
          Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
          const SizedBox(height: 6),
          ...items.map((item) {
            final active = item.$1 == selected;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onSelect(item.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: active ? cs.primaryContainer : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    Icon(item.$2, size: 18,
                      color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Text(item.$3, style: tt.bodyMedium?.copyWith(
                      color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    )),
                  ]),
                ),
              ),
            );
          }),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
            child: Text('v1.0', style: tt.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withOpacity(0.4), fontSize: 10)),
          ),
        ],
      ),
    );
  }
}
