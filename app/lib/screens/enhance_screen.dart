import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

class EnhanceScreen extends StatefulWidget {
  const EnhanceScreen({super.key});
  @override
  State<EnhanceScreen> createState() => _EnhanceScreenState();
}

class _EnhanceScreenState extends State<EnhanceScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  String? _fileName;
  Uint8List? _apkgBytes;
  bool _dragging = false;
  late EnhancementOptions _opts;
  List<String> _ollamaModels = [];
  bool _ollamaLoading = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _opts = EnhancementOptions(
      depth: s.defaultDepth,
      provider: s.selectedProvider,
      ollamaModel: s.defaultOllamaModel,
    );
    if (s.selectedProvider == 'ollama') _loadOllamaModels();
  }

  Future<void> _loadOllamaModels() async {
    setState(() => _ollamaLoading = true);
    final models = await ApiService(context.read<AppState>()).ollamaModels();
    if (!mounted) return;
    setState(() {
      _ollamaModels = models;
      _ollamaLoading = false;
      if (models.isNotEmpty && !models.contains(_opts.ollamaModel)) {
        _opts.ollamaModel = models.first;
      }
    });
  }

  Future<void> _pickApkg() async {
    try {
      final state = context.read<AppState>();
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
        initialDirectory: state.lastPickerPath.isNotEmpty ? state.lastPickerPath : null,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final path = file.path;
      if (path == null) { state.setError('Could not get file path'); return; }
      if (!path.toLowerCase().endsWith('.apkg')) {
        state.setError('Please pick an .apkg file (got: ${file.name})');
        return;
      }
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      final dir = path.substring(0, path.lastIndexOf('/'));
      state.lastPickerPath = dir;
      state.saveSettings();
      state.errorMessage = null;
      setState(() { _fileName = file.name; _apkgBytes = bytes; });
    } catch (e) {
      if (mounted) context.read<AppState>().setError('File picker error: $e');
    }
  }

  Future<void> _enhance() async {
    if (_apkgBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a deck first')));
      return;
    }
    final state = context.read<AppState>();
    final deckName = _fileName!.replaceAll('.apkg', '');
    state.deckName = deckName;
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);

    try {
      state.setProgress('Reading deck…', 0.1);
      final notes = await api.importApkg(_apkgBytes!);
      if (notes.isEmpty) { state.setError('No cards found in this deck'); return; }

      final desc = [
        if (_opts.combineCards) 'combining',
        if (_opts.addImages) 'finding images',
        'enhancing ${notes.length} cards',
      ].join(', ');
      state.setProgress('${desc[0].toUpperCase()}${desc.substring(1)}…', 0.25);

      final result = await api.augmentGenerate(notes, _opts, onProgress: (done, total) {
        if (total > 0) {
          final pct = 0.25 + (done / total) * 0.45;
          state.setProgress('Enhancing cards… ($done/$total)', pct.clamp(0.25, 0.70));
        }
      }, onJobStarted: (id) => state.activeJobId = id);

      state.setProgress('Applying enhancements…', 0.7);
      final acceptedIndices = List.generate(result.proposals.length, (i) => i);
      final enhanced = await api.augmentApply(
        notes: result.notes,
        proposals: result.proposals,
        acceptedIndices: acceptedIndices,
        expansionMode: _opts.expansionMode,
      );

      state.setProgress('Building enhanced deck…', 0.88);
      final buildResult = await api.buildDeck(
        notes: enhanced,
        deckName: deckName,
        classify: state.classify,
        mediaFilesB64: result.mediaFilesB64.isNotEmpty ? result.mediaFilesB64 : null,
      );

      state.totalCards = enhanced.length;
      state.setApkg(buildResult.bytes, dupesRemovedInBuild: buildResult.dupesRemoved);
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      state.setError(msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Enhance deck', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('AI enriches your cards with context, images, and smarter structure',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 20),

            // ── Drop zone ──────────────────────────────────────────────
            DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (d) async {
                setState(() => _dragging = false);
                final path = d.files.first.path;
                if (!path.endsWith('.apkg')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Drop an .apkg file')));
                  return;
                }
                final bytes = await File(path).readAsBytes();
                if (!mounted) return;
                setState(() { _fileName = path.split('/').last; _apkgBytes = bytes; });
              },
              child: GestureDetector(
                onTap: _pickApkg,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _dragging || _apkgBytes != null ? cs.primary : cs.outlineVariant,
                      width: _dragging ? 2 : 1.5,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    color: _dragging
                        ? cs.primaryContainer.withValues(alpha: 0.4)
                        : _apkgBytes != null
                            ? cs.primaryContainer.withValues(alpha: 0.15)
                            : cs.surfaceContainerLowest,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _dragging ? Icons.download_rounded
                            : _apkgBytes != null ? Icons.check_circle_rounded
                            : Icons.file_open_rounded,
                        size: 20,
                        color: _apkgBytes != null || _dragging ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _dragging ? 'Drop it!'
                            : _fileName ?? 'Tap or drop a deck (.apkg)',
                        style: tt.bodyMedium?.copyWith(
                          color: _apkgBytes != null ? cs.onSurface : cs.onSurfaceVariant,
                        ),
                      ),
                      if (_apkgBytes != null) ...[
                        const SizedBox(width: 8),
                        Text('· tap to change',
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ── Card style ─────────────────────────────────────────────
            _Label(icon: Icons.style_rounded, text: 'Card style'),
            const SizedBox(height: 8),
            _SegmentPicker<String>(
              options: const [
                ('cheesy_dorian',  'Cheesy Dorian'),
                ('anking',         'AnKing'),
                ('zanki',          'Zanki'),
                ('lightyear',      'Lightyear'),
                ('brosencephalon', 'Brosencephalon'),
                ('none',           'Enrich only'),
              ],
              value: _opts.cardStyle,
              onChanged: (v) => setState(() => _opts.cardStyle = v),
            ),

            const SizedBox(height: 20),

            // ── Content toggles ────────────────────────────────────────
            _Label(icon: Icons.auto_awesome_rounded, text: 'Add to cards'),
            const SizedBox(height: 8),
            _ToggleChips(
              options: const [
                ('clinical', Icons.biotech_rounded, 'Clinical context'),
                ('highyield', Icons.star_rounded, 'High-yield'),
                ('traps', Icons.warning_amber_rounded, 'Exam traps'),
                ('images', Icons.image_rounded, 'Images'),
                ('combine', Icons.merge_rounded, 'Combine'),
              ],
              selected: {
                if (_opts.addClinicalContext) 'clinical',
                if (_opts.addHighYield) 'highyield',
                if (_opts.addExamTraps) 'traps',
                if (_opts.addImages) 'images',
                if (_opts.combineCards) 'combine',
              },
              onToggle: (key) => setState(() {
                switch (key) {
                  case 'clinical': _opts.addClinicalContext = !_opts.addClinicalContext;
                  case 'highyield': _opts.addHighYield = !_opts.addHighYield;
                  case 'traps': _opts.addExamTraps = !_opts.addExamTraps;
                  case 'images': _opts.addImages = !_opts.addImages;
                  case 'combine': _opts.combineCards = !_opts.combineCards;
                }
              }),
            ),

            const SizedBox(height: 20),

            // ── Write mode ─────────────────────────────────────────────
            _Label(icon: Icons.edit_note_rounded, text: 'Write mode'),
            const SizedBox(height: 8),
            _SegmentPicker<String>(
              options: const [
                ('append',     'Add to extra'),
                ('empty_only', 'Fill blanks'),
                ('overwrite',  'Overwrite'),
              ],
              value: _opts.expansionMode,
              onChanged: (v) => setState(() => _opts.expansionMode = v),
            ),

            const SizedBox(height: 20),

            // ── Card format ────────────────────────────────────────────
            _Label(icon: Icons.transform_rounded, text: 'Card format'),
            const SizedBox(height: 8),
            _SegmentPicker<String>(
              options: const [
                ('keep',       'Keep original'),
                ('basic_extra','Basic + extra'),
                ('basic',      'Basic only'),
                ('cloze',      'Cloze'),
              ],
              value: _opts.targetFormat,
              onChanged: (v) => setState(() => _opts.targetFormat = v),
            ),

            const SizedBox(height: 20),

            // ── Depth ──────────────────────────────────────────────────
            _Label(icon: Icons.speed_rounded, text: 'Depth'),
            const SizedBox(height: 8),
            _SegmentPicker<String>(
              options: const [
                ('full',  'Full — all 5 sections'),
                ('quick', 'Quick — ~60% cheaper'),
              ],
              value: _opts.depth,
              onChanged: (v) => setState(() => _opts.depth = v),
            ),

            const SizedBox(height: 20),

            // ── Provider ───────────────────────────────────────────────
            _Label(icon: Icons.psychology_rounded, text: 'Provider'),
            const SizedBox(height: 8),
            _SegmentPicker<String>(
              options: const [
                ('anthropic', 'Claude'),
                ('openai',    'OpenAI'),
                ('ollama',    'Ollama (local)'),
              ],
              value: _opts.provider,
              onChanged: (v) {
                setState(() => _opts.provider = v);
                if (v == 'ollama') _loadOllamaModels();
              },
            ),
            const SizedBox(height: 8),
            if (_opts.provider == 'anthropic')
              _StaticModelPicker(
                models: EnhancementOptions.anthropicModels,
                value: _opts.anthropicModel,
                onChanged: (v) => setState(() => _opts.anthropicModel = v),
              )
            else if (_opts.provider == 'openai')
              _StaticModelPicker(
                models: EnhancementOptions.openaiModels,
                value: _opts.openaiModel,
                onChanged: (v) => setState(() => _opts.openaiModel = v),
              )
            else
              _OllamaModelPicker(
                models: _ollamaModels,
                loading: _ollamaLoading,
                value: _opts.ollamaModel,
                onChanged: (v) => setState(() => _opts.ollamaModel = v),
                onRefresh: _loadOllamaModels,
              ),

            const SizedBox(height: 28),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _enhance,
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: const Text('Enhance deck'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),

            Consumer<AppState>(
              builder: (_, state, __) => state.errorMessage != null
                ? Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline_rounded, size: 16, color: cs.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SelectableText(state.errorMessage!,
                              style: tt.bodySmall?.copyWith(color: cs.onErrorContainer)),
                          ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Label({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 13, color: cs.primary),
      const SizedBox(width: 5),
      Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: cs.primary, fontWeight: FontWeight.w600)),
    ]);
  }
}

class _SegmentPicker<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const _SegmentPicker({required this.options, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: options.map((opt) {
        final active = opt.$1 == value;
        return GestureDetector(
          onTap: () => onChanged(opt.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: active ? cs.primary : cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active ? cs.primary : cs.outlineVariant,
                width: 1,
              ),
            ),
            child: Text(opt.$2,
              style: tt.labelMedium?.copyWith(
                color: active ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _StaticModelPicker extends StatelessWidget {
  final List<(String, String)> models;
  final String value;
  final ValueChanged<String> onChanged;
  const _StaticModelPicker({required this.models, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final current = models.firstWhere((m) => m.$1 == value, orElse: () => models.first);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.smart_toy_rounded, size: 15, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: current.$1,
              isExpanded: true,
              items: models.map((m) => DropdownMenuItem(
                value: m.$1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(m.$2, style: tt.bodyMedium),
                  ],
                ),
              )).toList(),
              onChanged: (v) { if (v != null) onChanged(v); },
            ),
          ),
        ),
      ]),
    );
  }
}

class _OllamaModelPicker extends StatelessWidget {
  final List<String> models;
  final bool loading;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;
  const _OllamaModelPicker({
    required this.models, required this.loading, required this.value,
    required this.onChanged, required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    if (loading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(8),
          color: cs.surfaceContainerLow,
        ),
        child: Row(children: [
          SizedBox(width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
          const SizedBox(width: 10),
          Text('Loading models…', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      );
    }

    if (models.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: cs.errorContainer),
          borderRadius: BorderRadius.circular(8),
          color: cs.errorContainer.withValues(alpha: 0.3),
        ),
        child: Row(children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text('No models found — run: ollama pull mistral',
              style: tt.bodySmall?.copyWith(color: cs.onErrorContainer)),
          ),
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 16, color: cs.onSurfaceVariant),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onRefresh,
          ),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.smart_toy_rounded, size: 15, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: models.contains(value) ? value : models.first,
              isExpanded: true,
              items: models.map((m) => DropdownMenuItem(
                value: m,
                child: Text(m, style: tt.bodyMedium),
              )).toList(),
              onChanged: (v) { if (v != null) onChanged(v); },
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.refresh_rounded, size: 15, color: cs.onSurfaceVariant),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          tooltip: 'Refresh model list',
          onPressed: onRefresh,
        ),
      ]),
    );
  }
}

class _ToggleChips extends StatelessWidget {
  final List<(String, IconData, String)> options;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  const _ToggleChips({required this.options, required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: options.map((opt) {
        final active = selected.contains(opt.$1);
        return GestureDetector(
          onTap: () => onToggle(opt.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: active ? cs.secondaryContainer : cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: active ? cs.secondary : cs.outlineVariant,
                width: 1,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(opt.$2, size: 14,
                color: active ? cs.onSecondaryContainer : cs.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(opt.$3, style: tt.labelSmall?.copyWith(
                color: active ? cs.onSecondaryContainer : cs.onSurfaceVariant,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              )),
            ]),
          ),
        );
      }).toList(),
    );
  }
}
