import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
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

  @override
  void dispose() {
    _deckNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'csv'], withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final text = String.fromCharCodes(file.bytes!);
    if (!mounted) return;
    setState(() => _fileName = file.name);
    context.read<AppState>().cardText = text;
  }

  Future<void> _build() async {
    final state = context.read<AppState>();
    if (state.cardText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a file first')));
      return;
    }
    state.deckName = _deckNameCtrl.text.trim().isEmpty ? 'My Deck' : _deckNameCtrl.text.trim();
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);
    try {
      state.setProgress('Parsing cards…', 0.1);
      final notes = await api.parseCards(state.cardText);

      state.setProgress('Validating…', 0.35);
      final validation = await api.validate(notes);

      state.setProgress('Building deck…', 0.7);
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

          GestureDetector(
            onTap: _pickFile,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 36),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outline, style: BorderStyle.solid, width: 1.5),
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).colorScheme.surfaceContainerLow,
              ),
              child: Column(
                children: [
                  Icon(Icons.upload_file_rounded, size: 36, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 8),
                  Text(_fileName ?? 'Tap to pick a file (.txt or .csv)', style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),
          Text('Deck name', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _deckNameCtrl,
            decoration: const InputDecoration(hintText: 'e.g. Cardiology Block 2', border: OutlineInputBorder()),
          ),

          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Auto-classify into subdecks'),
            value: state.classify,
            onChanged: state.setClassify,
            contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 20),
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
