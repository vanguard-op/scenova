import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// An account-write failure, mapped from `C-020`'s error set.
///
/// `statusCode` is `0` for a transport failure — no connection or a timeout —
/// which the presentation layer reads as the account being unreachable.
class AccountApiException implements Exception {
  const AccountApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// The caller holds no account (`C-020`, 401). The reader's choice is held on
  /// the device alone, which is the signed-out case rather than a failure.
  bool get isSignedOut => statusCode == 401;

  /// The account store could not be reached (`C-020`, 503, or no connection).
  bool get isUnavailable => statusCode == 0 || statusCode >= 500;

  /// The write was refused outright (`C-020`, 400).
  bool get isRejected => statusCode == 400;

  @override
  String toString() => 'AccountApiException($statusCode, $message)';
}

/// The account's stored preferences, as `C-020` returns them.
@immutable
class AccountPreferences {
  const AccountPreferences({
    required this.consentModelProcessing,
    required this.locale,
  });

  /// Consent to send the selected word to the model provider.
  final bool consentModelProcessing;

  /// The reader's preferred locale for the selection-action label.
  final String locale;

  static AccountPreferences fromJson(Map<String, dynamic> json) {
    return AccountPreferences(
      consentModelProcessing: json['consentModelProcessing'] as bool? ?? true,
      locale: json['locale'] as String? ?? 'en',
    );
  }
}

/// The account store, as frozen in `C-020`.
///
/// The consent choice and the action-label language are stored on the account,
/// so they follow a signed-in reader to a new device; before sign-in they are
/// held on the device alone.
abstract interface class AccountApi {
  /// `PATCH /v1/account`. At least one field is given.
  Future<AccountPreferences> update({
    bool? consentModelProcessing,
    String? locale,
  });
}

/// Talks to the gateway over HTTP.
class HttpAccountApi implements AccountApi {
  HttpAccountApi({
    required this.baseUrl,
    required this.idTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// Supplies the Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  final http.Client _client;

  @override
  Future<AccountPreferences> update({
    bool? consentModelProcessing,
    String? locale,
  }) async {
    final body = <String, Object?>{
      'consentModelProcessing': ?consentModelProcessing,
      'locale': ?locale,
    };
    final response = await _send(
      () async => _client.patch(
        Uri.parse('$baseUrl/v1/account'),
        headers: await _headers(),
        body: jsonEncode(body),
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
      // token and the service refuses it as unauthenticated (`C-020`, 401),
      // rather than the failure reading as the account being unreachable.
      token = null;
    }
    return <String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw const AccountApiException(0, 'The account request timed out.');
    } on http.ClientException catch (error) {
      throw AccountApiException(0, error.message);
    } on Object {
      throw const AccountApiException(0, 'The device is offline.');
    }
  }

  AccountPreferences _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw const AccountApiException(0, 'The service returned no account.');
      }
      return AccountPreferences.fromJson(body);
    }
    throw _mapError(status, response.body);
  }

  /// Maps an error response to a failure, reading the contract's
  /// `{code, message}` body.
  AccountApiException _mapError(int status, String body) {
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
      400 => 'That setting could not be saved.',
      401 => 'Sign in to keep this choice on your account.',
      _ => 'Your account is unavailable right now.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return AccountApiException(status, message, code: code);
  }
}

/// A scripted account store for development and tests.
///
/// `docs/Scenova/` fixes the wire shape, so this speaks it exactly and the
/// screen is built against the frozen contract before the endpoint is live.
class MockAccountApi implements AccountApi {
  MockAccountApi({
    this.consentModelProcessing = true,
    this.locale = 'en',
    this.latency = Duration.zero,
    this.error,
    this.signedOut = false,
  });

  /// The consent the account holds.
  bool consentModelProcessing;

  /// The action-label language the account holds.
  String locale;

  /// Simulated network latency.
  final Duration latency;

  /// A failure to answer with instead, for the unavailable state.
  AccountApiException? error;

  /// Whether the caller holds no account, so the write is refused with `C-020`'s
  /// 401 and the choice stays on the device.
  final bool signedOut;

  /// Every write that reached the store, oldest first.
  final List<({bool? consentModelProcessing, String? locale})> writes =
      <({bool? consentModelProcessing, String? locale})>[];

  @override
  Future<AccountPreferences> update({
    bool? consentModelProcessing,
    String? locale,
  }) async {
    if (latency != Duration.zero) {
      await Future<void>.delayed(latency);
    }
    if (signedOut) {
      throw const AccountApiException(401, 'Sign in to keep this choice.');
    }
    final failure = error;
    if (failure != null) throw failure;
    writes.add((
      consentModelProcessing: consentModelProcessing,
      locale: locale,
    ));
    if (consentModelProcessing != null) {
      this.consentModelProcessing = consentModelProcessing;
    }
    if (locale != null) this.locale = locale;
    return AccountPreferences(
      consentModelProcessing: this.consentModelProcessing,
      locale: this.locale,
    );
  }
}
