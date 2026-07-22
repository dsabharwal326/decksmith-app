import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/backend_launcher.dart';

export '../services/backend_launcher.dart' show BackendStatus;

enum AppPhase { idle, processing, review, exporting }

enum SidebarPage { upload, topic, enhance, merge, history, settings }

enum ViewMode { compact, hybrid, full }

class NoteModel {
  final String noteType;
  String front;
  String back;
  String extra;
  List<String> tags;
  final String? guid;
  NoteModel({required this.noteType, required this.front, required this.back, required this.extra, required this.tags, this.guid});

  factory NoteModel.fromJson(Map<String, dynamic> j) => NoteModel(
    noteType: j['note_type'] ?? 'basic',
    front: j['front'] ?? '',
    back: j['back'] ?? '',
    extra: j['extra'] ?? '',
    tags: List<String>.from(j['tags'] ?? []),
    guid: j['guid'] as String?,
  );

  NoteModel copyWith({String? front, String? back, String? extra, List<String>? tags}) => NoteModel(
    noteType: noteType,
    front: front ?? this.front,
    back: back ?? this.back,
    extra: extra ?? this.extra,
    tags: tags ?? this.tags,
    guid: guid,
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
  final String? filePath;
  HistoryEntry({required this.deckName, required this.cardCount, required this.date, required this.apkgData, this.filePath});
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
  String? activeJobId;

  // ── Settings ──────────────────────────────────────────────────────────────
  String apiBaseURL = 'http://localhost:8503';
  // serviceKey is always 'decksmith' — invisible to users
  final String serviceKey = 'decksmith';
  String selectedProvider = 'ollama';
  String defaultOutputPath = '';
  String lastPickerPath = '';
  String defaultOllamaModel = 'mistral';
  String defaultDepth = 'full';
  ViewMode _viewMode = ViewMode.hybrid;
  ViewMode get viewMode => _viewMode;
  set viewMode(ViewMode v) { _viewMode = v; notifyListeners(); }

  // ── API keys (passed as request headers → backend) ────────────────────────
  String anthropicApiKey = '';
  String openaiApiKey = '';

  // ── Backend auto-launch ───────────────────────────────────────────────────
  String backendPath = '';   // path to api.py; empty = don't auto-launch
  BackendStatus backendStatus = BackendStatus.unknown;
  late final BackendLauncher _launcher;

  AppState() {
    _launcher = BackendLauncher(onStatusChanged: (s) {
      backendStatus = s;
      notifyListeners();
    });
    _loadSettings().then((_) => _startBackendIfNeeded());
    _loadHistory();
  }

  Future<void> _startBackendIfNeeded() async {
    await _launcher.ensureRunning(
      baseUrl: apiBaseURL,
      backendPath: backendPath,
      anthropicApiKey: anthropicApiKey,
      openaiApiKey: openaiApiKey,
    );
  }

  Future<void> launchBackend() => _launcher.launch(
    baseUrl: apiBaseURL,
    backendPath: backendPath,
    anthropicApiKey: anthropicApiKey,
    openaiApiKey: openaiApiKey,
  );

  Future<void> stopBackend() => _launcher.stop();

  Future<void> refreshBackendStatus() async {
    final alive = await _launcher.checkHealth(apiBaseURL);
    backendStatus = alive ? BackendStatus.running : BackendStatus.offline;
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedURL = prefs.getString('apiBaseURL') ?? '';
    apiBaseURL = savedURL.isNotEmpty ? savedURL : 'http://localhost:8503';
    selectedProvider = prefs.getString('selectedProvider') ?? 'ollama';
    defaultOutputPath = prefs.getString('defaultOutputPath') ?? '';
    lastPickerPath = prefs.getString('lastPickerPath') ?? '';
    defaultOllamaModel = prefs.getString('defaultOllamaModel') ?? 'mistral';
    defaultDepth = prefs.getString('defaultDepth') ?? 'full';
    anthropicApiKey = prefs.getString('anthropicApiKey') ?? '';
    openaiApiKey = prefs.getString('openaiApiKey') ?? '';
    final savedPath = prefs.getString('backendPath') ?? '';
    backendPath = savedPath.isNotEmpty ? savedPath : _defaultBackendPath();
    _viewMode = ViewMode.values.firstWhere(
      (v) => v.name == (prefs.getString('viewMode') ?? 'hybrid'),
      orElse: () => ViewMode.hybrid,
    );
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiBaseURL', apiBaseURL);
    await prefs.setString('selectedProvider', selectedProvider);
    await prefs.setString('defaultOutputPath', defaultOutputPath);
    await prefs.setString('lastPickerPath', lastPickerPath);
    await prefs.setString('defaultOllamaModel', defaultOllamaModel);
    await prefs.setString('defaultDepth', defaultDepth);
    await prefs.setString('anthropicApiKey', anthropicApiKey);
    await prefs.setString('openaiApiKey', openaiApiKey);
    await prefs.setString('backendPath', backendPath);
    await prefs.setString('viewMode', viewMode.name);
    notifyListeners();
  }

  static String _defaultBackendPath() {
    // macOS sandbox may block existsSync on ~/Documents; return the most
    // likely path unconditionally and let the launcher handle failure.
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return '';
    return '$home/Documents/Anki Generator/api.py';
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

  void setReview({
    required List<NoteModel> notes,
    required List<ValidationResult> validation,
  }) {
    parsedNotes = notes;
    validationResults = validation;
    totalCards = notes.length;
    phase = AppPhase.review;
    notifyListeners();
  }

  void setApkg(Uint8List data, {int dupesRemovedInBuild = 0}) {
    builtApkgData = data;
    activeJobId = null;
    dupesSkipped += dupesRemovedInBuild;
    phase = AppPhase.exporting;
    final entry = HistoryEntry(
      deckName: deckName,
      cardCount: totalCards,
      date: DateTime.now(),
      apkgData: data,
    );
    history.insert(0, entry);
    _persistHistoryEntry(entry);
    notifyListeners();
  }

  Future<void> _persistHistoryEntry(HistoryEntry entry) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final histDir = Directory('${dir.path}/decksmith/history');
      await histDir.create(recursive: true);
      final ts = entry.date.millisecondsSinceEpoch;
      final safe = entry.deckName.replaceAll(RegExp(r'[^\w]'), '_');
      final entryDir = Directory('${histDir.path}/${ts}_$safe');
      await entryDir.create();
      await File('${entryDir.path}/deck.apkg').writeAsBytes(entry.apkgData);
      await File('${entryDir.path}/meta.json').writeAsString(jsonEncode({
        'deckName': entry.deckName,
        'cardCount': entry.cardCount,
        'date': entry.date.toIso8601String(),
      }));
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final histDir = Directory('${dir.path}/decksmith/history');
      if (!await histDir.exists()) return;
      final entries = <HistoryEntry>[];
      await for (final entity in histDir.list()) {
        if (entity is! Directory) continue;
        final metaFile = File('${entity.path}/meta.json');
        final apkgFile = File('${entity.path}/deck.apkg');
        if (!await metaFile.exists() || !await apkgFile.exists()) continue;
        try {
          final meta = jsonDecode(await metaFile.readAsString()) as Map;
          final data = await apkgFile.readAsBytes();
          entries.add(HistoryEntry(
            deckName: meta['deckName'] as String,
            cardCount: meta['cardCount'] as int,
            date: DateTime.parse(meta['date'] as String),
            apkgData: data,
            filePath: apkgFile.path,
          ));
        } catch (_) {}
      }
      entries.sort((a, b) => b.date.compareTo(a.date));
      history = entries;
      notifyListeners();
    } catch (_) {}
  }

  void setError(String msg) {
    errorMessage = msg;
    activeJobId = null;
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
    activeJobId = null;
    phase = AppPhase.idle;
    notifyListeners();
  }
}
