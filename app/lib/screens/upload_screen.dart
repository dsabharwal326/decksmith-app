import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';
import '../widgets/scope_picker.dart';

// ── picked file record ──────────────────────────────────────────────────────

class _PickedFile {
  final String path;
  final String name;
  final bool isPdf;
  final bool isImage;
  _PickedFile({required this.path, required this.name, required this.isPdf, required this.isImage});

  static bool _isPdfPath(String p) => p.toLowerCase().endsWith('.pdf');
  static bool _isDocxPath(String p) => p.toLowerCase().endsWith('.docx');
  static bool _isApkgPath(String p) => p.toLowerCase().endsWith('.apkg');
  static bool _isImagePath(String p) {
    final lp = p.toLowerCase();
    return lp.endsWith('.png') || lp.endsWith('.jpg') || lp.endsWith('.jpeg') || lp.endsWith('.heic');
  }

  static bool isTextPath(String p) {
    final lp = p.toLowerCase();
    return lp.endsWith('.txt') || lp.endsWith('.tsv') || lp.endsWith('.csv');
  }

  static _PickedFile fromPath(String path) => _PickedFile(
    path: path,
    name: path.split('/').last,
    isPdf: _isPdfPath(path),
    isImage: _isImagePath(path),
  );

  bool get isDocx => _isDocxPath(path);
  bool get isApkg => _isApkgPath(path);
  bool get isText => !isPdf && !isImage && !isDocx && !isApkg;
}

// ── screen ──────────────────────────────────────────────────────────────────

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});
  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final _deckNameCtrl = TextEditingController(text: 'My Deck');
  final List<_PickedFile> _files = [];
  bool _draggingCard = false;
  bool _draggingApkg = false;
  bool _skipDupes = false;
  bool _questionMode = false;   // true = MCQ screenshot → cloze cards
  String? _detectedStep;

  @override
  void dispose() {
    _deckNameCtrl.dispose();
    super.dispose();
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  String _stepLabel(String step) => switch (step) {
    'step1' => 'USMLE Step 1 — Basic sciences',
    'step2' => 'USMLE Step 2 CK — Clinical knowledge',
    'step3' => 'USMLE Step 3 — Patient management',
    _ => step,
  };

  Future<void> _detectStep(String textSample) async {
    try {
      final step = await ApiService(context.read<AppState>()).detectStep(textSample);
      if (mounted) setState(() => _detectedStep = step);
    } catch (_) {}
  }

  void _suggestDeckName(String fileName) {
    final base = fileName.contains('.') ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName;
    final cleaned = base.replaceAll(RegExp(r'[_\-\.]+'), ' ').trim();
    final titled = cleaned.split(' ').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join(' ');
    if (titled.isNotEmpty) _deckNameCtrl.text = titled;
  }

  bool _isAcceptedPath(String path) {
    final lp = path.toLowerCase();
    return lp.endsWith('.txt') || lp.endsWith('.tsv') || lp.endsWith('.csv') ||
        lp.endsWith('.pdf') || lp.endsWith('.docx') || lp.endsWith('.apkg') ||
        lp.endsWith('.png') || lp.endsWith('.jpg') ||
        lp.endsWith('.jpeg') || lp.endsWith('.heic');
  }

  void _addFiles(List<String> paths) {
    bool addedFirst = _files.isEmpty;
    for (final path in paths) {
      if (!_isAcceptedPath(path)) continue;
      if (!_files.any((f) => f.path == path)) {
        final pf = _PickedFile.fromPath(path);
        _files.add(pf);
        if (addedFirst) {
          _suggestDeckName(pf.name);
          addedFirst = false;
        }
      }
    }
    _detectedStep = null;
  }

  // ── file pickers ─────────────────────────────────────────────────────────

  Future<void> _pickCardFiles() async {
    final state = context.read<AppState>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      allowMultiple: true,
      initialDirectory: state.lastPickerPath.isEmpty ? null : state.lastPickerPath,
    );
    if (result == null || result.files.isEmpty) return;
    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    state.lastPickerPath = File(paths.first).parent.path;
    await state.saveSettings();
    setState(() => _addFiles(paths));
    // detect step from first text file
    final firstText = _files.where((f) => f.isText).firstOrNull;
    if (firstText != null) {
      final text = await File(firstText.path).readAsString();
      _detectStep(text.substring(0, text.length.clamp(0, 2000)));
    }
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

  // ── build deck ────────────────────────────────────────────────────────────

  Future<void> _build() async {
    final state = context.read<AppState>();
    if (_files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least one card file first'), behavior: SnackBarBehavior.floating));
      return;
    }
    state.deckName = _deckNameCtrl.text.trim().isEmpty ? 'My Deck' : _deckNameCtrl.text.trim();
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);
    try {
      List<NoteModel> notes = [];

      // Handle binary files (PDF / DOCX / image) — all files processed and merged
      final binaryFiles = _files.where((f) => !f.isText).toList();
      for (int i = 0; i < binaryFiles.length; i++) {
        final bf = binaryFiles[i];
        final label = binaryFiles.length > 1 ? ' (${i + 1}/${binaryFiles.length})' : '';
        final bytes = await File(bf.path).readAsBytes();
        List<NoteModel> binaryNotes;
        if (bf.isPdf) {
          state.setProgress('Extracting PDF$label…', 0.05 + 0.3 * i / binaryFiles.length);
          binaryNotes = await api.importPdf(bytes);
        } else if (bf.isDocx) {
          state.setProgress('Extracting Word doc$label…', 0.05 + 0.3 * i / binaryFiles.length);
          binaryNotes = await api.importDocx(bytes);
        } else if (bf.isApkg) {
          state.setProgress('Reading Anki deck$label…', 0.05 + 0.3 * i / binaryFiles.length);
          binaryNotes = await api.importApkg(bytes);
        } else {
          final lp = bf.path.toLowerCase();
          final mediaType = lp.endsWith('.png') ? 'image/png'
              : lp.endsWith('.jpg') || lp.endsWith('.jpeg') ? 'image/jpeg'
              : 'image/heic';
          if (_questionMode) {
            state.setProgress('Analysing question$label…', 0.05 + 0.3 * i / binaryFiles.length);
            binaryNotes = await api.importQuestionImage(bytes, mediaType);
          } else {
            state.setProgress('Reading image$label…', 0.05 + 0.3 * i / binaryFiles.length);
            binaryNotes = await api.importImage(bytes, mediaType);
          }
        }
        notes = [...notes, ...binaryNotes];
      }

      // Handle text files — read and concatenate
      final textFiles = _files.where((f) => f.isText).toList();
      if (textFiles.isNotEmpty) {
        state.setProgress('Reading ${textFiles.length} file${textFiles.length > 1 ? 's' : ''}…', 0.1);
        final parts = <String>[];
        for (final tf in textFiles) {
          parts.add(await File(tf.path).readAsString());
        }
        final combined = parts.join('\n\n');
        state.cardText = combined;
        state.setProgress('Parsing cards…', 0.2);
        final textNotes = await api.parseCards(combined);
        notes = [...notes, ...textNotes];
      }

      if (_skipDupes && state.existingApkgBytes != null) {
        state.setProgress('Checking for duplicates…', 0.5);
        final dedupeResult = await api.dedupe(apkgBytes: state.existingApkgBytes!, notes: notes);
        notes = (dedupeResult['new_notes'] as List)
            .map((n) => NoteModel.fromJson(n as Map<String, dynamic>))
            .toList();
        state.dupesSkipped = dedupeResult['duplicate_count'] as int;
      }

      // Detect step from notes if we didn't already detect from a text file
      if (_detectedStep == null && notes.isNotEmpty) {
        final sample = notes.take(30).map((n) => '${n.front} ${n.back}').join(' ');
        _detectStep(sample.substring(0, sample.length.clamp(0, 2000)));
      }

      state.setProgress('Validating…', 0.8);
      final validation = await api.validate(notes);
      state.setReview(notes: notes, validation: validation);
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      state.setError(msg);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  // ── ui ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasFiles = _files.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Generate from file', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Drop one or more .txt, .tsv, .csv, .pdf, .docx, .apkg, or image files — all files are merged into one deck',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 16),

            // ── Image mode toggle ─────────────────────────────────────────
            Row(
              children: [
                Icon(Icons.image_search_rounded, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Text('Image mode:', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(width: 12),
                SegmentedButton<bool>(
                  style: SegmentedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    textStyle: tt.labelSmall,
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('General'), icon: Icon(Icons.auto_awesome_rounded, size: 14)),
                    ButtonSegment(value: true,  label: Text('Question screenshot'), icon: Icon(Icons.quiz_rounded, size: 14)),
                  ],
                  selected: {_questionMode},
                  onSelectionChanged: (s) => setState(() => _questionMode = s.first),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Drop zone ────────────────────────────────────────────────
            DropTarget(
              onDragEntered: (_) => setState(() => _draggingCard = true),
              onDragExited: (_) => setState(() => _draggingCard = false),
              onDragDone: (details) async {
                setState(() => _draggingCard = false);
                final paths = details.files.map((f) => f.path).toList();
                final valid = paths.where(_isAcceptedPath).toList();
                if (valid.isEmpty) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Drop .txt, .tsv, .csv, .pdf, .docx, .apkg, or image files'), behavior: SnackBarBehavior.floating));
                  return;
                }
                setState(() => _addFiles(valid));
                final firstText = _files.where((f) => f.isText).firstOrNull;
                if (firstText != null) {
                  final text = await File(firstText.path).readAsString();
                  if (mounted) _detectStep(text.substring(0, text.length.clamp(0, 2000)));
                }
              },
              child: GestureDetector(
                onTap: _pickCardFiles,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(vertical: hasFiles ? 20 : 36),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _draggingCard ? cs.primary : hasFiles ? cs.primary.withOpacity(0.7) : cs.outlineVariant,
                      width: _draggingCard ? 2 : 1.5,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    color: _draggingCard
                        ? cs.primaryContainer.withOpacity(0.4)
                        : hasFiles ? cs.primaryContainer.withOpacity(0.12) : cs.surfaceContainerLowest,
                  ),
                  child: hasFiles
                      ? _FileList(files: _files, cs: cs, tt: tt, onRemove: (f) => setState(() {
                          _files.remove(f);
                          if (_files.isEmpty) _detectedStep = null;
                        }))
                      : Column(children: [
                          Icon(Icons.upload_file_rounded, size: 32,
                            color: _draggingCard ? cs.primary : cs.onSurfaceVariant),
                          const SizedBox(height: 10),
                          Text(_draggingCard ? 'Drop it!'
                              : _questionMode ? 'Drop question screenshots'
                              : 'Tap or drop card files',
                            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                          const SizedBox(height: 4),
                          Text(_questionMode
                              ? 'PNG/JPG screenshots of MCQs → high-yield cloze cards'
                              : 'Anki text, TSV, CSV, PDF, DOCX, PNG/JPG — multi-file merges into one deck',
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withOpacity(0.6))),
                        ]),
                ),
              ),
            ),

            // Add more files button (when files already selected)
            if (hasFiles) ...[
              const SizedBox(height: 8),
              Row(children: [
                TextButton.icon(
                  onPressed: _pickCardFiles,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('Add more files'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
                if (_files.length > 1) ...[
                  const SizedBox(width: 8),
                  Text('${_files.length} files → 1 deck',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ]),
            ],

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
                      color: cs.onTertiaryContainer, fontWeight: FontWeight.w600)),
                ]),
              ),
            ],

            const SizedBox(height: 24),

            // ── Exam scope ──────────────────────────────────────────────
            const ScopePicker(),

            const SizedBox(height: 24),

            // ── Deck name ───────────────────────────────────────────────
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

            // ── Deduplicate ─────────────────────────────────────────────
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
              Text('Import an existing .apkg — cards already in that deck will be skipped.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
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
                    Expanded(child: Text(state.existingApkgName!,
                      style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis)),
                    GestureDetector(
                      onTap: state.clearExistingApkg,
                      child: Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant)),
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
                  label: Text(_draggingApkg ? 'Drop to import'
                      : state.existingApkgName != null ? 'Change .apkg'
                      : 'Import existing deck (.apkg)'),
                ),
              ),
            ],

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _build,
                icon: const Icon(Icons.preview_rounded, size: 18),
                label: const Text('Preview & build  →'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── file list widget ─────────────────────────────────────────────────────────

class _FileList extends StatelessWidget {
  final List<_PickedFile> files;
  final ColorScheme cs;
  final TextTheme tt;
  final void Function(_PickedFile) onRemove;
  const _FileList({required this.files, required this.cs, required this.tt, required this.onRemove});

  IconData _icon(_PickedFile f) {
    if (f.isPdf) return Icons.picture_as_pdf_rounded;
    if (f.isDocx) return Icons.description_rounded;
    if (f.isApkg) return Icons.style_rounded;
    if (f.isImage) return Icons.image_rounded;
    final ext = f.name.split('.').last.toLowerCase();
    if (ext == 'tsv') return Icons.table_rows_rounded;
    if (ext == 'csv') return Icons.grid_on_rounded;
    return Icons.text_snippet_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < files.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Row(children: [
              Icon(_icon(files[i]), size: 16, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(files[i].name,
                style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis)),
              GestureDetector(
                onTap: () => onRemove(files[i]),
                child: Icon(Icons.close_rounded, size: 15, color: cs.onSurfaceVariant)),
            ]),
          ],
        ],
      ),
    );
  }
}
