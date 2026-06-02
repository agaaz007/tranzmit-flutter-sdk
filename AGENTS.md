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

### Step 6: Present The Placement

At the upgrade point, call:

```dart
final tranzmit = Tranzmit.of(context);

final result = tranzmit.presentPlacement(
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
  },
);

if (!result.shown) {
  debugPrint('Tranzmit placement not shown');
}
```

Replace `upgrade_pro` with the dashboard trigger if Tranzmit supplied a different trigger.

### Step 7: Wire Billing Safely

`onCTA` receives a Tranzmit `ProductSpec`.

1. Read `product.id`; this is the dashboard **Billing Product ID**.
2. Use `product.id` to start the host app's billing flow.
3. Wait for billing success.
4. Let the host app grant entitlements.
5. Call `reportConversion()` only after success.

Never call `reportConversion()` before the purchase provider confirms the transaction.

### Step 8: Verify Locally

Before marking the task done:

1. Run `flutter pub get`.
2. Run the app.
3. Confirm no `onError` logs appear.
4. Confirm `Tranzmit.of(context).isReady` becomes `true`.
5. Confirm `Tranzmit.of(context).getPlacement('upgrade_pro')` returns a placement.
6. Confirm the placement's product ID matches the expected billing product.
7. Trigger `presentPlacement('upgrade_pro')`.
8. Confirm the remote paywall renders.
9. Tap CTA and confirm the host billing flow starts for the expected product.
10. Complete a sandbox/test purchase.
11. Confirm `reportConversion()` is called after success.

### Step 9: Verify Remote Config

During QA:

1. Change paywall copy, Billing Product ID, placement status, or variant split in the Tranzmit dashboard.
2. Call `await Tranzmit.of(context).refreshConfig()`.
3. Present the placement again.
4. Confirm the app reflects the dashboard change without an app release.

### Step 10: Final Acceptance Checklist

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

The SDK always adds a generated `stableID` under `identity.identifiers.stableID`. For paywall experiments, Statsig should bucket on `stableID` so logged-out and logged-in requests from the same install keep the same paywall variant.

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

```dart
final tranzmit = Tranzmit.of(context);

final result = tranzmit.presentPlacement(
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
  },
);

if (!result.shown) {
  debugPrint('Tranzmit placement not shown');
}
```

`onCTA` receives the product selected in the paywall. `product.id` is the **Billing Product ID** configured in the Tranzmit dashboard. The app must call its billing system with `product.id` and only call `reportConversion()` after billing succeeds.

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
4. Call `presentPlacement('upgrade_pro')` and confirm the remote paywall renders.
5. Tap CTA and confirm the host purchase flow starts for `product.id`.
6. Complete a test purchase and confirm `reportConversion()` runs.
7. Change paywall copy, Billing Product ID, or variant setup in the dashboard.
8. Call `await Tranzmit.of(context).refreshConfig()`.
9. Present again and confirm remote changes are visible.

## Statsig Checklist

For dynamic paywalls:

1. The dashboard client must have a Statsig server secret env var configured.
2. The placement must have a Statsig experiment id.
3. The Statsig experiment must return a parameter named `variant_id`.
4. `variant_id` values must match Tranzmit variant keys exactly.
5. Paywall experiments should bucket on custom id `stableID`.
6. Logged-in apps should still pass real `userId` for analytics.

Expected variant keys for the current demo setup:

- `control`
- `intro_offer`
- `annual_pro`

## Common Mistakes

- Importing the wrong package name. Use `tranzmit_flutter`, not `tranzmit-flutter-sdk`.
- Calling `presentPlacement()` before `TranzmitProvider` is in the widget tree.
- Forgetting to pass the public key supplied by Tranzmit.
- Generating random logged-out user IDs instead of relying on `stableID`.
- Hardcoding paywall UI in the host app.
- Hardcoding billing product IDs in the host app instead of using `product.id`.
- Calling conversion before billing succeeds.
- Using Statsig values that do not match Tranzmit variant keys.
