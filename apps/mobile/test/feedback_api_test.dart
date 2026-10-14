import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/models/feedback.dart';
import 'package:scenova/services/feedback_api.dart';

PendingFeedback _rating(ClipRating rating, {String lookupId = 'lk_1'}) {
  return PendingFeedback(
    lookupId: lookupId,
    rating: rating,
    clientFeedbackId: 'cf_1',
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('PendingFeedback', () {
    test('sends the frozen C-012 body', () {
      expect(_rating(ClipRating.notHelpful).toJson(), <String, dynamic>{
        'lookupId': 'lk_1',
        'rating': 'not_helpful',
        'clientFeedbackId': 'cf_1',
      });
    });

    test('keeps its key and rating through the stored form', () {
      final stored = _rating(ClipRating.wrong).toStoredJson();
      final restored = PendingFeedback.fromStoredJson(stored);
      expect(restored.lookupId, 'lk_1');
      expect(restored.rating, ClipRating.wrong);
      expect(restored.clientFeedbackId, 'cf_1');
    });
  });

  group('HttpFeedbackApi', () {
    HttpFeedbackApi apiReturning(
      http.Response Function(http.Request request) handler,
    ) {
      return HttpFeedbackApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async => handler(request)),
      );
    }

    test('posts the rating with the bearer token', () async {
      late http.Request captured;
      final api = apiReturning((r) {
        captured = r;
        return http.Response(
          jsonEncode(<String, dynamic>{'recorded': true}),
          202,
        );
      });

      final recorded = await api.rate(_rating(ClipRating.helpful));

      expect(recorded, isTrue);
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/feedback');
      expect(captured.headers['authorization'], 'Bearer token');
      expect(jsonDecode(captured.body), <String, dynamic>{
        'lookupId': 'lk_1',
        'rating': 'helpful',
        'clientFeedbackId': 'cf_1',
      });
    });

    test('reports a rating the service did not record', () async {
      final api = apiReturning(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{'recorded': false}),
          202,
        ),
      );

      expect(await api.rate(_rating(ClipRating.helpful)), isFalse);
    });

    test('reads the service wording from the error body', () async {
      final api = apiReturning(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{
            'code': 'no_clip_served',
            'message': 'No clip was served for this lookup.',
          }),
          400,
        ),
      );

      await expectLater(
        api.rate(_rating(ClipRating.helpful)),
        throwsA(
          isA<FeedbackApiException>()
              .having((e) => e.isRefused, 'isRefused', isTrue)
              .having((e) => e.code, 'code', 'no_clip_served')
              .having(
                (e) => e.message,
                'message',
                'No clip was served for this lookup.',
              ),
        ),
      );
    });

    test('a lookup the caller does not own is refused, not retried', () async {
      final api = apiReturning((_) => http.Response('{}', 404));
      await expectLater(
        api.rate(_rating(ClipRating.helpful)),
        throwsA(
          isA<FeedbackApiException>()
              .having((e) => e.isRefused, 'isRefused', isTrue)
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
    });

    test('an unavailable store is retryable', () async {
      final api = apiReturning((_) => http.Response('{}', 503));
      await expectLater(
        api.rate(_rating(ClipRating.helpful)),
        throwsA(
          isA<FeedbackApiException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.isRefused, 'isRefused', isFalse),
        ),
      );
    });

    test('a transport failure reads as the device being offline', () async {
      final api = HttpFeedbackApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((_) async => throw http.ClientException('no route')),
      );

      await expectLater(
        api.rate(_rating(ClipRating.helpful)),
        throwsA(
          isA<FeedbackApiException>().having(
            (e) => e.isOffline,
            'isOffline',
            isTrue,
          ),
        ),
      );
    });

    test('an identity that cannot be read still sends the rating', () async {
      late http.Request captured;
      final api = HttpFeedbackApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => throw StateError('no identity'),
        client: MockClient((request) async {
          captured = request;
          return http.Response('{"recorded":true}', 202);
        }),
      );

      await api.rate(_rating(ClipRating.helpful));

      expect(captured.headers.containsKey('authorization'), isFalse);
    });
  });
}
