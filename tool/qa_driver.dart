import 'dart:async';
import 'dart:io';

/// Drives the example app on an emulator using `flutter drive` with
/// integration_test. This script runs on the host machine and communicates
/// with the instrumented app via the Flutter Driver protocol.
///
/// The QA agent uses Process-based automation: it launches the app via
/// `flutter run` with dart-defines, then interacts programmatically via
/// `flutter drive`. Since we need to observe proxy traffic rather than
/// widget-tree internals, we use a simpler process-based approach:
/// launch the app, wait for readiness signals in the proxy, and use
/// `flutter` CLI commands to drive user interactions.
class QaDriver {
  QaDriver({
    required this.appPath,
    required this.publicKey,
    required this.trigger,
    required this.proxyPort,
    required this.platform,
  });

  final String appPath;
  final String publicKey;
  final String trigger;
  final int proxyPort;
  final String platform; // 'ios' or 'android'

  Process? _appProcess;
  bool _booted = false;
  int? _bootMs;

  bool get booted => _booted;
  int? get bootMs => _bootMs;

  /// Launches the app on the target emulator/simulator with the proxy URL
  /// and public key injected via --dart-define.
  Future<bool> launchApp() async {
    final sw = Stopwatch()..start();

    final dartDefines = [
      '--dart-define=TRANZMIT_API_BASE_URL=http://localhost:$proxyPort',
      '--dart-define=TRANZMIT_PUBLIC_KEY=$publicKey',
      '--dart-define=TRANZMIT_TRIGGER=$trigger',
    ];

    final deviceFlag = switch (platform) {
      'ios' => ['-d', 'iPhone'],
      'macos' => ['-d', 'macos'],
      'chrome' => ['-d', 'chrome'],
      _ => ['-d', 'emulator'],
    };

    stdout.writeln('[QA Driver] Launching app at $appPath on $platform...');

    _appProcess = await Process.start(
      'flutter',
      [
        'run',
        '--no-resident',
        ...dartDefines,
        ...deviceFlag,
      ],
      workingDirectory: appPath,
      environment: Platform.environment,
    );

    final bootCompleter = Completer<bool>();
    final outputBuffer = StringBuffer();

    _appProcess!.stdout
        .transform(const SystemEncoding().decoder)
        .listen((data) {
      outputBuffer.write(data);
      stdout.write(data);
      if (!bootCompleter.isCompleted &&
          data.contains('Flutter run key commands')) {
        bootCompleter.complete(true);
      }
    });

    _appProcess!.stderr
        .transform(const SystemEncoding().decoder)
        .listen((data) {
      stderr.write(data);
      if (!bootCompleter.isCompleted && data.contains('Error')) {
        bootCompleter.complete(false);
      }
    });

    final result = await bootCompleter.future
        .timeout(const Duration(minutes: 3), onTimeout: () => false);

    sw.stop();
    _booted = result;
    _bootMs = sw.elapsedMilliseconds;

    if (result) {
      stdout.writeln('[QA Driver] App booted in ${sw.elapsedMilliseconds}ms');
    } else {
      stdout.writeln('[QA Driver] App failed to boot');
    }

    return result;
  }

  /// Launches the app using `flutter drive` with the integration test target.
  /// This is the preferred approach for the SDK's own example app.
  Future<QaDriverResult> runIntegrationTest({
    required String driverPath,
    required String targetPath,
  }) async {
    final sw = Stopwatch()..start();

    final dartDefines = [
      '--dart-define=TRANZMIT_API_BASE_URL=http://localhost:$proxyPort',
      '--dart-define=TRANZMIT_PUBLIC_KEY=$publicKey',
      '--dart-define=TRANZMIT_TRIGGER=$trigger',
    ];

    final deviceFlag = switch (platform) {
      'ios' => ['-d', 'iPhone'],
      'macos' => ['-d', 'macos'],
      'chrome' => ['-d', 'chrome'],
      _ => ['-d', 'emulator'],
    };

    stdout.writeln('[QA Driver] Running integration test...');

    final result = await Process.run(
      'flutter',
      [
        'drive',
        '--driver=$driverPath',
        '--target=$targetPath',
        ...dartDefines,
        ...deviceFlag,
      ],
      workingDirectory: appPath,
      environment: Platform.environment,
    );

    sw.stop();

    stdout.writeln(result.stdout);
    if (result.stderr.toString().isNotEmpty) {
      stderr.writeln(result.stderr);
    }

    return QaDriverResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
      durationMs: sw.elapsedMilliseconds,
    );
  }

  /// Stops the running app process.
  Future<void> stop() async {
    if (_appProcess != null) {
      stdout.writeln('[QA Driver] Stopping app...');
      _appProcess!.stdin.writeln('q');
      await Future.delayed(const Duration(seconds: 2));
      _appProcess!.kill();
      _appProcess = null;
    }
  }
}

class QaDriverResult {
  const QaDriverResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;

  bool get passed => exitCode == 0;
}
