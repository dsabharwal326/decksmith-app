import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});
  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final _deckNameCtrl = TextEditingController(text: 'My Deck');
  String? _fileName;
  bool _draggingCard = false;
  bool _draggingApkg = false;
  bool _isPdf = false;
  bool _isImage = false;
  bool _skipDupes = false;
  String? _detectedStep;   // null = not yet detected

  @override
  void dispose() {
    _deckNameCtrl.dispose();
    super.dispose();
  }

  String _stepLabel(String step) => switch (step) {
    'step1' => 'USMLE Step 1 — Basic sciences',
    'step2' => 'USMLE Step 2 CK — Clinical knowledge',
    'step3' => 'USMLE Step 3 — Patient management',
    _ => step,
  };

  Future<void> _detectStep(String textSample) async {
    try {
      final state = context.read<AppState>();
      final step = await ApiService(state).detectStep(textSample);
      if (mounted) setState(() => _detectedStep = step);
    } catch (_) {}
  }

  void _suggestDeckName(String fileName) {
    final base = fileName.contains('.') ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName;
    final cleaned = base.replaceAll(RegExp(r'[_\-\.]+'), ' ').trim();
    final titled = cleaned.split(' ').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join(' ');
    if (titled.isNotEmpty) _deckNameCtrl.text = titled;
  }

  Future<void> _pickCardFile() async {
    final state = context.read<AppState>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      initialDirectory: state.lastPickerPath.isEmpty ? null : state.lastPickerPath,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    if (path == null) return;
    state.lastPickerPath = File(path).parent.path;
    state.saveSettings();
    final lp = path.toLowerCase();
    final isPdf = lp.endsWith('.pdf');
    final isImage = lp.endsWith('.png') || lp.endsWith('.jpg') ||
        lp.endsWith('.jpeg') || lp.endsWith('.heic');
    if (isPdf || isImage) {
      state.cardText = path; // store path; bytes read in _build
    } else {
      state.cardText = await File(path).readAsString();
    }
    if (!mounted) return;
    setState(() { _fileName = file.name; _isPdf = isPdf; _isImage = isImage; _detectedStep = null; });
    _suggestDeckName(file.name);
    if (!isPdf && !isImage) _detectStep(state.cardText.substring(0, state.cardText.length.clamp(0, 2000)));
  }

  Future<void> _pickApkg() async {
    final state = context.read<AppState>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      initialDirectory: state.lastPickerPath.isEmpty ? null : state.lastPickerPath,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    if (path == null || !path.toLowerCase().endsWith('.apkg')) return;
    final bytes = await File(path).readAsBytes();
    if (!mounted) return;
    state.lastPickerPath = File(path).parent.path;
    state.saveSettings();
    state.setExistingApkg(bytes, file.name);
  }

  Future<void> _build() async {
    final state = context.read<AppState>();
    if (state.cardText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a card file first'), behavior: SnackBarBehavior.floating));
      return;
    }
    state.deckName = _deckNameCtrl.text.trim().isEmpty ? 'My Deck' : _deckNameCtrl.text.trim();
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);
    try {
      List<NoteModel> notes;
      if (_isPdf) {
        state.setProgress('Extracting PDF…', 0.1);
        final bytes = await File(state.cardText).readAsBytes();
        notes = await api.importPdf(bytes);
      } else if (_isImage) {
        state.setProgress('Reading image…', 0.1);
        final bytes = await File(state.cardText).readAsBytes();
        final path = state.cardText.toLowerCase();
        final mediaType = path.endsWith('.png') ? 'image/png'
            : path.endsWith('.jpg') || path.endsWith('.jpeg') ? 'image/jpeg'
            : 'image/heic';
        notes = await api.importImage(bytes, mediaType);
      } else {
        state.setProgress('Parsing cards…', 0.1);
        notes = await api.parseCards(state.cardText);
      }

      if (_skipDupes && state.existingApkgBytes != null) {
        state.setProgress('Checking for duplicates…', 0.4);
        final dedupeResult = await api.dedupe(apkgBytes: state.existingApkgBytes!, notes: notes);
        notes = (dedupeResult['new_notes'] as List)
            .map((n) => NoteModel.fromJson(n as Map<String, dynamic>))
            .toList();
        state.dupesSkipped = dedupeResult['duplicate_count'] as int;
      }

      state.setProgress('Validating…', 0.7);
      final validation = await api.validate(notes);

      state.setReview(notes: notes, validation: validation);
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      state.setError(msg);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Generate from file', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Drop a .txt, .csv, .pdf, or image to create Anki cards',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 24),

            // ── Card file drop zone ────────────────────────────────────
            DropTarget(
              onDragEntered: (_) => setState(() => _draggingCard = true),
              onDragExited: (_) => setState(() => _draggingCard = false),
              onDragDone: (details) async {
                setState(() => _draggingCard = false);
                final path = details.files.first.path;
                final lp = path.toLowerCase();
                final isPdf = lp.endsWith('.pdf');
                final isImage = lp.endsWith('.png') || lp.endsWith('.jpg') ||
                    lp.endsWith('.jpeg') || lp.endsWith('.heic');
                if (!lp.endsWith('.txt') && !lp.endsWith('.csv') && !isPdf && !isImage) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Drop a .txt, .csv, .pdf, or image file'), behavior: SnackBarBehavior.floating));
                  return;
                }
                final st = context.read<AppState>();
                if (isPdf || isImage) {
                  st.cardText = path;
                } else {
                  final bytes = await File(path).readAsBytes();
                  st.cardText = String.fromCharCodes(bytes);
                }
                if (!mounted) return;
                final name = path.split('/').last;
                setState(() { _fileName = name; _isPdf = isPdf; _isImage = isImage; _detectedStep = null; });
                _suggestDeckName(name);
                if (!isPdf && !isImage) _detectStep(st.cardText.substring(0, st.cardText.length.clamp(0, 2000)));
              },
              child: GestureDetector(
                onTap: _pickCardFile,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _draggingCard
                          ? cs.primary
                          : _fileName != null
                              ? cs.primary.withOpacity(0.7)
                              : cs.outlineVariant,
                      width: _draggingCard ? 2 : 1.5,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    color: _draggingCard
                        ? cs.primaryContainer.withOpacity(0.4)
                        : _fileName != null
                            ? cs.primaryContainer.withOpacity(0.12)
                            : cs.surfaceContainerLowest,
                  ),
                  child: Column(children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        _draggingCard
                            ? Icons.download_rounded
                            : _fileName != null
                                ? Icons.check_circle_rounded
                                : Icons.upload_file_rounded,
                        key: ValueKey(_draggingCard ? 'drag' : _fileName != null ? 'done' : 'empty'),
                        size: 32,
                        color: _fileName != null || _draggingCard ? cs.primary : cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _draggingCard
                          ? 'Drop it!'
                          : _fileName ?? 'Tap or drop a card file (.txt, .csv, .pdf, image)',
                      style: tt.bodyMedium?.copyWith(
                        color: _fileName != null ? cs.onSurface : cs.onSurfaceVariant,
                        fontWeight: _fileName != null ? FontWeight.w500 : FontWeight.normal,
                      ),
                    ),
                    if (_fileName == null) ...[
                      const SizedBox(height: 4),
                      Text('Anki text, CSV, PDF, PNG/JPG',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withOpacity(0.6))),
                    ] else ...[
                      const SizedBox(height: 4),
                      Text('Tap to change', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ]),
                ),
              ),
            ),

            if (_detectedStep != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: cs.tertiary.withOpacity(0.4)),
                ),
                child: Row(children: [
                  Icon(Icons.school_rounded, size: 16, color: cs.tertiary),
                  const SizedBox(width: 8),
                  Text('Detected scope: ${_stepLabel(_detectedStep!)}',
                    style: tt.bodySmall?.copyWith(
                      color: cs.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    )),
                ]),
              ),
            ],

            const SizedBox(height: 24),

            // ── Deck name ──────────────────────────────────────────────
            Text('Deck name', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: _deckNameCtrl,
              decoration: InputDecoration(
                hintText: 'e.g. Cardiology Block 2',
                border: const OutlineInputBorder(),
                prefixIcon: Icon(Icons.layers_rounded, size: 18, color: cs.onSurfaceVariant),
              ),
            ),

            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Auto-classify into subdecks'),
              subtitle: Text('Uses AI to group cards by topic',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              value: state.classify,
              onChanged: state.setClassify,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),

            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),

            // ── Deduplicate section ────────────────────────────────────
            Row(children: [
              Icon(Icons.layers_clear_rounded, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Skip duplicates', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              Switch(
                value: _skipDupes,
                onChanged: (v) {
                  setState(() => _skipDupes = v);
                  if (!v) state.clearExistingApkg();
                },
              ),
            ]),
            if (_skipDupes) ...[
            const SizedBox(height: 6),
            Text(
              'Import an existing .apkg — cards already in that deck will be skipped.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),

            if (state.existingApkgName != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: cs.outline.withOpacity(0.3)),
                ),
                child: Row(children: [
                  Icon(Icons.check_circle_rounded, size: 16, color: cs.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(state.existingApkgName!,
                      style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                  ),
                  GestureDetector(
                    onTap: state.clearExistingApkg,
                    child: Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant),
                  ),
                ]),
              ),
              const SizedBox(height: 8),
            ],

            DropTarget(
              onDragEntered: (_) => setState(() => _draggingApkg = true),
              onDragExited: (_) => setState(() => _draggingApkg = false),
              onDragDone: (details) async {
                setState(() => _draggingApkg = false);
                final path = details.files.first.path;
                if (!path.endsWith('.apkg')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Drop an .apkg file'), behavior: SnackBarBehavior.floating));
                  return;
                }
                final bytes = await File(path).readAsBytes();
                if (!mounted) return;
                context.read<AppState>().setExistingApkg(bytes, path.split('/').last);
              },
              child: OutlinedButton.icon(
                onPressed: _pickApkg,
                icon: Icon(_draggingApkg ? Icons.download_rounded : Icons.file_open_rounded, size: 16),
                label: Text(_draggingApkg
                    ? 'Drop to import'
                    : state.existingApkgName != null
                        ? 'Change .apkg'
                        : 'Import existing deck (.apkg)'),
              ),
            ),
            ], // end if (_skipDupes)

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _build,
                icon: const Icon(Icons.preview_rounded, size: 18),
                label: const Text('Preview & build  →'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
