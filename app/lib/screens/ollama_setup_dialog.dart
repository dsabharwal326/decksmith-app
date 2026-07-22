import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Models the user can pick for first-run download.
const _kModels = [
  (id: 'llama3.2:3b',  label: 'Llama 3.2 3B',  size: '~2 GB',  note: 'Recommended — fast, good quality'),
  (id: 'mistral:7b',   label: 'Mistral 7B',     size: '~4 GB',  note: 'Higher quality, slower'),
  (id: 'phi3:mini',    label: 'Phi-3 Mini',      size: '~2 GB',  note: 'Lightweight, quick responses'),
];

/// Check whether Ollama has any pulled model available.
Future<bool> ollamaHasModels() async {
  try {
    final res = await http
        .get(Uri.parse('http://localhost:11434/api/tags'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return false;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (body['models'] as List?)?.cast<Map>() ?? [];
    return models.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Shows the dialog if Ollama is up but has no models.
/// Returns silently if Ollama is unreachable or already has models.
Future<void> maybeShowOllamaSetup(BuildContext context) async {
  final hasModels = await ollamaHasModels();
  if (hasModels) return;
  if (!context.mounted) return;
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const OllamaSetupDialog(),
  );
}

class OllamaSetupDialog extends StatefulWidget {
  const OllamaSetupDialog({super.key});
  @override
  State<OllamaSetupDialog> createState() => _OllamaSetupDialogState();
}

class _OllamaSetupDialogState extends State<OllamaSetupDialog> {
  String _selected = _kModels[0].id;
  bool _pulling = false;
  double _progress = 0;
  String _statusText = '';
  String? _error;
  StreamSubscription? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _pull() async {
    setState(() { _pulling = true; _error = null; _progress = 0; _statusText = 'Starting download…'; });

    try {
      final req = http.Request('POST', Uri.parse('http://localhost:11434/api/pull'));
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({'name': _selected, 'stream': true});

      final client = http.Client();
      final streamed = await client.send(req);

      int completed = 0;
      int total = 0;

      final completer = Completer<void>();
      _sub = streamed.stream
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.trim().isEmpty) return;
          try {
            final j = jsonDecode(line) as Map<String, dynamic>;
            final status = j['status'] as String? ?? '';
            final c = j['completed'] as int?;
            final t = j['total'] as int?;
            if (c != null) completed = c;
            if (t != null && t > 0) total = t;
            final pct = total > 0 ? completed / total : 0.0;
            if (mounted) setState(() {
              _statusText = status;
              _progress = pct.clamp(0.0, 1.0);
            });
            if (status == 'success') completer.complete();
          } catch (_) {}
        },
        onDone: () { if (!completer.isCompleted) completer.complete(); },
        onError: (e) { if (!completer.isCompleted) completer.completeError(e); },
        cancelOnError: true,
      );

      await completer.future;
      client.close();

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() { _pulling = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return AlertDialog(
      title: Row(children: [
        Icon(Icons.smart_toy_rounded, color: cs.primary, size: 22),
        const SizedBox(width: 8),
        const Text('Set up AI model'),
      ]),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Decksmith uses a local AI model via Ollama. '
              'Pick one to download — it only happens once.',
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (!_pulling) ...[
              for (final m in _kModels)
                RadioListTile<String>(
                  value: m.id,
                  groupValue: _selected,
                  onChanged: (v) => setState(() => _selected = v!),
                  title: Text('${m.label}  ${m.size}',
                      style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  subtitle: Text(m.note, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
            ] else ...[
              Text(_statusText, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _progress > 0 ? '${(_progress * 100).toStringAsFixed(1)}%' : '',
                style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: tt.bodySmall?.copyWith(color: cs.error)),
            ],
          ],
        ),
      ),
      actions: [
        if (!_pulling)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Skip for now'),
          ),
        if (!_pulling)
          FilledButton(
            onPressed: _pull,
            child: const Text('Download model'),
          ),
      ],
    );
  }
}
