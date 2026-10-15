import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/review_entry.dart';
import '../models/review_queue.dart';

/// A review-request failure, mapped from the contract's error set.
///
/// `statusCode` is `0` for a transport failure (no connection or a timeout),
/// which the presentation layer reads as the offline case.
class ReviewApiException implements Exception {
  const ReviewApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The machine-readable code when the service sends one.
  final String? code;

  /// A transport failure: the console could not reach the gateway.
  bool get isOffline => statusCode == 0;

  /// No operator session, or the session expired: the console redirects to
  /// sign-in (`C-014`, 401).
  bool get isUnauthenticated => statusCode == 401;

  /// An authenticated operator without the curator role or without a second
  /// factor: access is refused and the attempt is logged (`C-014`, 403).
  bool get isForbidden => statusCode == 403;

  /// The entry is unknown, or has nothing queued (`C-015`/`C-016`, 404).
  bool get isNotFound => statusCode == 404;

  /// The entry has moved since the curator saw it, so another action stands
  /// (`C-016`, 409).
  bool get isConflict => statusCode == 409;

  /// The action or the phrase did not match the contract (`C-016`, 400).
  bool get isInvalidRequest => statusCode == 400;

  /// The review service is unavailable: retrying may succeed (`C-014`, 503).
  bool get isRetryable => statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'ReviewApiException($statusCode, $message)';
}

/// The review surface, as frozen in `C-014` to `C-016`.
abstract interface class ReviewApi {
  /// `GET /internal/review/queue`.
  Future<ReviewQueuePage> queue({
    ReviewReason? reason,
    ReviewState? state,
    String? word,
    int page,
  });

  /// `GET /internal/review/entries/{entryId}`.
  Future<ReviewEntryDetail> entry(String entryId);

  /// `POST /internal/review/entries/{entryId}/actions`.
  Future<EntryActionResult> act(String entryId, EntryActionRequest request);
}

/// Talks to the gateway over HTTP.
///
/// On Firebase Hosting the console calls its own origin and the
/// `/internal/review/**` rewrite carries the request to the gateway; a local
/// run points [baseUrl] at the gateway `make boot` starts. Either way the
/// operator's Firebase ID token rides in the `Authorization` header and the
/// gateway enforces the curator role and the second factor (`C-014` auth).
class HttpReviewApi implements ReviewApi {
  HttpReviewApi({
    required this.baseUrl,
    required this.idTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// The gateway base, or empty for the console's own origin.
  final String baseUrl;

  /// Supplies the operator's Firebase ID token, refreshed per request.
  final Future<String?> Function() idTokenProvider;

  final http.Client _client;

  @override
  Future<ReviewQueuePage> queue({
    ReviewReason? reason,
    ReviewState? state,
    String? word,
    int page = 1,
  }) async {
    final response = await _send(
      () async => _client.get(
        _uri(reason, state, word, page),
        headers: await _headers(),
      ),
    );
    return ReviewQueuePage.fromJson(_decodeBody(response));
  }

  @override
  Future<ReviewEntryDetail> entry(String entryId) async {
    final response = await _send(
      () async => _client.get(_entryUri(entryId), headers: await _headers()),
    );
    return ReviewEntryDetail.fromJson(_decodeBody(response));
  }

  @override
  Future<EntryActionResult> act(
    String entryId,
    EntryActionRequest request,
  ) async {
    final response = await _send(
      () async => _client.post(
        Uri.parse('${_entryUri(entryId)}/actions'),
        headers: await _headers(json: true),
        body: jsonEncode(request.toJson()),
      ),
    );
    return EntryActionResult.fromJson(_decodeBody(response));
  }

  Uri _entryUri(String entryId) => Uri.parse(
    '$baseUrl/internal/review/entries/${Uri.encodeComponent(entryId)}',
  );

  Uri _uri(ReviewReason? reason, ReviewState? state, String? word, int page) {
    final query = <String, String>{'page': '$page'};
    if (reason != null) query['reason'] = reason.wireValue;
    if (state != null) query['state'] = state.wireValue;
    final trimmed = word?.trim() ?? '';
    if (trimmed.isNotEmpty) query['word'] = trimmed;
    return Uri.parse('$baseUrl/internal/review/queue')
        .replace(queryParameters: query);
  }

  Future<Map<String, String>> _headers({bool json = false}) async {
    String? token;
    try {
      token = await idTokenProvider();
    } on Object {
      // The identity could not be established. The request goes out without a
      // token and the gateway refuses it as unauthenticated (`C-014`, 401),
      // rather than the failure reading as the service being down.
      token = null;
    }
    return <String, String>{
      'accept': 'application/json',
      if (json) 'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(ConsoleConfig.requestTimeout);
    } on TimeoutException {
      throw const ReviewApiException(0, 'The request timed out.');
    } on http.ClientException catch (error) {
      throw ReviewApiException(0, error.message);
    } on Object {
      throw const ReviewApiException(0, 'The review service is unreachable.');
    }
  }

  Map<String, dynamic> _decodeBody(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw const ReviewApiException(0, 'The service returned no body.');
      }
      return body;
    }
    throw _mapError(status, response.body);
  }

  /// Maps an error response to a failure, reading the contract's
  /// `{code, message}` body.
  ReviewApiException _mapError(int status, String body) {
    String? code;
    String? serviceMessage;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        code = decoded['code'] as String?;
        serviceMessage = decoded['message'] as String?;
      }
    } on FormatException {
      // The body was not readable; fall back to the console's own wording.
    }
    final fallback = switch (status) {
      401 => 'Your session has ended. Sign in again.',
      403 => 'The curator role is required to open the review console.',
      404 => 'This entry is no longer waiting for review.',
      409 => 'This entry has already moved since you opened it.',
      _ => 'The review service is unavailable.',
    };
    final message = (serviceMessage == null || serviceMessage.isEmpty)
        ? fallback
        : serviceMessage;
    return ReviewApiException(status, message, code: code);
  }
}

/// A scripted review service for development and tests.
///
/// `docs/Scenova/` fixes the wire shapes, so this mock speaks them exactly and
/// the screens are built against the frozen contract before the endpoint is
/// live. It scripts one representative state per word so every state can be
/// viewed and tested.
class MockReviewApi implements ReviewApi {
  MockReviewApi({this.latency = Duration.zero, List<ReviewQueuePage>? script})
    : _script = List<ReviewQueuePage>.of(script ?? const <ReviewQueuePage>[]),
      _entries = _seedEntries();

  /// Simulated network latency.
  final Duration latency;

  final List<ReviewQueuePage> _script;

  /// The entries the queue lists, with their evidence, so a drill-down into any
  /// row shows a real entry. An action moves the entry here, so the effect of a
  /// clear, hold, retire, replace, or phrase edit is visible without a service.
  final Map<String, ReviewEntryDetail> _entries;

  /// Every query the console sent, so a test can assert the filter and page it
  /// built.
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  /// Every action the console recorded, so a test can assert what it sent.
  final List<EntryActionRequest> actions = <EntryActionRequest>[];

  @override
  Future<ReviewQueuePage> queue({
    ReviewReason? reason,
    ReviewState? state,
    String? word,
    int page = 1,
  }) async {
    requests.add(<String, Object?>{
      'reason': reason?.wireValue,
      'state': state?.wireValue,
      'word': word,
      'page': page,
    });
    await _delay();
    if (_script.isNotEmpty) return _script.removeAt(0);
    return _scenario(reason: reason, state: state, word: word, page: page);
  }

  Future<void> _delay() => latency == Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(latency);

  /// A representative queue for the requested filter.
  ReviewQueuePage _scenario({
    required ReviewReason? reason,
    required ReviewState? state,
    required String? word,
    required int page,
  }) {
    final all = _items();
    final filtered = all
        .where((item) {
          if (reason != null && item.reason != reason.wireValue) return false;
          if (state != null && item.state != state) return false;
          if (word != null &&
              word.trim().isNotEmpty &&
              !item.lemma.toLowerCase().contains(word.trim().toLowerCase())) {
            return false;
          }
          return true;
        })
        .toList(growable: false);

    const pageSize = 3;
    final pageCount = filtered.isEmpty
        ? 1
        : (filtered.length + pageSize - 1) ~/ pageSize;
    final current = page.clamp(1, pageCount);
    final start = (current - 1) * pageSize;
    final window = filtered.skip(start).take(pageSize).toList(growable: false);

    return ReviewQueuePage(
      items: window,
      openCount: all.where((item) => item.state != ReviewState.actioned).length,
      page: current,
      pageCount: pageCount,
    );
  }

  List<QueueItem> _items() {
    final now = DateTime.now().toUtc();
    return <QueueItem>[
      QueueItem(
        entryId: 'entry-bank-2',
        lemma: 'bank',
        senseLabel: '2',
        reason: ReviewReason.offensive.wireValue,
        queuedAt: now.subtract(const Duration(minutes: 20)),
        state: ReviewState.queued,
      ),
      QueueItem(
        entryId: 'entry-crane-1',
        lemma: 'crane',
        senseLabel: '1',
        reason: ReviewReason.wrongMeaning.wireValue,
        queuedAt: now.subtract(const Duration(hours: 3)),
        state: ReviewState.queued,
      ),
      QueueItem(
        entryId: 'entry-livid-1',
        lemma: 'livid',
        senseLabel: '1',
        reason: feedbackThresholdReason,
        queuedAt: now.subtract(const Duration(hours: 9)),
        state: ReviewState.queued,
      ),
      QueueItem(
        entryId: 'entry-aardvark-1',
        lemma: 'aardvark',
        senseLabel: '1',
        reason: ReviewReason.lowQuality.wireValue,
        queuedAt: now.subtract(const Duration(days: 2)),
        state: ReviewState.reviewed,
      ),
      QueueItem(
        entryId: 'entry-tessellate-1',
        lemma: 'tessellate',
        senseLabel: '1',
        reason: ReviewReason.other.wireValue,
        queuedAt: now.subtract(const Duration(days: 5)),
        state: ReviewState.actioned,
      ),
    ];
  }

  @override
  Future<ReviewEntryDetail> entry(String entryId) async {
    await _delay();
    final detail = _entries[entryId];
    if (detail == null) {
      throw const ReviewApiException(
        404,
        'This entry is no longer waiting for review.',
        code: 'review_entry_not_found',
      );
    }
    return detail;
  }

  @override
  Future<EntryActionResult> act(
    String entryId,
    EntryActionRequest request,
  ) async {
    actions.add(request);
    await _delay();
    final detail = _entries[entryId];
    if (detail == null) {
      throw const ReviewApiException(
        404,
        'This entry is no longer waiting for review.',
        code: 'review_entry_not_found',
      );
    }
    if (detail.state != request.expectedState) {
      throw const ReviewApiException(
        409,
        'This entry has already moved since you opened it.',
        code: 'review_conflict',
      );
    }
    if (request.action == EntryAction.editPhrase &&
        (request.phrase ?? '').trim().isEmpty) {
      throw const ReviewApiException(
        400,
        'A phrase edit needs the new generation phrase.',
        code: 'invalid_request',
      );
    }

    // The service's own effects: clear serves the entry, hold withholds it,
    // retire and replace stop it serving, and a phrase edit records the new
    // phrase and regenerates. A phrase edit leaves the item under review; every
    // other action resolves it (`C-016`).
    final status = switch (request.action) {
      EntryAction.clear => EntryStatus.active,
      EntryAction.hold => EntryStatus.held,
      EntryAction.retire ||
      EntryAction.replace ||
      EntryAction.editPhrase => EntryStatus.retired,
    };
    final state = request.action == EntryAction.editPhrase
        ? ReviewState.reviewed
        : ReviewState.actioned;
    final entry = detail.entry;
    _entries[entryId] = ReviewEntryDetail(
      entry: ReviewEntry(
        entryId: entry.entryId,
        lemma: entry.lemma,
        senseLabel: entry.senseLabel,
        glossPhrase: request.action == EntryAction.editPhrase
            ? request.phrase!.trim()
            : entry.glossPhrase,
        status: status,
        clip: entry.clip,
      ),
      reports: detail.reports,
      feedback: detail.feedback,
      state: state,
    );
    return EntryActionResult(
      actionId: 'action-${request.action.wireValue}',
      entryId: entryId,
      status: status,
      state: state,
    );
  }

  /// One representative entry per queue row, with the evidence a decision
  /// rests on: a report, repeated negative feedback, or both.
  static Map<String, ReviewEntryDetail> _seedEntries() {
    final now = DateTime.now().toUtc();

    ReviewEntryDetail detail({
      required String entryId,
      required String lemma,
      required String senseLabel,
      required String glossPhrase,
      required ReviewState state,
      EntryStatus status = EntryStatus.active,
      List<EntryReport> reports = const <EntryReport>[],
      List<EntryFeedback> feedback = const <EntryFeedback>[],
    }) {
      return ReviewEntryDetail(
        entry: ReviewEntry(
          entryId: entryId,
          lemma: lemma,
          senseLabel: senseLabel,
          glossPhrase: glossPhrase,
          status: status,
          clip: ReviewClip(
            url: 'mock://clip/$entryId',
            durationSeconds: 4,
            resolution: '360p',
            hasAudio: false,
          ),
        ),
        reports: reports,
        feedback: feedback,
        state: state,
      );
    }

    return <String, ReviewEntryDetail>{
      'entry-bank-2': detail(
        entryId: 'entry-bank-2',
        lemma: 'bank',
        senseLabel: '2',
        glossPhrase: 'a river bank',
        state: ReviewState.queued,
        reports: <EntryReport>[
          EntryReport(
            reportId: 'report-1',
            reason: ReviewReason.offensive.wireValue,
            note: 'This is not what the word means here.',
            createdAt: now.subtract(const Duration(minutes: 20)),
          ),
        ],
        feedback: <EntryFeedback>[
          EntryFeedback(
            rating: FeedbackRating.wrong,
            createdAt: now.subtract(const Duration(minutes: 40)),
          ),
        ],
      ),
      'entry-crane-1': detail(
        entryId: 'entry-crane-1',
        lemma: 'crane',
        senseLabel: '1',
        glossPhrase: 'a machine that lifts',
        state: ReviewState.queued,
        reports: <EntryReport>[
          EntryReport(
            reportId: 'report-2',
            reason: ReviewReason.wrongMeaning.wireValue,
            note: null,
            createdAt: now.subtract(const Duration(hours: 3)),
          ),
        ],
      ),
      'entry-livid-1': detail(
        entryId: 'entry-livid-1',
        lemma: 'livid',
        senseLabel: '1',
        glossPhrase: 'furious',
        state: ReviewState.queued,
        feedback: <EntryFeedback>[
          EntryFeedback(
            rating: FeedbackRating.notHelpful,
            createdAt: now.subtract(const Duration(hours: 9)),
          ),
          EntryFeedback(
            rating: FeedbackRating.notHelpful,
            createdAt: now.subtract(const Duration(hours: 12)),
          ),
        ],
      ),
      'entry-aardvark-1': detail(
        entryId: 'entry-aardvark-1',
        lemma: 'aardvark',
        senseLabel: '1',
        glossPhrase: 'a burrowing mammal',
        state: ReviewState.reviewed,
        reports: <EntryReport>[
          EntryReport(
            reportId: 'report-3',
            reason: ReviewReason.lowQuality.wireValue,
            note: 'The clip is too dark to make out.',
            createdAt: now.subtract(const Duration(days: 2)),
          ),
        ],
      ),
      'entry-tessellate-1': detail(
        entryId: 'entry-tessellate-1',
        lemma: 'tessellate',
        senseLabel: '1',
        glossPhrase: 'to fit together in a pattern',
        state: ReviewState.actioned,
        status: EntryStatus.retired,
      ),
    };
  }
}
