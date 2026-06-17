import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tranzmit_flutter/tranzmit_flutter.dart';

const _apiBaseUrl = String.fromEnvironment(
  'TRANZMIT_API_BASE_URL',
  defaultValue: 'https://api-production-2146.up.railway.app',
);
const _publicKey = String.fromEnvironment(
  'TRANZMIT_PUBLIC_KEY',
  defaultValue: 'pk_test_2a8a5f07d4b9fcf1cc77e024',
);
const _demoTrigger = String.fromEnvironment(
  'TRANZMIT_TRIGGER',
  defaultValue: 'upgrade_pro',
);
const _initialUserId = String.fromEnvironment(
  'TRANZMIT_USER_ID',
  defaultValue: '',
);

/// QA stableIDs — different IDs usually land in different Statsig buckets.
const _variantStableIds = <String, String>{
  'control': 'trz_qa_control',
  'intro_offer': 'trz_qa_intro_offer',
  'original': 'trz_qa_original',
};

void main() {
  runApp(
    TranzmitProvider(
      config: const TranzmitConfig(
        publicKey: _publicKey,
        apiBaseUrl: _apiBaseUrl,
      ),
      onError: (error) =>
          debugPrint('[Tranzmit] ${error.code}: ${error.message}'),
      child: const SdkHarnessApp(),
    ),
  );
}

class SdkHarnessApp extends StatelessWidget {
  const SdkHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6537D9)),
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        useMaterial3: true,
      ),
      home: const SdkHarnessScreen(),
    );
  }
}

class SdkHarnessScreen extends StatefulWidget {
  const SdkHarnessScreen({super.key});

  @override
  State<SdkHarnessScreen> createState() => _SdkHarnessScreenState();
}

class _SdkHarnessScreenState extends State<SdkHarnessScreen> {
  TranzmitController? _controller;
  final _userIdController = TextEditingController();
  final _stableIdController = TextEditingController();
  bool _loggedOut = true;
  int _probeBucket = 0;
  String? _lastError;
  String? _lastEvent;
  String? _preloadStatus;

  @override
  void initState() {
    super.initState();
    _userIdController.addListener(_onIdentityFieldChanged);
    _stableIdController.addListener(_onIdentityFieldChanged);
    final presetUserId = _initialUserId.trim();
    if (presetUserId.isNotEmpty) {
      _loggedOut = false;
      _userIdController.text = presetUserId;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Tranzmit.of(context);
    if (_controller == next) return;
    _controller?.removeListener(_onControllerChanged);
    _controller = next..addListener(_onControllerChanged);
    if (_initialUserId.trim().isNotEmpty && !_loggedOut) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_applyIdentity());
      });
    }
  }

  @override
  void dispose() {
    _userIdController.removeListener(_onIdentityFieldChanged);
    _stableIdController.removeListener(_onIdentityFieldChanged);
    _userIdController.dispose();
    _stableIdController.dispose();
    _controller?.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onIdentityFieldChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _setEvent(String message) {
    setState(() => _lastEvent = message);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  TranzmitConfig _buildConfig() {
    final raw = _userIdController.text.trim();
    final userId = _loggedOut || raw.isEmpty ? null : raw;
    final stableOverride = _stableIdController.text.trim();
    return TranzmitConfig(
      publicKey: _publicKey,
      apiBaseUrl: _apiBaseUrl,
      userId: userId,
      identifiers: stableOverride.isEmpty
          ? null
          : <String, String>{'stableID': stableOverride},
    );
  }

  bool _isIdentityDirty(TranzmitController? controller) {
    final identity = controller?.identity;
    if (identity == null) return true;
    if (_effectiveUserId != identity.userId) return true;
    final override = _stableIdController.text.trim();
    final activeStable = identity.identifiers['stableID'];
    if (override.isNotEmpty && override != activeStable) return true;
    return false;
  }

  Future<void> _applyVariantPreset(String variantKey) async {
    setState(() {
      _loggedOut = true;
      _userIdController.clear();
      _stableIdController.text =
          _variantStableIds[variantKey] ?? 'trz_qa_$variantKey';
    });
    await _applyIdentity();
  }

  Future<void> _applyNextProbeBucket() async {
    _probeBucket += 1;
    setState(() {
      _loggedOut = true;
      _userIdController.clear();
      _stableIdController.text = 'trz_qa_probe_$_probeBucket';
    });
    await _applyIdentity();
  }

  String? get _effectiveUserId {
    final raw = _userIdController.text.trim();
    if (_loggedOut || raw.isEmpty) return null;
    return raw;
  }

  Future<void> _applyIdentity() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      await controller.init(_buildConfig());
      final variant = controller.getPlacement(_demoTrigger)?.variantId;
      final stableId = controller.identity?.identifiers['stableID'];
      _setEvent(
        variant == null
            ? 'Identity applied (no placement yet)'
            : 'Identity applied → variant: $variant',
      );
      if (stableId != null) {
        debugPrint('[Tranzmit harness] stableID: $stableId');
      }
      final userId = controller.identity?.userId;
      if (userId != null) {
        debugPrint('[Tranzmit harness] userId: $userId');
      } else if (!_loggedOut) {
        debugPrint(
            '[Tranzmit harness] userId: (none — logged-in mode but empty field)');
      }
    } on TranzmitError catch (error) {
      setState(() => _lastError = '${error.code}: ${error.message}');
      _setEvent('Identity update failed: ${error.code}');
    }
  }

  Future<void> _refreshConfig() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.refreshConfig();
      _setEvent('Config refreshed from server');
    } on TranzmitError catch (error) {
      setState(() => _lastError = '${error.code}: ${error.message}');
      _setEvent('Refresh failed: ${error.code}');
    }
  }

  Future<void> _preloadPaywall() async {
    final controller = _controller;
    if (controller == null) return;

    setState(() => _preloadStatus = 'loading');
    final result = await controller.preloadPlacement(_demoTrigger);
    if (!mounted) return;

    setState(() => _preloadStatus = result.status.name);
    _setEvent('Preload ${result.status.name} for $_demoTrigger');
  }

  void _presentProviderPaywall() {
    final controller = _controller;
    if (controller == null) return;

    late final GateResult result;
    result = controller.presentPlacement(
      _demoTrigger,
      onCTA: (product) {
        _setEvent('CTA tapped: ${product.id}');
        result.dismiss();
      },
      onDismiss: () => _setEvent('Provider paywall dismissed'),
      onFallback: (event) {
        _setEvent('Fallback opened: ${event.reason.name}');
        _openFallbackPaywall(event);
      },
      onImpression: () =>
          _setEvent('Provider impression tracked for $_demoTrigger'),
    );

    if (!result.shown) {
      _setEvent('Provider paywall was not shown; fallback handled it');
    }
  }

  void _presentPaywall() {
    final controller = _controller;
    if (controller == null) return;

    late final GateResult result;
    result = Tranzmit.presentPlacementInRoute(
      context,
      _demoTrigger,
      onCTA: (product) async {
        _setEvent('CTA tapped: ${product.id} — starting host purchase flow');
        await _simulateHostPurchase(product);
        controller.reportConversion({
          'trigger': _demoTrigger,
          'productId': product.id,
          'revenue': 999,
          'currency': 'INR',
        });
        _setEvent('reportConversion sent for ${product.id}');
        result.dismiss();
      },
      onDismiss: () => _setEvent('Paywall dismissed'),
      onFallback: (event) {
        _setEvent('Fallback opened: ${event.reason.name}');
        _openFallbackPaywall(event);
      },
      onImpression: () => _setEvent('Impression tracked for $_demoTrigger'),
    );

    if (!result.shown) {
      _setEvent('Paywall was not shown; fallback handled it');
    }
  }

  Future<void> _simulateHostPurchase(ProductSpec product) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Host purchase (demo)'),
        content: Text(
          'In a real app this is where you call StoreKit / Play Billing / RevenueCat for:\n\n${product.id}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Complete purchase'),
          ),
        ],
      ),
    );
  }

  Future<void> _openFallbackPaywall(FallbackEvent event) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Existing paywall fallback'),
        content: Text(
          'A production app should open its original in-app paywall here.\n\n'
          'Trigger: ${event.trigger}\n'
          'Reason: ${event.reason.name}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final identity = controller?.identity;
    final stableId = identity?.identifiers['stableID'];
    final placement = controller?.getPlacement(_demoTrigger);
    final spec = placement?.spec;
    final document = spec?.document;
    final htmlLoaded = document?.html != null && document!.html!.isNotEmpty;
    final identityDirty = _isIdentityDirty(controller);
    final activeVariant = placement?.variantId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tranzmit SDK Harness'),
        actions: [
          IconButton(
            tooltip: 'Refresh config',
            onPressed: controller == null ? null : _refreshConfig,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _StatusCard(
              title: 'SDK status',
              rows: [
                _StatusRow('Ready', controller?.isReady == true ? 'yes' : 'no'),
                const _StatusRow('API', _apiBaseUrl),
                const _StatusRow('Public key', _publicKey),
                const _StatusRow('Trigger', _demoTrigger),
                if (_lastError != null) _StatusRow('Last error', _lastError!),
                if (_lastEvent != null) _StatusRow('Last event', _lastEvent!),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Statsig identity',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Statsig buckets on stableID when logged out. Set a stableID override or tap a variant preset, then apply identity.',
                      style: TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final key in _variantStableIds.keys)
                          ActionChip(
                            label: Text(key),
                            backgroundColor: activeVariant == key
                                ? const Color(0xFFE9D5FF)
                                : null,
                            onPressed: controller == null
                                ? null
                                : () => _applyVariantPreset(key),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.shuffle, size: 18),
                          label: const Text('Next bucket'),
                          onPressed:
                              controller == null ? null : _applyNextProbeBucket,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _stableIdController,
                      decoration: const InputDecoration(
                        labelText: 'stableID override',
                        hintText: 'e.g. trz_qa_control',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _applyIdentity(),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _userIdController,
                      enabled: !_loggedOut,
                      decoration: const InputDecoration(
                        labelText: 'userId (logged in only)',
                        hintText: 'e.g. user_123',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _applyIdentity(),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Logged out (omit userId)'),
                      subtitle: const Text(
                        'Statsig should bucket on stableID for anonymous installs.',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: _loggedOut,
                      onChanged: (value) {
                        setState(() => _loggedOut = value);
                        unawaited(_applyIdentity());
                      },
                    ),
                    _StatusRow(
                      'stableID',
                      stableId ?? '—',
                    ),
                    _StatusRow(
                      'Active userId',
                      identity?.userId ?? '(none)',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: controller == null ||
                              (!identityDirty && controller.isReady)
                          ? null
                          : _applyIdentity,
                      icon: const Icon(Icons.person),
                      label: Text(
                        identityDirty
                            ? 'Apply identity & reload config'
                            : 'Identity applied',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _StatusCard(
              title: 'Remote placement',
              rows: [
                _StatusRow(
                  'Placement',
                  placement == null
                      ? 'not loaded'
                      : placement.placementId ?? _demoTrigger,
                ),
                _StatusRow('Variant', placement?.variantId ?? '—'),
                _StatusRow('Renderer', spec?.renderer ?? '—'),
                _StatusRow('Presentation', spec?.presentationMode ?? 'sheet'),
                _StatusRow('Revision', spec?.revision?.toString() ?? '—'),
                _StatusRow('Cache key', spec?.cacheKey ?? '—'),
                _StatusRow('Document URL', document?.url ?? '—'),
                _StatusRow('HTML hydrated', htmlLoaded ? 'yes' : 'no'),
                _StatusRow('Integrity', document?.integrity ?? '—'),
                _StatusRow('Preload', _preloadStatus ?? 'not requested'),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'This app contains zero hardcoded paywall UI. Everything comes from Tranzmit config + hosted WebView documents.',
              style: TextStyle(color: Color(0xFF6B7280), height: 1.45),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: controller == null ? null : _presentPaywall,
              icon: const Icon(Icons.lock_open),
              label: const Text('Present "$_demoTrigger"'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: controller == null ? null : _preloadPaywall,
              icon: const Icon(Icons.memory),
              label: const Text('Preload "$_demoTrigger"'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: controller == null ? null : _presentProviderPaywall,
              icon: const Icon(Icons.flash_on),
              label: const Text('Present warmed "$_demoTrigger"'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: controller == null ? null : _refreshConfig,
              icon: const Icon(Icons.cloud_download),
              label: const Text('Refresh config from server'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.title, required this.rows});

  final String title;
  final List<_StatusRow> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: Color(0xFF6B7280),
              ),
            ),
            const SizedBox(height: 12),
            for (final row in rows) ...[
              row,
              if (row != rows.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Color(0xFF111827), fontSize: 13),
          ),
        ),
      ],
    );
  }
}
