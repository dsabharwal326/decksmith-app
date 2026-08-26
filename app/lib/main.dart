import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'screens/upload_screen.dart';
import 'screens/topic_screen.dart';
import 'screens/processing_screen.dart';
import 'screens/review_screen.dart';
import 'screens/export_screen.dart';
import 'screens/enhance_screen.dart';
import 'screens/merge_screen.dart';
import 'screens/repair_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/ollama_setup_dialog.dart';

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
      fontFamily: 'SF Pro Display',
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
  bool _ollamaChecked = false;

  static const _navItems = [
    (SidebarPage.upload,   Icons.upload_file_rounded,      'Generate', 'Generate cards from a file'),
    (SidebarPage.topic,    Icons.auto_awesome_rounded,     'Topic',    'Generate cards from a topic'),
    (SidebarPage.enhance,  Icons.brightness_auto_rounded,  'Enhance',  'AI-enhance an existing deck'),
    (SidebarPage.merge,    Icons.merge_rounded,            'Merge',    'Combine two decks into one'),
    (SidebarPage.repair,   Icons.build_rounded,            'Repair',   'Remove bad cards from a deck'),
    (SidebarPage.history,  Icons.history_rounded,          'History',  'Previously built decks'),
    (SidebarPage.settings, Icons.settings_rounded,         'Settings', 'API keys, backend, preferences'),
  ];

  Widget _pageWidget(AppState state) {
    if (state.phase == AppPhase.processing) return const ProcessingScreen();
    if (state.phase == AppPhase.review)     return const ReviewScreen();
    if (state.phase == AppPhase.exporting)  return const ExportScreen();
    return switch (_page) {
      SidebarPage.upload   => const UploadScreen(),
      SidebarPage.topic    => const TopicScreen(),
      SidebarPage.enhance  => const EnhanceScreen(),
      SidebarPage.merge    => const MergeScreen(),
      SidebarPage.repair   => const RepairScreen(),
      SidebarPage.history  => const HistoryScreen(),
      SidebarPage.settings => const SettingsScreen(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // Check for Ollama first-run once backend is up
    if (!_ollamaChecked &&
        state.backendStatus == BackendStatus.running &&
        state.selectedProvider == 'ollama') {
      _ollamaChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await maybeShowOllamaSetup(context);
      });
    }

    // Show error from AppState (screens may be unmounted when errors fire)
    if (state.errorMessage != null) {
      final msg = state.errorMessage!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        state.errorMessage = null;
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Error'),
            content: Text(msg),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          ),
        );
      });
    }

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

    final dividerColor = Theme.of(context).colorScheme.outlineVariant.withOpacity(0.4);

    Widget content = switch (mode) {
      // Compact: plain content, no chrome
      ViewMode.compact => Expanded(child: body),

      // Hybrid: content with a thin status bar at the top
      ViewMode.hybrid => Expanded(
        child: Column(children: [
          _StatusBar(page: _page),
          Expanded(child: body),
        ]),
      ),

      // Full: content + right context panel
      ViewMode.full => Expanded(
        child: Row(children: [
          Expanded(child: body),
          VerticalDivider(width: 1, color: dividerColor),
          _ContextPanel(
            page: _page,
            onNavigate: (p) => setState(() => _page = p),
          ),
        ]),
      ),
    };

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            mode: mode,
            selected: _page,
            items: _navItems,
            onSelect: (p) => setState(() => _page = p),
          ),
          VerticalDivider(width: 1, color: dividerColor),
          content,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hybrid: thin status bar above content
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final SidebarPage page;
  const _StatusBar({required this.page});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final backendOk = state.backendStatus == BackendStatus.running;
    final backendStarting = state.backendStatus == BackendStatus.starting;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: cs.outlineVariant.withOpacity(0.6))),
      ),
      child: Row(children: [
        // Backend pill
        _StatusChip(
          icon: backendOk
              ? Icons.circle
              : backendStarting
                  ? Icons.hourglass_top_rounded
                  : Icons.circle_outlined,
          label: backendOk ? 'Backend' : backendStarting ? 'Starting…' : 'Offline',
          color: backendOk
              ? const Color(0xFF22C55E)
              : backendStarting
                  ? cs.tertiary
                  : cs.error,
          cs: cs, tt: tt,
        ),
        const SizedBox(width: 12),

        // Phase / session state
        if (state.phase == AppPhase.processing) ...[
          _StatusChip(icon: Icons.sync_rounded, label: 'Processing…', color: cs.primary, cs: cs, tt: tt),
        ] else if (state.phase == AppPhase.review) ...[
          _StatusChip(
            icon: Icons.preview_rounded,
            label: '${state.totalCards} cards — review',
            color: cs.secondary,
            cs: cs, tt: tt,
          ),
        ] else if (state.phase == AppPhase.exporting) ...[
          _StatusChip(
            icon: Icons.check_circle_rounded,
            label: '${state.totalCards} cards built',
            color: const Color(0xFF22C55E),
            cs: cs, tt: tt,
          ),
        ] else ...[
          // Idle — show history count
          if (state.history.isNotEmpty)
            _StatusChip(
              icon: Icons.layers_rounded,
              label: '${state.history.length} deck${state.history.length == 1 ? '' : 's'} built',
              color: cs.onSurfaceVariant,
              cs: cs, tt: tt,
            ),
        ],

        const Spacer(),

        // Deck name when active
        if (state.phase != AppPhase.idle && state.deckName.isNotEmpty)
          Text(state.deckName,
            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final ColorScheme cs;
  final TextTheme tt;
  const _StatusChip({required this.icon, required this.label, required this.color,
    required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 9, color: color),
    const SizedBox(width: 5),
    Text(label, style: tt.labelSmall?.copyWith(color: color, fontSize: 11)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Full: right context panel
// ─────────────────────────────────────────────────────────────────────────────

class _ContextPanel extends StatelessWidget {
  final SidebarPage page;
  final ValueChanged<SidebarPage> onNavigate;
  const _ContextPanel({required this.page, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      width: 260,
      color: cs.surfaceContainerHigh,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Backend status ──────────────────────────────────────────
            _PanelSection(label: 'Backend', cs: cs, tt: tt),
            _BackendCard(cs: cs, tt: tt),

            const SizedBox(height: 16),

            // ── Session ─────────────────────────────────────────────────
            _PanelSection(label: 'Session', cs: cs, tt: tt),
            _SessionCard(cs: cs, tt: tt),

            const SizedBox(height: 16),

            // ── Recent decks ─────────────────────────────────────────────
            if (state.history.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _PanelSection(label: 'Recent', cs: cs, tt: tt),
                  GestureDetector(
                    onTap: () => onNavigate(SidebarPage.history),
                    child: Text('See all',
                      style: tt.labelSmall?.copyWith(color: cs.primary, fontSize: 11)),
                  ),
                ],
              ),
              _RecentDecksCard(cs: cs, tt: tt),
              const SizedBox(height: 16),
            ],

            // ── Quick actions ────────────────────────────────────────────
            _PanelSection(label: 'Quick start', cs: cs, tt: tt),
            _QuickActionsCard(cs: cs, tt: tt, onNavigate: onNavigate),
          ],
        ),
      ),
    );
  }
}

class _PanelSection extends StatelessWidget {
  final String label;
  final ColorScheme cs;
  final TextTheme tt;
  const _PanelSection({required this.label, required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(label.toUpperCase(),
      style: tt.labelSmall?.copyWith(
        color: cs.onSurfaceVariant,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      )),
  );
}

class _BackendCard extends StatelessWidget {
  final ColorScheme cs;
  final TextTheme tt;
  const _BackendCard({required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final status = state.backendStatus;
    final (label, color, icon) = switch (status) {
      BackendStatus.running  => ('Running',  const Color(0xFF22C55E), Icons.check_circle_rounded),
      BackendStatus.starting => ('Starting…', const Color(0xFFF59E0B), Icons.hourglass_top_rounded),
      BackendStatus.offline  => ('Offline',  const Color(0xFFEF4444), Icons.cancel_rounded),
      _                      => ('Unknown',  const Color(0xFF94A3B8), Icons.help_rounded),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
      ),
      child: Row(children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: tt.labelMedium?.copyWith(
              color: color, fontWeight: FontWeight.w600)),
            Text('port 8503', style: tt.bodySmall?.copyWith(
              color: cs.onSurfaceVariant, fontSize: 10)),
          ]),
        ),
        if (status == BackendStatus.offline)
          GestureDetector(
            onTap: () => state.launchBackend(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('Retry', style: tt.labelSmall?.copyWith(
                color: cs.onPrimaryContainer, fontSize: 10)),
            ),
          ),
      ]),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final ColorScheme cs;
  final TextTheme tt;
  const _SessionCard({required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    final (phaseLabel, phaseColor) = switch (state.phase) {
      AppPhase.idle       => ('Idle',       cs.onSurfaceVariant),
      AppPhase.processing => ('Processing', cs.primary),
      AppPhase.review     => ('Review',     cs.secondary),
      AppPhase.exporting  => ('Ready',      const Color(0xFF22C55E)),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Phase', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
          Text(phaseLabel, style: tt.labelSmall?.copyWith(
            color: phaseColor, fontWeight: FontWeight.w600)),
        ]),
        if (state.phase != AppPhase.idle) ...[
          const SizedBox(height: 8),
          Divider(height: 1, color: cs.outlineVariant.withOpacity(0.4)),
          const SizedBox(height: 8),
          if (state.deckName.isNotEmpty)
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Deck', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
              Flexible(child: Text(state.deckName,
                style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis)),
            ]),
          if (state.totalCards > 0) ...[
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Cards', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
              Text('${state.totalCards}', style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
            ]),
          ],
          if (state.dupesSkipped > 0) ...[
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Dupes skipped', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
              Text('${state.dupesSkipped}', style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
            ]),
          ],
        ] else ...[
          const SizedBox(height: 4),
          Text('No active session', style: tt.bodySmall?.copyWith(
            color: cs.onSurfaceVariant.withOpacity(0.5), fontSize: 11)),
        ],
      ]),
    );
  }
}

class _RecentDecksCard extends StatelessWidget {
  final ColorScheme cs;
  final TextTheme tt;
  const _RecentDecksCard({required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) {
    final history = context.watch<AppState>().history.take(3).toList();
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
      ),
      child: Column(
        children: history.asMap().entries.map((e) {
          final i = e.key;
          final entry = e.value;
          return Column(children: [
            if (i > 0) Divider(height: 1, color: cs.outlineVariant.withOpacity(0.4)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(Icons.layers_rounded, size: 14, color: cs.onSecondaryContainer),
                ),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(entry.deckName,
                    style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text('${entry.cardCount} cards · ${_relDate(entry.date)}',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 10)),
                ])),
              ]),
            ),
          ]);
        }).toList(),
      ),
    );
  }

  String _relDate(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7)  return '${diff.inDays}d ago';
    return '${d.month}/${d.day}';
  }
}

class _QuickActionsCard extends StatelessWidget {
  final ColorScheme cs;
  final TextTheme tt;
  final ValueChanged<SidebarPage> onNavigate;
  const _QuickActionsCard({required this.cs, required this.tt, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final actions = [
      (Icons.upload_file_rounded,     'Generate from file', SidebarPage.upload),
      (Icons.auto_awesome_rounded,    'Generate by topic', SidebarPage.topic),
      (Icons.brightness_auto_rounded, 'Enhance deck',      SidebarPage.enhance),
    ];

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
      ),
      child: Column(
        children: actions.asMap().entries.map((e) {
          final i = e.key;
          final action = e.value;
          final enabled = state.phase == AppPhase.idle &&
              state.backendStatus == BackendStatus.running;
          return Column(children: [
            if (i > 0) Divider(height: 1, color: cs.outlineVariant.withOpacity(0.4)),
            InkWell(
              onTap: enabled ? () => onNavigate(action.$3) : null,
              borderRadius: i == 0
                  ? const BorderRadius.vertical(top: Radius.circular(10))
                  : i == actions.length - 1
                      ? const BorderRadius.vertical(bottom: Radius.circular(10))
                      : BorderRadius.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Icon(action.$1, size: 15,
                    color: enabled ? cs.primary : cs.onSurfaceVariant.withOpacity(0.4)),
                  const SizedBox(width: 8),
                  Text(action.$2, style: tt.bodySmall?.copyWith(
                    color: enabled ? cs.onSurface : cs.onSurfaceVariant.withOpacity(0.4),
                    fontSize: 12,
                  )),
                  const Spacer(),
                  Icon(Icons.chevron_right_rounded, size: 14,
                    color: enabled ? cs.onSurfaceVariant : cs.onSurfaceVariant.withOpacity(0.3)),
                ]),
              ),
            ),
          ]);
        }).toList(),
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
  final List<(SidebarPage, IconData, String, String)> items;
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
  final List<(SidebarPage, IconData, String, String)> items;
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
  final List<(SidebarPage, IconData, String, String)> items;
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

// ── Full: icon + label + section groups, 200px ───────────────────────────────

class _FullSidebar extends StatelessWidget {
  final SidebarPage selected;
  final List<(SidebarPage, IconData, String, String)> items;
  final ValueChanged<SidebarPage> onSelect;
  const _FullSidebar({required this.selected, required this.items, required this.onSelect});

  // Section grouping: Build / Manage
  static const _buildPages = {SidebarPage.upload, SidebarPage.topic, SidebarPage.enhance};
  static const _managePages = {SidebarPage.history, SidebarPage.settings};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final state = context.watch<AppState>();

    final buildItems = items.where((i) => _buildPages.contains(i.$1)).toList();
    final manageItems = items.where((i) => _managePages.contains(i.$1)).toList();

    return Container(
      width: 200,
      color: cs.surfaceContainerLow.withOpacity(0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────
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

          // ── Build section ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Text('BUILD', style: tt.labelSmall?.copyWith(
              color: cs.onSurfaceVariant, fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 0.9)),
          ),
          ..._sectionItems(context, buildItems, cs, tt),

          const SizedBox(height: 6),

          // ── Manage section ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
            child: Text('MANAGE', style: tt.labelSmall?.copyWith(
              color: cs.onSurfaceVariant, fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 0.9)),
          ),
          ..._sectionItems(context, manageItems, cs, tt),

          const Spacer(),

          // ── Backend status chip at bottom ──────────────────────────
          Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Row(children: [
              Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: state.backendStatus == BackendStatus.running
                      ? const Color(0xFF22C55E)
                      : state.backendStatus == BackendStatus.starting
                          ? const Color(0xFFF59E0B)
                          : cs.error,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                state.backendStatus == BackendStatus.running
                    ? 'Backend running'
                    : state.backendStatus == BackendStatus.starting
                        ? 'Backend starting…'
                        : 'Backend offline',
                style: tt.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  List<Widget> _sectionItems(
    BuildContext context,
    List<(SidebarPage, IconData, String, String)> sectionItems,
    ColorScheme cs,
    TextTheme tt,
  ) {
    return sectionItems.map((item) {
      final active = item.$1 == selected;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Tooltip(
          message: item.$4,
          preferBelow: false,
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onSelect(item.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: active ? cs.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(item.$2, size: 16,
                  color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(item.$3, style: tt.bodySmall?.copyWith(
                    color: active ? cs.onPrimaryContainer : cs.onSurface,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    fontSize: 13,
                  )),
                ),
              ]),
            ),
          ),
        ),
      );
    }).toList();
  }
}
