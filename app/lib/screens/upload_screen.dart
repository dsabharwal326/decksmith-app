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

  @override
  void dispose() {
    _deckNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCardFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'csv'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    final file = result.files.first;
    setState(() => _fileName = file.name);
    context.read<AppState>().cardText = String.fromCharCodes(file.bytes!);
  }

  Future<void> _pickApkg() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apkg'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    final file = result.files.first;
    context.read<AppState>().setExistingApkg(file.bytes!, file.name);
  }

  Future<void> _build() async {
    final state = context.read<AppState>();
    if (state.cardText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a card file first')));
      return;
    }
    state.deckName = _deckNameCtrl.text.trim().isEmpty ? 'My Deck' : _deckNameCtrl.text.trim();
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);
    try {
      state.setProgress('Parsing cards…', 0.1);
      var notes = await api.parseCards(state.cardText);

      if (state.existingApkgBytes != null) {
        state.setProgress('Checking for duplicates…', 0.3);
        final dedupeResult = await api.dedupe(apkgBytes: state.existingApkgBytes!, notes: notes);
        final newNotes = (dedupeResult['new_notes'] as List)
            .map((n) => NoteModel.fromJson(n as Map<String, dynamic>))
            .toList();
        state.dupesSkipped = dedupeResult['duplicate_count'] as int;
        notes = newNotes;
      }

      state.setProgress('Validating…', 0.5);
      final validation = await api.validate(notes);

      state.setProgress('Building deck…', 0.75);
      final apkg = await api.buildDeck(notes: notes, deckName: state.deckName, classify: state.classify);

      state.setResults(notes: notes, validation: validation, cards: notes.length, subdecks: []);
      state.setApkg(apkg);
    } catch (e) {
      state.setError(e.toString());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Upload cards', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Drop a .txt or .csv file with your cards', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),

          // ── Card file picker ──
          DropTarget(
            onDragEntered: (_) => setState(() => _draggingCard = true),
            onDragExited: (_) => setState(() => _draggingCard = false),
            onDragDone: (details) async {
              setState(() => _draggingCard = false);
              final path = details.files.first.path;
              if (!path.endsWith('.txt') && !path.endsWith('.csv')) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Drop a .txt or .csv file')));
                return;
              }
              final bytes = await File(path).readAsBytes();
              if (!mounted) return;
              setState(() => _fileName = path.split('/').last);
              context.read<AppState>().cardText = String.fromCharCodes(bytes);
            },
            child: GestureDetector(
              onTap: _pickCardFile,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 32),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _draggingCard
                        ? Theme.of(context).colorScheme.primary
                        : _fileName != null
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                    width: _draggingCard ? 2 : 1.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  color: _draggingCard
                      ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5)
                      : _fileName != null
                          ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                          : Theme.of(context).colorScheme.surfaceContainerLow,
                ),
                child: Column(
                  children: [
                    Icon(
                      _draggingCard ? Icons.download_rounded : _fileName != null ? Icons.check_circle_rounded : Icons.upload_file_rounded,
                      size: 36,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _draggingCard ? 'Drop it!' : _fileName ?? 'Tap or drop a card file (.txt or .csv)',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ── Deck name ──
          Text('Deck name', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _deckNameCtrl,
            decoration: const InputDecoration(
              hintText: 'e.g. Cardiology Block 2',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Auto-classify into subdecks'),
            value: state.classify,
            onChanged: state.setClassify,
            contentPadding: EdgeInsets.zero,
          ),

          const Divider(height: 28),

          // ── Dedup section ──
          Row(
            children: [
              Icon(Icons.layers_clear_rounded, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Skip duplicates', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text('optional', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Import an existing .apkg deck — cards already in that deck will be skipped.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),

          if (state.existingApkgName != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 16, color: Theme.of(context).colorScheme.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(state.existingApkgName!, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                  ),
                  GestureDetector(
                    onTap: state.clearExistingApkg,
                    child: Icon(Icons.close_rounded, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
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
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Drop an .apkg file')));
                return;
              }
              final bytes = await File(path).readAsBytes();
              if (!mounted) return;
              context.read<AppState>().setExistingApkg(bytes, path.split('/').last);
            },
            child: OutlinedButton.icon(
              onPressed: _pickApkg,
              icon: Icon(_draggingApkg ? Icons.download_rounded : Icons.file_open_rounded, size: 18),
              label: Text(_draggingApkg ? 'Drop to import' : state.existingApkgName != null ? 'Change .apkg' : 'Import existing deck (.apkg)'),
            ),
          ),

          const SizedBox(height: 24),

          // ── Build button ──
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _build,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Build deck'),
            ),
          ),
        ],
      ),
    );
  }
}
