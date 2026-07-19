import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _enhanceAfter = false;
  EnhancementOptions _opts = EnhancementOptions();
  bool _building = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _opts = EnhancementOptions(
      depth: s.defaultDepth,
      provider: s.selectedProvider,
      ollamaModel: s.defaultOllamaModel,
    );
  }

  Future<void> _build() async {
    final state = context.read<AppState>();
    setState(() => _building = true);
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);

    try {
      var notes = List<NoteModel>.from(state.parsedNotes);

      if (state.existingApkgBytes != null) {
        state.setProgress('Checking for duplicates…', 0.15);
        final res = await api.dedupe(apkgBytes: state.existingApkgBytes!, notes: notes);
        notes = (res['new_notes'] as List)
            .map((n) => NoteModel.fromJson(n as Map<String, dynamic>))
            .toList();
        state.dupesSkipped = res['duplicate_count'] as int;
      }

      Map<String, String> mediaFilesB64 = {};
      if (_enhanceAfter) {
        state.setProgress('Enhancing ${notes.length} cards…', 0.3);
        final result = await api.augmentGenerate(
          notes, _opts,
          onProgress: (done, total) =>
            state.setProgress('Enhancing… $done / $total', 0.3 + 0.5 * (total > 0 ? done / total : 0)),
          onJobStarted: (id) => state.activeJobId = id,
        );
        final acceptedIndices = List.generate(result.proposals.length, (i) => i);
        notes = await api.augmentApply(
          notes: result.notes,
          proposals: result.proposals,
          acceptedIndices: acceptedIndices,
          expansionMode: _opts.expansionMode,
        );
        mediaFilesB64 = result.mediaFilesB64;
      }

      state.setProgress('Building deck…', 0.88);
      final buildResult = await api.buildDeck(
        notes: notes,
        deckName: state.deckName,
        classify: state.classify,
        mediaFilesB64: mediaFilesB64.isNotEmpty ? mediaFilesB64 : null,
      );

      state.totalCards = notes.length;
      state.setApkg(buildResult.bytes, dupesRemovedInBuild: buildResult.dupesRemoved);
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      state.setError(msg);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ));
        setState(() => _building = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final notes = state.parsedNotes;
    final errors = state.validationResults.where((v) => v.status == 'invalid').toList();

    return Column(
      children: [
        // ── Header bar ───────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: cs.outlineVariant.withOpacity(0.4))),
          ),
          child: Row(
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Review cards', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                Text('${notes.length} card${notes.length == 1 ? '' : 's'}'
                    '${errors.isNotEmpty ? '  ·  ${errors.length} issue${errors.length == 1 ? '' : 's'}' : ''}',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: state.reset,
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('Back'),
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),

        // ── Card list ────────────────────────────────────────────────
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            itemCount: notes.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _CardTile(
              note: notes[i],
              index: i,
              hasError: errors.any((e) => e.index == i),
              errorText: errors.firstWhere((e) => e.index == i,
                  orElse: () => ValidationResult(index: i, status: '', error: '', fixDescription: '')).error,
              onEdit: (updated) {
                setState(() => state.parsedNotes[i] = updated);
              },
              onDelete: () {
                setState(() => state.parsedNotes.removeAt(i));
              },
            ),
          ),
        ),

        // ── Bottom bar ───────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border(top: BorderSide(color: cs.outlineVariant.withOpacity(0.4))),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, -4))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Enhance toggle
              InkWell(
                onTap: () => setState(() => _enhanceAfter = !_enhanceAfter),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: _enhanceAfter ? cs.primaryContainer.withOpacity(0.5) : cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _enhanceAfter ? cs.primary.withOpacity(0.5) : cs.outlineVariant,
                    ),
                  ),
                  child: Row(children: [
                    Icon(Icons.auto_awesome_rounded, size: 16,
                      color: _enhanceAfter ? cs.primary : cs.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Enhance with AI before building',
                          style: tt.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: _enhanceAfter ? cs.onSurface : cs.onSurfaceVariant,
                          )),
                        if (_enhanceAfter)
                          Text('${_providerLabel(_opts.provider)}  ·  ${_opts.depth} mode',
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
                      ]),
                    ),
                    Switch(value: _enhanceAfter, onChanged: (v) => setState(() => _enhanceAfter = v)),
                  ]),
                ),
              ),

              if (_enhanceAfter) ...[
                const SizedBox(height: 10),
                _CompactEnhanceOptions(
                  opts: _opts,
                  onChanged: () => setState(() {}),
                ),
              ],

              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: notes.isEmpty || _building ? null : _build,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(notes.isEmpty ? 'No cards to build' : 'Build deck  →  ${notes.length} cards'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _providerLabel(String p) => switch (p) {
    'anthropic' => 'Claude',
    'openai'    => 'OpenAI',
    _           => 'Ollama',
  };
}

// ── Individual card tile ──────────────────────────────────────────────────────

class _CardTile extends StatefulWidget {
  final NoteModel note;
  final int index;
  final bool hasError;
  final String errorText;
  final ValueChanged<NoteModel> onEdit;
  final VoidCallback onDelete;
  const _CardTile({required this.note, required this.index, required this.hasError,
    required this.errorText, required this.onEdit, required this.onDelete});
  @override
  State<_CardTile> createState() => _CardTileState();
}

class _CardTileState extends State<_CardTile> {
  bool _expanded = false;

  Future<void> _showEditor() async {
    final updated = await showDialog<NoteModel>(
      context: context,
      builder: (_) => _CardEditorDialog(note: widget.note),
    );
    if (updated != null) widget.onEdit(updated);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final n = widget.note;

    return Container(
      decoration: BoxDecoration(
        color: widget.hasError
            ? cs.errorContainer.withOpacity(0.15)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.hasError
              ? cs.error.withOpacity(0.4)
              : cs.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Row(
                children: [
                  // Card number
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      color: cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Text('${widget.index + 1}',
                      style: tt.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700, color: cs.onSecondaryContainer)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(n.front,
                        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (widget.hasError) ...[
                        const SizedBox(height: 3),
                        Text(widget.errorText,
                          style: tt.bodySmall?.copyWith(color: cs.error, fontSize: 11),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      ] else ...[
                        const SizedBox(height: 2),
                        Text(n.back,
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 4),
                  // Type chip
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: cs.tertiaryContainer.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(n.noteType.replaceAll('_', ' '),
                      style: tt.labelSmall?.copyWith(
                        color: cs.onTertiaryContainer, fontSize: 10)),
                  ),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18, color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),

          if (_expanded) ...[
            Divider(height: 1, color: cs.outlineVariant.withOpacity(0.4)),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailRow(label: 'Front', text: n.front),
                  const SizedBox(height: 8),
                  _DetailRow(label: 'Back', text: n.back),
                  if (n.extra.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _DetailRow(label: 'Extra', text: n.extra),
                  ],
                  if (n.tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6, runSpacing: 4,
                      children: n.tags.map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(t, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                      )).toList(),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: widget.onDelete,
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        label: const Text('Delete'),
                        style: TextButton.styleFrom(
                          foregroundColor: cs.error,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: _showEditor,
                        icon: const Icon(Icons.edit_rounded, size: 16),
                        label: const Text('Edit'),
                        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String text;
  const _DetailRow({required this.label, required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label.toUpperCase(), style: tt.labelSmall?.copyWith(
        color: cs.onSurfaceVariant, letterSpacing: 0.8, fontSize: 10)),
      const SizedBox(height: 3),
      Text(text, style: tt.bodySmall),
    ]);
  }
}

// ── Card editor dialog ────────────────────────────────────────────────────────

class _CardEditorDialog extends StatefulWidget {
  final NoteModel note;
  const _CardEditorDialog({required this.note});
  @override
  State<_CardEditorDialog> createState() => _CardEditorDialogState();
}

class _CardEditorDialogState extends State<_CardEditorDialog> {
  late final TextEditingController _front;
  late final TextEditingController _back;
  late final TextEditingController _extra;
  late final TextEditingController _tags;

  @override
  void initState() {
    super.initState();
    _front = TextEditingController(text: widget.note.front);
    _back  = TextEditingController(text: widget.note.back);
    _extra = TextEditingController(text: widget.note.extra);
    _tags  = TextEditingController(text: widget.note.tags.join(', '));
  }

  @override
  void dispose() {
    _front.dispose(); _back.dispose(); _extra.dispose(); _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Edit card', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _EditorField(label: 'Front', controller: _front, minLines: 2),
              const SizedBox(height: 14),
              _EditorField(label: 'Back', controller: _back, minLines: 3),
              const SizedBox(height: 14),
              _EditorField(label: 'Extra (optional)', controller: _extra, minLines: 2),
              const SizedBox(height: 14),
              _EditorField(label: 'Tags (comma-separated)', controller: _tags, minLines: 1),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final tags = _tags.text.split(',')
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList();
            Navigator.pop(context, widget.note.copyWith(
              front: _front.text,
              back: _back.text,
              extra: _extra.text,
              tags: tags,
            ));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _EditorField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int minLines;
  const _EditorField({required this.label, required this.controller, required this.minLines});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        minLines: minLines,
        maxLines: null,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
    ]);
  }
}

// ── Compact enhancement options strip ────────────────────────────────────────

class _CompactEnhanceOptions extends StatelessWidget {
  final EnhancementOptions opts;
  final VoidCallback onChanged;
  const _CompactEnhanceOptions({required this.opts, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Provider + depth row
          Row(children: [
            _Pill(
              label: _providerLabel(opts.provider),
              onTap: () => _cycleProvider(opts, onChanged),
              active: false, cs: cs, tt: tt,
            ),
            const SizedBox(width: 6),
            _Pill(
              label: opts.depth == 'full' ? 'Full' : 'Quick',
              onTap: () { opts.depth = opts.depth == 'full' ? 'quick' : 'full'; onChanged(); },
              active: false, cs: cs, tt: tt,
            ),
            const SizedBox(width: 6),
            _Pill(
              label: _modeLabel(opts.expansionMode),
              onTap: () => _cycleMode(opts, onChanged),
              active: false, cs: cs, tt: tt,
            ),
          ]),
          const SizedBox(height: 8),
          // Content toggles
          Wrap(spacing: 6, runSpacing: 6, children: [
            _TogglePill(label: 'Clinical', active: opts.addClinicalContext,
              onTap: () { opts.addClinicalContext = !opts.addClinicalContext; onChanged(); }, cs: cs, tt: tt),
            _TogglePill(label: 'High-yield', active: opts.addHighYield,
              onTap: () { opts.addHighYield = !opts.addHighYield; onChanged(); }, cs: cs, tt: tt),
            _TogglePill(label: 'Exam traps', active: opts.addExamTraps,
              onTap: () { opts.addExamTraps = !opts.addExamTraps; onChanged(); }, cs: cs, tt: tt),
          ]),
        ],
      ),
    );
  }

  void _cycleProvider(EnhancementOptions o, VoidCallback cb) {
    const providers = ['anthropic', 'openai', 'ollama'];
    final idx = providers.indexOf(o.provider);
    o.provider = providers[(idx + 1) % providers.length];
    cb();
  }

  void _cycleMode(EnhancementOptions o, VoidCallback cb) {
    const modes = ['append', 'empty_only', 'overwrite'];
    final idx = modes.indexOf(o.expansionMode);
    o.expansionMode = modes[(idx + 1) % modes.length];
    cb();
  }

  String _providerLabel(String p) => switch (p) {
    'anthropic' => 'Claude',
    'openai'    => 'OpenAI',
    _           => 'Ollama',
  };

  String _modeLabel(String m) => switch (m) {
    'empty_only' => 'Fill blanks',
    'overwrite'  => 'Overwrite',
    _            => 'Append',
  };
}

class _Pill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;
  final ColorScheme cs;
  final TextTheme tt;
  const _Pill({required this.label, required this.onTap, required this.active,
    required this.cs, required this.tt});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(width: 4),
        Icon(Icons.swap_horiz_rounded, size: 12, color: cs.onSurfaceVariant),
      ]),
    ),
  );
}

class _TogglePill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final ColorScheme cs;
  final TextTheme tt;
  const _TogglePill({required this.label, required this.active, required this.onTap,
    required this.cs, required this.tt});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: active ? cs.primary.withOpacity(0.5) : cs.outlineVariant),
      ),
      child: Text(label, style: tt.labelSmall?.copyWith(
        color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
        fontWeight: active ? FontWeight.w600 : FontWeight.normal,
      )),
    ),
  );
}
