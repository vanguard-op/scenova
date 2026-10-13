import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/analytics_event.dart';

/// A failure from the event intake, mapped from the contract's error set
/// (`C-007`).
///
/// `statusCode` is `0` for a transport failure (no connection or a timeout),
/// which the client reads as the device being offline.
class AnalyticsApiException implements Exception {
  const AnalyticsApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// A transport failure: the device is offline or the request never arrived.
  bool get isOffline => statusCode == 0;

  /// Rate limited, or the intake is unavailable: retrying may succeed.
  bool get isRetryable => statusCode == 429 || statusCode >= 500;

  /// The batch was rejected: an unknown event name or a property carrying
  /// personal data. Resending it unchanged cannot succeed.
  bool get isRejected => statusCode == 400;

  /// The caller is not authenticated.
  bool get isUnauthenticated => statusCode == 401;

  @override
  String toString() => 'AnalyticsApiException($statusCode, $message)';
}

/// The event intake, as frozen in `C-007`.
abstract interface class AnalyticsApi {
  /// `POST /v1/events`. Sends a batch of at most fifty events and returns the
  /// number the service accepted.
  Future<int> send(List<AnalyticsEvent> events);
}

/// Talks to the gateway over HTTP.
class HttpAnalyticsApi implements AnalyticsApi {
  HttpAnalyticsApi({
    required this.baseUrl,
    required this.idTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// Supplies the Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  final http.Client _client;

  @override
  Future<int> send(List<AnalyticsEvent> events) async {
    assert(
      events.length <= AppConfig.analyticsBatchSize,
      'The intake takes at most ${AppConfig.analyticsBatchSize} events a batch.',
    );
    final response = await _send(
      () async => _client.post(
        Uri.parse('$baseUrl/v1/events'),
        headers: await _headers(),
        body: jsonEncode(<String, dynamic>{
          'events': events
              .map((event) => event.toJson())
              .toList(growable: false),
        }),
      ),
    );
    return _decode(response);
  }

  Future<Map<String, String>> _headers() async {
    String? token;
    try {
      token = await idTokenProvider();
    } on Object {
      // The identity could not be established. The request goes out without a
      // token and the gateway refuses it as unauthenticated (`C-007`, 401).
      token = null;
    }
    return <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw const AnalyticsApiException(0, 'The event batch timed out.');
    } on http.ClientException catch (error) {
      throw AnalyticsApiException(0, error.message);
    } on Object {
      throw const AnalyticsApiException(0, 'The device is offline.');
    }
  }

  int _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic> && body['accepted'] is int) {
          return body['accepted'] as int;
        }
      } on FormatException {
        // The body was not readable; the batch was still accepted.
      }
      return 0;
    }
    throw _mapError(status, response.body);
  }

  AnalyticsApiException _mapError(int status, String body) {
    String? code;
    String? serviceMessage;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        code = decoded['code'] as String?;
        serviceMessage = decoded['message'] as String?;
      }
    } on FormatException {
      // The body was not readable; fall back to the app's own wording.
    }
    final fallback = switch (status) {
      400 => 'The event batch was rejected.',
      401 => 'Sign in to send events.',
      429 => 'Too many events just now.',
      _ => 'The event intake is unavailable.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return AnalyticsApiException(status, message, code: code);
  }
}

/// A recording intake for development and tests.
///
/// It keeps every event it is handed, so a test can assert what the app
/// emitted, and can be scripted to fail so the client's queueing is exercised.
class MockAnalyticsApi implements AnalyticsApi {
  MockAnalyticsApi({this.latency = Duration.zero});

  /// Simulated network latency.
  final Duration latency;

  /// Every event accepted so far, in order.
  final List<AnalyticsEvent> sent = <AnalyticsEvent>[];

  /// The batches sent, so a test can assert the fifty-event cap.
  final List<List<AnalyticsEvent>> batches = <List<AnalyticsEvent>>[];

  /// When set, `send` throws this status instead of accepting the batch.
  int? failStatus;

  @override
  Future<int> send(List<AnalyticsEvent> events) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final status = failStatus;
    if (status != null) {
      throw AnalyticsApiException(status, 'Scripted failure $status.');
    }
    final batch = List<AnalyticsEvent>.of(events);
    batches.add(batch);
    sent.addAll(batch);
    return batch.length;
  }
}
