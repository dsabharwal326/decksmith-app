import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

const _specialties = ['Any / General', 'Cardiology', 'Neurology', 'Pharmacology', 'Anatomy', 'Physiology', 'Pathology', 'Microbiology', 'Biochemistry', 'Immunology', 'Surgery', 'Internal Medicine', 'Pediatrics', 'Psychiatry', 'Obstetrics'];

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a topic first')));
      return;
    }
    final state = context.read<AppState>();
    state.deckName = _topicCtrl.text.trim();
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);
    try {
      state.setProgress('Generating cards with AI…', 0.3);
      final notes = await api.generateTopic(topic: _topicCtrl.text.trim(), specialty: _specialty, count: _count);

      state.setProgress('Building deck…', 0.8);
      final apkg = await api.buildDeck(notes: notes, deckName: state.deckName, classify: state.classify);

      state.setResults(notes: notes, validation: [], cards: notes.length, subdecks: []);
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
          Text('Generate from topic', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('AI generates a full deck from a topic name', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),

          Text('Topic', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _topicCtrl,
            decoration: const InputDecoration(hintText: 'e.g. Heart failure pathophysiology', border: OutlineInputBorder()),
          ),

          const SizedBox(height: 16),
          Text('Specialty', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _specialty,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: _specialties.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
            onChanged: (v) { if (v != null) setState(() => _specialty = v); },
          ),

          const SizedBox(height: 16),
          Text('Number of cards: $_count', style: Theme.of(context).textTheme.labelMedium),
          Slider(
            value: _count.toDouble(),
            min: 5,
            max: 50,
            divisions: 9,
            label: '$_count',
            onChanged: (v) => setState(() => _count = v.round()),
          ),

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Generate deck'),
            ),
          ),
        ],
      ),
    );
  }
}
