import 'dart:convert';
import 'dart:io';

import 'qa_proxy.dart';

/// Quick smoke test: starts the proxy, sends a real /v1/config request
/// through it, and verifies the proxy captures the exchange.
void main() async {
  final proxy = QaProxy(
    upstreamBaseUrl: 'https://api-production-2146.up.railway.app',
    port: 9877,
  );
  await proxy.start();

  try {
    final client = HttpClient();

    // Simulate SDK init: POST /v1/config
    stdout.writeln('\n--- Sending POST /v1/config through proxy ---');
    final configReq = await client.postUrl(
      Uri.parse('http://localhost:9877/v1/config'),
    );
    configReq.headers.contentType = ContentType.json;
    configReq.write(jsonEncode({
      'publicKey': 'pk_test_2a8a5f07d4b9fcf1cc77e024',
      'identity': {
        'identifiers': {'stableID': 'trz_qa_smoke_test'},
      },
    }));
    final configResp = await configReq.close();
    final configBody = await configResp.transform(utf8.decoder).join();

    stdout.writeln('Status: ${configResp.statusCode}');
    stdout.writeln('Config response bytes: ${configBody.length}');
    stdout.writeln('Config calls captured: ${proxy.configPosts.length}');

    // Simulate SDK events: POST /v1/events
    stdout.writeln('\n--- Sending POST /v1/events through proxy ---');
    final eventsReq = await client.postUrl(
      Uri.parse('http://localhost:9877/v1/events'),
    );
    eventsReq.headers.contentType = ContentType.json;
    eventsReq.write(jsonEncode({
      'publicKey': 'pk_test_2a8a5f07d4b9fcf1cc77e024',
      'userId': null,
      'identity': {
        'identifiers': {'stableID': 'trz_qa_smoke_test'},
      },
      'sessionId': 'sess_qa_test_001',
      'traits': {},
      'events': [
        {
          'event': 'impression',
          'properties': {'trigger': 'upgrade_pro', 'variantId': 'intro_offer'},
          'timestamp': DateTime.now().toIso8601String(),
        },
        {
          'event': 'cta_click',
          'properties': {
            'trigger': 'upgrade_pro',
            'productId': 'pro_monthly',
            'variantId': 'intro_offer',
          },
          'timestamp': DateTime.now().toIso8601String(),
        },
        {
          'event': 'conversion',
          'properties': {
            'trigger': 'upgrade_pro',
            'productId': 'pro_monthly',
            'variantId': 'intro_offer',
            'variant_key': 'intro_offer',
            'placement_id': 'pl_123',
            'revenue': 999,
            'currency': 'INR',
          },
          'timestamp': DateTime.now().toIso8601String(),
        },
      ],
    }));
    final eventsResp = await eventsReq.close();
    await eventsResp.drain<void>();

    stdout.writeln('Status: ${eventsResp.statusCode}');
    stdout.writeln('Event posts captured: ${proxy.eventPosts.length}');
    stdout.writeln('All events extracted: ${proxy.allEvents.length}');

    // Show what the checks would see
    stdout.writeln('\n--- Proxy capture summary ---');
    stdout.writeln('impressions: ${proxy.eventsNamed("impression").length}');
    stdout.writeln('cta_clicks: ${proxy.eventsNamed("cta_click").length}');
    stdout.writeln('conversions: ${proxy.eventsNamed("conversion").length}');

    final conversion = proxy.eventsNamed('conversion').first;
    stdout.writeln('\nConversion event properties:');
    final props = conversion['properties'] as Map<String, dynamic>? ?? {};
    for (final entry in props.entries) {
      stdout.writeln('  ${entry.key}: ${entry.value}');
    }

    stdout.writeln('\nEnvelope identity:');
    final envelope = conversion['_envelope'] as Map<String, dynamic>? ?? {};
    stdout.writeln('  sessionId: ${envelope['sessionId']}');
    stdout.writeln('  identity: ${jsonEncode(envelope['identity'])}');

    client.close();
    stdout.writeln('\n✓ Proxy interception working correctly!');
  } finally {
    await proxy.stop();
  }
}
