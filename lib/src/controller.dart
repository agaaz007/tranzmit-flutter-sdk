import 'dart:async';

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'models.dart';

enum PresentationMode { modal, sheet, fullscreen, inline }

enum FallbackReason { notReady, placementNotFound, renderError }

enum PreloadStatus { loading, ready, failed }

class PreloadResult {
  const PreloadResult({
    required this.trigger,
    required this.status,
    this.variantId,
    this.error,
  });

  final String trigger;
  final PreloadStatus status;
  final String? variantId;
  final Object? error;

  bool get ready => status == PreloadStatus.ready;
}

class FallbackEvent {
  const FallbackEvent({
    required this.trigger,
    required this.reason,
    this.error,
    this.placement,
    this.variantId,
  });

  final String trigger;
  final FallbackReason reason;
  final Object? error;
  final PlacementConfig? placement;
  final String? variantId;
}

class GateOptions {
  const GateOptions({
    this.presentation,
    this.onCTA,
    this.onDismiss,
    this.onFallback,
    this.onImpression,
  });

  final PresentationMode? presentation;
  final void Function(ProductSpec product)? onCTA;
  final VoidCallback? onDismiss;
  final void Function(FallbackEvent event)? onFallback;
  final VoidCallback? onImpression;
}

class GateResult {
  const GateResult({
    required this.shown,
    this.variantId,
    required this.dismiss,
  });

  final bool shown;
  final String? variantId;
  final VoidCallback dismiss;
}

class ActivePaywall {
  ActivePaywall({
    required this.id,
    required this.trigger,
    required this.placement,
    required this.presentation,
    required this.options,
    required this.shownAt,
  });

  final String id;
  final String trigger;
  final PlacementConfig placement;
  final PresentationMode presentation;
  final GateOptions options;
  final DateTime shownAt;
}

class PreloadedPaywall {
  PreloadedPaywall._({
    required this.trigger,
    required this.placement,
    required this.presentation,
    required this.key,
    required this.requestedAt,
    required Completer<PreloadResult> completer,
  }) : _completer = completer;

  final String trigger;
  final PlacementConfig placement;
  final PresentationMode presentation;
  final String key;
  final DateTime requestedAt;
  final Completer<PreloadResult> _completer;
  PreloadStatus status = PreloadStatus.loading;
  Object? error;

  String? get variantId => placement.variantId;
}

class TranzmitController extends ChangeNotifier {
  TranzmitController(this._client);

  final TranzmitClient _client;
  final Map<String, ActivePaywall> _activePaywalls = <String, ActivePaywall>{};
  final Map<String, PreloadedPaywall> _preloadedPaywalls =
      <String, PreloadedPaywall>{};

  bool _isReady = false;
  bool _disposed = false;

  bool get isReady => _isReady;
  bool get ready => _isReady;
  TranzmitIdentity? get identity => _client.identity;
  List<ActivePaywall> get activePaywalls =>
      List<ActivePaywall>.unmodifiable(_activePaywalls.values);
  List<PreloadedPaywall> get preloadedPaywalls =>
      List<PreloadedPaywall>.unmodifiable(_preloadedPaywalls.values);

  Future<void> init(TranzmitConfig config) async {
    _setReady(false);
    _activePaywalls.clear();
    _clearPreloads();
    _notifyIfAlive();

    await _client.init(config);
    _setReady(_client.isReady);
  }

  Future<void> refreshConfig() async {
    _setReady(false);
    _activePaywalls.clear();
    _clearPreloads();
    _notifyIfAlive();

    await _client.refreshConfig();
    _setReady(_client.isReady);
  }

  PlacementConfig? getPlacement(String trigger) =>
      _client.getPlacement(trigger);

  Future<PreloadResult> preloadPlacement(
    String trigger, {
    PresentationMode? presentation,
  }) async {
    if (!_client.isReady) {
      return PreloadResult(trigger: trigger, status: PreloadStatus.failed);
    }

    final placement = _client.getPlacement(trigger);
    if (placement == null) {
      return PreloadResult(trigger: trigger, status: PreloadStatus.failed);
    }

    final resolvedPresentation =
        presentation ?? _presentationFromSpec(placement.spec);
    final key = _preloadKey(trigger, placement, resolvedPresentation);
    final existing = _preloadedPaywalls[trigger];
    if (existing != null && existing.key == key) {
      if (existing.status == PreloadStatus.ready) {
        return PreloadResult(
          trigger: trigger,
          status: PreloadStatus.ready,
          variantId: existing.variantId,
        );
      }
      if (existing.status == PreloadStatus.failed) {
        return PreloadResult(
          trigger: trigger,
          status: PreloadStatus.failed,
          variantId: existing.variantId,
          error: existing.error,
        );
      }
      return existing._completer.future;
    }

    final completer = Completer<PreloadResult>();
    _preloadedPaywalls[trigger] = PreloadedPaywall._(
      trigger: trigger,
      placement: placement,
      presentation: resolvedPresentation,
      key: key,
      requestedAt: DateTime.now(),
      completer: completer,
    );
    _notifyIfAlive();
    return completer.future;
  }

  PreloadedPaywall? claimPreloadForRoute(
    String trigger,
    PlacementConfig placement,
    PresentationMode presentation,
  ) {
    _dropStalePreload(trigger, placement, presentation);

    final preload = _preloadedPaywalls[trigger];
    if (preload == null) return null;

    if (preload.status == PreloadStatus.failed) {
      _preloadedPaywalls.remove(trigger);
      _notifyIfAlive();
      return null;
    }

    _preloadedPaywalls.remove(trigger);
    _notifyIfAlive();
    return preload;
  }

  PreloadedPaywall? claimReadyPreloadForRoute(
    String trigger,
    PlacementConfig placement,
    PresentationMode presentation,
  ) {
    final preload = _preloadedPaywalls[trigger];
    if (preload == null || preload.status != PreloadStatus.ready) return null;
    return claimPreloadForRoute(trigger, placement, presentation);
  }

  GateResult gate(String trigger, [GateOptions options = const GateOptions()]) {
    if (!_client.isReady) {
      options.onFallback?.call(
        FallbackEvent(trigger: trigger, reason: FallbackReason.notReady),
      );
      return _noopResult;
    }

    final placement = _client.getPlacement(trigger);
    if (placement == null) {
      options.onFallback?.call(
        FallbackEvent(
          trigger: trigger,
          reason: FallbackReason.placementNotFound,
        ),
      );
      return _noopResult;
    }

    final resolvedPresentation =
        options.presentation ?? _presentationFromSpec(placement.spec);
    _dropStalePreload(trigger, placement, resolvedPresentation);
    final preload = _preloadedPaywalls[trigger];
    if (preload != null && preload.status == PreloadStatus.failed) {
      _preloadedPaywalls.remove(trigger);
    }

    final existing = _activePaywalls[trigger];
    if (existing != null) {
      return GateResult(
        shown: true,
        variantId: existing.placement.variantId,
        dismiss: () => dismissPaywall(existing.id),
      );
    }

    final active = ActivePaywall(
      id: trigger,
      trigger: trigger,
      placement: placement,
      presentation: resolvedPresentation,
      options: options,
      shownAt: DateTime.now(),
    );

    _activePaywalls[trigger] = active;
    _client.track('impression', attribution(trigger, placement));
    options.onImpression?.call();
    _notifyIfAlive();

    return GateResult(
      shown: true,
      variantId: placement.variantId,
      dismiss: () => dismissPaywall(active.id),
    );
  }

  GateResult presentPlacement(
    String trigger, {
    PresentationMode? presentation,
    void Function(ProductSpec product)? onCTA,
    VoidCallback? onDismiss,
    void Function(FallbackEvent event)? onFallback,
    VoidCallback? onImpression,
  }) {
    return gate(
      trigger,
      GateOptions(
        presentation: presentation,
        onCTA: onCTA,
        onDismiss: onDismiss,
        onFallback: onFallback,
        onImpression: onImpression,
      ),
    );
  }

  void track(String event, [Map<String, Object?>? properties]) {
    _client.track(event, properties);
  }

  void reportConversion(Map<String, Object?> data) {
    _client.reportConversion(data);
  }

  Future<void> flush() => _client.flush();

  void handleCTA(ActivePaywall active, ProductSpec product) {
    _client.track('cta_click', {
      ...attribution(active.trigger, active.placement),
      'productId': product.id,
    });
    active.options.onCTA?.call(product);
    _notifyIfAlive();
  }

  void dismissPaywall(String id, {bool trackDismissal = true}) {
    final active = _activePaywalls.remove(id);
    if (active == null) return;

    if (trackDismissal) {
      _client.track('dismissal', {
        ...attribution(active.trigger, active.placement),
        'time_on_screen_ms':
            DateTime.now().difference(active.shownAt).inMilliseconds,
      });
      active.options.onDismiss?.call();
    }
    _notifyIfAlive();
  }

  void markPreloadReady(String trigger, String key) {
    final preload = _preloadedPaywalls[trigger];
    if (preload == null || preload.key != key) return;
    if (preload.status == PreloadStatus.ready) return;

    preload.status = PreloadStatus.ready;
    preload.error = null;
    if (!preload._completer.isCompleted) {
      preload._completer.complete(
        PreloadResult(
          trigger: trigger,
          status: PreloadStatus.ready,
          variantId: preload.variantId,
        ),
      );
    }
    _notifyIfAlive();
  }

  void markClaimedPreloadReady(PreloadedPaywall preload) {
    if (preload.status == PreloadStatus.ready) return;

    preload.status = PreloadStatus.ready;
    preload.error = null;
    if (!preload._completer.isCompleted) {
      preload._completer.complete(
        PreloadResult(
          trigger: preload.trigger,
          status: PreloadStatus.ready,
          variantId: preload.variantId,
        ),
      );
    }
    _notifyIfAlive();
  }

  void markPreloadFailed(String trigger, String key, Object error) {
    final preload = _preloadedPaywalls[trigger];
    if (preload == null || preload.key != key) return;

    preload.status = PreloadStatus.failed;
    preload.error = error;
    if (!preload._completer.isCompleted) {
      preload._completer.complete(
        PreloadResult(
          trigger: trigger,
          status: PreloadStatus.failed,
          variantId: preload.variantId,
          error: error,
        ),
      );
    }
    _notifyIfAlive();
  }

  void markClaimedPreloadFailed(PreloadedPaywall preload, Object error) {
    if (preload.status == PreloadStatus.failed) return;

    preload.status = PreloadStatus.failed;
    preload.error = error;
    if (!preload._completer.isCompleted) {
      preload._completer.complete(
        PreloadResult(
          trigger: preload.trigger,
          status: PreloadStatus.failed,
          variantId: preload.variantId,
          error: error,
        ),
      );
    }
    _notifyIfAlive();
  }

  void handlePaywallError(ActivePaywall active, Object error) {
    _client.track('paywall_error', {
      ...attribution(active.trigger, active.placement),
      'reason': 'render_error',
      'message': error.toString(),
    });
    _activePaywalls.remove(active.id);
    active.options.onFallback?.call(
      FallbackEvent(
        trigger: active.trigger,
        reason: FallbackReason.renderError,
        error: error,
        placement: active.placement,
        variantId: active.placement.variantId,
      ),
    );
    _notifyIfAlive();
  }

  void handleBackground() => _client.handleBackground();

  void handleForeground() => _client.handleForeground();

  void _setReady(bool ready) {
    if (_isReady == ready) return;
    _isReady = ready;
    _notifyIfAlive();
  }

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  void _clearPreloads() {
    for (final preload in _preloadedPaywalls.values) {
      if (!preload._completer.isCompleted) {
        preload._completer.complete(
          PreloadResult(
            trigger: preload.trigger,
            status: PreloadStatus.failed,
            variantId: preload.variantId,
          ),
        );
      }
    }
    _preloadedPaywalls.clear();
  }

  void _dropStalePreload(
    String trigger,
    PlacementConfig placement,
    PresentationMode presentation,
  ) {
    final preload = _preloadedPaywalls[trigger];
    if (preload == null) return;
    if (preload.key == _preloadKey(trigger, placement, presentation)) return;

    if (!preload._completer.isCompleted) {
      preload._completer.complete(
        PreloadResult(
          trigger: preload.trigger,
          status: PreloadStatus.failed,
          variantId: preload.variantId,
        ),
      );
    }
    _preloadedPaywalls.remove(trigger);
  }

  @override
  void dispose() {
    _disposed = true;
    _clearPreloads();
    super.dispose();
  }
}

String _preloadKey(
  String trigger,
  PlacementConfig placement,
  PresentationMode presentation,
) {
  final spec = placement.spec;
  return [
    trigger,
    placement.variantId,
    presentation.name,
    spec.cacheKey,
    spec.revision,
  ].join('|');
}

PresentationMode _presentationFromSpec(PaywallSpec spec) {
  switch (spec.presentationMode) {
    case 'modal':
      return PresentationMode.modal;
    case 'fullscreen':
      return PresentationMode.fullscreen;
    case 'inline':
      return PresentationMode.inline;
    case 'sheet':
    default:
      return PresentationMode.sheet;
  }
}

const _noopResult = GateResult(shown: false, dismiss: _noopDismiss);

void _noopDismiss() {}
