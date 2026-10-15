import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova_console/models/review_entry.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/services/review_api.dart';

void main() {
  group('HttpReviewApi', () {
    test('builds the queue query from the filter and the page', () async {
      Uri? requested;
      final api = HttpReviewApi(
        baseUrl: 'https://gateway.example',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[],
              'openCount': 0,
              'page': 1,
              'pageCount': 1,
            }),
            200,
          );
        }),
      );

      await api.queue(
        reason: ReviewReason.offensive,
        state: ReviewState.queued,
        word: 'bank',
        page: 2,
      );

      expect(requested!.path, '/internal/review/queue');
      expect(requested!.queryParameters, <String, String>{
        'reason': 'offensive',
        'state': 'queued',
        'word': 'bank',
        'page': '2',
      });
    });

    test('omits a filter that is not applied and trims the word', () async {
      Uri? requested;
      final api = HttpReviewApi(
        baseUrl: 'https://gateway.example',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            '{"items":[],"openCount":0,"page":1,"pageCount":1}',
            200,
          );
        }),
      );

      await api.queue(word: '  ', page: 1);

      expect(requested!.queryParameters, <String, String>{'page': '1'});
    });

    test('sends the operator token and decodes the page', () async {
      String? authorization;
      final api = HttpReviewApi(
        baseUrl: 'https://gateway.example',
        idTokenProvider: () async => 'operator-token',
        client: MockClient((request) async {
          authorization = request.headers['authorization'];
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'entryId': 'entry-1',
                  'lemma': 'bank',
                  'senseLabel': '2',
                  'reason': 'feedback_threshold',
                  'queuedAt': '2026-10-14T10:00:00Z',
                  'state': 'queued',
                },
              ],
              'openCount': 3,
              'page': 1,
              'pageCount': 2,
            }),
            200,
          );
        }),
      );

      final page = await api.queue();

      expect(authorization, 'Bearer operator-token');
      expect(page.openCount, 3);
      expect(page.pageCount, 2);
      expect(page.items.single.lemma, 'bank');
      expect(page.items.single.reasonLabel, 'Repeated negative feedback');
      expect(page.items.single.state, ReviewState.queued);
    });

    test('maps the contract\'s refusals to their cases', () async {
      Future<ReviewApiException> failureFor(int status, String body) async {
        final api = HttpReviewApi(
          baseUrl: 'https://gateway.example',
          idTokenProvider: () async => 'token',
          client: MockClient((request) async => http.Response(body, status)),
        );
        try {
          await api.queue();
          fail('expected a failure for $status');
        } on ReviewApiException catch (error) {
          return error;
        }
      }

      final unauthorised = await failureFor(
        401,
        '{"code":"unauthorized","message":"The operator session is missing."}',
      );
      expect(unauthorised.isUnauthenticated, isTrue);
      expect(unauthorised.isRetryable, isFalse);

      final forbidden = await failureFor(
        403,
        '{"code":"forbidden","message":"The curator role is required."}',
      );
      expect(forbidden.isForbidden, isTrue);
      expect(forbidden.message, 'The curator role is required.');

      final unavailable = await failureFor(
        503,
        '{"code":"unavailable","message":"The review service is unavailable."}',
      );
      expect(unavailable.isRetryable, isTrue);
    });

    test('reads a transport failure as offline', () async {
      final api = HttpReviewApi(
        baseUrl: 'https://gateway.example',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async {
          throw http.ClientException('connection refused');
        }),
      );

      try {
        await api.queue();
        fail('expected an offline failure');
      } on ReviewApiException catch (error) {
        expect(error.isOffline, isTrue);
        expect(error.isRetryable, isFalse);
      }
    });
  });

  group('QueueItem', () {
    test('renders a reader reason as its label and keeps an unknown one', () {
      expect(queueItemReason('wrong_meaning'), 'Wrong meaning');
      expect(queueItemReason('offensive'), 'Offensive');
      expect(queueItemReason('low_quality'), 'Low quality');
      expect(queueItemReason('other'), 'Other');
      expect(queueItemReason('something_new'), 'something_new');
    });
  });

  group('HttpReviewApi · entry', () {
    test('reads the entry, its evidence, and its state', () async {
      Uri? requested;
      String? authorization;
      final api = HttpReviewApi(
        baseUrl: 'https://gateway.example',
        idTokenProvider: () async => 'operator-token',
        client: MockClient((request) async {
          requested = request.url;
          authorization = request.headers['authorization'];
          return http.Response(
            jsonEncode(<String, Object?>{
              'entry': <String, Object?>{
                'entryId': 'entry-bank-2',
                'lemma': 'bank',
                'senseLabel': '2',
                'glossPhrase': 'a river bank',
                'status': 'held',
                'clip': <String, Object?>{
                  'url': 'https://cdn.example/bank.mp4',
                  'durationSeconds': 4,
                  'resolution': '360p',
                  'hasAudio': false,
                },
              },
              'reports': <Object?>[
                <String, Object?>{
                  'reportId': 'report-1',
                  'reason': 'offensive',
                  'note': 'Not for this sense.',
                  'createdAt': '2026-10-14T10:00:00Z',
                },
              ],
              'feedback': <Object?>[
                <String, Object?>{
                  'rating': 'wrong',
                  'createdAt': '2026-10-14T09:00:00Z',
                },
              ],
              'state': 'queued',
            }),
            200,
          );
        }),
      );

      final detail = await api.entry('entry-bank-2');

      expect(requested!.path, '/internal/review/entries/entry-bank-2');
      expect(authorization, 'Bearer operator-token');
      expect(detail.entry.lemma, 'bank');
      expect(detail.entry.glossPhrase, 'a river bank');
      expect(detail.entry.status, EntryStatus.held);
      expect(detail.entry.clip.isPlayable, isTrue);
      expect(detail.reports.single.reasonLabel, 'Offensive');
      expect(detail.reports.single.note, 'Not for this sense.');
      expect(detail.feedback.single.rating, FeedbackRating.wrong);
      expect(detail.state, ReviewState.queued);
    });

    test('escapes the entry id in the path', () async {
      Uri? requested;
      final api = HttpReviewApi(
        baseUrl: 'https://gateway.example',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response('{"code":"review_entry_not_found"}', 404);
        }),
      );

      await expectLater(
        api.entry('entry/with a space'),
        throwsA(isA<ReviewApiException>()),
      );
      expect(
        requested!.path,
        '/internal/review/entries/entry%2Fwith%20a%20space',
      );
    });
  });

  group('HttpReviewApi · act', () {
    test(
      'posts the action, the phrase, and the state the curator saw',
      () async {
        Uri? requested;
        String? body;
        String? contentType;
        final api = HttpReviewApi(
          baseUrl: 'https://gateway.example',
          idTokenProvider: () async => 'operator-token',
          client: MockClient((request) async {
            requested = request.url;
            body = request.body;
            contentType = request.headers['content-type'];
            return http.Response(
              jsonEncode(<String, Object?>{
                'actionId': 'action-1',
                'entryId': 'entry-bank-2',
                'status': 'retired',
                'state': 'reviewed',
              }),
              200,
            );
          }),
        );

        final result = await api.act(
          'entry-bank-2',
          const EntryActionRequest(
            action: EntryAction.editPhrase,
            expectedState: ReviewState.queued,
            phrase: 'a place to keep money',
            notes: 'Repeated reports.',
          ),
        );

        expect(
          requested!.path,
          '/internal/review/entries/entry-bank-2/actions',
        );
        expect(contentType, contains('application/json'));
        expect(jsonDecode(body!), <String, Object?>{
          'action': 'edit_phrase',
          'phrase': 'a place to keep money',
          'notes': 'Repeated reports.',
          'expectedState': 'queued',
        });
        expect(result.status, EntryStatus.retired);
        expect(result.state, ReviewState.reviewed);
      },
    );

    test('maps a conflict and a missing entry to their cases', () async {
      Future<ReviewApiException> failureFor(int status, String body) async {
        final api = HttpReviewApi(
          baseUrl: 'https://gateway.example',
          idTokenProvider: () async => 'token',
          client: MockClient((request) async => http.Response(body, status)),
        );
        try {
          await api.act(
            'entry-bank-2',
            const EntryActionRequest(
              action: EntryAction.clear,
              expectedState: ReviewState.queued,
            ),
          );
          fail('expected a failure for $status');
        } on ReviewApiException catch (error) {
          return error;
        }
      }

      final moved = await failureFor(
        409,
        '{"code":"review_conflict","message":"The entry has already moved."}',
      );
      expect(moved.isConflict, isTrue);
      expect(moved.message, 'The entry has already moved.');

      final gone = await failureFor(
        404,
        '{"code":"review_entry_not_found","message":"No entry is queued."}',
      );
      expect(gone.isNotFound, isTrue);

      final invalid = await failureFor(
        400,
        '{"code":"invalid_request","message":"A phrase edit needs a phrase."}',
      );
      expect(invalid.isInvalidRequest, isTrue);
    });
  });
}

String queueItemReason(String reason) {
  return QueueItem(
    entryId: 'entry-1',
    lemma: 'bank',
    senseLabel: '1',
    reason: reason,
    queuedAt: DateTime.utc(2026, 10, 14),
    state: ReviewState.queued,
  ).reasonLabel;
}
