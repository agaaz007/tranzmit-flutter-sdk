# tranzmit-flutter-sdk Example Harness

Minimal Flutter app for validating the Tranzmit SDK against a live server. There is **no hardcoded paywall UI** in this app. Paywalls come only from remote config and hosted WebView documents.

## Run

```bash
cd packages/tranzmit_flutter/example
flutter pub get
flutter run
```

## Optional overrides

```bash
flutter run \
  --dart-define=TRANZMIT_API_BASE_URL=https://api-production-2146.up.railway.app \
  --dart-define=TRANZMIT_PUBLIC_KEY=pk_test_2a8a5f07d4b9fcf1cc77e024 \
  --dart-define=TRANZMIT_TRIGGER=upgrade_pro
```

By default, the harness runs logged out and lets the SDK generate a `stableID`. Pass `--dart-define=TRANZMIT_USER_ID=demo_user_123` to test logged-in identity. In a customer app, pass the real logged-in app user id when available and omit `userId` when logged out.

## What to verify

1. **SDK status → Ready: yes** after init
2. **Remote placement** shows variant, presentation, cache key, document URL, and **HTML hydrated: yes**
3. Tap **Present "upgrade_pro"** and confirm the paywall renders from server HTML through the route API.
4. Tap **Preload "upgrade_pro"** and confirm **Remote placement → Preload: ready**.
5. Tap **Present "upgrade_pro"** again and confirm the route API reuses the warmed slot without a blank cold WebView moment.
6. Tap CTA and confirm the demo host purchase callback runs, then `reportConversion` fires in flows that simulate purchase success.
7. Change `TRANZMIT_TRIGGER` to a missing trigger and confirm the fallback dialog opens.
8. Edit paywall text, CSS, variant allocation, or `presentation.mode` in the dashboard.
9. Tap **Refresh config**, preload again, and present again to see updates.

## Preload controls

The harness includes two preload-specific buttons:

- **Preload "upgrade_pro"** calls `Tranzmit.of(context).preloadPlacement(...)`. It does not show UI or send an impression.
- **Present warmed "upgrade_pro"** calls the default provider-overlay `presentPlacement(...)`, which reuses a ready preload slot when one exists.

The regular **Present "upgrade_pro"** button uses `Tranzmit.presentPlacementInRoute(...)` to demo Flutter UI above the paywall after CTA. It also reuses a ready preload slot when one exists. Use that route path when the customer app needs dialogs, bottom sheets, snackbars, or pushed checkout screens above the paywall.

## Purchase ownership

Tranzmit renders the paywall. Your app owns billing. Wire `onCTA` to StoreKit / Play Billing / RevenueCat, then call `reportConversion()` after success.

## Fallback ownership

Wire `onFallback` to the app's existing paywall. The SDK calls it when config is not ready, the placement is missing, or the WebView renderer fails, so customers are not left without a monetization path.
