import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class ExportScreen extends StatelessWidget {
  const ExportScreen({super.key});

  Future<void> _save(BuildContext context) async {
    final state = context.read<AppState>();
    final data = state.builtApkgData;
    if (data == null) return;

    try {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final safe = state.deckName.replaceAll(RegExp(r'[^\w\s-]'), '').trim().replaceAll(' ', '_');
      final file = File('${dir.path}/$safe.apkg');
      await file.writeAsBytes(data);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text('Deck ready!', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('${state.totalCards} cards • "${state.deckName}"',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 32),
            SizedBox(
              width: 260,
              child: FilledButton.icon(
                onPressed: () => _save(context),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Save .apkg'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: 260,
              child: OutlinedButton.icon(
                onPressed: state.reset,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Build another deck'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
