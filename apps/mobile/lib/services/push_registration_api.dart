import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/lookup.dart';

/// A push-token registration failure, mapped from the contract's error set
/// (`C-008`).
///
/// `statusCode` is `0` for a transport failure (no connection or a timeout),
/// which the client reads as the device being offline.
class PushRegistrationException implements Exception {
  const PushRegistrationException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// A transport failure: the device is offline or the request never arrived.
  bool get isOffline => statusCode == 0;

  /// Rate limited, or the intake is unavailable: retrying may succeed.
  bool get isRetryable => statusCode == 429 || statusCode >= 500;

  /// The caller is not authenticated.
  bool get isUnauthenticated => statusCode == 401;

  /// The token or platform was rejected: resending it unchanged cannot succeed.
  bool get isRejected => statusCode == 400;

  @override
  String toString() => 'PushRegistrationException($statusCode, $message)';
}

/// The push-token registrations intake, as frozen in `C-008`.
abstract interface class PushRegistrationApi {
  /// `POST /v1/push-registrations`. Registers the device's platform push token
  /// against [lookupId] — the lookup the reader is waiting on — so the
  /// notification service can reach the reader when that generation completes.
  ///
  /// Returns whether a notice will come: `false` when the lookup has already
  /// finished, since there is no later event to tell the reader about.
  Future<bool> register({
    required String token,
    required LookupPlatform platform,
    required String lookupId,
  });
}

/// Talks to the gateway over HTTP.
class HttpPushRegistrationApi implements PushRegistrationApi {
  HttpPushRegistrationApi({
    required this.baseUrl,
    required this.idTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// Supplies the Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  final http.Client _client;

  @override
  Future<bool> register({
    required String token,
    required LookupPlatform platform,
    required String lookupId,
  }) async {
    final response = await _send(
      () async => _client.post(
        Uri.parse('$baseUrl/v1/push-registrations'),
        headers: await _headers(),
        body: jsonEncode(<String, dynamic>{
          'token': token,
          'platform': platform.wire,
          'lookupId': lookupId,
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
      // token and the gateway refuses it as unauthenticated (`C-008`, 401).
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
      throw const PushRegistrationException(0, 'The registration timed out.');
    } on http.ClientException catch (error) {
      throw PushRegistrationException(0, error.message);
    } on Object {
      throw const PushRegistrationException(0, 'The device is offline.');
    }
  }

  bool _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic> && body['registered'] is bool) {
          return body['registered'] as bool;
        }
      } on FormatException {
        // The body was not readable; the token was still accepted.
      }
      return true;
    }
    throw _mapError(status, response.body);
  }

  PushRegistrationException _mapError(int status, String body) {
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
      400 => 'That device token could not be read.',
      401 => 'Sign in to turn on clip notices.',
      429 => 'Too many attempts just now.',
      _ => 'Clip notices are unavailable right now.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return PushRegistrationException(status, message, code: code);
  }
}

/// A recording intake for development and tests.
///
/// It keeps every registration it is handed, so a test can assert what the app
/// sent, and can be scripted to fail so the client's retry is exercised.
class MockPushRegistrationApi implements PushRegistrationApi {
  MockPushRegistrationApi({this.latency = Duration.zero});

  /// Simulated network latency.
  final Duration latency;

  /// Every token registered so far, in order.
  final List<String> tokens = <String>[];

  /// The platform each registration reported, in order.
  final List<LookupPlatform> platforms = <LookupPlatform>[];

  /// The lookup each registration was tied to, in order.
  final List<String> lookupIds = <String>[];

  /// When set, `register` throws this status instead of accepting the token.
  int? failStatus;

  /// When true, the service accepts the call but reports that no notice is
  /// coming — the lookup has already finished (`C-008`, `registered: false`).
  bool declinesRegistration = false;

  @override
  Future<bool> register({
    required String token,
    required LookupPlatform platform,
    required String lookupId,
  }) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final status = failStatus;
    if (status != null) {
      throw PushRegistrationException(status, 'Scripted failure $status.');
    }
    if (declinesRegistration) return false;
    tokens.add(token);
    platforms.add(platform);
    lookupIds.add(lookupId);
    return true;
  }
}
