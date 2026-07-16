import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

const _expansionModes = [
  ('append', 'Add extra context', 'Keeps all existing content, adds clinical context and high-yield points to the extra field'),
  ('empty_only', 'Fill blanks only', 'Only fills cards that are missing a back or extra — leaves complete cards alone'),
  ('overwrite', 'Full rewrite', 'AI rewrites backs and extras for every card using the augmentation model'),
];

class EnhanceScreen extends StatefulWidget {
  const EnhanceScreen({super.key});
  @override
  State<EnhanceScreen> createState() => _EnhanceScreenState();
}

class _EnhanceScreenState extends State<EnhanceScreen> {
  String? _fileName;
  Uint8List? _apkgBytes;
  String _mode = 'append';

  Future<void> _pickApkg() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apkg'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _fileName = result.files.first.name;
      _apkgBytes = result.files.first.bytes;
    });
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

      if (notes.isEmpty) {
        state.setError('No cards found in this deck');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No cards found in this deck')));
        return;
      }

      state.setProgress('Generating AI enhancements (${notes.length} cards)…', 0.3);
      final proposals = await api.augmentGenerate(notes);

      state.setProgress('Applying enhancements…', 0.7);
      final acceptedIndices = List.generate(proposals.length, (i) => i);
      final enhanced = await api.augmentApply(
        notes: notes,
        proposals: proposals,
        acceptedIndices: acceptedIndices,
        expansionMode: _mode,
      );

      state.setProgress('Building enhanced deck…', 0.88);
      final apkg = await api.buildDeck(notes: enhanced, deckName: deckName, classify: state.classify);

      state.setResults(notes: enhanced, validation: [], cards: enhanced.length, subdecks: []);
      state.setApkg(apkg);
    } catch (e) {
      state.setError(e.toString());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Enhance existing deck', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('AI adds clinical context, high-yield points, and exam traps to your existing cards',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 24),

          // ── Deck picker ──
          GestureDetector(
            onTap: _pickApkg,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 32),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _apkgBytes != null
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(12),
                color: _apkgBytes != null
                    ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                    : Theme.of(context).colorScheme.surfaceContainerLow,
              ),
              child: Column(
                children: [
                  Icon(
                    _apkgBytes != null ? Icons.check_circle_rounded : Icons.file_open_rounded,
                    size: 36,
                    color: _apkgBytes != null
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _fileName ?? 'Tap to pick a deck (.apkg)',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── Enhancement mode ──
          Text('Enhancement mode', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          ..._expansionModes.map((m) => _ModeCard(
            value: m.$1,
            title: m.$2,
            description: m.$3,
            selected: _mode == m.$1,
            onTap: () => setState(() => _mode = m.$1),
          )),

          const SizedBox(height: 24),

          // ── Enhance button ──
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _apkgBytes != null ? _enhance : null,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Enhance deck'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final String value;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.value,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline.withOpacity(0.5),
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
          color: selected
              ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.25)
              : Theme.of(context).colorScheme.surface,
        ),
        child: Row(
          children: [
            Radio<String>(
              value: value,
              groupValue: selected ? value : '',
              onChanged: (_) => onTap(),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(description, style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
