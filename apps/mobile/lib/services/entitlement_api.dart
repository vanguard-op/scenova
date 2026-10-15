import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/entitlement.dart';

/// An entitlement failure, mapped from `C-018`'s error set.
///
/// `statusCode` is `0` for a transport failure — no connection or a timeout —
/// which the presentation layer reads as the service being unreachable.
class EntitlementApiException implements Exception {
  const EntitlementApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// The caller holds no account (`C-018`, 401): the reader is asked to sign in
  /// rather than shown an error.
  bool get isSignedOut => statusCode == 401;

  /// The entitlement service could not be reached. The reader is told, and a
  /// lookup is never blocked by it (`C-018`).
  bool get isUnavailable => statusCode == 0 || statusCode >= 500;

  @override
  String toString() => 'EntitlementApiException($statusCode, $message)';
}

/// The entitlement service, as frozen in `C-018`.
abstract interface class EntitlementApi {
  /// `GET /v1/entitlement`.
  Future<Entitlement> fetch();
}

/// Talks to the gateway over HTTP.
class HttpEntitlementApi implements EntitlementApi {
  HttpEntitlementApi({
    required this.baseUrl,
    required this.idTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// Supplies the Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  final http.Client _client;

  @override
  Future<Entitlement> fetch() async {
    final response = await _send(
      () async => _client.get(
        Uri.parse('$baseUrl/v1/entitlement'),
        headers: await _headers(),
      ),
    );
    return _decode(response);
  }

  Future<Map<String, String>> _headers() async {
    String? token;
    try {
      token = await idTokenProvider();
    } on Object {
      // The identity could not be established; the request goes out without a
      // token and the service refuses it as unauthenticated (`C-018`, 401),
      // rather than the failure reading as the device being offline.
      token = null;
    }
    return <String, String>{
      'accept': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw const EntitlementApiException(
        0,
        'The entitlement request timed out.',
      );
    } on http.ClientException catch (error) {
      throw EntitlementApiException(0, error.message);
    } on Object {
      throw const EntitlementApiException(0, 'The device is offline.');
    }
  }

  Entitlement _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw const EntitlementApiException(
          0,
          'The service returned no entitlement.',
        );
      }
      return Entitlement.fromJson(body);
    }
    throw _mapError(status, response.body);
  }

  /// Maps an error response to a failure, reading the contract's
  /// `{code, message}` body.
  EntitlementApiException _mapError(int status, String body) {
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
      401 => 'Sign in to see your plan.',
      _ => 'Your plan is unavailable right now.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return EntitlementApiException(status, message, code: code);
  }
}

/// A scripted entitlement for development and tests.
///
/// `docs/Scenova/` fixes the wire shape, so this speaks it exactly and the
/// screen is built against the frozen contract before the endpoint is live.
class MockEntitlementApi implements EntitlementApi {
  MockEntitlementApi({
    this.plan = _defaultFree,
    this.latency = Duration.zero,
    this.error,
  });

  /// The entitlement the service answers with.
  final Entitlement plan;

  /// Simulated network latency.
  final Duration latency;

  /// A failure to answer with instead, for the error and signed-out states.
  final EntitlementApiException? error;

  /// The default plan a signed-in reader on the free tier sees.
  static const Entitlement _defaultFree = Entitlement(
    tier: PlanTier.free,
    signedIn: true,
    lookupsUsed: 12,
    lookupsLimit: 20,
  );

  @override
  Future<Entitlement> fetch() async {
    if (latency != Duration.zero) {
      await Future<void>.delayed(latency);
    }
    final failure = error;
    if (failure != null) throw failure;
    return plan;
  }
}
