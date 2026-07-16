import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/app_state.dart';

class ApiService {
  final AppState state;
  ApiService(this.state);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-Service-Key': state.serviceKey,
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

  Future<Uint8List> buildDeck({required List<NoteModel> notes, required String deckName, required bool classify}) async {
    final res = await http.post(
      Uri.parse('$_base/build'),
      headers: _headers,
      body: jsonEncode({'notes': _serializeNotes(notes), 'deck_name': deckName, 'classify': classify}),
    ).timeout(const Duration(seconds: 60));
    _check(res);
    return res.bodyBytes;
  }

  Future<List<NoteModel>> generateTopic({required String topic, required String specialty, required int count}) async {
    final res = await http.post(
      Uri.parse('$_base/topic/generate'),
      headers: _headers,
      body: jsonEncode({'topic': topic, 'specialty': specialty, 'count': count, 'provider': state.selectedProvider}),
    ).timeout(const Duration(seconds: 120));
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
      final body = jsonDecode(res.body);
      throw Exception(body['detail'] ?? 'Request failed (${res.statusCode})');
    }
  }

  List<Map<String, dynamic>> _serializeNotes(List<NoteModel> notes) => notes.map((n) => {
    'note_type': n.noteType,
    'front': n.front,
    'back': n.back,
    'extra': n.extra,
    'tags': n.tags,
  }).toList();
}
