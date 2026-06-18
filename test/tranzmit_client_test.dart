import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tranzmit_flutter/tranzmit_flutter.dart';

const _baseSpec = {
  'renderer': 'webview',
  'templateId': 'test_paywall',
  'revision': 'test-1',
  'cacheKey': 'test_paywall:test-1',
  'header': {
    'title': 'Unlock Pro',
    'subtitle': 'Get unlimited exports',
  },
  'document': {
    'html':
        '<main><h1>Unlock Pro</h1><button data-tranzmit-action="cta" data-product-id="pro_monthly">Start Free Trial</button></main>',
    'css': 'body{font-family:sans-serif}',
  },
  'bridge': {
    'version': 1,
    'allowedActions': ['cta', 'dismiss', 'open_url'],
  },
  'cta': 'Start Free Trial',
  'secondaryCta': 'Maybe later',
  'theme': 'light',
  'features': ['Unlimited exports', 'Priority support'],
  'products': [
    {
      'id': 'pro_monthly',
      'name': 'Pro Monthly',
      'price': {'amount': 999, 'currency': 'USD', 'interval': 'month'},
      'badge': 'Popular',
      'highlighted': true,
    },
    {
      'id': 'pro_yearly',
      'name': 'Pro Yearly',
      'price': {'amount': 9999, 'currency': 'USD', 'interval': 'year'},
    },
  ],
};

const _mockConfig = {
  'version': '1.0.0',
  'placements': {
    'upgrade_pro': {
      'trigger': 'upgrade_pro',
      'enabled': true,
      'variantId': 'var_a',
      'spec': _baseSpec,
    },
  },
  'assets': <String, Object?>{},
  'ttl': 300,
};

void main() {
  test('generates and persists stable IDs per public key', () async {
    final storage = MemoryTranzmitStorage();
    final first = await resolveIdentity(
      publicKey: 'pk_test_one',
      storage: storage,
    );
    final second = await resolveIdentity(
      publicKey: 'pk_test_one',
      storage: storage,
    );
    final third = await resolveIdentity(
      publicKey: 'pk_test_two',
      storage: storage,
    );

    expect(first.identifiers['stableID'], startsWith('trz_'));
    expect(second.identifiers['stableID'], first.identifiers['stableID']);
    expect(third.identifiers['stableID'], isNot(first.identifiers['stableID']));
  });

  test('resolveIdentity preserves userId', () async {
    final identity = await resolveIdentity(
      publicKey: 'pk_test_user',
      userId: 'user_123',
      storage: MemoryTranzmitStorage(),
    );

    expect(identity.userId, 'user_123');
    expect(identity.toJson()['userId'], 'user_123');
  });

  test('later init wins when init is called twice with different identity',
      () async {
    final client = TranzmitClient(
      storage: MemoryTranzmitStorage(),
      httpClient: RecordingHttpClient(),
    );

    await client.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    await client.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
        userId: 'user_456',
      ),
    );

    expect(client.identity?.userId, 'user_456');
  });

  test('parses paywall specs and placement config', () {
    final response = ConfigResponse.fromJson(
      jsonDecode(jsonEncode(_mockConfig)) as JsonMap,
    );
    final placement = response.placements['upgrade_pro'];

    expect(placement, isNotNull);
    expect(placement!.enabled, isTrue);
    expect(placement.spec.products, hasLength(2));
    expect(placement.spec.renderer, 'webview');
    expect(placement.spec.document?.html, contains('Start Free Trial'));
    expect(placement.spec.products.first.price, isA<ProductPrice>());
  });

  test('calls fallback when placement is requested before SDK is ready', () {
    final controller = TranzmitController(
      TranzmitClient(storage: MemoryTranzmitStorage()),
    );
    FallbackEvent? fallback;

    final result = controller.gate(
      'upgrade_pro',
      GateOptions(onFallback: (event) => fallback = event),
    );

    expect(result.shown, isFalse);
    expect(fallback?.trigger, 'upgrade_pro');
    expect(fallback?.reason, FallbackReason.notReady);
  });

  test('calls fallback when placement is missing', () async {
    final controller = TranzmitController(
      TranzmitClient(
        storage: MemoryTranzmitStorage(),
        httpClient: RecordingHttpClient(),
      ),
    );
    await controller.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    FallbackEvent? fallback;

    final result = controller.gate(
      'missing_trigger',
      GateOptions(onFallback: (event) => fallback = event),
    );

    expect(result.shown, isFalse);
    expect(fallback?.trigger, 'missing_trigger');
    expect(fallback?.reason, FallbackReason.placementNotFound);
  });

  test('keeps paywall visible when CTA callback is empty', () async {
    final controller = TranzmitController(
      TranzmitClient(
        storage: MemoryTranzmitStorage(),
        httpClient: RecordingHttpClient(),
      ),
    );
    await controller.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    var ctaCount = 0;

    final result = controller.gate(
      'upgrade_pro',
      GateOptions(onCTA: (_) => ctaCount++),
    );
    final active = controller.activePaywalls.single;
    controller.handleCTA(active, active.placement.spec.products.first);

    expect(result.shown, isTrue);
    expect(ctaCount, 1);
    expect(controller.activePaywalls, hasLength(1));
  });

  test('calls fallback when paywall rendering fails', () async {
    final controller = TranzmitController(
      TranzmitClient(
        storage: MemoryTranzmitStorage(),
        httpClient: RecordingHttpClient(),
      ),
    );
    await controller.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    FallbackEvent? fallback;

    final result = controller.gate(
      'upgrade_pro',
      GateOptions(onFallback: (event) => fallback = event),
    );
    final active = controller.activePaywalls.single;
    controller.handlePaywallError(active, StateError('broken WebView'));

    expect(result.shown, isTrue);
    expect(controller.activePaywalls, isEmpty);
    expect(fallback?.trigger, 'upgrade_pro');
    expect(fallback?.reason, FallbackReason.renderError);
    expect(fallback?.variantId, 'var_a');
    expect(fallback?.error, isA<StateError>());
  });

  test('preloads placement without sending an impression', () async {
    final httpClient = RecordingHttpClient();
    final controller = TranzmitController(
      TranzmitClient(
        storage: MemoryTranzmitStorage(),
        httpClient: httpClient,
      ),
    );
    await controller.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    await controller.flush();
    httpClient.requests.clear();

    final preloadFuture = controller.preloadPlacement('upgrade_pro');
    final preload = controller.preloadedPaywalls.single;
    expect(preload.status, PreloadStatus.loading);

    await controller.flush();
    expect(httpClient.requests, isEmpty);

    controller.markPreloadReady(preload.trigger, preload.key);
    final preloadResult = await preloadFuture;
    expect(preloadResult.ready, isTrue);
    expect(controller.preloadedPaywalls.single.status, PreloadStatus.ready);

    await controller.flush();
    expect(httpClient.requests, isEmpty);

    final result = controller.presentPlacement('upgrade_pro');
    expect(result.shown, isTrue);

    await controller.flush();
    expect(httpClient.requests, hasLength(1));
    final body =
        jsonDecode(httpClient.requests.single.body) as Map<String, dynamic>;
    final events = body['events'] as List<dynamic>;
    expect(events.single['event'], 'impression');
  });

  test('route presentations claim ready preloads without sending an impression',
      () async {
    final httpClient = RecordingHttpClient();
    final controller = TranzmitController(
      TranzmitClient(
        storage: MemoryTranzmitStorage(),
        httpClient: httpClient,
      ),
    );
    await controller.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    await controller.flush();
    httpClient.requests.clear();

    final preloadFuture = controller.preloadPlacement('upgrade_pro');
    final preload = controller.preloadedPaywalls.single;
    controller.markPreloadReady(preload.trigger, preload.key);
    expect((await preloadFuture).ready, isTrue);

    final placement = controller.getPlacement('upgrade_pro')!;
    final claimed = controller.claimReadyPreloadForRoute(
      'upgrade_pro',
      placement,
      PresentationMode.sheet,
    );

    expect(claimed, same(preload));
    expect(controller.preloadedPaywalls, isEmpty);

    await controller.flush();
    expect(httpClient.requests, isEmpty);
  });

  test('refresh invalidates preloaded placements', () async {
    final httpClient = RecordingHttpClient();
    final controller = TranzmitController(
      TranzmitClient(
        storage: MemoryTranzmitStorage(),
        httpClient: httpClient,
      ),
    );
    await controller.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );

    final preloadFuture = controller.preloadPlacement('upgrade_pro');
    final preload = controller.preloadedPaywalls.single;
    controller.markPreloadReady(preload.trigger, preload.key);
    expect((await preloadFuture).ready, isTrue);

    final nextConfig = jsonDecode(jsonEncode(_mockConfig)) as JsonMap;
    final placement =
        nextConfig['placements']['upgrade_pro'] as Map<String, dynamic>;
    final spec = placement['spec'] as Map<String, dynamic>;
    spec['revision'] = 'test-2';
    spec['cacheKey'] = 'test_paywall:test-2';
    httpClient.configResponse = nextConfig;

    await controller.refreshConfig();

    expect(controller.preloadedPaywalls, isEmpty);
  });

  test('hydrates hosted WebView documents before caching config', () async {
    final httpClient = RecordingHttpClient(hostedDocumentMode: true);
    final client = TranzmitClient(
      storage: MemoryTranzmitStorage(),
      httpClient: httpClient,
    );

    await client.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );

    final placement = client.getPlacement('upgrade_pro');
    expect(placement, isNotNull);
    expect(placement!.spec.document?.html, contains('Hosted Upgrade'));
    expect(
      httpClient.requests.map((request) => request.url.path),
      contains('/v1/paywall-documents/pl_1/var_a/hosted:test-1.json'),
    );
  });

  test('flushes when the queue reaches ten events', () async {
    final httpClient = RecordingHttpClient();
    final client = TranzmitClient(
      storage: MemoryTranzmitStorage(),
      httpClient: httpClient,
      metadata: const PlatformMetadata(
        platform: 'flutter',
        os: 'ios',
        sdkVersion: '0.1.0',
      ),
    );

    await client.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    await client.flush();
    httpClient.requests.clear();

    for (var i = 0; i < 10; i++) {
      client.track('feature_clicked', {'i': i});
    }

    await Future<void>.delayed(Duration.zero);
    expect(httpClient.requests, hasLength(1));
    final body =
        jsonDecode(httpClient.requests.single.body) as Map<String, dynamic>;
    expect(body['events'], hasLength(10));
    expect(body['events'][0]['properties']['platform'], 'flutter');
    expect(body['events'][0]['properties']['os'], 'ios');
  });

  test('reports conversions immediately', () async {
    final httpClient = RecordingHttpClient();
    final client = TranzmitClient(
      storage: MemoryTranzmitStorage(),
      httpClient: httpClient,
    );

    await client.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );
    await client.flush();
    httpClient.requests.clear();

    client.reportConversion({
      'trigger': 'upgrade_pro',
      'productId': 'pro_monthly',
      'revenue': 9.99,
      'currency': 'USD',
    });

    await Future<void>.delayed(Duration.zero);
    expect(httpClient.requests, hasLength(1));
    final body =
        jsonDecode(httpClient.requests.single.body) as Map<String, dynamic>;
    final events = body['events'] as List<dynamic>;
    final conversion = events.firstWhere(
      (event) => event['event'] == 'conversion',
    ) as Map<String, dynamic>;
    expect(conversion['properties']['productId'], 'pro_monthly');
    expect(conversion['properties']['variantId'], 'var_a');
  });
}

class RecordedRequest {
  RecordedRequest({required this.url, required this.body});

  final Uri url;
  final String body;
}

class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient({this.hostedDocumentMode = false, this.configResponse});

  final bool hostedDocumentMode;
  Map<String, Object?>? configResponse;
  final List<RecordedRequest> requests = <RecordedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    requests.add(RecordedRequest(url: request.url, body: body));

    final responseBody = request.url.path.endsWith('/v1/config')
        ? jsonEncode(
            configResponse ??
                (hostedDocumentMode ? _hostedConfig() : _mockConfig),
          )
        : request.url.path.contains('/v1/paywall-documents/')
            ? jsonEncode({
                'html': '<main><h1>Hosted Upgrade</h1></main>',
                'css': 'body{font-family:sans-serif}',
                'integrity': 'sha256-test',
              })
            : '{}';
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(responseBody)),
      200,
      headers: {'Content-Type': 'application/json'},
    );
  }

  Map<String, Object?> _hostedConfig() {
    final config = jsonDecode(jsonEncode(_mockConfig)) as Map<String, dynamic>;
    final placement =
        config['placements']['upgrade_pro'] as Map<String, dynamic>;
    final spec = placement['spec'] as Map<String, dynamic>;
    spec['cacheKey'] = 'hosted:test-1';
    spec['document'] = {
      'url':
          'https://example.test/v1/paywall-documents/pl_1/var_a/hosted:test-1.json?key=pk_test_demo',
      'integrity': 'sha256-test',
    };
    return config;
  }
}
