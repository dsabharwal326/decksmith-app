import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

// ── data ────────────────────────────────────────────────────────────────────

class _AiAnalysis {
  final String verdict;   // keep | improve | remove
  final String reason;
  final String suggestion;
  _AiAnalysis({required this.verdict, required this.reason, required this.suggestion});
  factory _AiAnalysis.fromJson(Map<String, dynamic> j) => _AiAnalysis(
    verdict: j['verdict'] as String? ?? 'keep',
    reason: j['reason'] as String? ?? '',
    suggestion: j['suggestion'] as String? ?? '',
  );
}

class _CardEntry {
  final NoteModel note;
  final ValidationResult validation;
  bool keep;
  _AiAnalysis? ai;

  _CardEntry({required this.note, required this.validation})
      : keep = validation.status != 'invalid';

  NoteModel get effectiveNote =>
      validation.status == 'fixable' && validation.fixedNote != null && keep
          ? validation.fixedNote!
          : note;
}

// ── screen ──────────────────────────────────────────────────────────────────

class RepairScreen extends StatefulWidget {
  const RepairScreen({super.key});
  @override
  State<RepairScreen> createState() => _RepairScreenState();
}

class _RepairScreenState extends State<RepairScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // load phase
  String? _fileName;
  Uint8List? _apkgBytes;
  bool _dragging = false;
  bool _loading = false;
  String? _error;

  // review phase
  List<_CardEntry>? _cards;
  String _filter = 'all'; // all | keep | remove | invalid | fixable | ai_remove | ai_improve

  // ai analysis
  bool _analyzing = false;
  bool _analyzed = false;

  // save phase
  bool _saving = false;

  // ── load ────────────────────────────────────────────────────────────────

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: false);
    if (res == null || res.files.isEmpty) return;
    final path = res.files.first.path;
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.apkg')) {
      setState(() => _error = 'Please pick an .apkg file');
      return;
    }
    await _loadPath(path);
  }

  Future<void> _loadPath(String path) async {
    final bytes = await File(path).readAsBytes();
    if (!mounted) return;
    setState(() {
      _fileName = path.split('/').last;
      _apkgBytes = bytes;
      _cards = null;
      _error = null;
    });
    await _loadCards(bytes);
  }

  Future<void> _analyze() async {
    if (_cards == null || _analyzing) return;
    setState(() { _analyzing = true; });
    try {
      final api = ApiService(context.read<AppState>());
      final notes = _cards!.map((c) => c.note).toList();
      final results = await api.analyzeCards(notes);
      if (!mounted) return;
      for (final r in results) {
        final idx = r['index'] as int? ?? -1;
        if (idx >= 0 && idx < _cards!.length) {
          _cards![idx].ai = _AiAnalysis.fromJson(r);
          // auto-flip keep flag based on AI verdict, unless user already touched it
          if (r['verdict'] == 'remove') _cards![idx].keep = false;
        }
      }
      setState(() { _analyzing = false; _analyzed = true; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _analyzing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Analysis failed: ${e.toString().replaceFirst('Exception: ', '')}'),
        behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _loadCards(Uint8List bytes) async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = ApiService(context.read<AppState>());
      final notes = await api.importApkg(bytes);
      if (!mounted) return;
      if (notes.isEmpty) {
        setState(() { _loading = false; _error = 'No cards found in this deck'; });
        return;
      }
      final validation = await api.validate(notes);
      if (!mounted) return;
      final cards = List.generate(
        notes.length,
        (i) => _CardEntry(note: notes[i], validation: validation[i]),
      );
      setState(() { _cards = cards; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  // ── filter / counts ─────────────────────────────────────────────────────

  List<_CardEntry> get _filtered {
    final cards = _cards ?? [];
    return switch (_filter) {
      'keep'       => cards.where((c) => c.keep).toList(),
      'remove'     => cards.where((c) => !c.keep).toList(),
      'invalid'    => cards.where((c) => c.validation.status == 'invalid').toList(),
      'fixable'    => cards.where((c) => c.validation.status == 'fixable').toList(),
      'ai_remove'  => cards.where((c) => c.ai?.verdict == 'remove').toList(),
      'ai_improve' => cards.where((c) => c.ai?.verdict == 'improve').toList(),
      _            => cards,
    };
  }

  int get _keepCount      => _cards?.where((c) => c.keep).length ?? 0;
  int get _removeCount    => _cards?.where((c) => !c.keep).length ?? 0;
  int get _invalidCount   => _cards?.where((c) => c.validation.status == 'invalid').length ?? 0;
  int get _fixableCount   => _cards?.where((c) => c.validation.status == 'fixable').length ?? 0;
  int get _aiRemoveCount  => _cards?.where((c) => c.ai?.verdict == 'remove').length ?? 0;
  int get _aiImproveCount => _cards?.where((c) => c.ai?.verdict == 'improve').length ?? 0;

  // ── save ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_cards == null) return;
    final toKeep = _cards!.where((c) => c.keep).map((c) => c.effectiveNote).toList();
    if (toKeep.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No cards marked to keep'), behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _saving = true);
    try {
      final api = ApiService(context.read<AppState>());
      final deckName = _fileName!.replaceAll('.apkg', '');
      final result = await api.buildDeck(notes: toKeep, deckName: deckName, classify: false);
      if (!mounted) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save repaired deck',
        fileName: '${deckName}_repaired.apkg',
      );
      if (path == null) { setState(() => _saving = false); return; }
      await File(path).writeAsBytes(result.bytes);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${toKeep.length} cards to $path'), behavior: SnackBarBehavior.floating));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), behavior: SnackBarBehavior.floating));
    }
    if (mounted) setState(() => _saving = false);
  }

  // ── ui ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    if (_cards != null) return _buildReview(cs, tt);
    return _buildLoad(cs, tt);
  }

  Widget _buildLoad(ColorScheme cs, TextTheme tt) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Repair Deck',
              style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Review every card and decide what to keep',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 24),

            DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (d) {
                setState(() => _dragging = false);
                final path = d.files.firstOrNull?.path;
                if (path == null || !path.toLowerCase().endsWith('.apkg')) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Drop an .apkg file'), behavior: SnackBarBehavior.floating));
                  return;
                }
                _loadPath(path);
              },
              child: GestureDetector(
                onTap: _loading ? null : _pick,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: double.infinity,
                  height: 140,
                  decoration: BoxDecoration(
                    color: _dragging
                        ? cs.primaryContainer.withOpacity(0.3)
                        : cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _dragging ? cs.primary : cs.outlineVariant,
                      width: _dragging ? 2 : 1.5,
                    ),
                  ),
                  child: _loading
                    ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text('Loading deck…', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ])
                    : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.style_rounded, size: 36, color: cs.onSurfaceVariant),
                        const SizedBox(height: 10),
                        Text('Tap or drop an .apkg file',
                          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                      ]),
                ),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded, size: 16, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!,
                    style: tt.bodySmall?.copyWith(color: cs.onErrorContainer))),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReview(ColorScheme cs, TextTheme tt) {
    final cards = _cards!;
    final filtered = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── header ───────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_fileName ?? 'Deck',
                      style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text('${cards.length} cards  ·  ${_keepCount} keeping  ·  ${_removeCount} removing',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _cards = null; _fileName = null; _apkgBytes = null;
                  _analyzed = false; _filter = 'all';
                }),
                icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                label: const Text('Change deck'),
              ),
              const SizedBox(width: 8),
              if (!_analyzed)
                OutlinedButton.icon(
                  onPressed: _analyzing ? null : _analyze,
                  icon: _analyzing
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: Text(_analyzing ? 'Analyzing…' : 'AI Analysis'),
                ),
              if (_analyzed)
                OutlinedButton.icon(
                  onPressed: _analyzing ? null : _analyze,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Re-analyze'),
                ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download_rounded, size: 16),
                label: Text(_saving ? 'Saving…' : 'Export $_keepCount cards'),
              ),
            ],
          ),
        ),

        // ── filter chips ─────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Wrap(spacing: 8, children: [
            _FilterChip(label: 'All', value: 'all', count: cards.length,
              selected: _filter == 'all', cs: cs, onTap: () => setState(() => _filter = 'all')),
            _FilterChip(label: 'Keep', value: 'keep', count: _keepCount,
              selected: _filter == 'keep', cs: cs, color: Colors.green,
              onTap: () => setState(() => _filter = 'keep')),
            _FilterChip(label: 'Remove', value: 'remove', count: _removeCount,
              selected: _filter == 'remove', cs: cs, color: cs.error,
              onTap: () => setState(() => _filter = 'remove')),
            if (_fixableCount > 0)
              _FilterChip(label: 'Fixable', value: 'fixable', count: _fixableCount,
                selected: _filter == 'fixable', cs: cs, color: Colors.orange,
                onTap: () => setState(() => _filter = 'fixable')),
            if (_invalidCount > 0)
              _FilterChip(label: 'Invalid', value: 'invalid', count: _invalidCount,
                selected: _filter == 'invalid', cs: cs, color: cs.error,
                onTap: () => setState(() => _filter = 'invalid')),
            if (_analyzed && _aiRemoveCount > 0)
              _FilterChip(label: '✦ Cut', value: 'ai_remove', count: _aiRemoveCount,
                selected: _filter == 'ai_remove', cs: cs, color: Colors.deepOrange,
                onTap: () => setState(() => _filter = 'ai_remove')),
            if (_analyzed && _aiImproveCount > 0)
              _FilterChip(label: '✦ Improve', value: 'ai_improve', count: _aiImproveCount,
                selected: _filter == 'ai_improve', cs: cs, color: Colors.purple,
                onTap: () => setState(() => _filter = 'ai_improve')),
          ]),
        ),

        // ── batch actions ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Row(children: [
            TextButton(
              onPressed: () => setState(() { for (final c in filtered) c.keep = true; }),
              child: const Text('Keep all'),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => setState(() { for (final c in filtered) c.keep = false; }),
              child: const Text('Remove all'),
            ),
            const Spacer(),
            Text('${filtered.length} shown',
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),

        const Divider(height: 1),

        // ── card list ────────────────────────────────────────────────────
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) => _CardTile(
              entry: filtered[i],
              cs: cs,
              tt: tt,
              onToggle: () => setState(() => filtered[i].keep = !filtered[i].keep),
            ),
          ),
        ),
      ],
    );
  }
}

// ── card tile ───────────────────────────────────────────────────────────────

class _CardTile extends StatefulWidget {
  final _CardEntry entry;
  final ColorScheme cs;
  final TextTheme tt;
  final VoidCallback onToggle;
  const _CardTile({required this.entry, required this.cs, required this.tt, required this.onToggle});

  @override
  State<_CardTile> createState() => _CardTileState();
}

class _CardTileState extends State<_CardTile> {
  bool _expanded = true; // default open so content is always readable

  Color _statusColor(ColorScheme cs) => switch (widget.entry.validation.status) {
    'invalid'  => cs.error,
    'fixable'  => Colors.orange,
    _          => Colors.green,
  };

  String _statusLabel() => switch (widget.entry.validation.status) {
    'invalid' => 'invalid',
    'fixable' => 'fixable',
    _         => 'valid',
  };

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final cs = widget.cs;
    final tt = widget.tt;
    final note = entry.note;
    final statusColor = _statusColor(cs);
    final dimmed = !entry.keep;

    return AnimatedOpacity(
      opacity: dimmed ? 0.45 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          color: !entry.keep
              ? cs.errorContainer.withOpacity(0.08)
              : entry.validation.status == 'fixable'
                  ? Colors.orange.withOpacity(0.05)
                  : null,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // status dot
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 10),
                    child: Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: entry.keep ? statusColor : cs.outlineVariant,
                      ),
                    ),
                  ),

                  // front text
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Front
                        Text('FRONT', style: tt.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant, fontSize: 9,
                          fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                        const SizedBox(height: 3),
                        Text(
                          note.front.isEmpty ? '(empty)' : note.front,
                          style: tt.bodyMedium?.copyWith(
                            color: note.front.isEmpty ? cs.onSurfaceVariant : null,
                            fontStyle: note.front.isEmpty ? FontStyle.italic : null,
                          ),
                          maxLines: _expanded ? null : 2,
                          overflow: _expanded ? null : TextOverflow.ellipsis,
                        ),

                        // expanded: back + meta
                        if (_expanded) ...[
                          if (note.back.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text('BACK', style: tt.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant, fontSize: 9,
                              fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                            const SizedBox(height: 3),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(note.back, style: tt.bodyMedium),
                            ),
                          ],
                          if (entry.validation.error.isNotEmpty ||
                              entry.validation.fixDescription.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              entry.validation.error.isNotEmpty
                                  ? entry.validation.error
                                  : entry.validation.fixDescription,
                              style: tt.labelSmall?.copyWith(color: statusColor),
                            ),
                          ],
                          if (entry.validation.status == 'fixable' &&
                              entry.validation.fixedNote != null) ...[
                            const SizedBox(height: 4),
                            Text('Will be auto-fixed on export',
                              style: tt.labelSmall?.copyWith(color: Colors.orange)),
                          ],
                          if (entry.ai != null) ...[
                            const SizedBox(height: 10),
                            _AiBadge(ai: entry.ai!, cs: cs, tt: tt),
                          ],
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(width: 8),

                  // right side: type badge + toggle
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _TypeBadge(noteType: note.noteType, cs: cs, tt: tt),
                      const SizedBox(height: 6),
                      _KeepToggle(
                        keep: entry.keep,
                        status: entry.validation.status,
                        cs: cs,
                        onTap: widget.onToggle,
                      ),
                    ],
                  ),
                ],
              ),

            ],
          ),
        ),
      ),
    );
  }
}

// ── small widgets ────────────────────────────────────────────────────────────

class _AiBadge extends StatelessWidget {
  final _AiAnalysis ai;
  final ColorScheme cs;
  final TextTheme tt;
  const _AiBadge({required this.ai, required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) {
    final Color col = switch (ai.verdict) {
      'remove'  => Colors.deepOrange,
      'improve' => Colors.purple,
      _         => Colors.green,
    };
    final String icon = switch (ai.verdict) {
      'remove'  => '✂',
      'improve' => '✦',
      _         => '✓',
    };
    final text = ai.suggestion.isNotEmpty ? ai.suggestion : ai.reason;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: col.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: col.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$icon ', style: TextStyle(color: col, fontSize: 13, fontWeight: FontWeight.w700)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI · ${ai.verdict.toUpperCase()}',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: col, letterSpacing: 0.5)),
                if (text.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(text, style: tt.bodySmall?.copyWith(color: cs.onSurface)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KeepToggle extends StatelessWidget {
  final bool keep;
  final String status;
  final ColorScheme cs;
  final VoidCallback onTap;
  const _KeepToggle({required this.keep, required this.status, required this.cs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: keep
              ? (status == 'invalid' ? Colors.green.withOpacity(0.12) : Colors.green.withOpacity(0.12))
              : cs.errorContainer.withOpacity(0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: keep ? Colors.green.withOpacity(0.4) : cs.error.withOpacity(0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              keep ? Icons.check_rounded : Icons.close_rounded,
              size: 12,
              color: keep ? Colors.green : cs.error,
            ),
            const SizedBox(width: 4),
            Text(
              keep ? 'Keep' : 'Remove',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: keep ? Colors.green : cs.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String noteType;
  final ColorScheme cs;
  final TextTheme tt;
  const _TypeBadge({required this.noteType, required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) {
    final label = switch (noteType) {
      'cloze'        => 'Cloze',
      'basic_extra'  => 'Basic+',
      'basic_reverse'=> 'Reverse',
      'table'        => 'Table',
      _              => 'Basic',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withOpacity(0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
        style: tt.labelSmall?.copyWith(
          color: cs.onSecondaryContainer, fontWeight: FontWeight.w600, fontSize: 10)),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final String value;
  final int count;
  final bool selected;
  final ColorScheme cs;
  final Color? color;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.value, required this.count,
    required this.selected, required this.cs, this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final col = color ?? cs.primary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? col.withOpacity(0.15) : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? col.withOpacity(0.5) : cs.outlineVariant,
          ),
        ),
        child: Text('$label  $count',
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? col : cs.onSurfaceVariant,
          )),
      ),
    );
  }
}
