import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/feedback.dart';

/// A failure from the feedback intake, mapped from the contract's error set
/// (`C-012`).
///
/// `statusCode` is `0` for a transport failure (no connection or a timeout),
/// which the client reads as the device being offline.
class FeedbackApiException implements Exception {
  const FeedbackApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// A transport failure: the device is offline or the request never arrived.
  bool get isOffline => statusCode == 0;

  /// Rate limited, unauthenticated, or the feedback store unavailable:
  /// retrying may succeed. An unauthenticated request is retried rather than
  /// dropped, because the identity refreshes per request and the reader's rating
  /// is not the reader's to lose (`C-012`, 401/429/503).
  bool get isRetryable =>
      statusCode == 401 || statusCode == 429 || statusCode >= 500;

  /// The rating was refused and resending it cannot succeed: an unknown rating,
  /// a lookup with no clip served, a lookup the caller does not own, or a
  /// reused key carrying a different rating (`C-012`, 400/404/409).
  bool get isRefused =>
      statusCode == 400 || statusCode == 404 || statusCode == 409;

  @override
  String toString() => 'FeedbackApiException($statusCode, $message)';
}

/// The feedback intake, as frozen in `C-012`.
abstract interface class FeedbackApi {
  /// `POST /v1/feedback`. Returns whether the service recorded the rating.
  Future<bool> rate(PendingFeedback feedback);
}

/// Talks to the gateway over HTTP.
class HttpFeedbackApi implements FeedbackApi {
  HttpFeedbackApi({
    required this.baseUrl,
    required this.idTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// Supplies the Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  final http.Client _client;

  @override
  Future<bool> rate(PendingFeedback feedback) async {
    final response = await _send(
      () async => _client.post(
        Uri.parse('$baseUrl/v1/feedback'),
        headers: await _headers(),
        body: jsonEncode(feedback.toJson()),
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
      // token and the gateway refuses it as unauthenticated (`C-012`, 401),
      // rather than the failure reading as the device being offline.
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
      throw const FeedbackApiException(0, 'The rating timed out.');
    } on http.ClientException catch (error) {
      throw FeedbackApiException(0, error.message);
    } on Object {
      throw const FeedbackApiException(0, 'The device is offline.');
    }
  }

  bool _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic> && body['recorded'] is bool) {
          return body['recorded'] as bool;
        }
      } on FormatException {
        // The body was not readable; the intake accepted the rating.
      }
      return true;
    }
    throw _mapError(status, response.body);
  }

  /// Maps an error response to a failure, reading the contract's
  /// `{code, message}` body.
  FeedbackApiException _mapError(int status, String body) {
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
      400 => 'That rating could not be recorded.',
      401 => 'Sign in to rate a clip.',
      404 => 'That clip is no longer available.',
      409 => 'That rating was already recorded.',
      429 => 'Too many ratings just now.',
      _ => 'The feedback service is unavailable.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return FeedbackApiException(status, message, code: code);
  }
}

/// A recording intake for development and tests.
///
/// It keeps every rating it is handed, so a test can assert what the app sent,
/// and can be scripted to fail so the client's queueing is exercised.
class MockFeedbackApi implements FeedbackApi {
  MockFeedbackApi({this.latency = Duration.zero});

  /// Simulated network latency.
  final Duration latency;

  /// Every rating accepted so far, in order.
  final List<PendingFeedback> recorded = <PendingFeedback>[];

  /// When set, `rate` throws this status instead of accepting the rating.
  int? failStatus;

  /// When set beside [failStatus], only a rating for this lookup fails; the
  /// rest are accepted, so one refused rating can be told from the others.
  String? failLookupId;

  @override
  Future<bool> rate(PendingFeedback feedback) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final status = failStatus;
    final only = failLookupId;
    if (status != null && (only == null || only == feedback.lookupId)) {
      throw FeedbackApiException(status, 'Scripted failure $status.');
    }
    recorded.add(feedback);
    return true;
  }
}
