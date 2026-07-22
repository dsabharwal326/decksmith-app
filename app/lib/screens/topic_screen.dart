import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';
import 'enhance_screen.dart' show EnhancementOptions;

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

// ── Shared pill widget ──────────────────────────────────────────────────────

class _Pill extends StatelessWidget {
  final String label;
  final String? subtitle;
  final String value;
  final String selected;
  final ValueChanged<String> onTap;
  const _Pill({required this.label, this.subtitle, required this.value, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final active = value == selected;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: active ? cs.primary : cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: active ? cs.primary : cs.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(label, style: tt.labelMedium?.copyWith(
                color: active ? cs.onPrimary : cs.onSurface,
                fontWeight: FontWeight.w700,
              )),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: tt.bodySmall?.copyWith(
                  color: active ? cs.onPrimary.withOpacity(0.8) : cs.onSurfaceVariant,
                  fontSize: 10,
                ), textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Screen ──────────────────────────────────────────────────────────────────

class TopicScreen extends StatefulWidget {
  const TopicScreen({super.key});
  @override
  State<TopicScreen> createState() => _TopicScreenState();
}

class _TopicScreenState extends State<TopicScreen> {
  final _topicCtrl   = TextEditingController();
  final _batchCtrl   = TextEditingController();
  final _tagCtrl     = TextEditingController();
  final _excludeCtrl = TextEditingController();

  String _specialty    = 'Any / General';
  int    _count        = 20;
  String _cardStyle    = 'cheesy_dorian';
  String _usmleStep    = 'step1';
  String _clozeDensity = 'recommended';
  bool   _mnemonics    = false;
  bool   _batchMode    = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _specialty    = p.getString('topic_specialty')     ?? 'Any / General';
      _count        = p.getInt('topic_count')            ?? 20;
      _cardStyle    = p.getString('topic_card_style')    ?? 'cheesy_dorian';
      _usmleStep    = p.getString('topic_usmle_step')    ?? 'step1';
      _clozeDensity = p.getString('topic_cloze_density') ?? 'recommended';
      _mnemonics    = p.getBool('topic_mnemonics')       ?? false;
      _tagCtrl.text     = p.getString('topic_tag_prefix')    ?? '';
      _excludeCtrl.text = p.getString('topic_exclude_topics') ?? '';
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await Future.wait([
      p.setString('topic_specialty',      _specialty),
      p.setInt   ('topic_count',          _count),
      p.setString('topic_card_style',     _cardStyle),
      p.setString('topic_usmle_step',     _usmleStep),
      p.setString('topic_cloze_density',  _clozeDensity),
      p.setBool  ('topic_mnemonics',      _mnemonics),
      p.setString('topic_tag_prefix',     _tagCtrl.text),
      p.setString('topic_exclude_topics', _excludeCtrl.text),
    ]);
  }

  void _set(VoidCallback fn) { setState(fn); _savePrefs(); }

  @override
  void dispose() {
    _topicCtrl.dispose();
    _batchCtrl.dispose();
    _tagCtrl.dispose();
    _excludeCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final isBatch = _batchMode;
    final topics = isBatch
        ? _batchCtrl.text.split('\n').map((t) => t.trim()).where((t) => t.isNotEmpty).toList()
        : [_topicCtrl.text.trim()];

    if (topics.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter at least one topic'), behavior: SnackBarBehavior.floating));
      return;
    }

    final state = context.read<AppState>();
    // Capture all values before setPhase unmounts this widget
    final specialty    = _specialty;
    final count        = _count;
    final cardStyle    = _cardStyle;
    final usmleStep    = _usmleStep;
    final clozeDensity = _clozeDensity;
    final mnemonics    = _mnemonics;
    final tagPrefix    = _tagCtrl.text.trim();
    final exclude      = _excludeCtrl.text.trim();
    final deckName     = isBatch ? 'Batch Deck' : _cleanDeckName(topics.first);

    _savePrefs();
    state.deckName = deckName;
    state.setPhase(AppPhase.processing);
    final api = ApiService(state);

    try {
      final allNotes = <NoteModel>[];

      for (int i = 0; i < topics.length; i++) {
        final pct = 0.05 + 0.85 * (i / topics.length);
        state.setProgress(
          topics.length == 1
              ? 'Generating cards with AI…'
              : 'Generating topic ${i + 1} of ${topics.length}: ${topics[i]}…',
          pct,
        );
        final notes = await api.generateTopic(
          topic: topics[i],
          specialty: specialty,
          count: count,
          cardStyle: cardStyle,
          usmleStep: usmleStep,
          clozeDensity: clozeDensity,
          tagPrefix: tagPrefix,
          excludeTopics: exclude,
          mnemonics: mnemonics,
        );
        allNotes.addAll(notes);
      }

      state.setProgress('Validating…', 0.92);
      final validation = await api.validate(allNotes);
      state.setReview(notes: allNotes, validation: validation);
    } catch (e) {
      state.setError(e.toString().replaceFirst('Exception: ', ''));
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
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Generate from topic', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('AI generates a full deck from a topic or keyword',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ])),
              // Batch mode toggle
              Row(children: [
                Text('Batch', style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(width: 4),
                Switch(
                  value: _batchMode,
                  onChanged: (v) => setState(() => _batchMode = v),
                ),
              ]),
            ]),
            const SizedBox(height: 20),

            // ── Topic input ────────────────────────────────────────────────
            Text(_batchMode ? 'Topics (one per line)' : 'Topic',
              style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            if (_batchMode)
              TextField(
                controller: _batchCtrl,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(
                  hintText: 'Heart failure pathophysiology\nAtrial fibrillation\nHypertension management',
                  border: OutlineInputBorder(),
                ),
              )
            else
              TextField(
                controller: _topicCtrl,
                decoration: const InputDecoration(
                  hintText: 'e.g. Heart failure pathophysiology',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                ),
              ),

            const SizedBox(height: 20),

            // ── Specialty ──────────────────────────────────────────────────
            Text('Specialty', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _specialty,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _specialties.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) { if (v != null) _set(() => _specialty = v); },
            ),

            const SizedBox(height: 20),

            // ── Card count ────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Cards per topic: $_count', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
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
                onChanged: (v) => _set(() => _count = v.round()),
              ),
            ),

            const Divider(height: 32),

            // ── Exam scope ────────────────────────────────────────────────
            Row(children: [
              Icon(Icons.school_rounded, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Exam scope', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _Pill(label: 'Step 1',    subtitle: 'Basic sciences',   value: 'step1', selected: _usmleStep, onTap: (v) => _set(() => _usmleStep = v)),
              const SizedBox(width: 8),
              _Pill(label: 'Step 2 CK', subtitle: 'Clinical dx & tx', value: 'step2', selected: _usmleStep, onTap: (v) => _set(() => _usmleStep = v)),
              const SizedBox(width: 8),
              _Pill(label: 'Step 3',    subtitle: 'Patient mgmt',     value: 'step3', selected: _usmleStep, onTap: (v) => _set(() => _usmleStep = v)),
            ]),

            const SizedBox(height: 20),

            // ── Cloze density ──────────────────────────────────────────────
            Row(children: [
              Icon(Icons.format_list_numbered_rounded, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Cloze deletions', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _Pill(label: 'Recommended', subtitle: 'AI decides', value: 'recommended', selected: _clozeDensity, onTap: (v) => _set(() => _clozeDensity = v)),
              const SizedBox(width: 8),
              _Pill(label: 'c1 only',  subtitle: '1 blank',  value: 'single', selected: _clozeDensity, onTap: (v) => _set(() => _clozeDensity = v)),
              const SizedBox(width: 8),
              _Pill(label: 'c1 + c2', subtitle: '2 blanks', value: 'double', selected: _clozeDensity, onTap: (v) => _set(() => _clozeDensity = v)),
              const SizedBox(width: 8),
              _Pill(label: 'c1–c3',   subtitle: '3 blanks', value: 'triple', selected: _clozeDensity, onTap: (v) => _set(() => _clozeDensity = v)),
            ]),

            const Divider(height: 32),

            // ── Card style ────────────────────────────────────────────────
            Row(children: [
              Icon(Icons.style_rounded, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Card style', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            ]),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: EnhancementOptions.cardStyles.map((opt) {
                final active = opt.$1 == _cardStyle;
                final label = opt.$2.contains(' — ') ? opt.$2.split(' — ').first : opt.$2;
                return GestureDetector(
                  onTap: () => _set(() => _cardStyle = opt.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: active ? cs.primary : cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: active ? cs.primary : cs.outlineVariant),
                    ),
                    child: Text(label,
                      style: tt.labelMedium?.copyWith(
                        color: active ? cs.onPrimary : cs.onSurfaceVariant,
                        fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                      )),
                  ),
                );
              }).toList(),
            ),

            const Divider(height: 32),

            // ── Advanced options ──────────────────────────────────────────
            Row(children: [
              Icon(Icons.tune_rounded, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Advanced', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
            ]),
            const SizedBox(height: 12),

            // Mnemonics toggle
            InkWell(
              onTap: () => _set(() => _mnemonics = !_mnemonics),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _mnemonics ? cs.primaryContainer.withOpacity(0.4) : cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _mnemonics ? cs.primary.withOpacity(0.5) : cs.outlineVariant,
                  ),
                ),
                child: Row(children: [
                  Icon(Icons.lightbulb_rounded, size: 16,
                    color: _mnemonics ? cs.primary : cs.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Embed mnemonics', style: tt.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _mnemonics ? cs.onSurface : cs.onSurfaceVariant,
                    )),
                    Text('AI adds acronyms / phrases for list-based facts',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
                  ])),
                  Switch(value: _mnemonics, onChanged: (v) => _set(() => _mnemonics = v)),
                ]),
              ),
            ),

            const SizedBox(height: 12),

            // Tag prefix
            Text('Tag prefix', style: tt.labelMedium?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            TextField(
              controller: _tagCtrl,
              onChanged: (_) => _savePrefs(),
              decoration: InputDecoration(
                hintText: 'e.g. Cardiology::HeartFailure',
                border: const OutlineInputBorder(),
                prefixIcon: Icon(Icons.label_rounded, size: 18, color: cs.onSurfaceVariant),
                helperText: 'Applied to every generated card as an Anki tag',
              ),
            ),

            const SizedBox(height: 12),

            // Exclude topics
            Text('Exclude topics', style: tt.labelMedium?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            TextField(
              controller: _excludeCtrl,
              onChanged: (_) => _savePrefs(),
              decoration: InputDecoration(
                hintText: 'e.g. pharmacology, drug doses',
                border: const OutlineInputBorder(),
                prefixIcon: Icon(Icons.block_rounded, size: 18, color: cs.onSurfaceVariant),
                helperText: 'Comma-separated — AI will skip these subtopics',
              ),
            ),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _generate,
                icon: const Icon(Icons.preview_rounded, size: 18),
                label: Text(_batchMode ? 'Generate batch & preview  →' : 'Generate & preview  →'),
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
