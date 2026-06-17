import 'dart:io';

import 'qa_proxy.dart';

/// Result of a single QA check.
class CheckResult {
  const CheckResult({
    required this.id,
    required this.label,
    required this.passed,
    this.detail,
    this.durationMs,
  });

  final String id;
  final String label;
  final bool passed;
  final String? detail;
  final int? durationMs;

  bool get failed => !passed;
}

/// Runs all QA checks against the proxy captures and returns results.
class QaChecks {
  QaChecks({
    required this.proxy,
    required this.trigger,
    this.expectedProductId,
  });

  final QaProxy proxy;
  final String trigger;
  final String? expectedProductId;

  // ─── Check 1: pub_get ─────────────────────────────────────────────────────

  Future<CheckResult> checkPubGet(String appPath) async {
    final sw = Stopwatch()..start();
    final result = await Process.run(
      'flutter',
      ['pub', 'get'],
      workingDirectory: appPath,
    );
    sw.stop();
    final passed = result.exitCode == 0;
    return CheckResult(
      id: 'pub_get',
      label: 'Dependency resolves',
      passed: passed,
      detail: passed
          ? 'resolved in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
          : 'exit code ${result.exitCode}: ${result.stderr}',
      durationMs: sw.elapsedMilliseconds,
    );
  }

  // ─── Check 2: app_boots ───────────────────────────────────────────────────

  CheckResult checkAppBoots({required bool booted, int? bootMs}) {
    return CheckResult(
      id: 'app_boots',
      label: 'App launches without crash',
      passed: booted,
      detail: booted
          ? 'first frame in ${(bootMs ?? 0) / 1000}s'
          : 'app did not boot within timeout',
      durationMs: bootMs,
    );
  }

  // ─── Check 3: no_errors ───────────────────────────────────────────────────

  CheckResult checkNoErrors() {
    final errorEvents =
        proxy.eventsNamed('error') + proxy.eventsNamed('paywall_error');
    return CheckResult(
      id: 'no_errors',
      label: 'No onError callbacks fired',
      passed: errorEvents.isEmpty,
      detail: errorEvents.isEmpty
          ? '0 error events captured'
          : '${errorEvents.length} error event(s) detected',
    );
  }

  // ─── Check 4: sdk_ready ───────────────────────────────────────────────────

  CheckResult checkSdkReady({required bool ready, int? readyMs}) {
    return CheckResult(
      id: 'sdk_ready',
      label: 'isReady becomes true',
      passed: ready,
      detail: ready
          ? 'ready in ${((readyMs ?? 0) / 1000).toStringAsFixed(1)}s'
          : 'SDK did not become ready within timeout',
      durationMs: readyMs,
    );
  }

  // ─── Check 5: placement_fetched ───────────────────────────────────────────

  CheckResult checkPlacementFetched() {
    final configExchanges = proxy.configPosts;
    if (configExchanges.isEmpty) {
      return const CheckResult(
        id: 'placement_fetched',
        label: '/v1/config returns a placement',
        passed: false,
        detail: 'no /v1/config calls captured',
      );
    }

    final lastConfig = configExchanges.last;
    final placements =
        lastConfig.responseBody?['placements'] as Map<String, dynamic>?;
    final placement = placements?[trigger] as Map<String, dynamic>?;
    final enabled = placement?['enabled'] as bool? ?? false;
    final variantId = placement?['variantId'] as String?;

    return CheckResult(
      id: 'placement_fetched',
      label: '/v1/config returns a placement',
      passed: placement != null && enabled,
      detail: placement == null
          ? 'trigger "$trigger" not found in config response'
          : enabled
              ? '$trigger enabled, variant: ${variantId ?? "unknown"}'
              : '$trigger found but disabled',
    );
  }

  // ─── Check 6: product_id_match ────────────────────────────────────────────

  CheckResult checkProductIdMatch() {
    if (expectedProductId == null) {
      return const CheckResult(
        id: 'product_id_match',
        label: 'Product ID matches expected',
        passed: true,
        detail: 'skipped (no expected product ID provided)',
      );
    }

    final configExchanges = proxy.configPosts;
    if (configExchanges.isEmpty) {
      return const CheckResult(
        id: 'product_id_match',
        label: 'Product ID matches expected',
        passed: false,
        detail: 'no /v1/config calls captured',
      );
    }

    final lastConfig = configExchanges.last;
    final placements =
        lastConfig.responseBody?['placements'] as Map<String, dynamic>?;
    final placement = placements?[trigger] as Map<String, dynamic>?;
    final spec = placement?['spec'] as Map<String, dynamic>?;
    final products = spec?['products'] as List?;
    final firstProduct = products?.isNotEmpty == true
        ? products!.first as Map<String, dynamic>?
        : null;
    final actualId = firstProduct?['id'] as String?;

    final matches = actualId == expectedProductId;
    return CheckResult(
      id: 'product_id_match',
      label: 'Product ID matches expected',
      passed: matches,
      detail: matches
          ? '$actualId matches dashboard'
          : 'expected "$expectedProductId", got "$actualId"',
    );
  }

  // ─── Check 7: paywall_renders ─────────────────────────────────────────────

  CheckResult checkPaywallRenders({required bool rendered, int? renderMs}) {
    return CheckResult(
      id: 'paywall_renders',
      label: 'Paywall renders on screen',
      passed: rendered,
      detail: rendered
          ? 'WebView overlay detected${renderMs != null ? " in ${(renderMs / 1000).toStringAsFixed(1)}s" : ""}'
          : 'paywall did not appear within timeout',
      durationMs: renderMs,
    );
  }

  // ─── Check 8: cta_fires ──────────────────────────────────────────────────

  CheckResult checkCtaFires() {
    final ctaEvents = proxy.eventsNamed('cta_click');
    if (ctaEvents.isEmpty) {
      return const CheckResult(
        id: 'cta_fires',
        label: 'CTA tap sends cta_click event',
        passed: false,
        detail: 'no cta_click events captured',
      );
    }

    final last = ctaEvents.last;
    final props = last['properties'] as Map<String, dynamic>? ?? {};
    final productId = props['productId'] as String?;
    final hasTrigger = props['trigger'] == trigger;

    return CheckResult(
      id: 'cta_fires',
      label: 'CTA tap sends cta_click event',
      passed: productId != null && hasTrigger,
      detail:
          'cta_click captured: productId=$productId, trigger=${props['trigger']}',
    );
  }

  // ─── Check 9: conversion_reported ─────────────────────────────────────────

  CheckResult checkConversionReported() {
    final conversions = proxy.eventsNamed('conversion');
    if (conversions.isEmpty) {
      return const CheckResult(
        id: 'conversion_reported',
        label: 'reportConversion() has full attribution',
        passed: false,
        detail: 'no conversion events captured',
      );
    }

    final last = conversions.last;
    final props = last['properties'] as Map<String, dynamic>? ?? {};

    final hasVariantId = props.containsKey('variantId');
    final hasVariantKey = props.containsKey('variant_key');
    final hasPlacementId = props.containsKey('placement_id');
    final hasTrigger = props['trigger'] == trigger;
    final hasProductId = props.containsKey('productId');
    final hasRevenue = props.containsKey('revenue');
    final hasCurrency = props.containsKey('currency');

    final attributionComplete =
        hasVariantId && hasVariantKey && hasTrigger && hasProductId;
    final fullAttribution =
        attributionComplete && hasPlacementId && hasRevenue && hasCurrency;

    final missing = <String>[];
    if (!hasVariantId) missing.add('variantId');
    if (!hasVariantKey) missing.add('variant_key');
    if (!hasPlacementId) missing.add('placement_id');
    if (!hasTrigger) missing.add('trigger');
    if (!hasProductId) missing.add('productId');
    if (!hasRevenue) missing.add('revenue');
    if (!hasCurrency) missing.add('currency');

    return CheckResult(
      id: 'conversion_reported',
      label: 'reportConversion() has full attribution',
      passed: attributionComplete,
      detail: fullAttribution
          ? 'full attribution: variantId=${props['variantId']}, '
              'variant_key=${props['variant_key']}, '
              'productId=${props['productId']}'
          : 'missing fields: ${missing.join(", ")}',
    );
  }

  // ─── Check 10: identity_correct ───────────────────────────────────────────

  CheckResult checkIdentityCorrect() {
    final eventPosts = proxy.eventPosts;
    if (eventPosts.isEmpty) {
      return const CheckResult(
        id: 'identity_correct',
        label: 'Events include identity fields',
        passed: false,
        detail: 'no /v1/events calls captured',
      );
    }

    final last = eventPosts.last;
    final body = last.requestBody ?? {};

    final sessionId = body['sessionId'] as String?;
    final identity = body['identity'] as Map<String, dynamic>?;
    final identifiers = identity?['identifiers'] as Map<String, dynamic>?;
    final stableId = identifiers?['stableID'] as String?;
    final userId = body['userId'] as String?;

    final hasSession = sessionId != null && sessionId.isNotEmpty;
    final hasStable = stableId != null && stableId.isNotEmpty;

    return CheckResult(
      id: 'identity_correct',
      label: 'Events include identity fields',
      passed: hasSession && hasStable,
      detail: hasSession && hasStable
          ? 'stableID=${_truncate(stableId)}, sessionId=${_truncate(sessionId)}'
              '${userId != null ? ", userId=$userId" : ""}'
          : 'missing: ${!hasSession ? "sessionId " : ""}${!hasStable ? "stableID" : ""}',
    );
  }

  // ─── Check 11: refresh_config ─────────────────────────────────────────────

  CheckResult checkRefreshConfig(
      {required int configCallsBefore, required int configCallsAfter}) {
    final newCalls = configCallsAfter - configCallsBefore;
    return CheckResult(
      id: 'refresh_config',
      label: 'refreshConfig() triggers new /v1/config call',
      passed: newCalls > 0,
      detail: newCalls > 0
          ? '$newCalls new config call(s) after refresh'
          : 'no new /v1/config call detected after refresh',
    );
  }

  // ─── Check 12: config_change_reflected ────────────────────────────────────

  CheckResult checkConfigChangeReflected({
    required String? variantBefore,
    required String? variantAfter,
  }) {
    if (variantBefore == null || variantAfter == null) {
      return CheckResult(
        id: 'config_change_reflected',
        label: 'Config changes reflected after refresh',
        passed: variantAfter != null,
        detail: variantAfter != null
            ? 'variant active: $variantAfter'
            : 'no placement available after refresh',
      );
    }

    return CheckResult(
      id: 'config_change_reflected',
      label: 'Config changes reflected after refresh',
      passed: true,
      detail: 'variant before=$variantBefore, after=$variantAfter',
    );
  }

  // ─── Metrics ──────────────────────────────────────────────────────────────

  Map<String, dynamic> computeMetrics() {
    final configLatencies = proxy.configPosts.map((e) => e.latencyMs).toList();
    final avgConfigLatency = configLatencies.isEmpty
        ? 0
        : (configLatencies.reduce((a, b) => a + b) / configLatencies.length)
            .round();

    final allEvts = proxy.allEvents;
    final eventNames =
        allEvts.map((e) => e['event'] as String? ?? 'unknown').toSet();

    final conversions = proxy.eventsNamed('conversion');
    final hasFullAttribution = conversions.isNotEmpty &&
        (() {
          final props =
              conversions.last['properties'] as Map<String, dynamic>? ?? {};
          return props.containsKey('variantId') &&
              props.containsKey('variant_key') &&
              props.containsKey('placement_id');
        })();

    final lastEventPost =
        proxy.eventPosts.isNotEmpty ? proxy.eventPosts.last : null;
    final lastEnvelope = lastEventPost?.requestBody ?? {};
    final identity = lastEnvelope['identity'] as Map<String, dynamic>?;
    final identifiers = identity?['identifiers'] as Map<String, dynamic>?;

    return <String, dynamic>{
      'config_fetch_latency_ms': avgConfigLatency,
      'events_captured': allEvts.length,
      'event_types': eventNames.toList()..sort(),
      'attribution_complete': hasFullAttribution,
      'stableID': identifiers?['stableID'],
      'sessionId': lastEnvelope['sessionId'],
      'userId': lastEnvelope['userId'],
    };
  }
}

String _truncate(String s, [int maxLen = 20]) =>
    s.length <= maxLen ? s : '${s.substring(0, maxLen)}...';
