import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tranzmit_flutter/tranzmit_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

const _fakeWebViewKey = Key('fake-webview');
const _paywallRouteTransitionKey =
    ValueKey<String>('tranzmit_paywall_route_transition');
const _paywallOverlayTransitionKey =
    ValueKey<String>('tranzmit_paywall_overlay_transition');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
  });

  testWidgets('route paywall honors custom appearance transition duration',
      (tester) async {
    final controller = TranzmitController(
      TranzmitClient(
        storage: MemoryTranzmitStorage(),
        httpClient: _ConfigHttpClient(),
      ),
    );
    await controller.init(
      const TranzmitConfig(
        publicKey: 'pk_test_demo',
        apiBaseUrl: 'https://example.test',
      ),
    );

    GateResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Tranzmit(
          controller: controller,
          child: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    key: const Key('present-paywall'),
                    onPressed: () {
                      result = Tranzmit.presentPlacementInRoute(
                        context,
                        'upgrade_pro',
                        presentation: PresentationMode.fullscreen,
                        transitionDuration: const Duration(milliseconds: 400),
                      );
                    },
                    child: const Text('Present paywall'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('present-paywall')));
    await tester.pump();

    expect(result?.shown, isTrue);
    await tester.pump();

    expect(find.byKey(_fakeWebViewKey), findsOneWidget);
    expect(_routeFadeTransition(tester).opacity.value, lessThan(1));

    await tester.pump(const Duration(milliseconds: 230));
    expect(_routeFadeTransition(tester).opacity.value, lessThan(1));

    await tester.pumpAndSettle();
    expect(_routeFadeTransition(tester).opacity.value, 1);

    result!.dismiss();
    await tester.pumpAndSettle();

    expect(find.byKey(_fakeWebViewKey), findsNothing);

    await controller.flush();
  });

  testWidgets('provider overlay paywall honors custom appearance duration',
      (tester) async {
    TranzmitController? controller;
    GateResult? result;

    await tester.pumpWidget(
      TranzmitProvider(
        config: const TranzmitConfig(
          publicKey: 'pk_test_demo',
          apiBaseUrl: 'https://example.test',
        ),
        client: TranzmitClient(
          storage: MemoryTranzmitStorage(),
          httpClient: _ConfigHttpClient(),
        ),
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              controller = Tranzmit.of(context);
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    key: const Key('present-overlay-paywall'),
                    onPressed: () {
                      result = controller!.presentPlacement(
                        'upgrade_pro',
                        presentation: PresentationMode.fullscreen,
                        transitionDuration: const Duration(milliseconds: 400),
                      );
                    },
                    child: const Text('Present paywall'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await _pumpUntil(
      tester,
      () => controller?.isReady == true,
      reason: 'SDK did not become ready',
    );

    await tester.tap(find.byKey(const Key('present-overlay-paywall')));
    await tester.pump();

    expect(result?.shown, isTrue);
    await tester.pump();

    expect(find.byKey(_fakeWebViewKey), findsOneWidget);
    expect(_overlayFadeOpacity(tester).opacity, lessThan(1));

    await tester.pump(const Duration(milliseconds: 230));
    expect(_overlayFadeOpacity(tester).opacity, lessThan(1));

    await tester.pumpAndSettle();
    expect(_overlayFadeOpacity(tester).opacity, 1);

    result!.dismiss();
    await tester.pump();
    expect(find.byKey(_fakeWebViewKey), findsNothing);

    await controller?.flush();
  });
}

FadeTransition _routeFadeTransition(WidgetTester tester) {
  return tester.widget<FadeTransition>(
    find.byKey(_paywallRouteTransitionKey),
  );
}

Opacity _overlayFadeOpacity(WidgetTester tester) {
  return tester.widget<Opacity>(
    find.byKey(_paywallOverlayTransitionKey),
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var i = 0; i < 40; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 250));
  }
  fail(reason);
}

class _ConfigHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request.url.path.endsWith('/v1/config')
        ? jsonEncode({
            'version': '1.0.0',
            'placements': {
              'upgrade_pro': {
                'trigger': 'upgrade_pro',
                'enabled': true,
                'variantId': 'var_a',
                'spec': _paywallSpec,
              },
            },
            'assets': <String, Object?>{},
            'ttl': 300,
          })
        : '{}';

    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      headers: {'Content-Type': 'application/json'},
    );
  }
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return _FakeNavigationDelegate(params);
  }

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    return _FakeWebViewController(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _FakeWebViewWidget(params);
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  PageEventCallback? onPageFinished;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params) : super.implementation();

  _FakeNavigationDelegate? _navigationDelegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> enableZoom(bool enabled) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    _navigationDelegate = handler as _FakeNavigationDelegate;
  }

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _navigationDelegate?.onPageFinished?.call(baseUrl ?? 'about:blank');
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      key: _fakeWebViewKey,
      color: Colors.black,
    );
  }
}

const _paywallSpec = {
  'renderer': 'webview',
  'templateId': 'route_transition',
  'revision': 'test-1',
  'cacheKey': 'route_transition:test-1',
  'header': {
    'title': 'Unlock Pro',
    'subtitle': 'Get unlimited exports',
  },
  'document': {
    'html': '''
<main class="tranzmit-paywall">
  <button data-tranzmit-action="cta" data-product-id="pro_monthly">
    Start Free Trial
  </button>
</main>
''',
    'css': 'body{margin:0;background:#121212;}',
  },
  'bridge': {
    'version': 1,
    'allowedActions': ['cta', 'dismiss', 'open_url'],
  },
  'cta': 'Start Free Trial',
  'theme': 'dark',
  'features': ['Unlimited exports'],
  'products': [
    {
      'id': 'pro_monthly',
      'name': 'Pro Monthly',
      'price': {'amount': 999, 'currency': 'INR', 'interval': 'month'},
      'highlighted': true,
    },
  ],
};
