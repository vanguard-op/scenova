import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/services/entitlement_api.dart';

void main() {
  group('Entitlement', () {
    test('parses the frozen C-018 shape', () {
      final entitlement = Entitlement.fromJson(<String, dynamic>{
        'plan': 'pro',
        'lookupsUsed': 8,
        'lookupsLimit': 50,
        'periodStart': '2026-10-01T00:00:00Z',
        'periodEnd': '2026-11-01T00:00:00Z',
        'status': 'active',
        'trialEndsAt': null,
      });

      expect(entitlement.tier, PlanTier.pro);
      expect(entitlement.signedIn, isTrue);
      expect(entitlement.lookupsUsed, 8);
      expect(entitlement.lookupsLimit, 50);
      expect(entitlement.lookupsRemaining, 42);
      expect(entitlement.status, EntitlementStatus.active);
      expect(entitlement.periodEnd, DateTime.utc(2026, 11, 1));
      expect(entitlement.trialEndsAt, isNull);
    });

    test('carries the trial end and reads an exhausted allowance', () {
      final entitlement = Entitlement.fromJson(<String, dynamic>{
        'plan': 'trial',
        'lookupsUsed': 50,
        'lookupsLimit': 50,
        'periodStart': '2026-10-01T00:00:00Z',
        'periodEnd': '2026-11-01T00:00:00Z',
        'status': 'active',
        'trialEndsAt': '2026-10-20T00:00:00Z',
      });

      expect(entitlement.isTrial, isTrue);
      expect(entitlement.trialEndsAt, DateTime.utc(2026, 10, 20));
      expect(entitlement.lookupsRemaining, 0);
      expect(entitlement.exhausted, isTrue);
    });

    test('a signed-out reader carries no allowance', () {
      expect(Entitlement.signedOut.signedIn, isFalse);
      expect(Entitlement.signedOut.lookupsRemaining, isNull);
      expect(Entitlement.signedOut.exhausted, isFalse);
    });
  });

  group('HttpEntitlementApi', () {
    HttpEntitlementApi apiReturning(
      Future<http.Response> Function(http.Request request) handler,
    ) {
      return HttpEntitlementApi(
        baseUrl: 'https://gateway.test',
        idTokenProvider: () async => 'token-1',
        client: MockClient((request) => handler(request)),
      );
    }

    test('reads the entitlement with the bearer token', () async {
      late http.Request captured;
      final api = apiReturning((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'plan': 'free',
            'lookupsUsed': 12,
            'lookupsLimit': 20,
            'periodStart': '2026-10-01T00:00:00Z',
            'periodEnd': '2026-11-01T00:00:00Z',
            'status': 'active',
            'trialEndsAt': null,
          }),
          200,
        );
      });

      final entitlement = await api.fetch();

      expect(captured.url.toString(), 'https://gateway.test/v1/entitlement');
      expect(captured.headers['authorization'], 'Bearer token-1');
      expect(entitlement.tier, PlanTier.free);
      expect(entitlement.lookupsRemaining, 8);
    });

    test('a 401 reads as signed out, not as an error', () async {
      final api = apiReturning((_) async => http.Response('{}', 401));

      await expectLater(
        api.fetch(),
        throwsA(
          isA<EntitlementApiException>().having(
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
        api.fetch(),
        throwsA(
          isA<EntitlementApiException>().having(
            (error) => error.isUnavailable,
            'isUnavailable',
            isTrue,
          ),
        ),
      );
    });

    test(
      'a transport failure reads as unavailable, never as signed out',
      () async {
        final api = HttpEntitlementApi(
          baseUrl: 'https://gateway.test',
          idTokenProvider: () async => 'token-1',
          client: MockClient(
            (_) async => throw http.ClientException('no route'),
          ),
        );

        await expectLater(
          api.fetch(),
          throwsA(
            isA<EntitlementApiException>()
                .having((error) => error.isUnavailable, 'isUnavailable', isTrue)
                .having((error) => error.isSignedOut, 'isSignedOut', isFalse),
          ),
        );
      },
    );
  });

  group('MockEntitlementApi', () {
    test('answers with the scripted plan', () async {
      const plan = Entitlement(
        tier: PlanTier.pro,
        signedIn: true,
        lookupsUsed: 1,
        lookupsLimit: 50,
      );

      expect((await MockEntitlementApi(plan: plan).fetch()).tier, PlanTier.pro);
    });

    test('answers with a scripted failure', () async {
      await expectLater(
        MockEntitlementApi(
          error: const EntitlementApiException(401, 'Sign in.'),
        ).fetch(),
        throwsA(isA<EntitlementApiException>()),
      );
    });
  });
}
