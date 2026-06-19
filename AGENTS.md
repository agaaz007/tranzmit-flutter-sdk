# Agent Guide: tranzmit-flutter-sdk

This file is for Claude, Codex, Cursor agents, and other coding agents integrating the Tranzmit Flutter SDK into a customer Flutter app.

## Agent Integration Runbook

Follow these steps in order. Do not skip ahead unless the app already has that exact step completed.

### Step 1: Confirm Inputs

Ask the human or project owner for:

1. `publicKey`: the Tranzmit dashboard public key.
2. `placementTrigger`: the dashboard trigger, usually `upgrade_pro`.
3. Optional `apiBaseUrl`: only if Tranzmit provided a non-default API URL.
4. Billing Product ID for each paywall variant. This must match the host app's StoreKit, Play Billing, RevenueCat, or custom billing product/package ID.
5. The app's purchase API: RevenueCat, StoreKit, Google Play Billing, or a custom billing wrapper.
6. The app's logged-in user model: where the real app user ID is available.

If `publicKey` or `placementTrigger` is missing, stop and ask. Do not invent them.

### Step 2: Confirm Dashboard Product IDs

Before wiring billing, confirm each Tranzmit paywall variant has **Billing Product ID** set in the dashboard.

Examples:

1. StoreKit: `com.customer.app.pro.yearly`.
2. Google Play Billing: `pro_yearly`.
3. RevenueCat: the product/package ID passed into the customer's RevenueCat purchase call.

This dashboard value becomes `spec.products[0].id`. On CTA, the SDK calls `onCTA(product)` and `product.id` is the value the app must use for billing.

If the product ID is missing or wrong, stop and ask the human to fix the dashboard config. Do not hardcode a different billing product ID in the app.

### Step 3: Add The Dependency

Edit the host app's `pubspec.yaml`:

```yaml
dependencies:
  tranzmit_flutter:
    git:
      url: https://github.com/agaaz007/tranzmit-flutter-sdk.git
      ref: main
```

Run:

```bash
flutter pub get
```

### Step 4: Import The SDK

Add this import in the app entrypoint or root app file:

```dart
import 'package:tranzmit_flutter/tranzmit_flutter.dart';
```

Use `tranzmit_flutter` for Dart imports. `tranzmit-flutter-sdk` is only the GitHub repo name.

### Step 5: Wrap The App

Place `TranzmitProvider` above routes/screens that can show a paywall:

```dart
TranzmitProvider(
  config: const TranzmitConfig(
    publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
  ),
  onError: (error) {
    debugPrint('[Tranzmit] ${error.code}: ${error.message}');
  },
  child: const MyApp(),
)
```

If the app has a current user at startup, pass it:

```dart
TranzmitConfig(
  publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
  userId: currentUser.id,
)
```

If the user is logged out, omit `userId`. The SDK generates `stableID`; do not generate a fake user ID.

### Step 6: Preload The Placement

After the SDK is ready, warm hosted paywalls before the user taps the upgrade button:

```dart
final tranzmit = Tranzmit.of(context);

if (tranzmit.isReady) {
  final preload = await tranzmit.preloadPlacement('upgrade_pro');
  debugPrint('Tranzmit preload: ${preload.status.name}');
}
```

`preloadPlacement()` mounts a hidden but attached WebView in `TranzmitProvider`, loads the hosted document, and completes when the WebView finishes loading or the document posts a `ready` bridge event.

Preloading does not send an impression, does not report conversion, and does not show UI. The impression fires only when the host app later presents the placement.

Both the default `Tranzmit.of(context).presentPlacement(...)` provider-overlay path and `Tranzmit.presentPlacementInRoute(...)` can reuse a matching preload slot. If the preload is still loading, the route path continues that in-flight WebView load instead of starting a new cold WebView. Keep `presentPlacementInRoute(...)` opt-in for post-CTA Flutter UI layering, such as checkout modals, bottom sheets, dialogs, snackbars, or pushed checkout screens above the paywall.

### Step 7: Present The Placement

At the upgrade point, call:

```dart
final tranzmit = Tranzmit.of(context);

late final GateResult result;
result = tranzmit.presentPlacement(
  'upgrade_pro',
  onCTA: (product) async {
    // product.id is the Billing Product ID configured in Tranzmit.
    await purchaseProduct(product.id);

    tranzmit.reportConversion({
      'trigger': 'upgrade_pro',
      'productId': product.id,
      'revenue': 999,
      'currency': 'INR',
    });

    result.dismiss();
  },
);

if (!result.shown) {
  debugPrint('Tranzmit placement not shown');
}
```

Replace `upgrade_pro` with the dashboard trigger if Tranzmit supplied a different trigger.

The SDK does not dismiss the paywall on CTA by itself. If `onCTA` is empty, the paywall stays visible. Call `result.dismiss()` from the host app after checkout succeeds, or when the user closes the paywall.

### Step 8: Wire Billing Safely

`onCTA` receives a Tranzmit `ProductSpec`.

1. Read `product.id`; this is the dashboard **Billing Product ID**.
2. Use `product.id` to start the host app's billing flow.
3. Wait for billing success.
4. Let the host app grant entitlements.
5. Call `reportConversion()` only after success.
6. Call `result.dismiss()` to close the paywall.

Never call `reportConversion()` before the purchase provider confirms the transaction.

For Razorpay, put checkout inside `onCTA`:

```dart
late final GateResult result;
result = tranzmit.presentPlacement(
  'upgrade_pro',
  onCTA: (product) async {
    final success = await startRazorpayCheckout(product.id);
    if (!success) return;

    await grantPaidEntitlement();

    tranzmit.reportConversion({
      'trigger': 'upgrade_pro',
      'productId': product.id,
      'revenue': 999,
      'currency': 'INR',
    });

    result.dismiss();
  },
);
```

CTA taps are callbacks, not WebView redirects. Do not navigate the hosted paywall to Razorpay or `about:blank`; keep checkout in Flutter `onCTA`.

Use `Tranzmit.of(context).presentPlacement(...)` by default. It is the
lightweight provider-overlay path, keeps existing deployments unchanged, and
reuses any ready slot created by `preloadPlacement()`.

Use `Tranzmit.presentPlacementInRoute(...)` only when the host app must show
Flutter UI above the paywall after the hosted CTA is tapped, while the paywall
is still visible. This includes terms and conditions popups, payment bottom
sheets, error/retry dialogs, snackbars, and pushed checkout screens.

```dart
final tranzmit = Tranzmit.of(context);

late final GateResult result;
result = Tranzmit.presentPlacementInRoute(
  context,
  'upgrade_pro',
  onCTA: (product) async {
    final acceptedTerms = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Accept terms'),
        content: const Text('Please accept the terms before checkout.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    if (acceptedTerms != true) return;

    final success = await startRazorpayCheckout(product.id);
    if (!success) return;

    tranzmit.reportConversion({
      'trigger': 'upgrade_pro',
      'productId': product.id,
      'revenue': 999,
      'currency': 'INR',
    });

    result.dismiss();
  },
);
```

Only use `presentPlacementInRoute` for this layering case. The route API is
opt-in per placement call; do not change global SDK config or migrate customers
who do not need post-CTA Flutter UI above the paywall.

### Step 9: Verify Locally

Before marking the task done:

1. Run `flutter pub get`.
2. Run the app.
3. Confirm no `onError` logs appear.
4. Confirm `Tranzmit.of(context).isReady` becomes `true`.
5. Confirm `Tranzmit.of(context).getPlacement('upgrade_pro')` returns a placement.
6. Confirm the placement's product ID matches the expected billing product.
7. Call `await Tranzmit.of(context).preloadPlacement('upgrade_pro')`.
8. Confirm the preload reaches `PreloadStatus.ready`.
9. Trigger `presentPlacement('upgrade_pro')`.
10. Confirm the remote paywall renders without a blank cold WebView moment.
11. Tap CTA and confirm the host billing flow starts for the expected product.
12. Complete a sandbox/test purchase.
13. Confirm `reportConversion()` is called after success.

### Step 10: Verify Remote Config

During QA:

1. Change paywall copy, Billing Product ID, placement status, or variant split in the Tranzmit dashboard.
2. Call `await Tranzmit.of(context).refreshConfig()`.
3. Present the placement again.
4. Confirm the app reflects the dashboard change without an app release.

### Step 11: Final Acceptance Checklist

The integration is not complete until all of these are true:

1. No hardcoded paywall UI was added to the host app.
2. `TranzmitProvider` wraps the paywall route tree.
3. Logged-in users send the real app `userId`.
4. Logged-out users rely on SDK-generated `stableID`.
5. Each dashboard variant has the right **Billing Product ID**.
6. Native billing remains owned by the host app.
7. Billing starts from `product.id`, not from a hardcoded app-side plan.
8. Conversions are reported only after billing succeeds.
9. The dashboard trigger used in code matches the trigger configured in Tranzmit.
10. Remote dashboard changes can be pulled with `refreshConfig()` during QA.

## Package Identity

- Distribution/repo name: `tranzmit-flutter-sdk`
- Dart package name: `tranzmit_flutter`
- Import: `package:tranzmit_flutter/tranzmit_flutter.dart`
- Main provider: `TranzmitProvider`
- Runtime accessor: `Tranzmit.of(context)`
- Default placement trigger: `upgrade_pro`

Do not rename the Dart package to `tranzmit-flutter-sdk`; Dart package names cannot contain hyphens.

## Integration Goal

The host app should not contain hardcoded paywall UI. The app initializes the SDK with a Tranzmit public key, asks Tranzmit to present a placement at the monetization moment, and handles native billing when the user taps the CTA.

Tranzmit controls:

- Paywall copy and layout.
- Hosted WebView document delivery.
- Placement activation and pause state.
- Billing Product ID per paywall variant.
- Statsig-backed variant assignment.
- Paywall event collection.

The host app controls:

- Authentication and app user IDs.
- Native purchase flow.
- Entitlement grants.
- Restore purchases.
- Refunds and subscription provider logic.

## Required Dependency

Add the package to the customer app's `pubspec.yaml`.

For a git dependency:

```yaml
dependencies:
  tranzmit_flutter:
    git:
      url: https://github.com/agaaz007/tranzmit-flutter-sdk.git
      ref: main
```

For a local vendored dependency:

```yaml
dependencies:
  tranzmit_flutter:
    path: ./tranzmit-flutter-sdk
```

Then run:

```bash
flutter pub get
```

## Root App Setup

Wrap the app with `TranzmitProvider`.

```dart
import 'package:flutter/material.dart';
import 'package:tranzmit_flutter/tranzmit_flutter.dart';

void main() {
  runApp(
    TranzmitProvider(
      config: TranzmitConfig(
        publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
        userId: currentUserOrNull?.id,
      ),
      onError: (error) {
        debugPrint('[Tranzmit] ${error.code}: ${error.message}');
      },
      child: const MyApp(),
    ),
  );
}
```

The SDK defaults to the hosted Tranzmit API. If the Tranzmit team supplies an explicit API URL, set `apiBaseUrl`.

```dart
TranzmitConfig(
  publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
  apiBaseUrl: 'https://api-production-2146.up.railway.app',
  userId: currentUserOrNull?.id,
)
```

## Identity Rules

Always pass `userId` when the app has a logged-in user. Omit `userId` when the user is logged out.

The SDK always adds a generated `stableID` under `identity.identifiers.stableID`.

**Statsig randomization unit:** If your Statsig experiment uses **User ID** (the default), pass the real app `userId` when the user is logged in. The Tranzmit server maps that to Statsig `userID`. When logged out, the server falls back to `stableID` as Statsig `userID` so anonymous installs still bucket. If your experiment intentionally randomizes on the custom id `stableID` instead, configure that in Statsig Console — both `userID` and `customIDs.stableID` are sent when available.

Logged-out payload shape:

```json
{
  "identity": {
    "identifiers": {
      "stableID": "trz_install_generated_by_sdk"
    }
  }
}
```

Logged-in payload shape:

```json
{
  "identity": {
    "userId": "customer_app_user_123",
    "identifiers": {
      "stableID": "trz_install_generated_by_sdk"
    }
  }
}
```

Do not generate a random `userId` for logged-out users. Let the SDK's `stableID` handle anonymous bucketing.

## Presenting The Paywall

Call `presentPlacement` where the app normally starts an upgrade flow.

When the app can anticipate the upgrade moment, preload the placement first:

```dart
final preload = await Tranzmit.of(context).preloadPlacement('upgrade_pro');
if (!preload.ready) {
  debugPrint('Tranzmit preload failed: ${preload.error}');
}
```

If preload is still loading or failed when the user taps upgrade, still call
`presentPlacement()`. The SDK uses the warm slot when available and falls back
to the normal hosted renderer path otherwise.

```dart
final tranzmit = Tranzmit.of(context);

late final GateResult result;
result = tranzmit.presentPlacement(
  'upgrade_pro',
  onCTA: (product) async {
    // product.id is the Billing Product ID configured in Tranzmit.
    await purchaseProduct(product.id);

    tranzmit.reportConversion({
      'trigger': 'upgrade_pro',
      'productId': product.id,
      'revenue': 999,
      'currency': 'INR',
    });

    result.dismiss();
  },
);

if (!result.shown) {
  debugPrint('Tranzmit placement not shown');
}
```

`onCTA` receives the product selected in the paywall. `product.id` is the **Billing Product ID** configured in the Tranzmit dashboard. The app must call its billing system with `product.id`, call `reportConversion()` only after billing succeeds, then call `result.dismiss()` to close the paywall.

If `onCTA` must open Flutter UI above the paywall, such as a terms and
conditions popup, payment bottom sheet, error dialog, snackbar, or checkout
screen, use `Tranzmit.presentPlacementInRoute(context, ...)` for that placement
instead of the default `Tranzmit.of(context).presentPlacement(...)`. A ready
`preloadPlacement()` slot is reused by this route path too, including when the
preload is still loading, so these flows can avoid restarting a cold WebView. Do
not use the route API unless the host app needs that layering behavior.

## Native Billing

Use the customer's existing billing provider. Common options:

- RevenueCat.
- Google Play Billing.
- StoreKit.
- A custom subscription service.

Do not call `reportConversion()` before the native purchase succeeds. Do not grant entitlements in Tranzmit.

Do not hardcode the billing product in the app. The product should come from the dashboard via `product.id`, so Tranzmit can route different paywall variants to different plans without an app release.

## QA Checklist

After integration:

1. Launch the app and confirm no `onError` logs.
2. Confirm `Tranzmit.of(context).getPlacement('upgrade_pro')` returns a placement after init.
3. Confirm the placement product ID matches the dashboard **Billing Product ID**.
4. Call `preloadPlacement('upgrade_pro')` and confirm it reaches `ready`.
5. Call `presentPlacement('upgrade_pro')` and confirm the remote paywall renders without a blank cold WebView moment.
6. Tap CTA and confirm the host purchase flow starts for `product.id`.
7. Complete a test purchase and confirm `reportConversion()` runs.
8. Change paywall copy, Billing Product ID, or variant setup in the dashboard.
9. Call `await Tranzmit.of(context).refreshConfig()`.
10. Preload and present again, then confirm remote changes are visible.

## Statsig Checklist

For dynamic paywalls:

1. The dashboard client must have a Statsig server secret env var configured.
2. The placement must have a Statsig experiment id.
3. The Statsig experiment must return a parameter named `variant_id`.
4. `variant_id` values must match Tranzmit variant keys exactly.
5. Paywall experiments should bucket on Statsig **User ID** when users are logged in (pass real `userId`). For logged-out traffic, the server uses `stableID` as Statsig `userID`, or you can configure Statsig to randomize on custom id `stableID`.
6. Logged-in apps should still pass real `userId` for analytics.

Expected variant keys for the current demo setup:

- `control`
- `intro_offer`
- `annual_pro`

## Automated QA Testing Agent

The SDK ships with a CLI-driven QA agent (`tool/qa_agent.dart`) that automates the full integration verification checklist. It boots the app on an emulator, intercepts HTTP traffic via a local proxy, and validates that events reach Railway correctly.

### Quick Start

```bash
# Test the SDK's own example app
dart run tool/qa_agent.dart \
  --app-path=example \
  --public-key=pk_test_2a8a5f07d4b9fcf1cc77e024 \
  --trigger=upgrade_pro \
  --expected-product=pro_monthly \
  --platform=ios

# Test a customer app
dart run tool/qa_agent.dart \
  --app-path=/path/to/customer/app \
  --public-key=pk_live_abc123 \
  --trigger=upgrade_pro \
  --expected-product=com.customer.pro.monthly \
  --platform=android \
  --json-output=qa_report.json
```

### CLI Options

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--app-path` | Yes | — | Path to the Flutter app directory |
| `--public-key` | Yes | — | Tranzmit public key |
| `--trigger` | No | `upgrade_pro` | Placement trigger |
| `--expected-product` | No | — | Expected billing product ID to validate |
| `--platform` | No | `ios` | Target: `ios` or `android` |
| `--proxy-port` | No | `9877` | Local intercepting proxy port |
| `--upstream` | No | Railway prod URL | Backend API to forward traffic to |
| `--integration-test` | No | — | Use `flutter drive` with integration_test |
| `--json-output` | No | — | Write structured JSON report to file |

### What It Checks

The agent runs 12 automated checks derived from the AGENTS.md verification checklist:

1. **pub_get** — Dependency resolves
2. **app_boots** — App launches without crash
3. **no_errors** — No `onError` callbacks fired
4. **sdk_ready** — `isReady` becomes true
5. **placement_fetched** — `/v1/config` returns an enabled placement
6. **product_id_match** — Product ID matches expected billing product
7. **paywall_renders** — WebView paywall appears
8. **cta_fires** — CTA tap sends `cta_click` event with correct productId
9. **conversion_reported** — `reportConversion()` has full attribution (variantId, variant_key, placement_id, trigger, productId, revenue, currency)
10. **identity_correct** — Events include `stableID` + `sessionId`
11. **refresh_config** — `refreshConfig()` triggers a new `/v1/config` call
12. **config_change_reflected** — Placement data updates after refresh

### Customer App Requirements

For the QA agent to work against a customer app:

1. The app must accept `--dart-define=TRANZMIT_API_BASE_URL=...` so the proxy can intercept traffic.
2. The upgrade/paywall trigger must be reachable via a known tap target.
3. If billing is real (not mocked), the agent stops at the CTA check.

The SDK's example app (`example/`) already satisfies all requirements and supports full end-to-end testing with a simulated purchase flow.

### Architecture

```
CLI (dart run tool/qa_agent.dart)
  ├── Local HTTP Proxy (port 9877)
  │     └── Captures /v1/config and /v1/events
  │     └── Forwards to real Railway API
  ├── Flutter Driver / integration_test
  │     └── Automates the app on emulator
  │     └── Test target: example/integration_test/qa_flow_test.dart
  │     └── Driver: example/test_driver/qa_flow_driver.dart
  └── Event Validator + Report Formatter
        └── Runs 12 checks against captured traffic
        └── Outputs terminal table + optional JSON
```

## Common Mistakes

- Importing the wrong package name. Use `tranzmit_flutter`, not `tranzmit-flutter-sdk`.
- Calling `presentPlacement()` before `TranzmitProvider` is in the widget tree.
- Calling `preloadPlacement()` before the SDK is ready, then assuming a failed preload warmed the WebView.
- Forgetting to pass the public key supplied by Tranzmit.
- Generating random logged-out user IDs instead of relying on `stableID`.
- Hardcoding paywall UI in the host app.
- Hardcoding billing product IDs in the host app instead of using `product.id`.
- Calling conversion before billing succeeds.
- Using Statsig values that do not match Tranzmit variant keys.
