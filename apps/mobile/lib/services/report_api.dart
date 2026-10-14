import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/report.dart';

/// A failure from the report intake, mapped from the contract's error set
/// (`C-013`).
///
/// `statusCode` is `0` for a transport failure (no connection or a timeout),
/// which the client reads as the device being offline.
class ReportApiException implements Exception {
  const ReportApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// A transport failure: the device is offline or the request never arrived.
  bool get isOffline => statusCode == 0;

  /// Rate limited, unauthenticated, or the report store unavailable: retrying
  /// may succeed. An unauthenticated request is retried rather than dropped,
  /// because the identity refreshes per request and the reader's report is not
  /// the reader's to lose (`C-013`, 401/429/503).
  bool get isRetryable =>
      statusCode == 401 || statusCode == 429 || statusCode >= 500;

  /// The reader had already reported this clip, so the service keeps the one it
  /// holds (`C-013`, 409). Resending cannot add anything.
  bool get isDuplicate => statusCode == 409;

  /// The report was refused and resending it cannot succeed: an unknown reason,
  /// a note over the limit, a lookup with no clip served, or a lookup the
  /// caller does not own (`C-013`, 400/404).
  bool get isRefused => statusCode == 400 || statusCode == 404;

  @override
  String toString() => 'ReportApiException($statusCode, $message)';
}

/// The report intake, as frozen in `C-013`.
abstract interface class ReportApi {
  /// `POST /v1/reports`. Returns whether the service queued the report.
  Future<bool> report(PendingReport report);
}

/// Talks to the gateway over HTTP.
class HttpReportApi implements ReportApi {
  HttpReportApi({
    required this.baseUrl,
    required this.idTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// Supplies the Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  final http.Client _client;

  @override
  Future<bool> report(PendingReport report) async {
    final response = await _send(
      () async => _client.post(
        Uri.parse('$baseUrl/v1/reports'),
        headers: await _headers(),
        body: jsonEncode(report.toJson()),
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
      // token and the gateway refuses it as unauthenticated (`C-013`, 401),
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
      throw const ReportApiException(0, 'The report timed out.');
    } on http.ClientException catch (error) {
      throw ReportApiException(0, error.message);
    } on Object {
      throw const ReportApiException(0, 'The device is offline.');
    }
  }

  bool _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic> && body['status'] is String) {
          return body['status'] == 'queued';
        }
      } on FormatException {
        // The body was not readable; the intake accepted the report.
      }
      return true;
    }
    throw _mapError(status, response.body);
  }

  /// Maps an error response to a failure, reading the contract's
  /// `{code, message}` body.
  ReportApiException _mapError(int status, String body) {
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
      400 => 'That report could not be sent.',
      401 => 'Sign in to report a clip.',
      404 => 'That clip is no longer available.',
      409 => "You've already reported this clip.",
      429 => 'Too many reports just now.',
      _ => 'The report service is unavailable.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return ReportApiException(status, message, code: code);
  }
}

/// A recording intake for development and tests.
///
/// It keeps every report it is handed, so a test can assert what the app sent,
/// and can be scripted to fail so the client's queueing is exercised.
class MockReportApi implements ReportApi {
  MockReportApi({this.latency = Duration.zero});

  /// Simulated network latency.
  final Duration latency;

  /// Every report accepted so far, in order.
  final List<PendingReport> recorded = <PendingReport>[];

  /// When set, `report` throws this status instead of accepting the report.
  int? failStatus;

  /// When set beside [failStatus], only a report for this lookup fails; the
  /// rest are accepted, so one refused report can be told from the others.
  String? failLookupId;

  @override
  Future<bool> report(PendingReport report) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final status = failStatus;
    final only = failLookupId;
    if (status != null && (only == null || only == report.lookupId)) {
      throw ReportApiException(status, 'Scripted failure $status.');
    }
    recorded.add(report);
    return true;
  }
}
