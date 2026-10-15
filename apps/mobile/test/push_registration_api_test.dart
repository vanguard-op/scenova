import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/push_registration_api.dart';

void main() {
  group('HttpPushRegistrationApi', () {
    HttpPushRegistrationApi apiReturning(
      http.Response Function(http.Request request) handler,
    ) {
      return HttpPushRegistrationApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async => handler(request)),
      );
    }

    test(
      'posts the frozen token, platform, and lookup with the bearer token',
      () async {
        late http.Request captured;
        final api = apiReturning((request) {
          captured = request;
          return http.Response(
            jsonEncode(<String, dynamic>{'registered': true}),
            202,
          );
        });

        final registered = await api.register(
          token: 'fcm-token-1',
          platform: LookupPlatform.android,
          lookupId: 'lk_1',
        );

        expect(registered, isTrue);
        expect(captured.method, 'POST');
        expect(captured.url.path, '/v1/push-registrations');
        expect(captured.headers['authorization'], 'Bearer token');
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body, <String, dynamic>{
          'token': 'fcm-token-1',
          'platform': 'android',
          'lookupId': 'lk_1',
        });
      },
    );

    test('reports a service that does not register the token', () async {
      final api = apiReturning(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{'registered': false}),
          202,
        ),
      );
      expect(
        await api.register(
          token: 't',
          platform: LookupPlatform.ios,
          lookupId: 'lk_1',
        ),
        isFalse,
      );
    });

    test('maps a 400 to a rejected token', () async {
      final api = apiReturning((_) => http.Response('{}', 400));
      await expectLater(
        api.register(
          token: 't',
          platform: LookupPlatform.ios,
          lookupId: 'lk_1',
        ),
        throwsA(
          isA<PushRegistrationException>().having(
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
        api.register(
          token: 't',
          platform: LookupPlatform.ios,
          lookupId: 'lk_1',
        ),
        throwsA(
          isA<PushRegistrationException>().having(
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
        api.register(
          token: 't',
          platform: LookupPlatform.ios,
          lookupId: 'lk_1',
        ),
        throwsA(
          isA<PushRegistrationException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isTrue,
          ),
        ),
      );
    });

    test('maps a 503 to a retryable failure', () async {
      // C-008: the registration store being unavailable is retryable — the
      // registration is held and the reader is asked again.
      final api = apiReturning((_) => http.Response('{}', 503));
      await expectLater(
        api.register(
          token: 't',
          platform: LookupPlatform.ios,
          lookupId: 'lk_1',
        ),
        throwsA(
          isA<PushRegistrationException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.isRejected, 'isRejected', isFalse),
        ),
      );
    });

    test('reads the {code, message} error body', () async {
      final api = apiReturning(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{
            'code': 'unreadable_token',
            'message': 'That device token could not be read.',
          }),
          400,
        ),
      );
      await expectLater(
        api.register(
          token: 't',
          platform: LookupPlatform.ios,
          lookupId: 'lk_1',
        ),
        throwsA(
          isA<PushRegistrationException>()
              .having((e) => e.code, 'code', 'unreadable_token')
              .having(
                (e) => e.message,
                'message',
                'That device token could not be read.',
              ),
        ),
      );
    });

    test('maps a transport failure to the offline case', () async {
      final api = HttpPushRegistrationApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((_) async => throw http.ClientException('no route')),
      );
      await expectLater(
        api.register(
          token: 't',
          platform: LookupPlatform.ios,
          lookupId: 'lk_1',
        ),
        throwsA(
          isA<PushRegistrationException>().having(
            (e) => e.isOffline,
            'isOffline',
            isTrue,
          ),
        ),
      );
    });
  });
}
