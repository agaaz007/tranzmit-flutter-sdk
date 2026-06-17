import 'dart:convert';
import 'dart:io';

import 'qa_checks.dart';

/// Formats QA check results as a terminal-friendly table and optional JSON.
class QaReport {
  QaReport({required this.results, required this.metrics});

  final List<CheckResult> results;
  final Map<String, dynamic> metrics;

  int get passCount => results.where((r) => r.passed).length;
  int get failCount => results.where((r) => r.failed).length;
  int get total => results.length;
  bool get allPassed => failCount == 0;

  /// Print the report to stdout with ANSI colors.
  void printToTerminal() {
    const reset = '\x1B[0m';
    const green = '\x1B[32m';
    const red = '\x1B[31m';
    const bold = '\x1B[1m';
    const dim = '\x1B[2m';
    const cyan = '\x1B[36m';

    stdout.writeln('');
    stdout.writeln('$bold${cyan}Tranzmit SDK QA Report$reset');
    stdout.writeln('$dim${"=" * 50}$reset');
    stdout.writeln('');

    for (final result in results) {
      final icon = result.passed ? '${green}PASS$reset' : '${red}FAIL$reset';
      final id = result.id.padRight(24);
      final detail = result.detail ?? '';
      stdout.writeln(' [$icon] $id$dim— $detail$reset');
    }

    stdout.writeln('');
    stdout.writeln('${bold}Metrics:$reset');
    stdout.writeln(
        '  Config fetch latency:     ${metrics['config_fetch_latency_ms']}ms');
    stdout.writeln('  Events captured:          ${metrics['events_captured']}');
    if (metrics['event_types'] is List) {
      final types = (metrics['event_types'] as List).join(', ');
      stdout.writeln('  Event types:              $types');
    }
    stdout.writeln(
        '  Attribution complete:     ${metrics['attribution_complete'] == true ? "yes" : "no"}');

    final identityParts = <String>[];
    if (metrics['stableID'] != null) {
      identityParts
          .add('stableID=${_truncateStr(metrics['stableID'] as String)}');
    }
    if (metrics['sessionId'] != null) {
      identityParts
          .add('sessionId=${_truncateStr(metrics['sessionId'] as String)}');
    }
    if (metrics['userId'] != null) {
      identityParts.add('userId=${metrics['userId']}');
    } else {
      identityParts.add('userId=null');
    }
    stdout.writeln('  Identity fields:          ${identityParts.join(", ")}');

    stdout.writeln('');
    final resultColor = allPassed ? green : red;
    stdout.writeln('${bold}Result: $resultColor$passCount/$total PASSED$reset');

    if (!allPassed) {
      stdout.writeln('');
      stdout.writeln('${red}Failed checks:$reset');
      for (final r in results.where((r) => r.failed)) {
        stdout.writeln('  - ${r.id}: ${r.detail}');
      }
    }

    stdout.writeln('');
  }

  /// Returns the report as a JSON map for CI consumption.
  Map<String, dynamic> toJson() {
    return {
      'passed': allPassed,
      'summary': '$passCount/$total passed',
      'checks': [
        for (final r in results)
          {
            'id': r.id,
            'label': r.label,
            'passed': r.passed,
            'detail': r.detail,
            if (r.durationMs != null) 'duration_ms': r.durationMs,
          },
      ],
      'metrics': metrics,
    };
  }

  /// Writes JSON report to a file.
  Future<void> writeJsonFile(String path) async {
    final json = const JsonEncoder.withIndent('  ').convert(toJson());
    await File(path).writeAsString(json);
    stdout.writeln('[QA Report] JSON written to $path');
  }
}

String _truncateStr(String s, [int maxLen = 20]) =>
    s.length <= maxLen ? s : '${s.substring(0, maxLen)}...';
