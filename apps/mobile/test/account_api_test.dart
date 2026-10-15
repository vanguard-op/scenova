import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/services/account_api.dart';

void main() {
  group('HttpAccountApi', () {
    HttpAccountApi apiReturning(
      Future<http.Response> Function(http.Request request) handler,
    ) {
      return HttpAccountApi(
        baseUrl: 'https://gateway.test',
        idTokenProvider: () async => 'token-1',
        client: MockClient((request) => handler(request)),
      );
    }

    test(
      'writes the consent with the bearer token and reads it back',
      () async {
        late http.Request captured;
        final api = apiReturning((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'consentModelProcessing': false,
              'locale': 'en',
            }),
            200,
          );
        });

        final account = await api.update(consentModelProcessing: false);

        expect(captured.method, 'PATCH');
        expect(captured.url.toString(), 'https://gateway.test/v1/account');
        expect(captured.headers['authorization'], 'Bearer token-1');
        expect(jsonDecode(captured.body), <String, dynamic>{
          'consentModelProcessing': false,
        });
        expect(account.consentModelProcessing, isFalse);
        expect(account.locale, 'en');
      },
    );

    test('sends only the language when that is the only change', () async {
      late http.Request captured;
      final api = apiReturning((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'consentModelProcessing': true,
            'locale': 'fr',
          }),
          200,
        );
      });

      final account = await api.update(locale: 'fr');

      expect(jsonDecode(captured.body), <String, dynamic>{'locale': 'fr'});
      expect(account.locale, 'fr');
    });

    test('a 401 reads as signed out, not as an error', () async {
      final api = apiReturning((_) async => http.Response('{}', 401));

      await expectLater(
        api.update(consentModelProcessing: true),
        throwsA(
          isA<AccountApiException>().having(
            (error) => error.isSignedOut,
            'isSignedOut',
            isTrue,
          ),
        ),
      );
    });

    test('a 503 reads as unavailable', () async {
      final api = apiReturning((_) async => http.Response('{}', 503));

      await expectLater(
        api.update(locale: 'en'),
        throwsA(
          isA<AccountApiException>().having(
            (error) => error.isUnavailable,
            'isUnavailable',
            isTrue,
          ),
        ),
      );
    });

    test('a 400 reads as a rejected write', () async {
      final api = apiReturning(
        (_) async => http.Response(
          jsonEncode(<String, String>{
            'code': 'unknown_locale',
            'message': 'That language is not available.',
          }),
          400,
        ),
      );

      await expectLater(
        api.update(locale: 'xx'),
        throwsA(
          isA<AccountApiException>()
              .having((error) => error.isRejected, 'isRejected', isTrue)
              .having(
                (error) => error.message,
                'message',
                'That language is not available.',
              ),
        ),
      );
    });

    test(
      'a transport failure reads as unavailable, never as signed out',
      () async {
        final api = HttpAccountApi(
          baseUrl: 'https://gateway.test',
          idTokenProvider: () async => 'token-1',
          client: MockClient(
            (_) async => throw http.ClientException('no route'),
          ),
        );

        await expectLater(
          api.update(consentModelProcessing: false),
          throwsA(
            isA<AccountApiException>()
                .having((error) => error.isUnavailable, 'isUnavailable', isTrue)
                .having((error) => error.isSignedOut, 'isSignedOut', isFalse),
          ),
        );
      },
    );
  });

  group('MockAccountApi', () {
    test('records each write and holds the latest values', () async {
      final api = MockAccountApi();

      await api.update(consentModelProcessing: false);
      final account = await api.update(locale: 'pt');

      expect(api.writes, hasLength(2));
      expect(api.writes.first.consentModelProcessing, isFalse);
      expect(api.writes.last.locale, 'pt');
      expect(account.consentModelProcessing, isFalse);
      expect(account.locale, 'pt');
    });

    test('refuses a caller with no account', () async {
      await expectLater(
        MockAccountApi(signedOut: true).update(consentModelProcessing: true),
        throwsA(
          isA<AccountApiException>().having(
            (error) => error.isSignedOut,
            'isSignedOut',
            isTrue,
          ),
        ),
      );
    });
  });
}
