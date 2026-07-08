import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  Future<void> _redownload(BuildContext context, HistoryEntry entry) async {
    try {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final safe = entry.deckName.replaceAll(RegExp(r'[^\w\s-]'), '').trim().replaceAll(' ', '_');
      final file = File('${dir.path}/$safe.apkg');
      await file.writeAsBytes(entry.apkgData);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = context.watch<AppState>().history;
    if (history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 48, color: Theme.of(context).colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text('No decks built yet', style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: history.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final entry = history[i];
        return ListTile(
          leading: const Icon(Icons.layers_rounded),
          title: Text(entry.deckName),
          subtitle: Text('${entry.cardCount} cards • ${_fmt(entry.date)}'),
          trailing: IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Re-download',
            onPressed: () => _redownload(context, entry),
          ),
        );
      },
    );
  }

  String _fmt(DateTime d) => '${d.month}/${d.day}/${d.year}';
}
