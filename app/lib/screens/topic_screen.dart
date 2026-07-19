import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

const _specialties = [
  'Any / General', 'Cardiology', 'Neurology', 'Pharmacology', 'Anatomy',
  'Physiology', 'Pathology', 'Microbiology', 'Biochemistry', 'Immunology',
  'Surgery', 'Internal Medicine', 'Pediatrics', 'Psychiatry', 'Obstetrics',
];

String _costEstimate(int count) {
  final tokens = count * 500;
  final dollars = tokens / 1_000_000 * 0.25;
  if (dollars < 0.01) return '≈ <\$0.01';
  return '≈ \$${dollars.toStringAsFixed(2)}';
}

String _cleanDeckName(String raw) => raw
    .replaceAll('_', ' ')
    .split(' ')
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');

class TopicScreen extends StatefulWidget {
  const TopicScreen({super.key});
  @override
  State<TopicScreen> createState() => _TopicScreenState();
}

class _TopicScreenState extends State<TopicScreen> {
  final _topicCtrl = TextEditingController();
  String _specialty = 'Any / General';
  int _count = 20;

  @override
  void dispose() {
    _topicCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_topicCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a topic first'), behavior: SnackBarBehavior.floating));
      return;
    }
    final state = context.read<AppState>();
    state.deckName = _cleanDeckName(_topicCtrl.text.trim());
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);
    try {
      state.setProgress('Generating cards with AI…', 0.3);
      var notes = await api.generateTopic(
        topic: _topicCtrl.text.trim(),
        specialty: _specialty,
        count: _count,
      );

      state.setProgress('Validating…', 0.7);
      final validation = await api.validate(notes);

      state.setReview(notes: notes, validation: validation);
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      state.setError(msg);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Generate from topic', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('AI generates a full deck from a topic or keyword',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 24),

            Text('Topic', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: _topicCtrl,
              decoration: const InputDecoration(
                hintText: 'e.g. Heart failure pathophysiology',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search_rounded, size: 18),
              ),
            ),

            const SizedBox(height: 20),

            Text('Specialty', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _specialty,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _specialties.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) { if (v != null) setState(() => _specialty = v); },
            ),

            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Cards: $_count', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Text(_costEstimate(_count),
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(showValueIndicator: ShowValueIndicator.always),
              child: Slider(
                value: _count.toDouble(), min: 5, max: 50, divisions: 9, label: '$_count',
                onChanged: (v) => setState(() => _count = v.round()),
              ),
            ),

            const Divider(height: 32),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _generate,
                icon: const Icon(Icons.preview_rounded, size: 18),
                label: const Text('Generate & preview  →'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
