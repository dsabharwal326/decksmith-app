import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppPhase { idle, processing, results, exporting }

enum SidebarPage { upload, topic, enhance, history, settings }

class NoteModel {
  final String noteType;
  final String front;
  final String back;
  final String extra;
  final List<String> tags;
  NoteModel({required this.noteType, required this.front, required this.back, required this.extra, required this.tags});

  factory NoteModel.fromJson(Map<String, dynamic> j) => NoteModel(
    noteType: j['note_type'] ?? 'basic',
    front: j['front'] ?? '',
    back: j['back'] ?? '',
    extra: j['extra'] ?? '',
    tags: List<String>.from(j['tags'] ?? []),
  );
}

class ValidationResult {
  final int index;
  final String status;
  final String error;
  final String fixDescription;
  final NoteModel? fixedNote;
  ValidationResult({required this.index, required this.status, required this.error, required this.fixDescription, this.fixedNote});

  factory ValidationResult.fromJson(Map<String, dynamic> j) => ValidationResult(
    index: j['index'] ?? 0,
    status: j['status'] ?? 'valid',
    error: j['error'] ?? '',
    fixDescription: j['fix_description'] ?? '',
    fixedNote: j['fixed_note'] != null ? NoteModel.fromJson(j['fixed_note']) : null,
  );
}

class HistoryEntry {
  final String deckName;
  final int cardCount;
  final DateTime date;
  final Uint8List apkgData;
  HistoryEntry({required this.deckName, required this.cardCount, required this.date, required this.apkgData});
}

class AppState extends ChangeNotifier {
  AppPhase phase = AppPhase.idle;
  SidebarPage page = SidebarPage.upload;

  String cardText = '';
  String deckName = 'My Deck';
  bool classify = true;

  String topicInput = '';
  String topicSpecialty = 'Any / General';
  int topicCardCount = 20;

  String processingStatus = '';
  double processingProgress = 0;

  List<NoteModel> parsedNotes = [];
  List<ValidationResult> validationResults = [];
  int totalCards = 0;
  List<Map<String, dynamic>> subdeckCounts = [];

  Uint8List? builtApkgData;
  String? errorMessage;

  // dedup
  Uint8List? existingApkgBytes;
  String? existingApkgName;
  int dupesSkipped = 0;

  List<HistoryEntry> history = [];

  String apiBaseURL = 'http://localhost:8503';
  String serviceKey = '';
  String selectedProvider = 'anthropic';

  AppState() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    apiBaseURL = prefs.getString('apiBaseURL') ?? 'http://localhost:8503';
    serviceKey = prefs.getString('serviceKey') ?? '';
    selectedProvider = prefs.getString('selectedProvider') ?? 'anthropic';
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiBaseURL', apiBaseURL);
    await prefs.setString('serviceKey', serviceKey);
    await prefs.setString('selectedProvider', selectedProvider);
    notifyListeners();
  }

  void setClassify(bool v) {
    classify = v;
    notifyListeners();
  }

  void setPage(SidebarPage p) {
    page = p;
    notifyListeners();
  }

  void setPhase(AppPhase p) {
    phase = p;
    notifyListeners();
  }

  void setProgress(String status, double progress) {
    processingStatus = status;
    processingProgress = progress;
    notifyListeners();
  }

  void setResults({required List<NoteModel> notes, required List<ValidationResult> validation, required int cards, required List<Map<String, dynamic>> subdecks}) {
    parsedNotes = notes;
    validationResults = validation;
    totalCards = cards;
    subdeckCounts = subdecks;
    phase = AppPhase.results;
    notifyListeners();
  }

  void setApkg(Uint8List data) {
    builtApkgData = data;
    phase = AppPhase.exporting;
    history.insert(0, HistoryEntry(deckName: deckName, cardCount: totalCards, date: DateTime.now(), apkgData: data));
    notifyListeners();
  }

  void setError(String msg) {
    errorMessage = msg;
    phase = AppPhase.idle;
    notifyListeners();
  }

  void setExistingApkg(Uint8List bytes, String name) {
    existingApkgBytes = bytes;
    existingApkgName = name;
    notifyListeners();
  }

  void clearExistingApkg() {
    existingApkgBytes = null;
    existingApkgName = null;
    notifyListeners();
  }

  void reset() {
    cardText = '';
    parsedNotes = [];
    validationResults = [];
    totalCards = 0;
    subdeckCounts = [];
    builtApkgData = null;
    errorMessage = null;
    processingStatus = '';
    processingProgress = 0;
    dupesSkipped = 0;
    phase = AppPhase.idle;
    notifyListeners();
  }
}
