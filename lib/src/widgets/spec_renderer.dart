import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models.dart';
import '../presentation_mode.dart';
import '../webview_document.dart';

export '../webview_document.dart';

class SpecRenderer extends StatefulWidget {
  const SpecRenderer({
    super.key,
    required this.spec,
    required this.onCTA,
    required this.onDismiss,
    this.onError,
    this.onReady,
    this.presentation = PresentationMode.sheet,
  });

  final PaywallSpec spec;
  final PresentationMode presentation;
  final void Function(ProductSpec product) onCTA;
  final VoidCallback onDismiss;
  final void Function(Object error)? onError;
  final VoidCallback? onReady;

  @override
  State<SpecRenderer> createState() => _SpecRendererState();
}

class _SpecRendererState extends State<SpecRenderer> {
  late final WebViewController _controller;
  String? _lastLoadedSignature;
  String? _lastViewportSignature;
  String? _lastReportedErrorSignature;
  bool _allowDocumentNavigation = false;
  bool _isDocumentVisible = false;
  bool _reportedReady = false;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  @override
  void didUpdateWidget(covariant SpecRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldBackdrop = _hostedDocumentBackdropColor(oldWidget.spec);
    final nextBackdrop = _hostedDocumentBackdropColor(widget.spec);
    if (oldBackdrop != nextBackdrop) {
      unawaited(_controller.setBackgroundColor(nextBackdrop));
    }
    if (oldWidget.presentation != widget.presentation ||
        oldWidget.spec.cacheKey != widget.spec.cacheKey ||
        oldWidget.spec.revision != widget.spec.revision ||
        oldWidget.spec.document?.html != widget.spec.document?.html ||
        oldWidget.spec.document?.css != widget.spec.document?.css ||
        oldWidget.spec.document?.js != widget.spec.document?.js) {
      _lastLoadedSignature = null;
      _lastViewportSignature = null;
      _isDocumentVisible = false;
      _reportedReady = false;
    }
  }

  WebViewController _buildController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(false)
      ..setBackgroundColor(_hostedDocumentBackdropColor(widget.spec))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _allowDocumentNavigation = false;
            _markDocumentVisible();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _reportRenderError(error);
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (_allowDocumentNavigation &&
                isInitialDocumentNavigation(
                  uri,
                  widget.spec.document?.baseUrl,
                )) {
              return NavigationDecision.navigate;
            }
            _handleBridgeMessage(
              jsonEncode({'type': 'open_url', 'url': request.url}),
            );
            return NavigationDecision.prevent;
          },
        ),
      )
      ..addJavaScriptChannel(
        'TranzmitBridge',
        onMessageReceived: (message) => _handleBridgeMessage(message.message),
      );
    return controller;
  }

  void _handleBridgeMessage(String raw) {
    final message = parseWebViewBridgeMessage(raw);
    if (message == null) return;
    final type = bridgeMessageType(message);
    if (!_isAllowed(type)) return;
    if (type == 'ready') _markDocumentVisible();

    switch (type) {
      case 'cta':
      case 'cta_click':
        final product = productForWebViewBridgeMessage(widget.spec, message) ??
            _defaultProduct(widget.spec);
        if (product != null) widget.onCTA(product);
        return;
      case 'dismiss':
        widget.onDismiss();
        return;
      case 'custom_action':
      case 'open_url':
      case 'ready':
        return;
    }
  }

  void _markDocumentVisible() {
    if (!mounted) return;
    if (!_isDocumentVisible) {
      setState(() => _isDocumentVisible = true);
    }
    if (_reportedReady) return;
    _reportedReady = true;
    widget.onReady?.call();
  }

  bool _isAllowed(String? type) {
    if (type == null) return false;
    if (type == 'cta_click') return true;
    final allowed = widget.spec.bridge?.allowedActions;
    if (allowed == null || allowed.isEmpty) {
      return const {
        'cta',
        'dismiss',
        'custom_action',
        'open_url',
        'ready',
      }.contains(type);
    }
    return allowed.contains(type) || type == 'ready';
  }

  @override
  Widget build(BuildContext context) {
    final html = widget.spec.document?.html;
    if (html == null || html.isEmpty) {
      _reportRenderError(StateError('Tranzmit paywall document not loaded'));
      return _MissingDocumentView(
        cacheKey: widget.spec.cacheKey,
        documentUrl: widget.spec.document?.url,
        height: _heightFor(context),
        presentation: widget.presentation,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = _viewportFromContext(
          context,
          constraints,
          widget.presentation,
        );
        _scheduleDocumentLoad(viewport);
        final radius = widget.presentation == PresentationMode.inline ||
                widget.presentation == PresentationMode.fullscreen
            ? 0.0
            : 28.0;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: _hostedDocumentBackdropColor(widget.spec)),
                if (!_isDocumentVisible) const _DocumentLoadingView(),
                AnimatedOpacity(
                  opacity: _isDocumentVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  child: IgnorePointer(
                    ignoring: !_isDocumentVisible,
                    child: WebViewWidget(controller: _controller),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _scheduleDocumentLoad(PaywallViewport viewport) {
    final signature = _documentSignature(widget.spec, widget.presentation);
    final viewportSignature = viewport.signature;
    if (_lastLoadedSignature == signature) {
      if (_lastViewportSignature != viewportSignature) {
        _lastViewportSignature = viewportSignature;
        if (_isDocumentVisible) _updateDocumentViewport(viewport);
      }
      return;
    }
    _lastLoadedSignature = signature;
    _lastViewportSignature = viewportSignature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastLoadedSignature != signature) return;
      if (_isDocumentVisible) {
        setState(() => _isDocumentVisible = false);
      }
      _reportedReady = false;
      _allowDocumentNavigation = true;
      unawaited(
        _controller
            .loadHtmlString(
          composePaywallDocument(
            widget.spec,
            widget.presentation,
            viewport: viewport,
          ),
          baseUrl: widget.spec.document?.baseUrl,
        )
            .catchError((Object error) {
          _allowDocumentNavigation = false;
          _reportRenderError(error);
        }),
      );
    });
  }

  void _updateDocumentViewport(PaywallViewport viewport) {
    final viewportJson = jsonEncode(viewport.toJson());
    final cssVariablesJson = jsonEncode(viewport.cssVariableValues);
    unawaited(
      _controller.runJavaScript('''
(function() {
  window.TranzmitNativeViewport = $viewportJson;
  var vars = $cssVariablesJson;
  var root = document.documentElement;
  Object.keys(vars).forEach(function(key) {
    root.style.setProperty(key, vars[key]);
  });
  window.dispatchEvent(new CustomEvent('tranzmitviewportchange', {
    detail: window.TranzmitNativeViewport
  }));
})();
''').catchError((Object error) {}),
    );
  }

  void _reportRenderError(Object error) {
    final signature = [
      widget.spec.cacheKey,
      widget.spec.revision,
      error.runtimeType,
      error.toString(),
    ].join('|');
    if (_lastReportedErrorSignature == signature) return;
    _lastReportedErrorSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onError?.call(error);
    });
  }

  String _documentSignature(PaywallSpec spec, PresentationMode presentation) {
    return [
      presentation.name,
      spec.cacheKey,
      spec.revision,
      spec.document?.baseUrl,
      spec.document?.html,
      spec.document?.css,
      spec.document?.js,
    ].join('|');
  }

  double _heightFor(BuildContext context, [double? availableHeight]) {
    final mediaHeight = MediaQuery.maybeOf(context)?.size.height ?? 700;
    final height = availableHeight != null && availableHeight.isFinite
        ? availableHeight
        : mediaHeight;
    switch (widget.presentation) {
      case PresentationMode.inline:
        return height * 0.72;
      case PresentationMode.modal:
        return height * 0.90;
      case PresentationMode.fullscreen:
        return height;
      case PresentationMode.sheet:
        return height * 0.86;
    }
  }
}

ProductSpec? _defaultProduct(PaywallSpec spec) {
  if (spec.products.isEmpty) return null;
  return spec.products.firstWhere(
    (product) => product.isDefault == true || product.highlighted == true,
    orElse: () => spec.products.first,
  );
}

PaywallViewport _viewportFromContext(
  BuildContext context,
  BoxConstraints constraints,
  PresentationMode presentation,
) {
  final media = MediaQuery.maybeOf(context);
  final size = media?.size ?? const Size(390, 844);
  final padding = media?.padding ?? EdgeInsets.zero;
  final pixelRatio = media?.devicePixelRatio ?? 1;
  final constrainedWidth =
      constraints.maxWidth.isFinite && constraints.maxWidth > 0
          ? constraints.maxWidth
          : size.width;
  final constrainedHeight =
      constraints.maxHeight.isFinite && constraints.maxHeight > 0
          ? constraints.maxHeight
          : fallbackPaywallHeight(size.height, presentation);

  return PaywallViewport(
    width: constrainedWidth,
    height: constrainedHeight,
    safeTop: padding.top,
    safeBottom: padding.bottom,
    safeLeft: padding.left,
    safeRight: padding.right,
    pixelRatio: pixelRatio,
    presentation: presentation,
  );
}

// Android WebView can expose the Flutter/preview backing by a physical pixel
// when its platform texture rounds differently from the document viewport.
Color _hostedDocumentBackdropColor(PaywallSpec spec) {
  final templateId = spec.templateId?.replaceAll('-', '_');
  if (templateId == 'original_paywall' ||
      templateId == 'original_paywall_responsive') {
    return Colors.black;
  }

  final html = spec.document?.html ?? '';
  final css = spec.document?.css ?? '';
  if (html.contains('original_paywall') &&
      (css.contains('background:#000') || css.contains('background: #000'))) {
    return Colors.black;
  }

  return Colors.transparent;
}

class _DocumentLoadingView extends StatelessWidget {
  const _DocumentLoadingView();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFFE8E2F5),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Color(0xFF7A3EE0),
          ),
        ),
      ),
    );
  }
}

class _MissingDocumentView extends StatelessWidget {
  const _MissingDocumentView({
    required this.cacheKey,
    required this.documentUrl,
    required this.height,
    required this.presentation,
  });

  final String? cacheKey;
  final String? documentUrl;
  final double height;
  final PresentationMode presentation;

  @override
  Widget build(BuildContext context) {
    final radius = presentation == PresentationMode.inline ||
            presentation == PresentationMode.fullscreen
        ? 0.0
        : 28.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: ColoredBox(
          color: const Color(0xFFFFF7ED),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Paywall document not loaded',
                  style: TextStyle(
                    color: Color(0xFF9A3412),
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This SDK does not render local fallback paywalls. Wait for init/refresh to hydrate the hosted document from your Tranzmit server.',
                  style: TextStyle(color: Color(0xFF7C2D12), height: 1.4),
                ),
                if (cacheKey != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'cacheKey: $cacheKey',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                if (documentUrl != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'url: $documentUrl',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
