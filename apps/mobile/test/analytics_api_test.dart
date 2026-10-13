import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/models/analytics_event.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/analytics_api.dart';

AnalyticsEvent _event(String name, {AnalyticsEventName? taxonomy}) {
  return AnalyticsEvent(
    eventId: 'evt-1',
    name: taxonomy ?? AnalyticsEventName.appOpened,
    occurredAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    anonymousId: 'anon',
    sessionId: 'session',
    platform: LookupPlatform.android,
    appVersion: '1.0.0+1',
    locale: 'en-GB',
    properties: <String, Object?>{'source': name},
  );
}

void main() {
  group('HttpAnalyticsApi', () {
    HttpAnalyticsApi apiReturning(
      http.Response Function(http.Request request) handler,
    ) {
      return HttpAnalyticsApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async => handler(request)),
      );
    }

    test('posts the frozen batch with the bearer token', () async {
      late http.Request captured;
      final api = apiReturning((request) {
        captured = request;
        return http.Response(jsonEncode(<String, dynamic>{'accepted': 1}), 202);
      });

      final accepted = await api.send(<AnalyticsEvent>[_event('launch')]);

      expect(accepted, 1);
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/events');
      expect(captured.headers['authorization'], 'Bearer token');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final events = body['events'] as List<dynamic>;
      expect(events, hasLength(1));
      final event = events.single as Map<String, dynamic>;
      expect(event['name'], 'app_opened');
      expect(event['occurredAt'], '2026-01-02T03:04:05.000Z');
      expect(event['anonymousId'], 'anon');
      expect(event['sessionId'], 'session');
      expect(event['platform'], 'android');
      expect(event['appVersion'], '1.0.0+1');
      expect(event['locale'], 'en-GB');
      expect(event['properties'], <String, Object?>{'source': 'launch'});
      // The pseudonymous user_id is the token subject, resolved by the gateway;
      // the client never sends an email, name, or the selected text.
      expect(event.containsKey('userId'), isFalse);
    });

    test('maps a 400 to a rejected batch', () async {
      final api = apiReturning((_) => http.Response('{}', 400));
      await expectLater(
        api.send(<AnalyticsEvent>[_event('launch')]),
        throwsA(
          isA<AnalyticsApiException>().having(
            (e) => e.isRejected,
            'isRejected',
            isTrue,
          ),
        ),
      );
    });

    test('maps a 401 to an unauthenticated failure', () async {
      final api = apiReturning((_) => http.Response('{}', 401));
      await expectLater(
        api.send(<AnalyticsEvent>[_event('launch')]),
        throwsA(
          isA<AnalyticsApiException>().having(
            (e) => e.isUnauthenticated,
            'isUnauthenticated',
            isTrue,
          ),
        ),
      );
    });

    test('maps a 429 to a retryable failure', () async {
      final api = apiReturning((_) => http.Response('{}', 429));
      await expectLater(
        api.send(<AnalyticsEvent>[_event('launch')]),
        throwsA(
          isA<AnalyticsApiException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isTrue,
          ),
        ),
      );
    });

    test('reads the {code, message} error body', () async {
      final api = apiReturning(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{
            'code': 'unknown_event',
            'message': 'Unknown event name.',
          }),
          400,
        ),
      );

      await expectLater(
        api.send(<AnalyticsEvent>[_event('launch')]),
        throwsA(
          isA<AnalyticsApiException>()
              .having((e) => e.code, 'code', 'unknown_event')
              .having((e) => e.message, 'message', 'Unknown event name.'),
        ),
      );
    });

    test('maps a transport failure to the offline case', () async {
      final api = HttpAnalyticsApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((_) async => throw http.ClientException('no route')),
      );
      await expectLater(
        api.send(<AnalyticsEvent>[_event('launch')]),
        throwsA(
          isA<AnalyticsApiException>().having(
            (e) => e.isOffline,
            'isOffline',
            isTrue,
          ),
        ),
      );
    });
  });

  group('MockAnalyticsApi', () {
    test('records the events and reports the batch size', () async {
      final api = MockAnalyticsApi();
      final accepted = await api.send(<AnalyticsEvent>[
        _event('launch'),
        _event('resume'),
      ]);
      expect(accepted, 2);
      expect(api.sent, hasLength(2));
      expect(api.batches.single, hasLength(2));
    });
  });
}
