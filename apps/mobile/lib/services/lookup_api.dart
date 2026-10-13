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

  /// Rate limited or a service-side failure: retrying may succeed.
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
    final token = await idTokenProvider();
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

  LookupApiException _mapError(int status, String body) {
    String? code;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        code = decoded['code'] as String?;
      }
    } on FormatException {
      code = null;
    }
    final message = switch (status) {
      400 => 'Scenova looks up single words and short phrases.',
      401 => 'Sign in to look up a word.',
      404 => 'That lookup is no longer available.',
      409 => 'That lookup was already started.',
      429 => 'Too many lookups just now. Try again shortly.',
      _ => 'The lookup service is unavailable.',
    };
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
      _ => _libraryHit(selection),
    };
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
          senseLabel: Sense.bestGuessLabel,
          partOfSpeech: 'verb',
          glossPhrase: 'to print a picture from a carved block of wood',
          entryId: null,
        ),
      ],
      notice: _bestGuessNotice,
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
          senseLabel: Sense.bestGuessLabel,
          partOfSpeech: 'adjective',
          glossPhrase: 'hopeful even when things are unlikely',
          entryId: null,
        ),
      ],
      notice: _bestGuessNotice,
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

  /// Mirrors the service's own wording for a word it does not hold.
  static const String _bestGuessNotice =
      "This word isn't in our sense list yet, so we're showing the most likely "
      'meaning.';
}
