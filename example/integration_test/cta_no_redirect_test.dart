import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:tranzmit_flutter/tranzmit_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('route CTA can show host dialog above the paywall',
      (tester) async {
    final client = TranzmitClient(
      storage: MemoryTranzmitStorage(),
      httpClient: _ConfigHttpClient(),
    );
    TranzmitController? controller;
    var ctaCount = 0;
    var dialogShown = false;

    await tester.pumpWidget(
      TranzmitProvider(
        config: const TranzmitConfig(
          publicKey: 'pk_test_demo',
          apiBaseUrl: 'https://example.test',
        ),
        client: client,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              controller = Tranzmit.of(context);
              return Scaffold(
                backgroundColor: Colors.black,
                body: Center(
                  child: FilledButton(
                    key: const Key('present-paywall'),
                    onPressed: () {
                      late final GateResult result;
                      result = Tranzmit.presentPlacementInRoute(
                        context,
                        'upgrade_pro',
                        presentation: PresentationMode.fullscreen,
                        onCTA: (_) async {
                          ctaCount++;
                          dialogShown = true;
                          await showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              key: const Key('payment-dialog'),
                              title: const Text('Payment failed'),
                              content:
                                  const Text('Try another payment method.'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          );
                          result.dismiss();
                        },
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

    await tester.tap(find.byKey(const Key('present-paywall')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(controller!.activePaywalls, isEmpty);

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await tester.pump(const Duration(milliseconds: 700));

    expect(ctaCount, 1);
    expect(dialogShown, isTrue);
    expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
    expect(find.text('Payment failed'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await client.flush();
  });
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

const _paywallSpec = {
  'renderer': 'webview',
  'templateId': 'cta_no_redirect',
  'revision': 'test-1',
  'cacheKey': 'cta_no_redirect:test-1',
  'header': {
    'title': 'Unlock Pro',
    'subtitle': 'Get unlimited exports',
  },
  'document': {
    'html': '''
<main class="tranzmit-paywall" style="min-height:100vh;background:#121212;color:white;font-family:sans-serif;padding:24px;">
  <a class="cta" href="about:blank" style="position:fixed;inset:0;background:#7c3aed;color:white;display:flex;align-items:center;justify-content:center;text-align:center;text-decoration:none;font-size:24px;font-weight:700;">
    Start Free Trial
  </a>
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
