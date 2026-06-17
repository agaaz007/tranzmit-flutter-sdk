import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A captured HTTP request/response pair for inspection by the QA checks.
class CapturedExchange {
  CapturedExchange({
    required this.method,
    required this.path,
    required this.requestBody,
    required this.responseStatus,
    required this.responseBody,
    required this.timestamp,
    required this.latencyMs,
  });

  final String method;
  final String path;
  final Map<String, dynamic>? requestBody;
  final int responseStatus;
  final Map<String, dynamic>? responseBody;
  final DateTime timestamp;
  final int latencyMs;
}

/// Lightweight intercepting proxy that forwards SDK traffic to the real Railway
/// API while capturing request/response bodies for the QA checklist.
class QaProxy {
  QaProxy({
    required this.upstreamBaseUrl,
    this.port = 9877,
  });

  final String upstreamBaseUrl;
  final int port;

  HttpServer? _server;
  final HttpClient _upstream = HttpClient()..autoUncompress = false;
  final List<CapturedExchange> _exchanges = [];
  final StreamController<CapturedExchange> _exchangeController =
      StreamController<CapturedExchange>.broadcast();

  List<CapturedExchange> get exchanges => List.unmodifiable(_exchanges);
  Stream<CapturedExchange> get onExchange => _exchangeController.stream;

  /// All captured `/v1/events` POST bodies.
  List<CapturedExchange> get eventPosts => _exchanges
      .where((e) => e.path == '/v1/events' && e.method == 'POST')
      .toList();

  /// All captured `/v1/config` POST bodies.
  List<CapturedExchange> get configPosts => _exchanges
      .where((e) => e.path == '/v1/config' && e.method == 'POST')
      .toList();

  /// All individual events extracted from `/v1/events` batches.
  List<Map<String, dynamic>> get allEvents {
    final result = <Map<String, dynamic>>[];
    for (final exchange in eventPosts) {
      final body = exchange.requestBody;
      if (body == null) continue;
      final events = body['events'];
      if (events is List) {
        for (final event in events) {
          if (event is Map<String, dynamic>) {
            result.add(<String, dynamic>{
              ...event,
              '_envelope': <String, dynamic>{
                'publicKey': body['publicKey'],
                'userId': body['userId'],
                'identity': body['identity'],
                'sessionId': body['sessionId'],
                'traits': body['traits'],
              },
            });
          }
        }
      }
    }
    return result;
  }

  /// Events filtered by name.
  List<Map<String, dynamic>> eventsNamed(String name) =>
      allEvents.where((e) => e['event'] == name).toList();

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    stdout.writeln(
        '[QA Proxy] Listening on http://localhost:$port → $upstreamBaseUrl');
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _upstream.close(force: true);
    await _exchangeController.close();
    stdout.writeln('[QA Proxy] Stopped');
  }

  Future<void> _handleRequest(HttpRequest clientRequest) async {
    final stopwatch = Stopwatch()..start();
    Map<String, dynamic>? requestBody;
    Map<String, dynamic>? responseBody;
    int responseStatus = 502;

    try {
      final requestBytes = await clientRequest.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );

      if (requestBytes.isNotEmpty) {
        try {
          requestBody =
              jsonDecode(utf8.decode(requestBytes)) as Map<String, dynamic>?;
        } catch (_) {}
      }

      final upstreamUri =
          Uri.parse('$upstreamBaseUrl${clientRequest.uri.path}');
      final upstreamRequest =
          await _upstream.openUrl(clientRequest.method, upstreamUri);

      clientRequest.headers.forEach((name, values) {
        if (name.toLowerCase() == 'host') return;
        for (final v in values) {
          upstreamRequest.headers.add(name, v);
        }
      });

      if (requestBytes.isNotEmpty) {
        upstreamRequest.contentLength = requestBytes.length;
        upstreamRequest.add(requestBytes);
      }

      final upstreamResponse = await upstreamRequest.close();
      responseStatus = upstreamResponse.statusCode;

      final responseBytes = await upstreamResponse.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );

      // Decompress for inspection if gzipped
      List<int> decompressedBytes = responseBytes;
      final contentEncoding =
          upstreamResponse.headers.value('content-encoding');
      if (contentEncoding == 'gzip' && responseBytes.isNotEmpty) {
        try {
          decompressedBytes = gzip.decode(responseBytes);
        } catch (_) {}
      }

      if (decompressedBytes.isNotEmpty) {
        try {
          responseBody = jsonDecode(utf8.decode(decompressedBytes))
              as Map<String, dynamic>?;
        } catch (_) {}
      }

      // Forward the raw (possibly compressed) response to the client
      clientRequest.response.statusCode = responseStatus;
      upstreamResponse.headers.forEach((name, values) {
        if (name.toLowerCase() == 'transfer-encoding') return;
        for (final v in values) {
          clientRequest.response.headers.add(name, v);
        }
      });
      clientRequest.response.add(responseBytes);
      await clientRequest.response.close();
    } catch (e) {
      try {
        clientRequest.response.statusCode = 502;
        clientRequest.response.write('Proxy error: $e');
        await clientRequest.response.close();
      } catch (_) {}
    }

    stopwatch.stop();

    final exchange = CapturedExchange(
      method: clientRequest.method,
      path: clientRequest.uri.path,
      requestBody: requestBody,
      responseStatus: responseStatus,
      responseBody: responseBody,
      timestamp: DateTime.now(),
      latencyMs: stopwatch.elapsedMilliseconds,
    );

    _exchanges.add(exchange);
    _exchangeController.add(exchange);
  }

  /// Wait until at least one exchange matching [path] and optionally containing
  /// an event named [eventName] is captured, or timeout.
  Future<CapturedExchange?> waitForExchange({
    required String path,
    String? eventName,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final existing = _exchanges.where((e) => e.path == path).where((e) {
      if (eventName == null) return true;
      final events = e.requestBody?['events'] as List?;
      if (events == null) return false;
      return events.any((ev) => ev is Map && ev['event'] == eventName);
    });
    if (existing.isNotEmpty) return existing.last;

    final completer = Completer<CapturedExchange?>();
    late StreamSubscription<CapturedExchange> sub;
    Timer? timer;

    sub = onExchange.listen((exchange) {
      if (exchange.path != path) return;
      if (eventName != null) {
        final events = exchange.requestBody?['events'] as List?;
        if (events == null) return;
        if (!events.any((ev) => ev is Map && ev['event'] == eventName)) return;
      }
      timer?.cancel();
      sub.cancel();
      if (!completer.isCompleted) completer.complete(exchange);
    });

    timer = Timer(timeout, () {
      sub.cancel();
      if (!completer.isCompleted) completer.complete(null);
    });

    return completer.future;
  }
}
