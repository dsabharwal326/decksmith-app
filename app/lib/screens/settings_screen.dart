import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';
import '../services/backend_launcher.dart';

export '../models/app_state.dart' show ViewMode;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _anthropicKeyCtrl;
  late TextEditingController _openaiKeyCtrl;
  late TextEditingController _backendPathCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _ollamaCtrl;
  late String _provider;
  late String _depth;
  late String _outputPath;
  bool _saved = false;
  bool _showAnthropic = false;
  bool _showOpenAI = false;
  bool? _ollamaReachable;
  bool _checkingOllama = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _anthropicKeyCtrl = TextEditingController(text: s.anthropicApiKey);
    _openaiKeyCtrl    = TextEditingController(text: s.openaiApiKey);
    _backendPathCtrl  = TextEditingController(text: s.backendPath);
    _urlCtrl          = TextEditingController(text: s.apiBaseURL);
    _ollamaCtrl       = TextEditingController(text: s.defaultOllamaModel);
    _provider   = s.selectedProvider;
    _depth      = s.defaultDepth;
    _outputPath = s.defaultOutputPath;
    if (s.selectedProvider == 'ollama') _checkOllama();
  }

  @override
  void dispose() {
    _anthropicKeyCtrl.dispose();
    _openaiKeyCtrl.dispose();
    _backendPathCtrl.dispose();
    _urlCtrl.dispose();
    _ollamaCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkOllama() async {
    setState(() { _checkingOllama = true; _ollamaReachable = null; });
    final models = await ApiService(context.read<AppState>()).ollamaModels();
    if (!mounted) return;
    setState(() { _checkingOllama = false; _ollamaReachable = models.isNotEmpty; });
  }

  Future<void> _pickOutputFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Default output folder');
    if (path != null) setState(() => _outputPath = path);
  }

  Future<void> _pickBackendPath() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Locate api.py',
      type: FileType.custom,
      allowedExtensions: ['py'],
    );
    if (result != null && result.files.first.path != null) {
      setState(() => _backendPathCtrl.text = result.files.first.path!);
    }
  }

  void _save() {
    final s = context.read<AppState>();
    s.anthropicApiKey  = _anthropicKeyCtrl.text.trim();
    s.openaiApiKey     = _openaiKeyCtrl.text.trim();
    s.backendPath      = _backendPathCtrl.text.trim();
    s.apiBaseURL       = _urlCtrl.text.trim().isEmpty ? 'http://localhost:8503' : _urlCtrl.text.trim();
    s.selectedProvider = _provider;
    s.defaultOllamaModel = _ollamaCtrl.text.trim().isEmpty ? 'mistral' : _ollamaCtrl.text.trim();
    s.defaultDepth     = _depth;
    s.defaultOutputPath = _outputPath;
    s.saveSettings();
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () { if (mounted) setState(() => _saved = false); });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Settings', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Configure backend, API keys, and defaults',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 32),

            // ── Backend ─────────────────────────────────────────────────
            _SectionLabel(icon: Icons.terminal_rounded, label: 'Backend'),
            const SizedBox(height: 12),
            _BackendControl(),
            const SizedBox(height: 12),
            _Field(
              label: 'Backend URL',
              child: TextField(controller: _urlCtrl, decoration: _dec('http://localhost:8503')),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Backend path (api.py)',
              hint: 'Leave empty to skip auto-launch',
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _backendPathCtrl,
                    decoration: _dec('/path/to/api.py'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickBackendPath,
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('Browse'),
                ),
              ]),
            ),

            const SizedBox(height: 28),

            // ── API keys ────────────────────────────────────────────────
            _SectionLabel(icon: Icons.key_rounded, label: 'API keys'),
            const SizedBox(height: 4),
            Text('Keys are stored locally and sent only to your own backend.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            _Field(
              label: 'Anthropic (Claude)',
              child: TextField(
                controller: _anthropicKeyCtrl,
                obscureText: !_showAnthropic,
                decoration: _dec('sk-ant-…').copyWith(
                  prefixIcon: const Icon(Icons.vpn_key_rounded, size: 16),
                  suffixIcon: IconButton(
                    icon: Icon(_showAnthropic ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 16),
                    onPressed: () => setState(() => _showAnthropic = !_showAnthropic),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'OpenAI',
              child: TextField(
                controller: _openaiKeyCtrl,
                obscureText: !_showOpenAI,
                decoration: _dec('sk-…').copyWith(
                  prefixIcon: const Icon(Icons.vpn_key_rounded, size: 16),
                  suffixIcon: IconButton(
                    icon: Icon(_showOpenAI ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 16),
                    onPressed: () => setState(() => _showOpenAI = !_showOpenAI),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),

            // ── AI provider ─────────────────────────────────────────────
            _SectionLabel(icon: Icons.psychology_rounded, label: 'Default AI provider'),
            const SizedBox(height: 12),
            _SegmentRow(
              options: const [
                ('anthropic', 'Claude'),
                ('openai',    'OpenAI'),
                ('ollama',    'Ollama'),
              ],
              selected: _provider,
              onSelect: (v) {
                setState(() => _provider = v);
                if (v == 'ollama') _checkOllama();
              },
            ),
            if (_provider == 'ollama') ...[
              const SizedBox(height: 12),
              _Field(
                label: 'Ollama model',
                hint: 'Must be pulled locally: ollama pull <model>',
                child: TextField(controller: _ollamaCtrl, decoration: _dec('mistral')),
              ),
              const SizedBox(height: 10),
              Row(children: [
                if (_checkingOllama)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                else if (_ollamaReachable == true)
                  _StatusChip(label: 'Ollama running', color: Colors.green)
                else if (_ollamaReachable == false)
                  _StatusChip(label: 'Ollama not found', color: Colors.red)
                else
                  const SizedBox.shrink(),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _checkOllama,
                  icon: const Icon(Icons.refresh_rounded, size: 15),
                  label: const Text('Check', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ]),
            ],

            const SizedBox(height: 28),

            // ── Enhancement defaults ────────────────────────────────────
            _SectionLabel(icon: Icons.auto_awesome_rounded, label: 'Enhancement defaults'),
            const SizedBox(height: 12),
            _Field(
              label: 'Default depth',
              child: _SegmentRow(
                options: const [
                  ('full',  'Full — all 5 sections'),
                  ('quick', 'Quick — ~60% cheaper'),
                ],
                selected: _depth,
                onSelect: (v) => setState(() => _depth = v),
              ),
            ),

            const SizedBox(height: 28),

            // ── Appearance ──────────────────────────────────────────────
            _SectionLabel(icon: Icons.view_sidebar_rounded, label: 'Appearance'),
            const SizedBox(height: 12),
            _Field(
              label: 'Sidebar mode',
              child: Consumer<AppState>(
                builder: (_, state, __) => _SegmentRow(
                  options: const [
                    ('compact', 'Compact'),
                    ('hybrid',  'Hybrid'),
                    ('full',    'Full'),
                  ],
                  selected: state.viewMode.name,
                  onSelect: (v) {
                    state.viewMode = ViewMode.values.byName(v);
                    state.saveSettings();
                  },
                ),
              ),
            ),

            const SizedBox(height: 28),

            // ── Output ──────────────────────────────────────────────────
            _SectionLabel(icon: Icons.folder_rounded, label: 'Output'),
            const SizedBox(height: 12),
            _Field(
              label: 'Default save folder',
              hint: 'Leave empty to be prompted each time',
              child: Row(children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outline),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _outputPath.isEmpty ? 'Ask every time' : _outputPath,
                      style: tt.bodyMedium?.copyWith(
                        color: _outputPath.isEmpty ? cs.onSurfaceVariant : cs.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickOutputFolder,
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('Browse'),
                ),
                if (_outputPath.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    tooltip: 'Clear',
                    onPressed: () => setState(() => _outputPath = ''),
                  ),
                ],
              ]),
            ),

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: Icon(_saved ? Icons.check_rounded : Icons.save_rounded, size: 18),
                label: Text(_saved ? 'Saved' : 'Save settings'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),

            const SizedBox(height: 32),
            _CacheInfo(),
          ],
        ),
      ),
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    border: const OutlineInputBorder(),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
  );
}

// ── Backend status control ────────────────────────────────────────────────────

class _BackendControl extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final status = state.backendStatus;

    final (color, label, icon) = switch (status) {
      BackendStatus.running  => (Colors.green,  'Running on ${state.apiBaseURL}', Icons.check_circle_rounded),
      BackendStatus.starting => (Colors.orange, 'Starting…',                      Icons.pending_rounded),
      BackendStatus.offline  => (Colors.red,    'Offline',                        Icons.cancel_rounded),
      BackendStatus.unknown  => (cs.onSurfaceVariant, 'Checking…',               Icons.help_outline_rounded),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: tt.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w500)),
        ),
        const SizedBox(width: 8),
        if (status == BackendStatus.offline || status == BackendStatus.unknown) ...[
          OutlinedButton.icon(
            onPressed: () => state.launchBackend(),
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: const Text('Start', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ] else if (status == BackendStatus.running) ...[
          OutlinedButton.icon(
            onPressed: () => state.refreshBackendStatus(),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Check', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ],
      ]),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionLabel({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 15, color: cs.primary),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: cs.primary, fontWeight: FontWeight.w600)),
      const SizedBox(width: 8),
      Expanded(child: Divider(color: cs.outlineVariant)),
    ]);
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String? hint;
  final Widget child;
  const _Field({required this.label, required this.child, this.hint});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500)),
      if (hint != null) ...[
        const SizedBox(height: 2),
        Text(hint!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
      const SizedBox(height: 6),
      child,
    ]);
  }
}

class _SegmentRow extends StatelessWidget {
  final List<(String, String)> options;
  final String selected;
  final ValueChanged<String> onSelect;
  const _SegmentRow({required this.options, required this.selected, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: options.map((opt) {
        final active = opt.$1 == selected;
        return GestureDetector(
          onTap: () => onSelect(opt.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: active ? cs.primaryContainer : cs.surfaceContainerLow,
              border: Border.all(color: active ? cs.primary : cs.outlineVariant, width: active ? 1.5 : 1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(opt.$2, style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            )),
          ),
        );
      }).toList(),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 7, color: color),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
    ]),
  );
}

class _CacheInfo extends StatefulWidget {
  @override
  State<_CacheInfo> createState() => _CacheInfoState();
}

class _CacheInfoState extends State<_CacheInfo> {
  int? _count;
  bool _loading = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final stats = await ApiService(context.read<AppState>()).cacheStats();
      if (!mounted) return;
      setState(() { _count = stats['cached_cards'] as int?; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    try { await ApiService(context.read<AppState>()).cacheClean(); } catch (_) {}
    if (!mounted) return;
    setState(() => _clearing = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(children: [
        Icon(Icons.storage_rounded, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Enhancement cache', style: tt.labelMedium?.copyWith(fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            if (_loading)
              Text('Loading…', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
            else
              Text(
                _count == null
                  ? 'Cache unavailable (backend offline?)'
                  : '$_count card${_count == 1 ? '' : 's'} cached — re-runs are free',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
          ]),
        ),
        if (!_loading && _count != null && _count! > 0) ...[
          const SizedBox(width: 8),
          _clearing
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                tooltip: 'Clear cache',
                color: cs.error,
                onPressed: _clear,
              ),
        ],
      ]),
    );
  }
}
