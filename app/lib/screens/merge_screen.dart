import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

class MergeScreen extends StatefulWidget {
  const MergeScreen({super.key});
  @override
  State<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends State<MergeScreen> {
  final _nameCtrl = TextEditingController(text: 'Merged Deck');
  Uint8List? _bytesA;
  Uint8List? _bytesB;
  String? _nameA;
  String? _nameB;
  bool _classify = true;
  bool _merging = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDeck(bool isA) async {
    final state = context.read<AppState>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      initialDirectory: state.lastPickerPath.isEmpty ? null : state.lastPickerPath,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    if (path == null || !path.toLowerCase().endsWith('.apkg')) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please pick an .apkg file'), behavior: SnackBarBehavior.floating));
      return;
    }
    final bytes = await File(path).readAsBytes();
    if (!mounted) return;
    state.lastPickerPath = File(path).parent.path;
    state.saveSettings();
    setState(() {
      if (isA) { _bytesA = bytes; _nameA = file.name; }
      else      { _bytesB = bytes; _nameB = file.name; }
    });
  }

  Future<void> _merge() async {
    if (_bytesA == null || _bytesB == null) return;
    final state = context.read<AppState>();
    final api = ApiService(state);
    final deckName = _nameCtrl.text.trim().isEmpty ? 'Merged Deck' : _nameCtrl.text.trim();
    setState(() => _merging = true);
    try {
      final result = await api.mergeDeck(
        apkgA: _bytesA!,
        apkgB: _bytesB!,
        deckName: deckName,
        classify: _classify,
      );
      if (!mounted) return;
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save merged deck',
        fileName: '${deckName.replaceAll(' ', '_')}.apkg',
      );
      if (savePath != null) {
        await File(savePath).writeAsBytes(result.bytes, flush: true);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Saved — ${result.totalNotes} cards'
            '${result.dupeCount > 0 ? ', ${result.dupeCount} duplicates removed' : ''}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ));
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final ready = _bytesA != null && _bytesB != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Merge decks', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Combine two .apkg files into one deck, deduplicating cards',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 28),

            // ── Deck A ─────────────────────────────────────────────────
            Text('Deck A', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            _DeckPicker(
              name: _nameA,
              onPick: () => _pickDeck(true),
              onClear: () => setState(() { _bytesA = null; _nameA = null; }),
              cs: cs, tt: tt,
            ),

            const SizedBox(height: 16),

            // Merge arrow
            Center(
              child: Icon(Icons.merge_rounded, size: 32, color: cs.onSurfaceVariant.withOpacity(0.5)),
            ),

            const SizedBox(height: 16),

            // ── Deck B ─────────────────────────────────────────────────
            Text('Deck B', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            _DeckPicker(
              name: _nameB,
              onPick: () => _pickDeck(false),
              onClear: () => setState(() { _bytesB = null; _nameB = null; }),
              cs: cs, tt: tt,
            ),

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 20),

            // ── Output name ────────────────────────────────────────────
            Text('Output deck name', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.layers_rounded, size: 18),
              ),
            ),

            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Auto-classify into subdecks'),
              subtitle: Text('Uses AI to group cards by topic',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              value: _classify,
              onChanged: (v) => setState(() => _classify = v),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: ready && !_merging ? _merge : null,
                icon: _merging
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.merge_type_rounded, size: 18),
                label: Text(ready ? 'Merge & download  →' : 'Pick both decks to merge'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeckPicker extends StatelessWidget {
  final String? name;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final ColorScheme cs;
  final TextTheme tt;
  const _DeckPicker({required this.name, required this.onPick, required this.onClear, required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) {
    if (name != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cs.secondaryContainer.withOpacity(0.4),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.secondary.withOpacity(0.5)),
        ),
        child: Row(children: [
          Icon(Icons.check_circle_rounded, size: 18, color: cs.secondary),
          const SizedBox(width: 10),
          Expanded(child: Text(name!, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
          GestureDetector(onTap: onClear, child: Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant)),
        ]),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPick,
      icon: const Icon(Icons.file_open_rounded, size: 16),
      label: const Text('Pick .apkg file'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 48),
        alignment: Alignment.centerLeft,
      ),
    );
  }
}
