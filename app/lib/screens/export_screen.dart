import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class ExportScreen extends StatelessWidget {
  const ExportScreen({super.key});

  Future<void> _save(BuildContext context) async {
    final state = context.read<AppState>();
    final data = state.builtApkgData;
    if (data == null) return;

    try {
      final safe = state.deckName.replaceAll(RegExp(r'[^\w\s-]'), '').trim().replaceAll(' ', '_');
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
      await File(savePath).writeAsBytes(data);

      final dir = savePath.substring(0, savePath.lastIndexOf('/'));
      state.lastPickerPath = dir;
      state.saveSettings();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved to $savePath'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(label: 'OK', onPressed: () {}),
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
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final sizeMb = ((state.builtApkgData?.lengthInBytes ?? 0) / 1024 / 1024);
    final sizeLabel = sizeMb < 0.1 ? '<0.1 MB' : '${sizeMb.toStringAsFixed(1)} MB';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Success badge ──────────────────────────────────────────
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.check_rounded, size: 38, color: cs.onPrimaryContainer),
              ),
              const SizedBox(height: 20),
              Text('Deck ready', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('Your Anki deck is built and ready to import',
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 28),

              // ── Stats card ─────────────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.layers_rounded, size: 18, color: cs.onSecondaryContainer),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(state.deckName,
                            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                          Text('.apkg  ·  $sizeLabel',
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _Stat(value: '${state.totalCards}', label: 'cards',
                          icon: Icons.style_rounded, cs: cs, tt: tt),
                        if (state.dupesSkipped > 0)
                          _Stat(value: '${state.dupesSkipped}', label: 'dupes skipped',
                            icon: Icons.filter_list_rounded, cs: cs, tt: tt),
                        if (state.subdeckCounts.isNotEmpty)
                          _Stat(value: '${state.subdeckCounts.length}', label: 'subdecks',
                            icon: Icons.account_tree_rounded, cs: cs, tt: tt),
                        _Stat(value: sizeLabel, label: 'file size',
                          icon: Icons.folder_rounded, cs: cs, tt: tt),
                      ],
                    ),
                    if (state.subdeckCounts.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: state.subdeckCounts.take(8).map((sub) {
                          final name = (sub['name'] as String?) ?? '';
                          final count = (sub['count'] as int?) ?? 0;
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: cs.secondaryContainer.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('$name  $count',
                              style: tt.labelSmall?.copyWith(color: cs.onSecondaryContainer)),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // ── Actions ────────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _save(context),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Save .apkg file'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: state.reset,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Build another deck'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final ColorScheme cs;
  final TextTheme tt;
  const _Stat({required this.value, required this.label, required this.icon,
    required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, size: 16, color: cs.primary),
      const SizedBox(height: 4),
      Text(value, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
      Text(label, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
    ],
  );
}
