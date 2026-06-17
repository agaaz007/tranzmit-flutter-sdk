import 'dart:async';

import 'package:flutter/material.dart';

import 'client.dart';
import 'controller.dart';
import 'models.dart';
import 'provider.dart';
import 'widgets/spec_renderer.dart';

GateResult presentPaywallRoute({
  required BuildContext context,
  required TranzmitController controller,
  required String trigger,
  PresentationMode? presentation,
  void Function(ProductSpec product)? onCTA,
  VoidCallback? onDismiss,
  void Function(FallbackEvent event)? onFallback,
  VoidCallback? onImpression,
}) {
  if (!controller.isReady) {
    onFallback?.call(
      FallbackEvent(trigger: trigger, reason: FallbackReason.notReady),
    );
    return const GateResult(shown: false, dismiss: _noopDismissRoute);
  }

  final placement = controller.getPlacement(trigger);
  if (placement == null) {
    onFallback?.call(
      FallbackEvent(trigger: trigger, reason: FallbackReason.placementNotFound),
    );
    return const GateResult(shown: false, dismiss: _noopDismissRoute);
  }

  final navigator = Navigator.of(context);
  final shownAt = DateTime.now();
  var completed = false;
  var renderFailed = false;

  late final Route<void> route;

  void removeRoute() {
    if (completed || !route.isActive) return;
    route.navigator?.removeRoute(route);
  }

  void completeRoute() {
    if (completed) return;
    completed = true;
    if (renderFailed) return;

    controller.track('dismissal', {
      ...attribution(trigger, placement),
      'time_on_screen_ms': DateTime.now().difference(shownAt).inMilliseconds,
    });
    onDismiss?.call();
  }

  route = PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    pageBuilder: (routeContext, animation, secondaryAnimation) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _PresentedSpec(
            spec: placement.spec,
            presentation: presentation ?? _presentationFromSpec(placement.spec),
            onCTA: (product) {
              controller.track('cta_click', {
                ...attribution(trigger, placement),
                'productId': product.id,
              });
              onCTA?.call(product);
            },
            onDismiss: removeRoute,
            onError: (error) {
              renderFailed = true;
              controller.track('paywall_error', {
                ...attribution(trigger, placement),
                'reason': 'render_error',
                'message': error.toString(),
              });
              onFallback?.call(
                FallbackEvent(
                  trigger: trigger,
                  reason: FallbackReason.renderError,
                  error: error,
                  placement: placement,
                  variantId: placement.variantId,
                ),
              );
              removeRoute();
            },
          ),
        ],
      );
    },
  );

  controller.track('impression', attribution(trigger, placement));
  onImpression?.call();
  unawaited(navigator.push(route).whenComplete(completeRoute));

  return GateResult(
    shown: true,
    variantId: placement.variantId,
    dismiss: removeRoute,
  );
}

void _noopDismissRoute() {}

class TranzmitPaywallHost extends StatelessWidget {
  const TranzmitPaywallHost({super.key, required this.controller});

  final TranzmitController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final activePaywalls = controller.activePaywalls;
        final preloadedPaywalls = controller.preloadedPaywalls
            .where((preload) => preload.status != PreloadStatus.failed)
            .toList(growable: false);
        if (activePaywalls.isEmpty && preloadedPaywalls.isEmpty) {
          return const SizedBox.shrink();
        }

        final activeByTrigger = <String, ActivePaywall>{
          for (final active in activePaywalls) active.trigger: active,
        };
        final warmTriggers =
            preloadedPaywalls.map((preload) => preload.trigger).toSet();

        return Stack(
          children: [
            for (final preload in preloadedPaywalls)
              if (!activeByTrigger.containsKey(preload.trigger))
                _WarmPaywallSlot(
                  preload: preload,
                  active: null,
                  controller: controller,
                ),
            for (final preload in preloadedPaywalls)
              if (activeByTrigger.containsKey(preload.trigger))
                _WarmPaywallSlot(
                  preload: preload,
                  active: activeByTrigger[preload.trigger],
                  controller: controller,
                ),
            for (final active in activePaywalls)
              if (!warmTriggers.contains(active.trigger))
                _PresentedPaywall(
                  active: active,
                  onCTA: (product) => controller.handleCTA(active, product),
                  onDismiss: () => controller.dismissPaywall(active.id),
                  onError: (error) =>
                      controller.handlePaywallError(active, error),
                ),
          ],
        );
      },
    );
  }
}

class _WarmPaywallSlot extends StatelessWidget {
  const _WarmPaywallSlot({
    required this.preload,
    required this.active,
    required this.controller,
  });

  final PreloadedPaywall preload;
  final ActivePaywall? active;
  final TranzmitController controller;

  @override
  Widget build(BuildContext context) {
    final currentActive = active;
    final isVisible = currentActive != null;
    return KeyedSubtree(
      key: ValueKey('tranzmit-preload:${preload.key}'),
      child: ExcludeSemantics(
        excluding: !isVisible,
        child: IgnorePointer(
          ignoring: !isVisible,
          child: Opacity(
            opacity: isVisible ? 1 : 0.001,
            child: _PresentedSpec(
              spec: preload.placement.spec,
              presentation: preload.presentation,
              onCTA: (product) {
                if (currentActive == null) return;
                controller.handleCTA(currentActive, product);
              },
              onDismiss: () {
                if (currentActive == null) return;
                controller.dismissPaywall(currentActive.id);
              },
              onError: (error) {
                if (currentActive == null) {
                  controller.markPreloadFailed(
                      preload.trigger, preload.key, error);
                  return;
                }
                controller.handlePaywallError(currentActive, error);
              },
              onReady: () => controller.markPreloadReady(
                preload.trigger,
                preload.key,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TranzmitPaywall extends StatefulWidget {
  const TranzmitPaywall({
    super.key,
    required this.visible,
    this.trigger,
    this.spec,
    this.variantId,
    this.presentation,
    this.onCTA,
    this.onDismiss,
    this.onError,
    this.onImpression,
  });

  final String? trigger;
  final PaywallSpec? spec;
  final String? variantId;
  final bool visible;
  final PresentationMode? presentation;
  final void Function(ProductSpec product)? onCTA;
  final VoidCallback? onDismiss;
  final void Function(Object error)? onError;
  final VoidCallback? onImpression;

  @override
  State<TranzmitPaywall> createState() => _TranzmitPaywallState();
}

class _TranzmitPaywallState extends State<TranzmitPaywall> {
  String? _lastImpressionKey;
  DateTime _shownAt = DateTime.now();

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    final controller = Tranzmit.maybeOf(context);
    final placement = widget.trigger == null
        ? null
        : controller?.getPlacement(widget.trigger!);
    final spec = widget.spec ?? placement?.spec;
    if (spec == null) return const SizedBox.shrink();

    final trigger = widget.trigger ?? 'dynamic_spec';
    final variantId =
        widget.spec == null ? placement?.variantId : widget.variantId;
    final impressionKey =
        '$trigger:${variantId ?? 'none'}:${spec.cacheKey ?? spec.revision ?? 'none'}';

    if (_lastImpressionKey != impressionKey) {
      _lastImpressionKey = impressionKey;
      _shownAt = DateTime.now();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller?.track('impression', {
          'trigger': trigger,
          if (variantId != null) 'variantId': variantId,
        });
        widget.onImpression?.call();
      });
    }

    return _PresentedSpec(
      spec: spec,
      presentation: widget.presentation ?? _presentationFromSpec(spec),
      onCTA: (product) {
        controller?.track('cta_click', {
          'trigger': trigger,
          if (variantId != null) 'variantId': variantId,
          'productId': product.id,
        });
        widget.onCTA?.call(product);
      },
      onDismiss: () {
        controller?.track('dismissal', {
          'trigger': trigger,
          if (variantId != null) 'variantId': variantId,
          'time_on_screen_ms':
              DateTime.now().difference(_shownAt).inMilliseconds,
        });
        widget.onDismiss?.call();
      },
      onError: widget.onError,
    );
  }
}

class _PresentedPaywall extends StatelessWidget {
  const _PresentedPaywall({
    required this.active,
    required this.onCTA,
    required this.onDismiss,
    required this.onError,
  });

  final ActivePaywall active;
  final void Function(ProductSpec product) onCTA;
  final VoidCallback onDismiss;
  final void Function(Object error) onError;

  @override
  Widget build(BuildContext context) {
    return _PresentedSpec(
      spec: active.placement.spec,
      presentation: active.presentation,
      onCTA: onCTA,
      onDismiss: onDismiss,
      onError: onError,
    );
  }
}

class _PresentedSpec extends StatelessWidget {
  const _PresentedSpec({
    required this.spec,
    required this.presentation,
    required this.onCTA,
    required this.onDismiss,
    this.onError,
    this.onReady,
  });

  final PaywallSpec spec;
  final PresentationMode presentation;
  final void Function(ProductSpec product) onCTA;
  final VoidCallback onDismiss;
  final void Function(Object error)? onError;
  final VoidCallback? onReady;

  @override
  Widget build(BuildContext context) {
    if (presentation == PresentationMode.inline) {
      return SpecRenderer(
        spec: spec,
        presentation: presentation,
        onCTA: onCTA,
        onDismiss: onDismiss,
        onError: onError,
        onReady: onReady,
      );
    }

    if (presentation == PresentationMode.fullscreen) {
      return Positioned.fill(
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned.fill(
                child: SpecRenderer(
                  spec: spec,
                  presentation: presentation,
                  onCTA: onCTA,
                  onDismiss: onDismiss,
                  onError: onError,
                  onReady: onReady,
                ),
              ),
              if (!_paywallProvidesHostedDismissControl(spec))
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _FullscreenCloseButton(
                      spec: spec,
                      onDismiss: onDismiss,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (presentation == PresentationMode.modal) {
      return Positioned.fill(
        child: Container(
          color: Colors.black.withValues(alpha: 0.45),
          padding: const EdgeInsets.all(24),
          child: SafeArea(
            child: Center(
              child: FractionallySizedBox(
                heightFactor: 0.90,
                widthFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: SpecRenderer(
                    spec: spec,
                    presentation: presentation,
                    onCTA: onCTA,
                    onDismiss: onDismiss,
                    onError: onError,
                    onReady: onReady,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onDismiss,
        child: Container(
          color: Colors.black.withValues(alpha: 0.35),
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FractionallySizedBox(
                  heightFactor: 0.86,
                  widthFactor: 1,
                  child: SpecRenderer(
                    spec: spec,
                    presentation: presentation,
                    onCTA: onCTA,
                    onDismiss: onDismiss,
                    onError: onError,
                    onReady: onReady,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hosted Influish paywalls ship their own dismiss control (`close-btn` or
/// `tz-close`). The intro-offer variant hides its HTML close in fullscreen and
/// keeps a minimal SDK close on the top-right.
bool _paywallProvidesHostedDismissControl(PaywallSpec spec) {
  final templateId = spec.templateId;
  if (templateId == null) return false;
  if (templateId == 'influish_intro_offer') return false;
  if (templateId == 'original_paywall' || templateId == 'influish_annual_pro') {
    return true;
  }
  return templateId.startsWith('influish_');
}

class _FullscreenCloseButton extends StatelessWidget {
  const _FullscreenCloseButton({required this.spec, required this.onDismiss});

  final PaywallSpec spec;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final alignRight = spec.templateId == 'influish_intro_offer';
    return Align(
      alignment: alignRight ? Alignment.topRight : Alignment.topLeft,
      child: Material(
        color: Colors.transparent,
        elevation: 0,
        child: InkWell(
          onTap: onDismiss,
          child: SizedBox(
            width: alignRight ? 40 : 48,
            height: alignRight ? 40 : 48,
            child: Icon(
              Icons.close,
              color: const Color(0xFF6F6878),
              size: alignRight ? 28 : 24,
            ),
          ),
        ),
      ),
    );
  }
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
