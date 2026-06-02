# tranzmit-flutter-sdk

Client Flutter SDK for Tranzmit server-driven paywalls. The SDK fetches remote placement config, renders hosted paywall documents, assigns users through Statsig-backed experiments, and sends impression / CTA / dismissal / conversion events back to Tranzmit.

The git repository or distribution folder can be named `tranzmit-flutter-sdk`. The Dart package name is `tranzmit_flutter` because Dart package imports use underscores, not hyphens.

## What Customers Need

To integrate Tranzmit, a customer app needs:

- The Tranzmit Flutter package.
- A Tranzmit public key from the dashboard, for example `pk_live_...` or `pk_test_...`.
- A placement trigger configured in the dashboard, usually `upgrade_pro`.
- A Billing Product ID configured on each paywall variant in the Tranzmit dashboard.
- A stable app user id when the user is logged in.
- A native purchase implementation in the host app: StoreKit, Google Play Billing, RevenueCat, or another billing provider.

Once the public key and placement are configured in the dashboard, paywall changes and experiment splits flow remotely. The customer should not hardcode paywall UI in their app.

## Client Integration Steps

Use this checklist as the source of truth for customer engineers and AI coding agents.

### Step 1: Get The Tranzmit Inputs

Before editing the app, collect these values from the Tranzmit team:

1. `publicKey`: the dashboard client key, for example `pk_live_...`.
2. `placementTrigger`: the dashboard trigger to present, for example `upgrade_pro`.
3. Optional `apiBaseUrl`: only needed if Tranzmit gives you a non-default API URL.
4. Billing Product ID for each paywall variant. This must match the app's StoreKit, Play Billing, RevenueCat, or billing system product/package ID.

### Step 2: Configure Billing Product IDs In Tranzmit

In the Tranzmit dashboard, open each paywall variant and set **Billing Product ID**.

Examples:

1. StoreKit: `com.customer.app.pro.yearly`.
2. Google Play Billing: `pro_yearly`.
3. RevenueCat: the product/package ID the customer app uses to start purchase.

This value is saved as `spec.products[0].id`. When the user taps the paywall CTA, the Flutter SDK receives the matching `ProductSpec` and passes it to the host app as `product.id`.

If the dashboard product ID does not match the billing provider, the paywall will still open, but the app may start the wrong plan or fail to start checkout.

### Step 3: Add The Flutter Dependency

Add the SDK to the customer app's `pubspec.yaml`:

```yaml
dependencies:
  tranzmit_flutter:
    git:
      url: https://github.com/agaaz007/tranzmit-flutter-sdk.git
      ref: main
```

Then fetch dependencies:

```bash
flutter pub get
```

### Step 4: Import The SDK

Import the Dart package with underscores:

```dart
import 'package:tranzmit_flutter/tranzmit_flutter.dart';
```

Do not import `tranzmit-flutter-sdk`; that is the GitHub repo name, not the Dart package name.

### Step 5: Wrap The Root App

Place `TranzmitProvider` above every screen that may show a paywall.

```dart
void main() {
  runApp(
    TranzmitProvider(
      config: const TranzmitConfig(
        publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
      ),
      onError: (error) {
        debugPrint('[Tranzmit] ${error.code}: ${error.message}');
      },
      child: const MyApp(),
    ),
  );
}
```

### Step 6: Pass User Identity Correctly

If the user is logged out, omit `userId`. The SDK creates and persists a `stableID` automatically.

```dart
TranzmitConfig(
  publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
)
```

If the user is logged in, pass the real app user ID. Do not generate fake logged-out user IDs.

```dart
TranzmitConfig(
  publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
  userId: currentUser.id,
  userTraits: {
    'plan': currentUser.plan,
    'country': currentUser.country,
  },
)
```

For paywall experiments, Statsig should bucket on the custom ID `stableID`. This keeps logged-out and logged-in requests from the same install in the same experiment bucket.

### Step 7: Present The Paywall At The Upgrade Moment

Call `presentPlacement()` where the app normally starts an upgrade flow.

```dart
final tranzmit = Tranzmit.of(context);

final result = tranzmit.presentPlacement(
  'upgrade_pro',
  onCTA: (product) async {
    // product.id is the Billing Product ID configured in the Tranzmit dashboard.
    // Tranzmit owns paywall UI. The host app owns native billing.
    await purchaseWithStoreKitPlayBillingOrRevenueCat(product.id);

    tranzmit.reportConversion({
      'trigger': 'upgrade_pro',
      'productId': product.id,
      'revenue': 999,
      'currency': 'INR',
    });
  },
  onFallback: (event) {
    debugPrint('Tranzmit fallback: ${event.reason.name}');
    openExistingInAppPaywall();
  },
);

if (!result.shown) {
  // onFallback already routed to the existing in-app paywall.
  return;
}
```

### Step 8: Fallback To The Existing App Paywall

Always wire `onFallback` to the app's current paywall. That keeps monetization available if Tranzmit config is still loading, the placement is missing or disabled, or the WebView renderer reports an error.

```dart
final result = tranzmit.presentPlacement(
  'upgrade_pro',
  onCTA: (product) => purchaseWithStoreKitPlayBillingOrRevenueCat(product.id),
  onFallback: (event) {
    debugPrint('Tranzmit fallback: ${event.reason.name}');
    openExistingInAppPaywall();
  },
);

if (!result.shown) {
  return; // onFallback already handled notReady / placementNotFound.
}
```

Fallback reasons:

1. `FallbackReason.notReady`: the SDK has not loaded a valid config yet.
2. `FallbackReason.placementNotFound`: the trigger has no enabled placement in config.
3. `FallbackReason.renderError`: the hosted document or WebView failed after showing began.

### Step 9: Keep Billing In The Host App

When the paywall CTA is tapped:

1. Read `product.id`; this is the dashboard **Billing Product ID**.
2. Start the app's native purchase flow using `product.id`.
3. Wait for the purchase provider to confirm success.
4. Grant the entitlement in the app's existing entitlement system.
5. Call `reportConversion()` only after the purchase succeeds.

Tranzmit does not call StoreKit, Google Play Billing, RevenueCat, restore purchases, or grant entitlements.

### Step 10: Verify The Integration

Run this QA checklist before shipping:

1. Launch the app and confirm there are no `onError` logs.
2. Confirm `Tranzmit.of(context).isReady` becomes `true`.
3. Confirm `Tranzmit.of(context).getPlacement('upgrade_pro')` returns a placement.
4. Confirm the dashboard paywall variant has the right **Billing Product ID**.
5. Temporarily use a missing trigger and confirm `onFallback` opens the existing app paywall.
6. Call `presentPlacement('upgrade_pro')` and confirm the remote paywall renders.
7. Tap the CTA and confirm the host purchase flow starts for the matching billing product.
8. Complete a test purchase and confirm `reportConversion()` runs.
9. Change paywall copy, product ID, or variants in the Tranzmit dashboard.
10. Call `await Tranzmit.of(context).refreshConfig()`.
11. Present the paywall again and confirm the dashboard change appears.

### Step 11: AI Agent Acceptance Criteria

If Claude, Codex, Cursor, or another coding agent implements this SDK, the task is done only when:

1. `pubspec.yaml` contains the `tranzmit_flutter` dependency.
2. The app imports `package:tranzmit_flutter/tranzmit_flutter.dart`.
3. `TranzmitProvider` wraps the root widget tree.
4. The provided `publicKey` is passed to `TranzmitConfig`.
5. Logged-in users pass a real `userId`; logged-out users do not pass a fake ID.
6. Each dashboard paywall variant has a **Billing Product ID** matching the host app's billing provider.
7. The app calls `presentPlacement()` with the dashboard trigger.
8. `onCTA` starts native billing with `product.id`.
9. `onFallback` opens the app's existing paywall.
10. `reportConversion()` is called only after billing succeeds.
11. No hardcoded paywall UI is added to the host app.
12. The integration has a manual QA path that proves the remote paywall renders, opens the right billing product, and falls back safely.

## Install

If this SDK is shared as a standalone git repo:

```yaml
dependencies:
  tranzmit_flutter:
    git:
      url: https://github.com/agaaz007/tranzmit-flutter-sdk.git
      ref: main
```

If this SDK is vendored locally during development:

```yaml
dependencies:
  tranzmit_flutter:
    path: ./tranzmit-flutter-sdk
```

Then run:

```bash
flutter pub get
```

## Initialize

Wrap the app with `TranzmitProvider` near the root of the widget tree, above any screen that may show a paywall.

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

`apiBaseUrl` is optional for production because the SDK defaults to the hosted Tranzmit API. If a Tranzmit engineer gives you a custom API URL, pass it explicitly:

```dart
TranzmitConfig(
  publicKey: 'pk_live_REPLACE_WITH_CUSTOMER_PUBLIC_KEY',
  apiBaseUrl: 'https://api-production-2146.up.railway.app',
  userId: currentUserOrNull?.id,
)
```

## Identity And Statsig Bucketing

Tranzmit always sends an install-level `stableID`.

When the user is logged out, the SDK sends:

```json
{
  "identity": {
    "identifiers": {
      "stableID": "trz_install_generated_by_sdk"
    }
  }
}
```

When the user is logged in, the SDK sends both the app user id and the same stable install id:

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

For paywall experiments, configure Statsig to bucket on the custom id `stableID`. This keeps a user's paywall assignment consistent before and after login. The real `userId` is still included for logged-in analytics and event analysis.

The SDK persists `stableID` in `SharedPreferences` per Tranzmit public key. It remains stable across app launches, but can reset if the user uninstalls the app, clears app data, or device storage is unavailable.

## Present A Paywall

Use the trigger configured in the Tranzmit dashboard. The default trigger used by the demo client is `upgrade_pro`.

```dart
final tranzmit = Tranzmit.of(context);

final result = tranzmit.presentPlacement(
  'upgrade_pro',
  onCTA: (product) async {
    // product.id is the Billing Product ID configured in the Tranzmit dashboard.
    // Tranzmit owns paywall rendering. The host app owns billing.
    await purchaseWithStoreKitPlayBillingOrRevenueCat(product.id);

    tranzmit.reportConversion({
      'trigger': 'upgrade_pro',
      'productId': product.id,
      'revenue': 999,
      'currency': 'INR',
    });
  },
  onDismiss: () {
    debugPrint('Tranzmit paywall dismissed');
  },
  onImpression: () {
    debugPrint('Tranzmit paywall impression tracked');
  },
  onFallback: (event) {
    debugPrint('Tranzmit fallback: ${event.reason.name}');
    openExistingInAppPaywall();
  },
);

if (!result.shown) {
  return; // onFallback already routed to the existing in-app paywall.
}
```

## Fallback Route

The SDK exposes a first-class fallback route through `onFallback`. Wire it to the app's original paywall so users can still subscribe if Tranzmit cannot render.

```dart
tranzmit.presentPlacement(
  'upgrade_pro',
  onCTA: (product) => purchaseWithStoreKitPlayBillingOrRevenueCat(product.id),
  onFallback: (event) {
    switch (event.reason) {
      case FallbackReason.notReady:
      case FallbackReason.placementNotFound:
      case FallbackReason.renderError:
        openExistingInAppPaywall();
    }
  },
);
```

`FallbackEvent` includes the `trigger`, `reason`, optional `error`, optional `placement`, and optional `variantId`.

## Purchase Ownership

Tranzmit does not call StoreKit, Google Play Billing, or RevenueCat. The WebView bridge emits a CTA event with the selected `product.id`; this is the **Billing Product ID** configured for that paywall variant in the Tranzmit dashboard. The host app must:

1. Start the native purchase flow using `product.id`.
2. Confirm the purchase provider started the expected product or package.
3. Grant entitlements using the app's existing billing system.
4. Call `reportConversion()` only after a successful purchase.

This keeps purchases, restores, refunds, subscriptions, and entitlements under the customer app's control.

## Refresh During QA

Dashboard changes are fetched automatically through the server TTL cache. During QA, after saving a paywall or experiment change in the dashboard, force refresh:

```dart
await Tranzmit.of(context).refreshConfig();
```

Then call `presentPlacement('upgrade_pro')` again.

## Events

The SDK automatically tracks:

- `page_view` after successful SDK initialization.
- `impression` when a paywall is shown.
- `cta_click` when the paywall CTA is tapped.
- `dismissal` when the paywall is dismissed.
- `conversion` when the host app calls `reportConversion()`.

Events are queued locally, flushed at 10 events or after 30 seconds, flushed when the app backgrounds, and flushed immediately for conversions.

## Remote Config Behavior

On init, the SDK calls:

- `POST /v1/config` to fetch placements, specs, variant assignments, and hosted document URLs.
- Hosted document URLs to hydrate WebView HTML/CSS.
- `POST /v1/events` to send analytics events.

Config is cached locally. The SDK can render a previously cached config while a fresh network request runs in the background.

## Troubleshooting Checklist

If a paywall does not show:

1. Confirm `TranzmitProvider` wraps the current widget tree.
2. Confirm the public key is correct for the dashboard client.
3. Confirm the placement trigger exists and is active in the dashboard.
4. Confirm the paywall variant has a **Billing Product ID** in the dashboard.
5. Confirm the app calls `presentPlacement('upgrade_pro')` after SDK init.
6. Check `onError` logs for `config_fetch_failed`, `paywall_document_fetch_failed`, or HTTP status codes.
7. Call `await Tranzmit.of(context).refreshConfig()` after dashboard edits.
8. Confirm the device can reach the Tranzmit API and hosted document URLs.

If the CTA opens the wrong plan:

1. Confirm the dashboard **Billing Product ID** matches StoreKit, Play Billing, RevenueCat, or the host billing system exactly.
2. Confirm the app starts billing from `product.id`, not a hardcoded local product ID.
3. Refresh config after dashboard edits and present the paywall again.

If Statsig buckets look wrong:

1. Confirm the dashboard placement has the correct Statsig experiment id.
2. Confirm Statsig has a parameter named exactly `variant_id`.
3. Confirm `variant_id` values match dashboard variant keys exactly, such as `control`, `intro_offer`, and `annual_pro`.
4. Confirm Statsig buckets on the custom id `stableID` for paywall experiments.
5. For logged-in users, still pass `userId` for analytics hygiene.

## Agent Implementation Notes

For Claude, Codex, or another coding agent integrating this SDK into a customer app:

1. Add the `tranzmit_flutter` dependency.
2. Run `flutter pub get`.
3. Import `package:tranzmit_flutter/tranzmit_flutter.dart`.
4. Wrap the root app with `TranzmitProvider`.
5. Pass the Tranzmit public key supplied by the Tranzmit team.
6. Confirm each dashboard variant has the correct **Billing Product ID**.
7. Pass `userId` when available; omit it when logged out.
8. Use `presentPlacement('upgrade_pro')` at the upgrade or monetization moment.
9. Wire `onCTA` to the app's existing billing provider using `product.id`.
10. Call `reportConversion()` only after billing succeeds.
11. Do not hardcode paywall UI or billing product selection. Tranzmit dashboard controls design, copy, products, placement status, and experiment variants.

## Supported Layouts

The renderer supports these server-driven layout names:

- `stack`
- `hero`
- `hero_vertical`
- `hero_horizontal`
- `comparison`
- `minimal`
- `compact`
- `fullscreen`
- `influish_intro_offer`
- `influish_free_trial`
- `influish_annual_pro`
- `custom` as a stack fallback
