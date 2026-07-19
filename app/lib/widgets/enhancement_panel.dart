import 'package:flutter/material.dart';
import '../services/api_service.dart';

class EnhancementPanel extends StatelessWidget {
  final EnhancementOptions opts;
  final VoidCallback onChanged;
  const EnhancementPanel({super.key, required this.opts, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _toggle(context, 'Clinical context', 'Mechanism, pathophysiology, clinical relevance',
              opts.addClinicalContext, (v) { opts.addClinicalContext = v; onChanged(); }),
          _toggle(context, 'High-yield points', 'Key facts most likely to appear on exams',
              opts.addHighYield, (v) { opts.addHighYield = v; onChanged(); }),
          _toggle(context, 'Exam traps', 'Common pitfalls, wrong answers, mnemonics',
              opts.addExamTraps, (v) { opts.addExamTraps = v; onChanged(); }),
          _toggle(context, 'Add images', 'Relevant diagrams from Wikimedia Commons',
              opts.addImages, (v) { opts.addImages = v; onChanged(); }),
          _toggle(context, 'Combine related cards', 'Merge cards covering the same concept',
              opts.combineCards, (v) { opts.combineCards = v; onChanged(); }),
        ],
      ),
    );
  }

  Widget _toggle(BuildContext context, String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant)),
      value: value,
      onChanged: onChanged,
    );
  }
}
