import 'dart:io';
import 'package:http/http.dart' as http;

void _log(String msg) => stderr.writeln('[BackendLauncher] $msg');

enum BackendStatus { unknown, starting, running, offline }

class BackendLauncher {
  Process? _process;
  BackendStatus _status = BackendStatus.unknown;
  BackendStatus get status => _status;

  final void Function(BackendStatus) onStatusChanged;
  BackendLauncher({required this.onStatusChanged});

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

    if (backendPath.isEmpty) {
      _log('backendPath is empty — not auto-launching');
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

      final python = await _findPython();
      _log('python found: $python');
      if (python == null) {
        _log('no python found — giving up');
        _setStatus(BackendStatus.offline);
        return;
      }

      final workDir = File(backendPath).parent.path;
      // Derive the module name from the filename (e.g. api.py → api)
      final module = File(backendPath).uri.pathSegments.last.replaceAll('.py', '');
      _log('launching: $python -m uvicorn $module:app --port 8503 in $workDir');

      // Use a wrapper script so we can cd into the backend dir before
      // starting uvicorn — Process.start workingDirectory is ignored when
      // the app is sandboxed on macOS.
      final script = 'cd ${_shellEscape(workDir)} && '
          '${_shellEscape(python)} -m uvicorn $module:app '
          '--host 0.0.0.0 --port 8503';
      _log('script: $script');
      _process = await Process.start(
        '/bin/sh', ['-c', script],
        environment: env,
        mode: ProcessStartMode.normal,
      );
      _process!.stdout.transform(const SystemEncoding().decoder).listen((l) => _log('stdout: $l'));
      _process!.stderr.transform(const SystemEncoding().decoder).listen((l) => _log('stderr: $l'));

      // Wait up to 12s for the backend to start
      for (var i = 0; i < 24; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await checkHealth(baseUrl)) {
          _log('backend is up after ${(i+1)*500}ms');
          _setStatus(BackendStatus.running);
          return;
        }
      }
      _log('backend did not respond within 12s');
      _setStatus(BackendStatus.offline);
    } catch (e) {
      _log('launch error: $e');
      _setStatus(BackendStatus.offline);
    }
  }

  Future<void> stop() async {
    _process?.kill();
    _process = null;
    _setStatus(BackendStatus.offline);
  }

  void _setStatus(BackendStatus s) {
    _status = s;
    onStatusChanged(s);
  }

  static Future<String?> _findPython() async {
    // Try shell PATH first (works when launched from terminal)
    for (final candidate in ['python3', 'python']) {
      try {
        final res = await Process.run('which', [candidate],
            environment: {'PATH': _extendedPath()});
        if (res.exitCode == 0) {
          final path = (res.stdout as String).trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    }
    // Absolute fallbacks for GUI apps where PATH is minimal
    const candidates = [
      '/Library/Frameworks/Python.framework/Versions/3.13/bin/python3',
      '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3',
      '/Library/Frameworks/Python.framework/Versions/3.11/bin/python3',
      '/opt/homebrew/bin/python3',
      '/usr/local/bin/python3',
      '/usr/bin/python3',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
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
