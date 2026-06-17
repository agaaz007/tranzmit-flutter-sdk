import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tranzmit_flutter/tranzmit_flutter.dart';

/// Integration test target for the QA agent. Exercises the full SDK flow
/// against the live proxy: init → placement fetch → paywall render →
/// CTA → simulated purchase → reportConversion → refresh.
///
/// The proxy intercepts all traffic, so the QA checks can validate events
/// and config calls after this test completes.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('QA agent full flow', (tester) async {
    const apiBaseUrl = String.fromEnvironment(
      'TRANZMIT_API_BASE_URL',
      defaultValue: 'http://localhost:9877',
    );
    const publicKey = String.fromEnvironment(
      'TRANZMIT_PUBLIC_KEY',
      defaultValue: 'pk_test_2a8a5f07d4b9fcf1cc77e024',
    );
    const trigger = String.fromEnvironment(
      'TRANZMIT_TRIGGER',
      defaultValue: 'upgrade_pro',
    );

    TranzmitController? controller;

    await tester.pumpWidget(
      TranzmitProvider(
        config: const TranzmitConfig(
          publicKey: publicKey,
          apiBaseUrl: apiBaseUrl,
        ),
        onError: (error) => debugPrint('[QA] ${error.code}: ${error.message}'),
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              controller = Tranzmit.of(context);
              return Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        key: const Key('qa-present-paywall'),
                        onPressed: () {
                          late final GateResult result;
                          result = Tranzmit.presentPlacementInRoute(
                            context,
                            trigger,
                            onCTA: (product) async {
                              await showDialog<void>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  key: const Key('qa-purchase-dialog'),
                                  title: const Text('Confirm Purchase'),
                                  content: Text('Buy ${product.id}?'),
                                  actions: [
                                    TextButton(
                                      key: const Key('qa-confirm-purchase'),
                                      onPressed: () => Navigator.of(ctx).pop(),
                                      child: const Text('Buy'),
                                    ),
                                  ],
                                ),
                              );

                              controller!.reportConversion({
                                'trigger': trigger,
                                'productId': product.id,
                                'revenue': 999,
                                'currency': 'INR',
                              });
                              result.dismiss();
                            },
                          );
                        },
                        child: const Text('Present Paywall'),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('qa-refresh-config'),
                        onPressed: () async {
                          await controller?.refreshConfig();
                        },
                        child: const Text('Refresh Config'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    // Wait for SDK ready
    await _pumpUntil(
      tester,
      () => controller?.isReady == true,
      reason: 'SDK did not become ready',
      maxAttempts: 80,
    );
    expect(controller!.isReady, isTrue, reason: 'SDK should be ready');

    // Verify placement was fetched
    final placement = controller!.getPlacement(trigger);
    expect(placement, isNotNull,
        reason: 'Placement for "$trigger" should exist');

    // Present paywall
    await tester.tap(find.byKey(const Key('qa-present-paywall')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    // Tap the CTA in the WebView (center of screen)
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await tester.pump(const Duration(seconds: 1));

    // Confirm purchase dialog
    final confirmButton = find.byKey(const Key('qa-confirm-purchase'));
    if (confirmButton.evaluate().isNotEmpty) {
      await tester.tap(confirmButton);
      await tester.pumpAndSettle();
    }

    // Wait for events to flush
    await tester.pump(const Duration(seconds: 2));

    // Refresh config (checks 11-12)
    await tester.tap(find.byKey(const Key('qa-refresh-config')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxAttempts = 40,
}) async {
  for (var i = 0; i < maxAttempts; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 250));
  }
  fail(reason);
}
