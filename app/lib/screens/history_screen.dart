import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  Future<void> _redownload(BuildContext context, HistoryEntry entry) async {
    final state = context.read<AppState>();
    try {
      final safe = entry.deckName.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      final fileName = '$safe.apkg';

      String? savePath;
      if (state.defaultOutputPath.isNotEmpty) {
        savePath = '${state.defaultOutputPath}/$fileName';
      } else {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save deck as…',
          fileName: fileName,
          initialDirectory: state.lastPickerPath.isNotEmpty ? state.lastPickerPath : null,
        );
      }
      if (savePath == null) return;

      await File(savePath).writeAsBytes(entry.apkgData);

      final dir = savePath.substring(0, savePath.lastIndexOf('/'));
      state.lastPickerPath = dir;
      state.saveSettings();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved to $savePath'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Save failed: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final history = context.watch<AppState>().history;

    if (history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.history_rounded, size: 40, color: cs.outlineVariant),
            ),
            const SizedBox(height: 20),
            Text('No decks yet', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('Decks you build will appear here',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('History', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('${history.length} deck${history.length == 1 ? '' : 's'} built',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: history.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final entry = history[i];
              return Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.layers_rounded, size: 20, color: cs.onPrimaryContainer),
                  ),
                  title: Text(entry.deckName,
                    style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${entry.cardCount} cards  ·  ${_fmt(entry.date)}',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  trailing: FilledButton.tonalIcon(
                    onPressed: () => _redownload(context, entry),
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: const Text('Export'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _fmt(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${d.month}/${d.day}/${d.year}';
  }
}
