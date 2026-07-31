import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/app_state.dart';

class EnhancementOptions {
  bool combineCards;
  bool addImages;
  bool addClinicalContext;
  bool addHighYield;
  bool addExamTraps;
  String targetFormat; // keep | basic | cloze | basic_extra
  String expansionMode; // append | empty_only | overwrite

  String depth;
  String provider;
  String ollamaModel;
  String anthropicModel;
  String openaiModel;

  static const anthropicModels = [
    ('claude-haiku-4-5-20251001', 'Haiku 4.5 — fast & cheap'),
    ('claude-sonnet-4-5',         'Sonnet 4.5 — balanced'),
    ('claude-sonnet-5',           'Sonnet 5 — best quality'),
    ('claude-opus-4-8',           'Opus 4.8 — most powerful'),
  ];

  static const openaiModels = [
    ('gpt-4o-mini', 'GPT-4o mini — fast & cheap'),
    ('gpt-4o',      'GPT-4o — best quality'),
  ];

  EnhancementOptions({
    this.combineCards = false,
    this.addImages = false,
    this.addClinicalContext = true,
    this.addHighYield = true,
    this.addExamTraps = true,
    this.targetFormat = 'keep',
    this.expansionMode = 'append',
    this.depth = 'full',
    this.provider = 'anthropic',
    this.ollamaModel = 'mistral',
    this.anthropicModel = 'claude-haiku-4-5-20251001',
    this.openaiModel = 'gpt-4o-mini',
    this.cardStyle = 'cheesy_dorian',
  });

  String cardStyle; // none | cheesy_dorian | anking | zanki | lightyear | brosencephalon

  static const cardStyles = [
    ('cheesy_dorian', 'Cheesy Dorian — clinical scenario cloze'),
    ('anking',        'AnKing — atomic, one-fact cloze'),
    ('zanki',         'Zanki — ultra-atomic, high volume'),
    ('lightyear',     'Lightyear — concept-relationship'),
    ('brosencephalon','Brosencephalon — textbook dense'),
    ('none',          'No style rewrite — enrich only'),
  ];

  Map<String, dynamic> toJson() => {
    'combine_cards': combineCards,
    'add_images': addImages,
    'add_clinical_context': addClinicalContext,
    'add_high_yield': addHighYield,
    'add_exam_traps': addExamTraps,
    'target_format': targetFormat,
    'expansion_mode': expansionMode,
    'depth': depth,
    'provider': provider,
    'ollama_model': ollamaModel,
    'anthropic_model': anthropicModel,
    'openai_model': openaiModel,
    'card_style': cardStyle,
  };
}

class AugmentGenerateResult {
  final List<Map<String, dynamic>> proposals;
  final List<NoteModel> notes;
  final Map<String, String> mediaFilesB64;

  AugmentGenerateResult({
    required this.proposals,
    required this.notes,
    required this.mediaFilesB64,
  });
}

class ApiService {
  final AppState state;
  ApiService(this.state);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-Service-Key': state.serviceKey,
    if (state.anthropicApiKey.isNotEmpty) 'X-Anthropic-Key': state.anthropicApiKey,
    if (state.openaiApiKey.isNotEmpty)    'X-Openai-Key':    state.openaiApiKey,
  };

  String get _base => state.apiBaseURL.replaceAll(RegExp(r'/$'), '');

  Future<void> checkHealth() async {
    final res = await http.get(Uri.parse('$_base/health'), headers: _headers).timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) throw Exception('Server unreachable');
  }

  Future<List<NoteModel>> parseCards(String text) async {
    final res = await http.post(Uri.parse('$_base/parse'), headers: _headers, body: jsonEncode({'text': text}));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['notes'] as List).map((n) => NoteModel.fromJson(n as Map<String, dynamic>)).toList();
  }

  Future<List<ValidationResult>> validate(List<NoteModel> notes) async {
    final res = await http.post(Uri.parse('$_base/validate'), headers: _headers, body: jsonEncode({'notes': _serializeNotes(notes)}));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['results'] as List).map((r) => ValidationResult.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<({Uint8List bytes, int dupesRemoved})> buildDeck({
    required List<NoteModel> notes,
    required String deckName,
    required bool classify,
    Map<String, String>? mediaFilesB64,
  }) async {
    final body = <String, dynamic>{
      'notes': _serializeNotes(notes),
      'deck_name': deckName,
      'classify': classify,
    };
    if (mediaFilesB64 != null && mediaFilesB64.isNotEmpty) {
      body['media_files_b64'] = mediaFilesB64;
    }
    final res = await http.post(
      Uri.parse('$_base/build'),
      headers: _headers,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    final dupesRemoved = int.tryParse(res.headers['x-dupes-removed'] ?? '0') ?? 0;
    return (bytes: res.bodyBytes, dupesRemoved: dupesRemoved);
  }

  Future<List<NoteModel>> generateTopic({
    required String topic,
    required String specialty,
    required int count,
    required String cardStyle,
    required String usmleStep,
    required String clozeDensity,
    String tagPrefix = '',
    String excludeTopics = '',
    bool mnemonics = false,
  }) async {
    final res = await http.post(
      Uri.parse('$_base/topic/generate'),
      headers: _headers,
      body: jsonEncode({
        'topic': topic, 'specialty': specialty, 'card_count': count,
        'provider': state.selectedProvider, 'card_style': cardStyle,
        'usmle_step': usmleStep, 'cloze_density': clozeDensity,
        'tag_prefix': tagPrefix, 'exclude_topics': excludeTopics,
        'mnemonics': mnemonics,
      }),
    ).timeout(const Duration(seconds: 180));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['notes'] as List).map((n) => NoteModel.fromJson(n as Map<String, dynamic>)).toList();
  }

  Future<NoteModel?> regenerateCard({
    required String front,
    required String topic,
    String specialty = '',
    String cardStyle = 'none',
    String usmleStep = 'step1',
  }) async {
    final res = await http.post(
      Uri.parse('$_base/topic/regenerate_card'),
      headers: _headers,
      body: jsonEncode({
        'front': front, 'topic': topic, 'specialty': specialty.isEmpty ? null : specialty,
        'card_style': cardStyle, 'usmle_step': usmleStep,
      }),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    final n = data['note'];
    if (n == null) return null;
    return NoteModel.fromJson(n as Map<String, dynamic>);
  }

  Future<({Uint8List bytes, int totalNotes, int dupeCount})> mergeDeck({
    required Uint8List apkgA,
    required Uint8List apkgB,
    required String deckName,
    bool classify = true,
  }) async {
    final res = await http.post(
      Uri.parse('$_base/deck/merge'),
      headers: _headers,
      body: jsonEncode({
        'apkg_a_b64': base64Encode(apkgA),
        'apkg_b_b64': base64Encode(apkgB),
        'deck_name': deckName,
        'classify': classify,
      }),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    final bytes = base64Decode(data['apkg_b64'] as String);
    return (
      bytes: Uint8List.fromList(bytes),
      totalNotes: (data['total_notes'] as num).toInt(),
      dupeCount: (data['duplicate_count'] as num).toInt(),
    );
  }

  Future<String> detectStep(String text) async {
    final res = await http.post(
      Uri.parse('$_base/detect/step'),
      headers: _headers,
      body: jsonEncode({'text': text}),
    ).timeout(const Duration(seconds: 10));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return data['step'] as String;
  }

  Future<String> notesToText(List<NoteModel> notes) async {
    // Convert client-side using the same Decksmith format — no round-trip needed
    final buf = StringBuffer();
    for (final n in notes) {
      if (n.noteType == 'cloze') {
        buf.writeln(n.extra.isNotEmpty ? '${n.front} ||| ${n.extra}' : n.front);
      } else if (n.noteType == 'basic_reverse') {
        buf.writeln('${n.front} || ${n.back}');
      } else if (n.noteType == 'basic_extra') {
        buf.writeln('${n.front} ||| ${n.back} ||| ${n.extra}');
      } else {
        buf.writeln('${n.front} :: ${n.back}');
      }
    }
    return buf.toString();
  }

  Future<bool> cancelJob(String jobId) async {
    try {
      final res = await http.delete(
        Uri.parse('$_base/augment/job/$jobId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<Map<String, dynamic>> cacheStats() async {
    final res = await http.get(Uri.parse('$_base/cache/stats'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    _check(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> cacheClean() async {
    final res = await http.delete(Uri.parse('$_base/cache'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _check(res);
  }

  Future<List<String>> ollamaModels() async {
    try {
      final res = await http.get(
        Uri.parse('$_base/ollama/models'),
        headers: _headers,
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body) as Map;
      return List<String>.from(data['models'] as List? ?? []);
    } catch (_) {
      return [];
    }
  }

  Future<List<NoteModel>> importPdf(Uint8List pdfBytes) async {
    final b64 = base64Encode(pdfBytes);
    final res = await http.post(
      Uri.parse('$_base/import/pdf'),
      headers: _headers,
      body: jsonEncode({'pdf_b64': b64}),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['notes'] as List).map((n) => NoteModel.fromJson(n as Map<String, dynamic>)).toList();
  }

  Future<List<NoteModel>> importDocx(Uint8List docxBytes) async {
    final b64 = base64Encode(docxBytes);
    final res = await http.post(
      Uri.parse('$_base/import/docx'),
      headers: _headers,
      body: jsonEncode({'docx_b64': b64}),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['notes'] as List).map((n) => NoteModel.fromJson(n as Map<String, dynamic>)).toList();
  }

  Future<List<NoteModel>> importImage(Uint8List imageBytes, String mediaType) async {
    final b64 = base64Encode(imageBytes);
    final res = await http.post(
      Uri.parse('$_base/import/image'),
      headers: _headers,
      body: jsonEncode({'image_b64': b64, 'media_type': mediaType}),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['notes'] as List).map((n) => NoteModel.fromJson(n as Map<String, dynamic>)).toList();
  }

  Future<List<NoteModel>> importApkg(Uint8List apkgBytes) async {
    final b64 = base64Encode(apkgBytes);
    final res = await http.post(
      Uri.parse('$_base/import'),
      headers: _headers,
      body: jsonEncode({'apkg_b64': b64}),
    ).timeout(const Duration(seconds: 30));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['notes'] as List).map((n) => NoteModel.fromJson(n as Map<String, dynamic>)).toList();
  }

  Future<AugmentGenerateResult> augmentGenerate(
    List<NoteModel> notes,
    EnhancementOptions opts, {
    void Function(int done, int total)? onProgress,
    void Function(String jobId)? onJobStarted,
  }) async {
    // Start the job — returns immediately with a job_id
    final startRes = await http.post(
      Uri.parse('$_base/augment/generate'),
      headers: _headers,
      body: jsonEncode({
        'notes': _serializeNotes(notes),
        'options': opts.toJson(),
      }),
    ).timeout(const Duration(seconds: 30));
    _check(startRes);
    final startData = jsonDecode(startRes.body) as Map;
    final jobId = startData['job_id'] as String;
    onJobStarted?.call(jobId);

    // Poll until done
    while (true) {
      await Future.delayed(const Duration(seconds: 2));

      final pollRes = await http.get(
        Uri.parse('$_base/augment/job/$jobId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 60));
      _check(pollRes);
      final pollData = jsonDecode(pollRes.body) as Map;

      final status = pollData['status'] as String;
      final doneCount = (pollData['done_count'] as num?)?.toInt() ?? 0;
      final total = (pollData['total'] as num?)?.toInt() ?? 0;

      onProgress?.call(doneCount, total);

      if (status == 'failed' || status == 'cancelled') {
        throw Exception(status == 'cancelled'
          ? 'Enhancement cancelled'
          : _friendly('Enhancement failed: ${pollData['error']}'));
      }

      if (status == 'done') {
        final data = pollData['result'] as Map<String, dynamic>;
        return AugmentGenerateResult(
          proposals: List<Map<String, dynamic>>.from(data['proposals'] as List),
          notes: (data['notes'] as List?)
              ?.map((n) => NoteModel.fromJson(n as Map<String, dynamic>))
              .toList() ?? notes,
          mediaFilesB64: Map<String, String>.from(data['media_files_b64'] as Map? ?? {}),
        );
      }
      // status == 'pending' or 'running' — keep polling
    }
  }

  Future<List<NoteModel>> augmentApply({
    required List<NoteModel> notes,
    required List<Map<String, dynamic>> proposals,
    required List<int> acceptedIndices,
    required String expansionMode,
  }) async {
    final res = await http.post(
      Uri.parse('$_base/augment/apply'),
      headers: _headers,
      body: jsonEncode({
        'notes': _serializeNotes(notes),
        'proposals': proposals,
        'accepted_indices': acceptedIndices,
        'expansion_mode': expansionMode,
      }),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    final data = jsonDecode(res.body) as Map;
    return (data['notes'] as List).map((n) => NoteModel.fromJson(n as Map<String, dynamic>)).toList();
  }

  Future<Map<String, dynamic>> dedupe({required Uint8List apkgBytes, required List<NoteModel> notes}) async {
    final b64 = base64Encode(apkgBytes);
    final res = await http.post(
      Uri.parse('$_base/dedupe'),
      headers: _headers,
      body: jsonEncode({'apkg_b64': b64, 'notes': _serializeNotes(notes)}),
    ).timeout(const Duration(seconds: 30));
    _check(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  void _check(http.Response res) {
    if (res.statusCode >= 400) {
      try {
        final body = jsonDecode(res.body) as Map;
        final detail = body['detail']?.toString() ?? 'Request failed (${res.statusCode})';
        throw Exception(_friendly(detail));
      } on FormatException {
        throw Exception('HTTP ${res.statusCode}: ${res.body.substring(0, res.body.length.clamp(0, 300))}');
      }
    }
  }

  static String _friendly(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('connection refused') || lower.contains('failed host lookup'))
      return 'Cannot reach the backend. Make sure it\'s running on port 8503 with the correct API key.';
    if (lower.contains('anthropic_api_key') || lower.contains('api key'))
      return 'API key not set. Set ANTHROPIC_API_KEY (or OPENAI_API_KEY) in the backend environment.';
    if (lower.contains('timeout') || lower.contains('timed out'))
      return 'Request timed out. The server may be overloaded — try again or use a smaller batch.';
    if (lower.contains('ollama') && (lower.contains('not found') || lower.contains('refused')))
      return 'Ollama is not running. Start it with: ollama serve';
    if (lower.contains('model not found') || lower.contains('no such model'))
      return 'Model not found locally. Pull it with: ollama pull <model-name>';
    if (lower.contains('rate limit') || lower.contains('429'))
      return 'Rate limit hit. Wait a moment and try again, or switch to a different model.';
    if (lower.contains('insufficient') || lower.contains('credits') || lower.contains('quota'))
      return 'API quota exceeded. Check your billing or switch providers in Settings.';
    return raw;
  }

  List<Map<String, dynamic>> _serializeNotes(List<NoteModel> notes) => notes.map((n) => {
    'note_type': n.noteType,
    'front': n.front,
    'back': n.back,
    'extra': n.extra,
    'tags': n.tags,
    if (n.guid != null) 'guid': n.guid,
  }).toList();
}
