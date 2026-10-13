import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/config.dart';
import 'package:scenova/services/analytics_api.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/push_registration_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('live-by-default wiring', () {
    test('a release build talks to the live stack, never scripted data', () {
      // A build that ships the mock intakes would serve every reader scripted
      // data, so the live path is the default and the mocks are opt-in.
      expect(AppConfig.useMockLookupApi, isFalse);
      expect(AppConfig.useMockAnalyticsApi, isFalse);
      expect(AppConfig.useMockPushApi, isFalse);
    });

    test('the development wiring builds the live HTTP intakes', () {
      final services = ScenovaServices.development();
      addTearDown(services.dispose);

      expect(services.lookupApi, isA<HttpLookupApi>());
      expect(services.analytics.api, isA<HttpAnalyticsApi>());
      expect(services.pushRegistrar.api, isA<HttpPushRegistrationApi>());
      // The default base URL is the local stack the Makefile boots.
      expect(
        (services.lookupApi as HttpLookupApi).baseUrl,
        AppConfig.apiBaseUrl,
      );
    });

    test('the local default reaches the host from the device it runs on', () {
      // The emulator cannot see the host as `localhost` — there that name is
      // the device itself — so the Android default is the emulator's alias for
      // the host loopback. Elsewhere the host's own `localhost` is right.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(AppConfig.apiBaseUrl, 'http://10.0.2.2:8080');

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(AppConfig.apiBaseUrl, 'http://localhost:8080');

      debugDefaultTargetPlatformOverride = null;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
    });
  });

  group('transport encryption (NFR-022)', () {
    test('accepts https on any host', () {
      expect(AppConfig.isSecureGateway('https://gateway.scenova.app'), isTrue);
    });

    test('accepts http on a local development host', () {
      expect(AppConfig.isSecureGateway('http://localhost:8080'), isTrue);
      expect(AppConfig.isSecureGateway('http://127.0.0.1:8080'), isTrue);
      expect(AppConfig.isSecureGateway('http://[::1]:8080'), isTrue);
      // The Android emulator's alias for the host loopback.
      expect(AppConfig.isSecureGateway('http://10.0.2.2:8080'), isTrue);
    });

    test('refuses a plaintext remote host', () {
      expect(AppConfig.isSecureGateway('http://gateway.scenova.app'), isFalse);
      expect(AppConfig.isSecureGateway('http://10.0.2.3:8080'), isFalse);
    });

    test('refuses a scheme that is neither http nor https', () {
      expect(AppConfig.isSecureGateway('ftp://gateway.scenova.app'), isFalse);
      expect(AppConfig.isSecureGateway('not a url'), isFalse);
    });

    test('ensureSecureGateway fails fast on a plaintext remote host', () {
      expect(
        () => AppConfig.ensureSecureGateway('http://gateway.scenova.app'),
        throwsArgumentError,
      );
      expect(
        () => AppConfig.ensureSecureGateway('https://gateway.scenova.app'),
        returnsNormally,
      );
      expect(
        () => AppConfig.ensureSecureGateway('http://localhost:8080'),
        returnsNormally,
      );
      expect(
        () => AppConfig.ensureSecureGateway('http://10.0.2.2:8080'),
        returnsNormally,
      );
    });
  });
}
