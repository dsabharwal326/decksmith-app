import 'dart:io';
import 'package:http/http.dart' as http;

void _log(String msg) => stderr.writeln('[BackendLauncher] $msg');

enum BackendStatus { unknown, starting, running, offline }

class BackendLauncher {
  Process? _process;
  Process? _ollamaProcess;
  BackendStatus _status = BackendStatus.unknown;
  BackendStatus get status => _status;

  final void Function(BackendStatus) onStatusChanged;
  BackendLauncher({required this.onStatusChanged});

  Future<bool> checkOllamaHealth() async {
    try {
      final res = await http
          .get(Uri.parse('http://localhost:11434/api/tags'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> checkHealth(String baseUrl) async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> ensureRunning({
    required String baseUrl,
    required String backendPath,
    required String anthropicApiKey,
    required String openaiApiKey,
  }) async {
    _log('ensureRunning: baseUrl=$baseUrl backendPath=$backendPath');
    if (await checkHealth(baseUrl)) {
      _log('health check passed — already running');
      _setStatus(BackendStatus.running);
      return;
    }

    final hasBundled = _bundledBinaryPath() != null;
    if (backendPath.isEmpty && !hasBundled) {
      _log('backendPath is empty and no bundled binary — not auto-launching');
      _setStatus(BackendStatus.offline);
      return;
    }

    await launch(
      baseUrl: baseUrl,
      backendPath: backendPath,
      anthropicApiKey: anthropicApiKey,
      openaiApiKey: openaiApiKey,
    );
  }

  Future<void> launch({
    required String baseUrl,
    required String backendPath,
    required String anthropicApiKey,
    required String openaiApiKey,
  }) async {
    _setStatus(BackendStatus.starting);
    try {
      final env = Map<String, String>.from(Platform.environment);
      env['PATH'] = _extendedPath();
      env['SERVICE_API_KEY'] = 'decksmith';
      if (anthropicApiKey.isNotEmpty) env['ANTHROPIC_API_KEY'] = anthropicApiKey;
      if (openaiApiKey.isNotEmpty)    env['OPENAI_API_KEY']    = openaiApiKey;

      // Start bundled Ollama if present and not already running
      await _ensureOllamaRunning(env);

      // Prefer the bundled binary shipped inside the .app
      final bundled = _bundledBinaryPath();
      if (bundled != null) {
        _log('using bundled backend: $bundled');
        _process = await Process.start(
          bundled, [],
          environment: env,
          mode: ProcessStartMode.normal,
        );
      } else {
        // Fall back to launching api.py via Python/uvicorn
        final python = await _findPython();
        _log('python found: $python');
        if (python == null) {
          _log('no python found — giving up');
          _setStatus(BackendStatus.offline);
          return;
        }
        final workDir = File(backendPath).parent.path;
        final module = File(backendPath).uri.pathSegments.last.replaceAll('.py', '');
        _log('launching: $python -m uvicorn $module:app --port 8503 in $workDir');
        final script = 'cd ${_shellEscape(workDir)} && '
            '${_shellEscape(python)} -m uvicorn $module:app --host 0.0.0.0 --port 8503';
        _process = await Process.start(
          '/bin/sh', ['-c', script],
          environment: env,
          mode: ProcessStartMode.normal,
        );
      }

      _process!.stdout.transform(const SystemEncoding().decoder).listen((l) => _log('stdout: $l'));
      _process!.stderr.transform(const SystemEncoding().decoder).listen((l) => _log('stderr: $l'));

      // Wait up to 20s for the backend to start (bundled binary may take longer first time)
      for (var i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await checkHealth(baseUrl)) {
          _log('backend is up after ${(i+1)*500}ms');
          _setStatus(BackendStatus.running);
          return;
        }
      }
      _log('backend did not respond within 20s');
      _setStatus(BackendStatus.offline);
    } catch (e) {
      _log('launch error: $e');
      _setStatus(BackendStatus.offline);
    }
  }

  Future<void> _ensureOllamaRunning(Map<String, String> env) async {
    if (await checkOllamaHealth()) {
      _log('ollama already running on :11434');
      return;
    }
    final ollamaPath = _bundledOllamaPath();
    if (ollamaPath == null) {
      // Try system ollama
      try {
        final which = await Process.run('which', ['ollama'], environment: env);
        final systemOllama = (which.stdout as String).trim();
        if (systemOllama.isNotEmpty) {
          _log('starting system ollama: $systemOllama');
          _ollamaProcess = await Process.start(systemOllama, ['serve'],
              environment: env, mode: ProcessStartMode.normal);
          _ollamaProcess!.stderr.transform(const SystemEncoding().decoder).listen((l) => _log('ollama: $l'));
          await _waitForOllama();
        }
      } catch (_) {}
      return;
    }
    _log('starting bundled ollama: $ollamaPath');
    final ollamaEnv = Map<String, String>.from(env);
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      ollamaEnv['OLLAMA_MODELS'] = '$home/Library/Application Support/Decksmith/ollama/models';
    }
    _ollamaProcess = await Process.start(ollamaPath, ['serve'],
        environment: ollamaEnv, mode: ProcessStartMode.normal);
    _ollamaProcess!.stdout.transform(const SystemEncoding().decoder).listen((l) => _log('ollama: $l'));
    _ollamaProcess!.stderr.transform(const SystemEncoding().decoder).listen((l) => _log('ollama: $l'));
    await _waitForOllama();
  }

  Future<void> _waitForOllama() async {
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (await checkOllamaHealth()) {
        _log('ollama up after ${(i+1)*500}ms');
        return;
      }
    }
    _log('ollama did not respond within 10s');
  }

  /// Returns the path to the PyInstaller-bundled backend if it exists inside
  /// the .app bundle (Contents/Resources/decksmith_backend/decksmith_backend).
  static String? _bundledBinaryPath() {
    try {
      // Platform.resolvedExecutable = .../Contents/MacOS/decksmith_app
      final exe = File(Platform.resolvedExecutable);
      final candidate = File(
        '${exe.parent.parent.path}/Resources/decksmith_backend/decksmith_backend',
      );
      if (candidate.existsSync()) return candidate.path;
    } catch (_) {}
    return null;
  }

  /// Returns the path to the bundled Ollama binary if present in the .app bundle.
  static String? _bundledOllamaPath() {
    try {
      final exe = File(Platform.resolvedExecutable);
      final candidate = File('${exe.parent.parent.path}/Resources/ollama/ollama');
      if (candidate.existsSync()) return candidate.path;
    } catch (_) {}
    return null;
  }

  Future<void> stop() async {
    _process?.kill();
    _process = null;
    _ollamaProcess?.kill();
    _ollamaProcess = null;
    _setStatus(BackendStatus.offline);
  }

  void _setStatus(BackendStatus s) {
    _status = s;
    onStatusChanged(s);
  }

  static Future<String?> _findPython() async {
    // Collect candidates — Framework / Homebrew before system stubs
    final candidates = <String>[
      '/Library/Frameworks/Python.framework/Versions/3.13/bin/python3',
      '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3',
      '/Library/Frameworks/Python.framework/Versions/3.11/bin/python3',
      '/opt/homebrew/bin/python3',
      '/usr/local/bin/python3',
    ];

    // Also collect whatever `which python3` finds via extended PATH
    for (final cmd in ['python3', 'python']) {
      try {
        final res = await Process.run('which', [cmd],
            environment: {'PATH': _extendedPath()});
        if (res.exitCode == 0) {
          final p = (res.stdout as String).trim();
          if (p.isNotEmpty && !candidates.contains(p)) candidates.add(p);
        }
      } catch (_) {}
    }

    // Return first candidate that actually has uvicorn installed
    for (final p in candidates) {
      if (!File(p).existsSync()) continue;
      try {
        final res = await Process.run(p, ['-c', 'import uvicorn']);
        if (res.exitCode == 0) {
          _log('using python: $p');
          return p;
        }
      } catch (_) {}
    }
    return null;
  }

  static String _shellEscape(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _extendedPath() {
    final existing = Platform.environment['PATH'] ?? '';
    const extra = '/usr/local/bin:/opt/homebrew/bin'
        ':/Library/Frameworks/Python.framework/Versions/3.13/bin'
        ':/Library/Frameworks/Python.framework/Versions/3.12/bin'
        ':/Library/Frameworks/Python.framework/Versions/3.11/bin';
    return '$existing:$extra';
  }
}
