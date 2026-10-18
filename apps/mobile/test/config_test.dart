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
      expect(AppConfig.useMockPurchases, isFalse);
    });

    test(
      'a debug run starts on the reader\'s own history, not sample data',
      () {
        // The sample lookups are a development convenience, so a run that asks
        // for nothing opens on the reader's own history rather than filling it
        // with words they never looked up (FEAT-009).
        expect(AppConfig.seedHistory, isFalse);
      },
    );

    test('the development wiring builds the live HTTP intakes', () {
      final services = ScenovaServices.development();
      addTearDown(services.dispose);

      expect(services.lookupApi, isA<HttpLookupApi>());
      expect(services.analytics.api, isA<HttpAnalyticsApi>());
      expect(services.pushRegistrar.api, isA<HttpPushRegistrationApi>());
      // Every live intake is pointed at the base URL the app resolves, so the
      // one place the gateway is decided is the one the client uses.
      expect(
        (services.lookupApi as HttpLookupApi).baseUrl,
        AppConfig.apiBaseUrl,
      );
    });

    test('the default reaches the deployed gateway, not a loopback address', () {
      // A build installed on a device has no stack on the developer's own
      // machine to reach, so the default is the deployed gateway, and it is
      // carried over https (NFR-022). A loopback default would leave the reader
      // with nothing the moment the app left the developer's laptop.
      expect(AppConfig.apiBaseUrl, AppConfig.deployedGatewayUrl);
      expect(AppConfig.apiBaseUrl.startsWith('https://'), isTrue);
      expect(AppConfig.isSecureGateway(AppConfig.apiBaseUrl), isTrue);
    });

    test(
      'the local stack default reaches the host from the device it runs on',
      () {
        // The emulator cannot see the host as `localhost` — there that name is
        // the device itself — so the local-stack URL an explicit run passes is
        // the emulator's alias for the host loopback. Elsewhere the host's own
        // `localhost` is right.
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect(AppConfig.localStackBaseUrl, 'http://10.0.2.2:8080');

        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        expect(AppConfig.localStackBaseUrl, 'http://localhost:8080');

        debugDefaultTargetPlatformOverride = null;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
      },
    );
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

  group('the store client configuration (FEAT-013)', () {
    test('a build with no store configuration drives no store', () {
      // A plain development run carries none of the defines the build path bakes
      // in, so the scripted store stands in rather than a store with no key.
      expect(StoreConfig.isConfigured, isFalse);
      expect(StoreConfig.catalog, isNull);
      expect(StoreConfig.sdkKey, isNull);
    });

    test('refuses a build that could sell nothing', () {
      expect(() => StoreConfig.ensureConfigured(), throwsArgumentError);
    });

    test('takes the key for the store the build ships to', () {
      expect(
        StoreConfig.sdkKeyFor(
          TargetPlatform.iOS,
          appStoreKey: 'app-store-key',
          playStoreKey: 'play-store-key',
        ),
        'app-store-key',
      );
      expect(
        StoreConfig.sdkKeyFor(
          TargetPlatform.android,
          appStoreKey: 'app-store-key',
          playStoreKey: 'play-store-key',
        ),
        'play-store-key',
      );
      // No store to buy from elsewhere, and no key is guessed.
      expect(
        StoreConfig.sdkKeyFor(
          TargetPlatform.macOS,
          appStoreKey: 'app-store-key',
          playStoreKey: 'play-store-key',
        ),
        isNull,
      );
    });

    test('a key and the two plans the Paywall sells are all required', () {
      StoreCatalog? catalogWith({
        String? key = 'public-key',
        String proMonthly = 'com.scenova.pro.monthly',
        String topUp = 'com.scenova.topup.lookups20',
      }) => StoreConfig.catalogFrom(
        sdkKey: key,
        entitlementId: 'pro',
        offeringId: 'default',
        proMonthlyId: proMonthly,
        proAnnualId: 'com.scenova.pro.annual',
        topUpId: topUp,
      );

      final catalog = catalogWith();
      expect(catalog?.proMonthlyId, 'com.scenova.pro.monthly');
      expect(catalog?.proAnnualId, 'com.scenova.pro.annual');
      expect(catalog?.topUpId, 'com.scenova.topup.lookups20');
      expect(catalogWith(key: null), isNull);
      expect(catalogWith(proMonthly: ''), isNull);
      expect(catalogWith(topUp: ''), isNull);
      // The annual plan is the store's option to offer, not a requirement.
      expect(
        StoreConfig.catalogFrom(
          sdkKey: 'public-key',
          entitlementId: 'pro',
          offeringId: 'default',
          proMonthlyId: 'com.scenova.pro.monthly',
          proAnnualId: '',
          topUpId: 'com.scenova.topup.lookups20',
        )?.proAnnualId,
        isNull,
      );
    });
  });
}
