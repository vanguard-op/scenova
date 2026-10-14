import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/lookup.dart';

/// A lookup failure, mapped from the contract's error set.
///
/// `statusCode` is `0` for a transport failure (no connection or a timeout),
/// which the presentation layer reads as the offline case.
class LookupApiException implements Exception {
  const LookupApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// A transport failure: the device is offline or the request never arrived.
  bool get isOffline => statusCode == 0;

  /// Rate limited, or the upstream lookup is unavailable: retrying may
  /// succeed. `503` is the contract's retryable upstream case; other `5xx`
  /// failures are treated the same way.
  bool get isRetryable => statusCode == 429 || statusCode >= 500;

  /// The selection was empty or over the phrase limit.
  bool get isInvalidSelection => statusCode == 400;

  /// The caller is not authenticated.
  bool get isUnauthenticated => statusCode == 401;

  /// The lookup is unknown or not owned by the caller.
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => 'LookupApiException($statusCode, $message)';
}

/// The lookup service, as frozen in `C-001` and `C-002`.
abstract interface class LookupApi {
  /// `POST /v1/lookups`.
  Future<LookupResult> createLookup(LookupRequest request);

  /// `GET /v1/lookups/{lookupId}`.
  Future<LookupResult> getLookup(String lookupId);
}

/// Talks to the gateway over HTTP.
class HttpLookupApi implements LookupApi {
  HttpLookupApi({
    required this.baseUrl,
    required this.idTokenProvider,
    required this.localeProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// Supplies the Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  /// Supplies the reader's locale for the request body.
  final String Function() localeProvider;

  final http.Client _client;

  @override
  Future<LookupResult> createLookup(LookupRequest request) async {
    final response = await _send(
      () async => _client.post(
        _uri('/v1/lookups'),
        headers: await _headers(),
        body: jsonEncode(request.toJson()),
      ),
    );
    return _decode(response);
  }

  @override
  Future<LookupResult> getLookup(String lookupId) async {
    final response = await _send(
      () async =>
          _client.get(_uri('/v1/lookups/$lookupId'), headers: await _headers()),
    );
    return _decode(response);
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, String>> _headers() async {
    String? token;
    try {
      token = await idTokenProvider();
    } on Object {
      // The identity could not be established. The request goes out without a
      // token and the gateway refuses it as unauthenticated (`C-001`/`C-002`,
      // 401), rather than the failure reading as the device being offline.
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
      throw const LookupApiException(0, 'The lookup timed out.');
    } on http.ClientException catch (error) {
      throw LookupApiException(0, error.message);
    } on Object {
      throw const LookupApiException(0, 'The device is offline.');
    }
  }

  LookupResult _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw const LookupApiException(0, 'The service returned no lookup.');
      }
      return LookupResult.fromJson(body);
    }
    throw _mapError(status, response.body);
  }

  /// Maps an error response to a failure, reading the contract's
  /// `{code, message}` body.
  ///
  /// The service's `message` is used when it sends one; a status we know falls
  /// back to the app's own wording so a reader never sees a raw error.
  LookupApiException _mapError(int status, String body) {
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
      400 => 'Scenova looks up single words and short phrases.',
      401 => 'Sign in to look up a word.',
      404 => 'That lookup is no longer available.',
      409 => 'That lookup was already started.',
      429 => 'Too many lookups just now. Try again shortly.',
      _ => 'The lookup service is unavailable.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return LookupApiException(status, message, code: code);
  }
}

/// A scripted lookup service for development and tests.
///
/// `docs/Scenova/` fixes the wire shapes, so this mock speaks them exactly and
/// the screens are built against the frozen contract before the endpoint is
/// live. It also scripts one representative state per selection so every state
/// can be viewed and tested.
class MockLookupApi implements LookupApi {
  MockLookupApi({
    this.latency = Duration.zero,
    this.pollsUntilReady = 2,
    List<LookupResult>? script,
  }) : _script = List<LookupResult>.of(script ?? const <LookupResult>[]);

  /// Simulated network latency.
  final Duration latency;

  /// How many `getLookup` calls a generating result needs before it serves.
  final int pollsUntilReady;

  final List<LookupResult> _script;
  final Map<String, LookupResult> _byId = <String, LookupResult>{};
  final Map<String, int> _polls = <String, int>{};
  int _counter = 0;

  @override
  Future<LookupResult> createLookup(LookupRequest request) async {
    await _delay();
    final result = _script.isNotEmpty
        ? _script.removeAt(0)
        : _scenarioFor(request.selection);
    _byId[result.lookupId] = result;
    return result;
  }

  @override
  Future<LookupResult> getLookup(String lookupId) async {
    await _delay();
    final current = _byId[lookupId];
    if (current == null) {
      throw const LookupApiException(
        404,
        'That lookup is no longer available.',
      );
    }
    if (current.status != LookupStatus.generating) return current;

    // A phrase lookup never resolves to served: its clip reaches the client by
    // the clip-ready notice and is never served on the read path (`C-001`,
    // `C-002`, `FEAT-007`). The mock keeps it generating, as the lookup service
    // does, so the client's notice path is what is exercised.
    if (current.kind == LookupKind.phrase) return current;

    final polls = (_polls[lookupId] ?? 0) + 1;
    _polls[lookupId] = polls;
    if (polls < pollsUntilReady) return current;

    final ready = _servedFrom(current);
    _byId[lookupId] = ready;
    return ready;
  }

  Future<void> _delay() => latency == Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(latency);

  /// The representative state each selection resolves to.
  ///
  /// A selection not listed resolves to a library hit, which is the common
  /// case.
  LookupResult _scenarioFor(String selection) {
    final key = selection.toLowerCase();
    return switch (key) {
      'bank' => _senseChoice(selection),
      'xylograph' => _generating(selection),
      'quixotic' => _fallback(selection),
      _ =>
        selection.contains(' ')
            ? _phraseClip(selection)
            : _libraryHit(selection),
    };
  }

  /// A short phrase generates its clip on demand and keeps it only on the
  /// device, so the phrase never carries a library entry (`FEAT-007`). It stays
  /// generating: its clip is delivered by the clip-ready notice, never on this
  /// read path.
  LookupResult _phraseClip(String selection) {
    return LookupResult(
      lookupId: _nextId(),
      kind: LookupKind.phrase,
      rawSelection: selection,
      // A phrase is not normalised to a base form; it is its own key.
      normalisedLemma: null,
      status: LookupStatus.generating,
      senses: <Sense>[
        Sense(
          senseLabel: '1',
          partOfSpeech: '',
          glossPhrase: selection,
          entryId: null,
        ),
      ],
      notice: null,
      correlationId: 'mock-correlation',
    );
  }

  LookupResult _libraryHit(String selection) {
    return LookupResult(
      lookupId: _nextId(),
      kind: selection.contains(' ') ? LookupKind.phrase : LookupKind.word,
      rawSelection: selection,
      normalisedLemma: selection.toLowerCase(),
      status: LookupStatus.served,
      senses: <Sense>[
        Sense(
          senseLabel: '1',
          partOfSpeech: 'noun',
          glossPhrase: 'a short clip that shows what the word means',
          entryId: 'lib-$selection',
          clip: const Clip(
            url: 'mock://clip/library-hit',
            durationSeconds: 4,
            resolution: '360p',
            hasAudio: false,
          ),
        ),
      ],
      notice: null,
      correlationId: 'mock-correlation',
    );
  }

  LookupResult _senseChoice(String selection) {
    return LookupResult(
      lookupId: _nextId(),
      kind: LookupKind.word,
      rawSelection: selection,
      normalisedLemma: 'bank',
      status: LookupStatus.served,
      senses: <Sense>[
        Sense(
          senseLabel: '1',
          partOfSpeech: 'noun',
          glossPhrase: 'the land along the side of a river',
          entryId: 'lib-bank-1',
          clip: const Clip(
            url: 'mock://clip/bank-river',
            durationSeconds: 4,
            resolution: '360p',
            hasAudio: true,
          ),
        ),
        Sense(
          senseLabel: '2',
          partOfSpeech: 'noun',
          glossPhrase: 'a place that keeps money safe',
          entryId: 'lib-bank-2',
          clip: const Clip(
            url: 'mock://clip/bank-money',
            durationSeconds: 4,
            resolution: '360p',
            hasAudio: false,
          ),
        ),
      ],
      notice: null,
      correlationId: 'mock-correlation',
    );
  }

  LookupResult _generating(String selection) {
    return LookupResult(
      lookupId: _nextId(),
      kind: LookupKind.word,
      rawSelection: selection,
      // The word is not in the sense inventory, so no base form is supplied.
      normalisedLemma: null,
      status: LookupStatus.generating,
      senses: <Sense>[
        Sense(
          senseLabel: '1',
          partOfSpeech: 'verb',
          glossPhrase: 'to print a picture from a carved block of wood',
          entryId: null,
        ),
      ],
      // No notice: the reader is told nothing about the product's confidence.
      notice: null,
      correlationId: 'mock-correlation',
    );
  }

  LookupResult _fallback(String selection) {
    return LookupResult(
      lookupId: _nextId(),
      kind: LookupKind.word,
      rawSelection: selection,
      normalisedLemma: null,
      status: LookupStatus.fallback,
      senses: <Sense>[
        Sense(
          senseLabel: '1',
          partOfSpeech: 'adjective',
          glossPhrase: 'hopeful even when things are unlikely',
          entryId: null,
        ),
      ],
      notice: null,
      correlationId: 'mock-correlation',
    );
  }

  LookupResult _servedFrom(LookupResult generating) {
    final first = generating.senses.isEmpty ? null : generating.senses.first;
    return LookupResult(
      lookupId: generating.lookupId,
      kind: generating.kind,
      rawSelection: generating.rawSelection,
      normalisedLemma: generating.normalisedLemma,
      status: LookupStatus.served,
      senses: <Sense>[
        Sense(
          senseLabel: first?.senseLabel ?? '1',
          partOfSpeech: first?.partOfSpeech ?? 'noun',
          glossPhrase: first?.glossPhrase ?? generating.rawSelection,
          entryId: first?.entryId,
          clip: const Clip(
            url: 'mock://clip/generated',
            durationSeconds: 4,
            resolution: '360p',
            hasAudio: false,
          ),
        ),
      ],
      notice: generating.notice,
      correlationId: generating.correlationId,
    );
  }

  String _nextId() => 'mock-${_counter++}';
}
