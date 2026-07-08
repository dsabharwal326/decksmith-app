import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _urlCtrl;
  late TextEditingController _keyCtrl;
  late String _provider;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _urlCtrl = TextEditingController(text: s.apiBaseURL);
    _keyCtrl = TextEditingController(text: s.serviceKey);
    _provider = s.selectedProvider;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final s = context.read<AppState>();
    s.apiBaseURL = _urlCtrl.text.trim();
    s.serviceKey = _keyCtrl.text.trim();
    s.selectedProvider = _provider;
    s.saveSettings();
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () { if (mounted) setState(() => _saved = false); });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),

          Text('Backend URL', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(hintText: 'http://localhost:8503', border: OutlineInputBorder()),
          ),

          const SizedBox(height: 16),
          Text('Service key', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(hintText: 'From SERVICE_API_KEY env var', border: OutlineInputBorder()),
          ),

          const SizedBox(height: 16),
          Text('AI provider', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _provider,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'anthropic', child: Text('Anthropic (Claude)')),
              DropdownMenuItem(value: 'openai', child: Text('OpenAI (GPT-4)')),
              DropdownMenuItem(value: 'stub', child: Text('Offline / stub')),
            ],
            onChanged: (v) => setState(() => _provider = v!),
          ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _save,
              icon: Icon(_saved ? Icons.check_rounded : Icons.save_rounded),
              label: Text(_saved ? 'Saved!' : 'Save settings'),
            ),
          ),
        ],
      ),
    );
  }
}
