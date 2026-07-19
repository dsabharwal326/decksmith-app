import 'dart:io';
import 'package:http/http.dart' as http;

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
    if (await checkHealth(baseUrl)) {
      _setStatus(BackendStatus.running);
      return;
    }

    if (backendPath.isEmpty) {
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
      env['SERVICE_API_KEY'] = 'decksmith';
      if (anthropicApiKey.isNotEmpty) env['ANTHROPIC_API_KEY'] = anthropicApiKey;
      if (openaiApiKey.isNotEmpty)    env['OPENAI_API_KEY']    = openaiApiKey;

      // Find python3 on PATH
      final python = await _findPython();
      if (python == null) {
        _setStatus(BackendStatus.offline);
        return;
      }

      _process = await Process.start(
        python,
        ['-m', 'uvicorn', 'api:app', '--host', '0.0.0.0', '--port', '8503', '--reload'],
        workingDirectory: File(backendPath).parent.path,
        environment: env,
        mode: ProcessStartMode.detachedWithStdio,
      );

      // Wait up to 8s for the backend to start
      for (var i = 0; i < 16; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await checkHealth(baseUrl)) {
          _setStatus(BackendStatus.running);
          return;
        }
      }
      _setStatus(BackendStatus.offline);
    } catch (_) {
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
    for (final candidate in ['python3', 'python']) {
      try {
        final res = await Process.run('which', [candidate]);
        if (res.exitCode == 0) return (res.stdout as String).trim();
      } catch (_) {}
    }
    return null;
  }
}
