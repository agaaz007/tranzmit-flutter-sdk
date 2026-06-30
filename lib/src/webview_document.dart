import 'dart:convert';

import 'models.dart';
import 'presentation_mode.dart';

class PaywallViewport {
  const PaywallViewport({
    required this.width,
    required this.height,
    required this.safeTop,
    required this.safeBottom,
    required this.safeLeft,
    required this.safeRight,
    required this.pixelRatio,
    required this.presentation,
  });

  final double width;
  final double height;
  final double safeTop;
  final double safeBottom;
  final double safeLeft;
  final double safeRight;
  final double pixelRatio;
  final PresentationMode presentation;

  factory PaywallViewport.fallback(PresentationMode presentation) {
    return PaywallViewport(
      width: 390,
      height: fallbackPaywallHeight(844, presentation),
      safeTop: 0,
      safeBottom: 0,
      safeLeft: 0,
      safeRight: 0,
      pixelRatio: 3,
      presentation: presentation,
    );
  }

  String get signature => [
    width.toStringAsFixed(1),
    height.toStringAsFixed(1),
    safeTop.toStringAsFixed(1),
    safeBottom.toStringAsFixed(1),
    safeLeft.toStringAsFixed(1),
    safeRight.toStringAsFixed(1),
    pixelRatio.toStringAsFixed(2),
    presentation.name,
  ].join(':');

  String get cssVariables =>
      '''
  --tz-container-width: ${width.toStringAsFixed(2)}px;
  --tz-container-height: ${height.toStringAsFixed(2)}px;
  --tz-vw: ${width.toStringAsFixed(2)}px;
  --tz-vh: ${height.toStringAsFixed(2)}px;
  --tz-safe-top: ${safeTop.toStringAsFixed(2)}px;
  --tz-safe-bottom: ${safeBottom.toStringAsFixed(2)}px;
  --tz-safe-left: ${safeLeft.toStringAsFixed(2)}px;
  --tz-safe-right: ${safeRight.toStringAsFixed(2)}px;
  --tz-device-pixel-ratio: ${pixelRatio.toStringAsFixed(3)};
  --tz-scale: ${scale.toStringAsFixed(4)};
  --tz-cta-reserved-height: clamp(86px, 10.5vh, 108px);
''';

  Map<String, String> get cssVariableValues => {
    '--tz-container-width': '${width.toStringAsFixed(2)}px',
    '--tz-container-height': '${height.toStringAsFixed(2)}px',
    '--tz-vw': '${width.toStringAsFixed(2)}px',
    '--tz-vh': '${height.toStringAsFixed(2)}px',
    '--tz-safe-top': '${safeTop.toStringAsFixed(2)}px',
    '--tz-safe-bottom': '${safeBottom.toStringAsFixed(2)}px',
    '--tz-safe-left': '${safeLeft.toStringAsFixed(2)}px',
    '--tz-safe-right': '${safeRight.toStringAsFixed(2)}px',
    '--tz-device-pixel-ratio': pixelRatio.toStringAsFixed(3),
    '--tz-scale': scale.toStringAsFixed(4),
    '--tz-cta-reserved-height': 'clamp(86px, 10.5vh, 108px)',
  };

  double get scale {
    final widthScale = width / 390;
    final heightScale = height / 844;
    final raw = widthScale < heightScale ? widthScale : heightScale;
    if (raw < 0.82) return 0.82;
    if (raw > 1.12) return 1.12;
    return raw;
  }

  Map<String, Object> toJson() => {
    'width': width,
    'height': height,
    'safeTop': safeTop,
    'safeBottom': safeBottom,
    'safeLeft': safeLeft,
    'safeRight': safeRight,
    'pixelRatio': pixelRatio,
    'scale': scale,
    'presentation': presentation.name,
  };
}

double fallbackPaywallHeight(
  double mediaHeight,
  PresentationMode presentation,
) {
  switch (presentation) {
    case PresentationMode.inline:
      return mediaHeight * 0.72;
    case PresentationMode.modal:
      return mediaHeight * 0.90;
    case PresentationMode.fullscreen:
      return mediaHeight;
    case PresentationMode.sheet:
      return mediaHeight * 0.86;
  }
}

Map<String, dynamic>? parseWebViewBridgeMessage(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  return Map<String, dynamic>.from(decoded);
}

String? bridgeMessageType(Map<String, dynamic> message) {
  return message['type']?.toString() ?? message['action']?.toString();
}

bool isInitialDocumentNavigation(Uri uri, String? baseUrl) {
  if (uri.scheme == 'about' || uri.scheme == 'data') return true;

  final normalizedBaseUrl = _normalizeUrl(baseUrl);
  if (normalizedBaseUrl == null) return false;

  return _normalizeUrl(uri.toString()) == normalizedBaseUrl;
}

String? _normalizeUrl(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return null;

  final normalized = uri.removeFragment().toString();
  if (normalized.length > 1 && normalized.endsWith('/')) {
    return normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

ProductSpec? productForWebViewBridgeMessage(
  PaywallSpec spec,
  Map<String, dynamic> message,
) {
  final productId =
      message['productId']?.toString() ?? message['product_id']?.toString();
  if (productId == null) return null;
  for (final product in spec.products) {
    if (product.id == productId) return product;
  }
  return null;
}

String composePaywallDocumentForTest(
  PaywallSpec spec, {
  PresentationMode presentation = PresentationMode.sheet,
  PaywallViewport? viewport,
}) {
  return composePaywallDocument(spec, presentation, viewport: viewport);
}

String composePaywallDocument(
  PaywallSpec spec,
  PresentationMode presentation, {
  PaywallViewport? viewport,
}) {
  final document = spec.document;
  final rawHtml = document?.html;
  if (document == null || rawHtml == null || rawHtml.isEmpty) {
    return '''<!doctype html><html><body></body></html>''';
  }

  final hostedDocument = _HostedDocumentParts.fromHtml(rawHtml);
  final ctaTextJson = jsonEncode(spec.cta.text);

  final bootstrap =
      '''
<script>
(function(){
  var viewport = window.TranzmitNativeViewport || null;
  var configuredCtaText = $ctaTextJson;
  function post(message){
    try { window.TranzmitBridge.postMessage(JSON.stringify(message)); } catch (_) {}
  }
  function normalizeText(value){
    return (value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
  }
  function productIdFor(node){
    return node.getAttribute('data-product-id') ||
      node.getAttribute('data-tranzmit-product-id') ||
      node.getAttribute('data-billing-product-id') ||
      undefined;
  }
  function isInteractiveElement(node){
    if (!node || !node.getAttribute) return false;
    var tag = (node.tagName || '').toLowerCase();
    return tag === 'a' || tag === 'button' || node.getAttribute('role') === 'button';
  }
  function looksLikeDismiss(node){
    if (!node || !node.getAttribute) return false;
    var action = node.getAttribute('data-tranzmit-action');
    if (action === 'dismiss' || action === 'close') return true;
    var tag = (node.tagName || '').toLowerCase();
    if (tag !== 'a' && tag !== 'button' && node.getAttribute('role') !== 'button') {
      return false;
    }
    if (node.getAttribute('aria-label') === 'Close') return true;
    var marker = [
      node.getAttribute('class'),
      node.getAttribute('id'),
      node.getAttribute('data-testid')
    ].filter(Boolean).join(' ');
    return /(^|[\\s_-])(close-btn|tz-close|close-button|paywall-close)([\\s_-]|\$)/i.test(marker);
  }
  function looksLikeCta(node){
    if (!node || !node.getAttribute) return false;
    if (looksLikeDismiss(node)) return false;
    var marker = [
      node.getAttribute('class'),
      node.getAttribute('id'),
      node.getAttribute('data-testid')
    ].filter(Boolean).join(' ');
    if (/(^|[\\s_-])(cta|primary-cta|checkout|purchase|subscribe|upgrade|continue)([\\s_-]|\$)/i.test(marker)) {
      return true;
    }
    if (!isInteractiveElement(node)) return false;
    return configuredCtaText && normalizeText(node.textContent) === normalizeText(configuredCtaText);
  }
  window.Tranzmit = {
    viewport: viewport,
    post: post,
    cta: function(productId){ post({ type: 'cta', productId: productId }); },
    dismiss: function(){ post({ type: 'dismiss' }); },
    customAction: function(name, payload){ post({ type: 'custom_action', name: name, payload: payload || {} }); }
  };
  document.addEventListener('click', function(event){
    var node = event.target;
    while (node && node !== document) {
      var action = node.getAttribute && node.getAttribute('data-tranzmit-action');
      if (action) {
        event.preventDefault();
        post({
          type: action === 'cta' ? 'cta' : action,
          productId: productIdFor(node),
          name: node.getAttribute('data-action-name') || undefined,
          url: node.getAttribute('href') || undefined
        });
        return;
      }
      if (looksLikeDismiss(node)) {
        event.preventDefault();
        post({ type: 'dismiss' });
        return;
      }
      if (looksLikeCta(node)) {
        event.preventDefault();
        post({
          type: 'cta',
          productId: productIdFor(node),
          url: node.getAttribute('href') || undefined
        });
        return;
      }
      if (isInteractiveElement(node)) return;
      node = node.parentNode;
    }
  }, true);
  window.addEventListener('load', function(){ post({ type: 'ready' }); });
})();
</script>
''';

  final presentationClass = 'tz-presentation-${presentation.name}';
  final resolvedViewport = viewport ?? PaywallViewport.fallback(presentation);
  final viewportJson = jsonEncode(resolvedViewport.toJson());
  final documentChromeClass = _documentChromeClass(rawHtml, document.css);
  final htmlClass = documentChromeClass == null
      ? presentationClass
      : '$presentationClass $documentChromeClass';
  final bodyClass = [
    presentationClass,
    if (hostedDocument.bodyClass != null) hostedDocument.bodyClass!,
    if (documentChromeClass != null) documentChromeClass,
  ].join(' ');

  return '''<!doctype html>
<html class="$htmlClass" data-tranzmit-presentation="${presentation.name}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<style>
  :root {
${resolvedViewport.cssVariables}
  }
  html, body { margin: 0; padding: 0; width: var(--tz-vw); min-height: var(--tz-vh); background: transparent; -webkit-font-smoothing: antialiased; overflow-x: hidden; }
  body { min-height: var(--tz-vh); }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  button, a { touch-action: manipulation; }
  img, svg, video, canvas { max-width: 100%; height: auto; }
${document.css ?? ''}
  html, body { max-width: var(--tz-vw); overflow-x: hidden !important; }
  body { overflow-y: auto; -webkit-overflow-scrolling: touch; }
  html.tz-doc-original-paywall,
  body.tz-doc-original-paywall {
    background: #000 !important;
  }
  html.tz-doc-original-paywall::before,
  body.tz-doc-original-paywall::before {
    content: "";
    position: fixed;
    inset: -2px;
    background: #000;
    pointer-events: none;
    z-index: -1;
  }
  .tz-paywall:not(.phone), .tranzmit-paywall {
    max-width: var(--tz-vw);
    overflow-x: hidden !important;
    overflow-y: auto !important;
  }
  .tz-doc-original-paywall .original_paywall {
    background: #000 !important;
    isolation: isolate;
  }
  .$presentationClass .tz-paywall:not(.phone),
  .$presentationClass .tranzmit-paywall {
    min-height: 100%;
  }
  .tz-presentation-fullscreen,
  .tz-presentation-fullscreen body {
    width: var(--tz-vw);
    height: var(--tz-vh);
    min-height: var(--tz-vh);
    overflow: hidden;
  }
  .tz-presentation-fullscreen .tz-paywall:not(.phone),
  .tz-presentation-fullscreen .tranzmit-paywall {
    width: var(--tz-vw) !important;
    height: var(--tz-vh) !important;
    min-height: var(--tz-vh) !important;
    max-height: var(--tz-vh) !important;
    margin: 0 !important;
    padding-bottom: calc(var(--tz-safe-bottom) + var(--tz-cta-reserved-height)) !important;
    border-radius: 0 !important;
    box-shadow: none !important;
    overflow-y: auto !important;
  }
  .tz-presentation-fullscreen .tz-paywall:not(.phone) .cta,
  .tz-presentation-fullscreen .tranzmit-paywall .cta {
    left: calc(var(--tz-safe-left) + clamp(14px, 4vw, 22px)) !important;
    right: calc(var(--tz-safe-right) + clamp(14px, 4vw, 22px)) !important;
    bottom: calc(var(--tz-safe-bottom) + clamp(10px, 3vw, 18px)) !important;
  }
  .tz-presentation-fullscreen .tz-paywall:not(.phone) .tz-close,
  .tz-presentation-fullscreen .tranzmit-paywall .tz-close,
  .tz-presentation-fullscreen .tz-paywall:not(.phone) .close,
  .tz-presentation-fullscreen .tranzmit-paywall .close {
    display: none !important;
  }
  .tz-presentation-fullscreen .influish_annual_pro .tz-close {
    display: block !important;
    width: 22px !important;
    height: 22px !important;
    line-height: 22px !important;
    font-size: 22px !important;
    background: transparent !important;
    box-shadow: none !important;
    border-radius: 0 !important;
    color: #5f5a6b !important;
    left: clamp(14px, 4vw, 22px) !important;
    top: clamp(14px, 4vw, 22px) !important;
  }
  @media (max-height: 880px) {
    .tz-presentation-fullscreen .influish_intro_offer {
      gap: clamp(4px, 0.75vh, 8px) !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .intro-brand {
      margin-top: 0 !important;
      margin-bottom: 2px !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer h1 {
      font-size: clamp(30px, 8.6vw, 39px) !important;
      line-height: 0.98 !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .subtitle {
      font-size: clamp(13px, 3.6vw, 15px) !important;
      line-height: 1.25 !important;
      margin-top: 2px !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .intro-offer {
      margin-top: 6px !important;
      padding: 18px 14px 10px !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .intro-price strong {
      font-size: clamp(28px, 7.8vw, 36px) !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .feature-panel {
      padding: 10px 12px !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .feature-panel li {
      padding-top: 6px !important;
      padding-bottom: 6px !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .intro-testimonial {
      display: flex !important;
      gap: 9px !important;
      padding: 9px 10px !important;
      border-radius: 16px !important;
      font-size: 12px !important;
      line-height: 1.18 !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .intro-testimonial .avatar {
      width: 42px !important;
      height: 42px !important;
      flex: 0 0 42px !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .intro-testimonial p {
      margin: 1px 0 0 !important;
      letter-spacing: 1px !important;
      line-height: 1 !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .intro-testimonial em {
      display: none !important;
    }
    .tz-presentation-fullscreen .influish_intro_offer .legal-row {
      margin-top: auto !important;
    }
  }
  .tz-presentation-sheet .tz-paywall:not(.phone),
  .tz-presentation-sheet .tranzmit-paywall,
  .tz-presentation-modal .tz-paywall:not(.phone),
  .tz-presentation-modal .tranzmit-paywall {
    border-radius: clamp(20px, 7vw, 28px);
  }
  .tz-paywall:not(.phone) h1,
  .tz-paywall:not(.phone) h2,
  .tz-paywall:not(.phone) h3,
  .tz-paywall:not(.phone) p,
  .tz-paywall:not(.phone) strong,
  .tz-paywall:not(.phone) span,
  .tz-paywall:not(.phone) button,
  .tz-paywall:not(.phone) a,
  .tranzmit-paywall h1,
  .tranzmit-paywall h2,
  .tranzmit-paywall h3,
  .tranzmit-paywall p,
  .tranzmit-paywall strong,
  .tranzmit-paywall span,
  .tranzmit-paywall button,
  .tranzmit-paywall a { overflow-wrap: anywhere; }
</style>
${hostedDocument.head}
</head>
<body class="$bodyClass">
<script>window.TranzmitNativeViewport = $viewportJson;</script>
$bootstrap
${hostedDocument.body}
${document.js == null ? '' : '<script>${document.js}</script>'}
</body>
</html>''';
}

class _HostedDocumentParts {
  const _HostedDocumentParts({
    required this.head,
    required this.body,
    required this.bodyClass,
  });

  final String head;
  final String body;
  final String? bodyClass;

  static final RegExp _headPattern = RegExp(
    r'<head\b[^>]*>([\s\S]*?)<\/head>',
    caseSensitive: false,
  );
  static final RegExp _bodyPattern = RegExp(
    r'<body\b([^>]*)>([\s\S]*?)<\/body>',
    caseSensitive: false,
  );
  static final RegExp _classPattern = RegExp(
    r'''\bclass\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );

  factory _HostedDocumentParts.fromHtml(String html) {
    final headMatch = _headPattern.firstMatch(html);
    final bodyMatch = _bodyPattern.firstMatch(html);
    if (headMatch == null && bodyMatch == null) {
      return _HostedDocumentParts(head: '', body: html, bodyClass: null);
    }

    return _HostedDocumentParts(
      head: headMatch?.group(1)?.trim() ?? '',
      body: bodyMatch?.group(2)?.trim() ?? _stripDocumentShell(html),
      bodyClass: _extractClass(bodyMatch?.group(1)),
    );
  }

  static String _stripDocumentShell(String html) {
    return html
        .replaceAll(RegExp(r'<!doctype[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<\/?html\b[^>]*>', caseSensitive: false), '')
        .replaceAll(_headPattern, '')
        .trim();
  }

  static String? _extractClass(String? attributes) {
    if (attributes == null || attributes.isEmpty) return null;
    final match = _classPattern.firstMatch(attributes);
    final value = match?.group(1) ?? match?.group(2) ?? match?.group(3);
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

String? _documentChromeClass(String html, String? css) {
  if (html.contains('original_paywall') ||
      (css?.contains('.original_paywall') ?? false)) {
    return 'tz-doc-original-paywall';
  }
  return null;
}
