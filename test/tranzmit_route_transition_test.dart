import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tranzmit_flutter/tranzmit_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

const _fakeWebViewKey = Key('fake-webview');
const _paywallRouteTransitionKey =
    ValueKey<String>('tranzmit_paywall_route_transition');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
  });

  testWidgets('route paywall honors custom transition durations',
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
                        reverseTransitionDuration:
                            const Duration(milliseconds: 300),
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    expect(find.byKey(_fakeWebViewKey), findsOneWidget);
    expect(_routeFadeTransition(tester).opacity.value, lessThan(1));

    await tester.pumpAndSettle();
    expect(find.byKey(_fakeWebViewKey), findsNothing);

    await controller.flush();
  });
}

FadeTransition _routeFadeTransition(WidgetTester tester) {
  return tester.widget<FadeTransition>(
    find.byKey(_paywallRouteTransitionKey),
  );
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
