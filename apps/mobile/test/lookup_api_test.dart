import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/lookup_api.dart';

void main() {
  group('LookupResult', () {
    test('parses the frozen C-001 shape', () {
      final result = LookupResult.fromJson(<String, dynamic>{
        'lookupId': 'lk_1',
        'kind': 'word',
        'rawSelection': 'coming',
        'normalisedLemma': 'come',
        'status': 'served',
        'senses': <Map<String, dynamic>>[
          <String, dynamic>{
            'senseLabel': '1',
            'partOfSpeech': 'verb',
            'glossPhrase': 'to move towards someone',
            'entryId': 'lib-come-1',
            'clip': <String, dynamic>{
              'url': 'https://cdn/scenova/come.mp4',
              'durationSeconds': 4,
              'resolution': '360p',
              'hasAudio': true,
            },
          },
        ],
        'notice': null,
        'correlationId': 'corr_1',
      });

      expect(result.lookupId, 'lk_1');
      expect(result.kind, LookupKind.word);
      expect(result.status, LookupStatus.served);
      expect(result.displayWord, 'come');
      expect(result.senses.single.clip!.hasAudio, isTrue);
      expect(result.senses.single.clip!.resolution, '360p');
      expect(result.playableSenses, hasLength(1));
    });

    test('falls back to the raw selection when no lemma is supplied', () {
      final result = LookupResult.fromJson(<String, dynamic>{
        'lookupId': 'lk_2',
        'kind': 'phrase',
        'rawSelection': 'give up',
        'normalisedLemma': null,
        'status': 'fallback',
        'senses': <Map<String, dynamic>>[
          <String, dynamic>{
            'senseLabel': '1',
            'partOfSpeech': 'verb',
            'glossPhrase': 'to stop trying',
            'entryId': null,
            'clip': null,
          },
        ],
        'notice': 'A clip is not available for this word right now.',
        'correlationId': 'corr_2',
      });

      expect(result.displayWord, 'give up');
      expect(result.kind, LookupKind.phrase);
      expect(result.status, LookupStatus.fallback);
      expect(result.primaryClip, isNull);
      expect(result.notice, isNotNull);
    });

    test('round-trips through JSON', () {
      final result = LookupResult.fromJson(<String, dynamic>{
        'lookupId': 'lk_3',
        'kind': 'word',
        'rawSelection': 'bank',
        'normalisedLemma': 'bank',
        'status': 'served',
        'senses': <Map<String, dynamic>>[
          <String, dynamic>{
            'senseLabel': '1',
            'partOfSpeech': 'noun',
            'glossPhrase': 'a place that keeps money safe',
            'entryId': 'lib-bank-2',
            'clip': <String, dynamic>{
              'url': 'https://cdn/scenova/bank.mp4',
              'durationSeconds': 4,
              'resolution': '360p',
              'hasAudio': false,
            },
          },
        ],
        'notice': null,
        'correlationId': 'corr_3',
      });

      expect(LookupResult.fromJson(result.toJson()).toJson(), result.toJson());
    });
  });

  group('HttpLookupApi', () {
    HttpLookupApi apiReturning(
      http.Response Function(http.Request request) handler,
    ) {
      return HttpLookupApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        localeProvider: () => 'en-GB',
        client: MockClient((request) async => handler(request)),
      );
    }

    final request = LookupRequest(
      selection: 'come',
      clientLookupId: 'key-1',
      platform: LookupPlatform.android,
      locale: 'en-GB',
      consentModelProcessing: true,
    );

    test('sends the frozen request body and bearer token', () async {
      late http.Request captured;
      final api = apiReturning((r) {
        captured = r;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'lookupId': 'lk_1',
            'kind': 'word',
            'rawSelection': 'come',
            'normalisedLemma': 'come',
            'status': 'served',
            'senses': <dynamic>[],
            'notice': null,
            'correlationId': 'c',
          }),
          200,
        );
      });

      await api.createLookup(request);

      expect(captured.url.path, '/v1/lookups');
      expect(captured.headers['authorization'], 'Bearer token');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['selection'], 'come');
      expect(body['clientLookupId'], 'key-1');
      expect(body['platform'], 'android');
      expect(body['locale'], 'en-GB');
      expect(body['consentModelProcessing'], isTrue);
    });

    test('maps a 400 to an invalid-selection failure', () async {
      final api = apiReturning((_) => http.Response('{}', 400));
      await expectLater(
        api.createLookup(request),
        throwsA(
          isA<LookupApiException>().having(
            (e) => e.isInvalidSelection,
            'isInvalidSelection',
            isTrue,
          ),
        ),
      );
    });

    test('maps a 401 to an unauthenticated failure', () async {
      final api = apiReturning((_) => http.Response('{}', 401));
      await expectLater(
        api.getLookup('lk_1'),
        throwsA(
          isA<LookupApiException>().having(
            (e) => e.isUnauthenticated,
            'isUnauthenticated',
            isTrue,
          ),
        ),
      );
    });

    test('maps a 404 to a not-found failure', () async {
      final api = apiReturning((_) => http.Response('{}', 404));
      await expectLater(
        api.getLookup('lk_1'),
        throwsA(
          isA<LookupApiException>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });

    test('maps a 429 to a retryable failure', () async {
      final api = apiReturning((_) => http.Response('{}', 429));
      await expectLater(
        api.createLookup(request),
        throwsA(
          isA<LookupApiException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isTrue,
          ),
        ),
      );
    });

    test('maps a transport failure to the offline case', () async {
      final api = HttpLookupApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => null,
        localeProvider: () => 'en',
        client: MockClient((_) async => throw http.ClientException('no route')),
      );
      await expectLater(
        api.createLookup(request),
        throwsA(
          isA<LookupApiException>().having(
            (e) => e.isOffline,
            'isOffline',
            isTrue,
          ),
        ),
      );
    });
  });

  group('MockLookupApi', () {
    test('serves a library hit with a clip', () async {
      final result = await MockLookupApi().createLookup(_request('come'));
      expect(result.status, LookupStatus.served);
      expect(result.playableSenses, hasLength(1));
    });

    test('returns one clip per sense for a word with several senses', () async {
      final result = await MockLookupApi().createLookup(_request('bank'));
      expect(result.status, LookupStatus.served);
      expect(result.playableSenses, hasLength(2));
    });

    test('moves a generating lookup to served across polls', () async {
      final api = MockLookupApi(pollsUntilReady: 2);
      final created = await api.createLookup(_request('xylograph'));
      expect(created.status, LookupStatus.generating);

      final first = await api.getLookup(created.lookupId);
      expect(first.status, LookupStatus.generating);

      final second = await api.getLookup(created.lookupId);
      expect(second.status, LookupStatus.served);
      expect(second.playableSenses, hasLength(1));
    });

    test('reports an unavailable clip as a fallback', () async {
      final result = await MockLookupApi().createLookup(_request('quixotic'));
      expect(result.status, LookupStatus.fallback);
      expect(result.primaryClip, isNull);
    });

    test('reports an unknown lookup as not found', () async {
      await expectLater(
        MockLookupApi().getLookup('missing'),
        throwsA(
          isA<LookupApiException>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });
  });
}

LookupRequest _request(String selection) => LookupRequest(
  selection: selection,
  clientLookupId: 'key-$selection',
  platform: LookupPlatform.android,
  locale: 'en',
  consentModelProcessing: true,
);
