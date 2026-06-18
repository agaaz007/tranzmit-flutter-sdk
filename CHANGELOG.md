# Changelog

## Unreleased

- Added `preloadPlacement()` to warm hosted WebView paywalls before presentation.
- Added hidden provider-overlay warm slots so `presentPlacement()` can reuse a ready hosted paywall without a cold blank loading moment.
- Added route warm-slot reuse so `presentPlacementInRoute()` can avoid a cold WebView spinner for checkout-modal flows.
- Added preload verification docs, example harness controls, and QA tooling.

## 0.1.0

- Initial `tranzmit-flutter-sdk` client package.
- Added `TranzmitProvider` for app-level SDK initialization.
- Added server-driven placement fetch through `/v1/config`.
- Added hosted paywall document hydration for WebView rendering.
- Added persistent install-level `stableID` generation through `SharedPreferences`.
- Added optional app `userId` support for logged-in analytics.
- Added `presentPlacement()` for remote paywall presentation.
- Added event tracking for page views, impressions, CTA clicks, dismissals, and conversions.
- Added `reportConversion()` for host-app billing success attribution.
- Added local config caching, background refresh, event queueing, and lifecycle flush behavior.
