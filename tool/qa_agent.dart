import 'dart:async';
import 'dart:io';

import 'qa_checks.dart';
import 'qa_driver.dart';
import 'qa_proxy.dart';
import 'qa_report.dart';

/// CLI entry point for the Tranzmit SDK QA Testing Agent.
///
/// Usage:
///   dart run tool/qa_agent.dart \
///     --app-path=example \
///     --public-key=pk_test_2a8a5f07d4b9fcf1cc77e024 \
///     --trigger=upgrade_pro \
///     --expected-product=pro_monthly \
///     --platform=ios \
///     --json-output=qa_report.json
void main(List<String> args) async {
  final config = _parseArgs(args);
  if (config == null) {
    exit(_isHelpRequest(args) ? 0 : 1);
  }

  stdout.writeln('');
  stdout.writeln('╔══════════════════════════════════════════╗');
  stdout.writeln('║   Tranzmit SDK QA Agent                  ║');
  stdout.writeln('╚══════════════════════════════════════════╝');
  stdout.writeln('');
  stdout.writeln('Config:');
  stdout.writeln('  App path:          ${config.appPath}');
  stdout.writeln('  Public key:        ${config.publicKey}');
  stdout.writeln('  Trigger:           ${config.trigger}');
  stdout.writeln('  Expected product:  ${config.expectedProduct ?? "(any)"}');
  stdout.writeln('  Platform:          ${config.platform}');
  stdout.writeln('  Proxy port:        ${config.proxyPort}');
  stdout.writeln('  Upstream:          ${config.upstream}');
  stdout.writeln('');

  final results = <CheckResult>[];

  // ─── Step 1: pub_get ────────────────────────────────────────────────────

  stdout.writeln('[1/12] Running flutter pub get...');
  final proxy = QaProxy(
    upstreamBaseUrl: config.upstream,
    port: config.proxyPort,
  );
  final checks = QaChecks(
    proxy: proxy,
    trigger: config.trigger,
    expectedProductId: config.expectedProduct,
  );

  results.add(await checks.checkPubGet(config.appPath));
  if (results.last.failed) {
    _earlyExit(results, checks);
    exit(1);
  }

  // ─── Step 2: Start proxy & launch app ─────────────────────────────────

  stdout.writeln('[2/12] Starting proxy and launching app...');
  await proxy.start();

  final driver = QaDriver(
    appPath: config.appPath,
    publicKey: config.publicKey,
    trigger: config.trigger,
    proxyPort: config.proxyPort,
    platform: config.platform,
  );

  if (config.useIntegrationTest) {
    // Use the integration test approach for the SDK's own example app
    final driverResult = await driver.runIntegrationTest(
      driverPath: 'test_driver/qa_flow_driver.dart',
      targetPath: 'integration_test/qa_flow_test.dart',
    );

    results.add(CheckResult(
      id: 'app_boots',
      label: 'App launches without crash',
      passed: driverResult.passed ||
          driverResult.stdout.contains('All tests passed'),
      detail: driverResult.passed
          ? 'integration test passed in ${(driverResult.durationMs / 1000).toStringAsFixed(1)}s'
          : 'integration test failed (exit ${driverResult.exitCode})',
      durationMs: driverResult.durationMs,
    ));
  } else {
    // Process-based approach for arbitrary customer apps
    final booted = await driver.launchApp();
    results.add(checks.checkAppBoots(booted: booted, bootMs: driver.bootMs));
  }

  // Wait for events to arrive at the proxy
  stdout.writeln('[3/12] Waiting for SDK initialization traffic...');
  await proxy.waitForExchange(
      path: '/v1/config', timeout: const Duration(seconds: 20));
  await Future.delayed(const Duration(seconds: 3));

  // ─── Checks 3-10 from proxy captures ──────────────────────────────────

  stdout.writeln('[4/12] Checking for errors...');
  results.add(checks.checkNoErrors());

  stdout.writeln('[5/12] Checking SDK ready (config fetched)...');
  final configFetched = proxy.configPosts.isNotEmpty;
  results.add(checks.checkSdkReady(
    ready: configFetched,
    readyMs: configFetched ? proxy.configPosts.first.latencyMs : null,
  ));

  stdout.writeln('[6/12] Checking placement fetched...');
  results.add(checks.checkPlacementFetched());

  stdout.writeln('[7/12] Checking product ID match...');
  results.add(checks.checkProductIdMatch());

  stdout.writeln('[8/12] Checking paywall rendered...');
  final hasImpression = proxy.eventsNamed('impression').isNotEmpty;
  results.add(checks.checkPaywallRenders(rendered: hasImpression));

  stdout.writeln('[9/12] Checking CTA event...');
  results.add(checks.checkCtaFires());

  stdout.writeln('[10/12] Checking conversion event...');
  results.add(checks.checkConversionReported());

  stdout.writeln('[11/12] Checking identity fields...');
  results.add(checks.checkIdentityCorrect());

  // ─── Bonus: refresh config ────────────────────────────────────────────

  stdout.writeln('[12/12] Checking refresh config...');
  final configCallsBefore = proxy.configPosts.length;
  await Future.delayed(const Duration(seconds: 2));
  final configCallsAfter = proxy.configPosts.length;
  results.add(checks.checkRefreshConfig(
    configCallsBefore: configCallsBefore,
    configCallsAfter: configCallsAfter,
  ));

  // ─── Report ──────────────────────────────────────────────────────────

  await proxy.stop();
  await driver.stop();

  final metrics = checks.computeMetrics();
  final report = QaReport(results: results, metrics: metrics);
  report.printToTerminal();

  if (config.jsonOutput != null) {
    await report.writeJsonFile(config.jsonOutput!);
  }

  exit(report.allPassed ? 0 : 1);
}

// ─── Arg Parsing ──────────────────────────────────────────────────────────

class _Config {
  _Config({
    required this.appPath,
    required this.publicKey,
    required this.trigger,
    this.expectedProduct,
    required this.platform,
    required this.proxyPort,
    required this.upstream,
    required this.useIntegrationTest,
    this.jsonOutput,
  });

  final String appPath;
  final String publicKey;
  final String trigger;
  final String? expectedProduct;
  final String platform;
  final int proxyPort;
  final String upstream;
  final bool useIntegrationTest;
  final String? jsonOutput;
}

_Config? _parseArgs(List<String> args) {
  String? appPath;
  String? publicKey;
  String trigger = 'upgrade_pro';
  String? expectedProduct;
  String platform = 'ios';
  int proxyPort = 9877;
  String upstream = 'https://api-production-2146.up.railway.app';
  bool useIntegrationTest = false;
  String? jsonOutput;

  for (final arg in args) {
    if (arg.startsWith('--app-path=')) {
      appPath = arg.split('=').skip(1).join('=');
    } else if (arg.startsWith('--public-key=')) {
      publicKey = arg.split('=').skip(1).join('=');
    } else if (arg.startsWith('--trigger=')) {
      trigger = arg.split('=').skip(1).join('=');
    } else if (arg.startsWith('--expected-product=')) {
      expectedProduct = arg.split('=').skip(1).join('=');
    } else if (arg.startsWith('--platform=')) {
      platform = arg.split('=').skip(1).join('=');
    } else if (arg.startsWith('--proxy-port=')) {
      proxyPort = int.tryParse(arg.split('=').skip(1).join('=')) ?? 9877;
    } else if (arg.startsWith('--upstream=')) {
      upstream = arg.split('=').skip(1).join('=');
    } else if (arg == '--integration-test') {
      useIntegrationTest = true;
    } else if (arg.startsWith('--json-output=')) {
      jsonOutput = arg.split('=').skip(1).join('=');
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      return null;
    } else {
      stderr.writeln('Unknown argument: $arg');
      _printUsage();
      return null;
    }
  }

  if (appPath == null) {
    stderr.writeln('Error: --app-path is required');
    _printUsage();
    return null;
  }

  if (publicKey == null) {
    stderr.writeln('Error: --public-key is required');
    _printUsage();
    return null;
  }

  if (!Directory(appPath).existsSync()) {
    stderr.writeln('Error: app path does not exist: $appPath');
    return null;
  }

  return _Config(
    appPath: appPath,
    publicKey: publicKey,
    trigger: trigger,
    expectedProduct: expectedProduct,
    platform: platform,
    proxyPort: proxyPort,
    upstream: upstream,
    useIntegrationTest: useIntegrationTest,
    jsonOutput: jsonOutput,
  );
}

void _printUsage() {
  stdout.writeln('''
Usage: dart run tool/qa_agent.dart [OPTIONS]

Required:
  --app-path=<path>           Path to the Flutter app directory
  --public-key=<key>          Tranzmit public key

Optional:
  --trigger=<name>            Placement trigger (default: upgrade_pro)
  --expected-product=<id>     Expected billing product ID to validate
  --platform=<ios|android>    Target platform (default: ios)
  --proxy-port=<port>         Local proxy port (default: 9877)
  --upstream=<url>            Railway API URL (default: production)
  --integration-test          Use flutter drive with integration_test
  --json-output=<path>        Write JSON report to file
  -h, --help                  Show this help

Example:
  dart run tool/qa_agent.dart \\
    --app-path=example \\
    --public-key=pk_test_2a8a5f07d4b9fcf1cc77e024 \\
    --trigger=upgrade_pro \\
    --expected-product=pro_monthly \\
    --platform=ios \\
    --json-output=qa_report.json
''');
}

bool _isHelpRequest(List<String> args) =>
    args.contains('--help') || args.contains('-h');

void _earlyExit(List<CheckResult> results, QaChecks checks) {
  final metrics = checks.computeMetrics();
  final report = QaReport(results: results, metrics: metrics);
  report.printToTerminal();
}
