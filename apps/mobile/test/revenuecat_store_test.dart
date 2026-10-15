import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart'
    show PurchasesErrorCode;
import 'package:scenova/config.dart';
import 'package:scenova/services/purchase_service.dart';
import 'package:scenova/services/revenuecat_store.dart';
import 'package:scenova/services/store_sdk.dart';

/// The catalog a build is configured with, mirroring `.env.example`.
const StoreCatalog _catalog = StoreCatalog(
  entitlementId: 'pro',
  offeringId: 'default',
  proMonthlyId: 'com.scenova.pro.monthly',
  proAnnualId: 'com.scenova.pro.annual',
  topUpId: 'com.scenova.topup.lookups20',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the store client behind the purchase seam', () {
    test('reads the offering into the products the Paywall shows', () async {
      final sdk = _ScriptedStoreSdk();
      final store = _store(sdk);

      final offering = await store.offerings();

      expect(sdk.offeringIds, <String>['default']);
      expect(offering.proMonthly.id, 'com.scenova.pro.monthly');
      expect(offering.proMonthly.displayPrice, r'$6.99');
      expect(offering.proMonthly.displayPeriod, 'month');
      expect(offering.proAnnual?.displayPrice, r'$59.99');
      expect(offering.proAnnual?.displayPeriod, 'year');
      expect(offering.topUp.id, 'com.scenova.topup.lookups20');
      expect(offering.topUp.displayPrice, r'$2.99');
      expect(offering.topUp.displayPeriod, isNull);
      expect(offering.trialDays, 7);
      expect(offering.topUpLookups, 20);
    });

    test('leaves the annual plan out when the store offers none', () async {
      final sdk = _ScriptedStoreSdk(
        catalogProducts: <StoreProductInfo>[_monthly, _topUp],
      );

      expect((await _store(sdk).offerings()).proAnnual, isNull);
    });

    test('reports a build whose catalog the store does not carry', () async {
      final sdk = _ScriptedStoreSdk(
        catalogProducts: <StoreProductInfo>[_monthly],
      );

      await expectLater(
        _store(sdk).offerings(),
        throwsA(
          isA<StoreCatalogException>().having(
            (error) => error.missingProductIds,
            'missing',
            <String>['com.scenova.topup.lookups20'],
          ),
        ),
      );
    });

    test('starts the Pro subscription on the configured product', () async {
      final sdk = _ScriptedStoreSdk();
      final store = _store(sdk);

      expect(await store.startPro(), isA<PurchaseCompleted>());
      expect(sdk.purchased, <String>['com.scenova.pro.monthly']);
      expect(sdk.purchaseOfferings, <String>['default']);
    });

    test('buys the top-up pack on the configured product', () async {
      final sdk = _ScriptedStoreSdk();

      expect(await _store(sdk).buyTopUp(), isA<PurchaseCompleted>());
      expect(sdk.purchased, <String>['com.scenova.topup.lookups20']);
    });

    test('a purchase the reader backed out of changes nothing', () async {
      final sdk = _ScriptedStoreSdk(
        purchaseResult: StoreActionResult.cancelled,
      );

      expect(await _store(sdk).startPro(), isA<PurchaseDismissed>());
    });

    test('a purchase the store refused carries the reason to show', () async {
      final sdk = _ScriptedStoreSdk(
        purchaseError: const StorePurchaseDeclined(
          'Your payment was declined. Try another payment method.',
        ),
      );

      final outcome = await _store(sdk).startPro();

      expect(
        outcome,
        isA<PurchaseFailed>().having(
          (failed) => failed.message,
          'message',
          'Your payment was declined. Try another payment method.',
        ),
      );
    });

    test('an unreachable store stays an outage, not a refusal', () async {
      final sdk = _ScriptedStoreSdk(purchaseError: const StoreUnavailable());

      await expectLater(
        _store(sdk).startPro(),
        throwsA(isA<StoreUnavailable>()),
      );
    });

    test('restores a prior purchase when the entitlement is active', () async {
      final sdk = _ScriptedStoreSdk(entitlementActive: true);

      expect(await _store(sdk).restore(), isA<PurchaseCompleted>());
      expect(sdk.restoredEntitlement, 'pro');
    });

    test('reports a restore that found nothing', () async {
      final sdk = _ScriptedStoreSdk();

      expect(await _store(sdk).restore(), isA<PurchaseNothingToRestore>());
    });

    test('opens the store\'s own plan management', () async {
      final sdk = _ScriptedStoreSdk();

      expect(await _store(sdk).managePlan(), isA<PurchaseDismissed>());
      expect(sdk.manageCalls, 1);
    });

    test('prepares the store once, with the key the build baked in', () async {
      final sdk = _ScriptedStoreSdk();
      final store = _store(sdk);

      await store.offerings();
      await store.startPro();

      expect(sdk.startCalls, 1);
      expect(sdk.startedWithKey, 'public-sdk-key');
    });

    test('attributes every action to the reader\'s account', () async {
      final sdk = _ScriptedStoreSdk();

      await _store(sdk, accountId: () async => 'account-9').startPro();

      expect(sdk.identified, <String>['account-9']);
    });

    test('buys anonymously when the app holds no identity', () async {
      final sdk = _ScriptedStoreSdk();

      await _store(sdk).startPro();

      expect(sdk.identified, isEmpty);
      expect(sdk.startedWithUserId, isNull);
    });
  });

  group('the RevenueCat SDK mapping', () {
    const channel = MethodChannel('purchases_flutter');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    void answers(Future<Object?> Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(channel, handler);
    }

    test('maps the offering\'s packages onto the products shown', () async {
      answers((call) async {
        if (call.method == 'getOfferings') return _offerings;
        return null;
      });
      final sdk = RevenueCatStoreSdk();

      final products = await sdk.products('default');

      expect(products.map((product) => product.id), <String>[
        'com.scenova.pro.monthly',
        'com.scenova.pro.annual',
        'com.scenova.topup.lookups20',
      ]);
      expect(products.first.displayPrice, r'$6.99');
      expect(products.first.period, 'month');
      expect(products[1].period, 'year');
      expect(products.last.period, isNull);
    });

    test('reads an offering the store does not carry as empty', () async {
      answers(
        (call) async => call.method == 'getOfferings' ? _offerings : null,
      );

      expect(await RevenueCatStoreSdk().products('missing'), isEmpty);
    });

    test('reads the reader backing out of the store sheet', () async {
      answers((call) async {
        if (call.method == 'getOfferings') return _offerings;
        if (call.method == 'purchasePackage') {
          throw PlatformException(
            code: '${PurchasesErrorCode.purchaseCancelledError.index}',
          );
        }
        return null;
      });
      final sdk = RevenueCatStoreSdk();
      await sdk.products('default');

      final result = await sdk.purchase(
        offeringId: 'default',
        productId: 'com.scenova.pro.monthly',
      );

      expect(result, StoreActionResult.cancelled);
    });

    test('gives a refusal a plain reason, never the provider\'s', () async {
      answers((call) async {
        if (call.method == 'getOfferings') return _offerings;
        if (call.method == 'purchasePackage') {
          throw PlatformException(
            code: '${PurchasesErrorCode.purchaseNotAllowedError.index}',
          );
        }
        return null;
      });
      final sdk = RevenueCatStoreSdk();
      await sdk.products('default');

      await expectLater(
        sdk.purchase(
          offeringId: 'default',
          productId: 'com.scenova.pro.monthly',
        ),
        throwsA(
          isA<StorePurchaseDeclined>().having(
            (declined) => declined.message,
            'message',
            'Purchases are not allowed on this device.',
          ),
        ),
      );
    });

    test('reads a store it cannot reach as an outage', () async {
      answers((call) async {
        if (call.method == 'getOfferings') return _offerings;
        if (call.method == 'purchasePackage') {
          throw PlatformException(
            code: '${PurchasesErrorCode.networkError.index}',
          );
        }
        return null;
      });
      final sdk = RevenueCatStoreSdk();
      await sdk.products('default');

      await expectLater(
        sdk.purchase(
          offeringId: 'default',
          productId: 'com.scenova.pro.monthly',
        ),
        throwsA(isA<StoreUnavailable>()),
      );
    });

    test('reads a restore by whether Pro is active afterwards', () async {
      answers((call) async {
        if (call.method == 'restorePurchases') {
          return _customerInfo(proActive: true);
        }
        return null;
      });

      expect(await RevenueCatStoreSdk().restore('pro'), isTrue);
    });

    test('reads a restore with nothing behind it', () async {
      answers((call) async {
        if (call.method == 'restorePurchases') {
          return _customerInfo(proActive: false);
        }
        return null;
      });

      expect(await RevenueCatStoreSdk().restore('pro'), isFalse);
    });

    test('opens the store\'s own page for the plan', () async {
      final opened = <Uri>[];
      final sdk = RevenueCatStoreSdk(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await sdk.manageSubscriptions();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await sdk.manageSubscriptions();

      // The store owns plan management, and each store has its own page.
      expect(opened.map((url) => url.host), <String>[
        'apps.apple.com',
        'play.google.com',
      ]);
    });

    test('reports a plan page that could not be opened', () async {
      final sdk = RevenueCatStoreSdk(open: (url) async => false);

      await expectLater(
        sdk.manageSubscriptions(),
        throwsA(isA<StoreUnavailable>()),
      );
    });
  });
}

/// The store client under test, driven by the scripted SDK.
RevenueCatPurchaseService _store(
  StoreSdk sdk, {
  Future<String?> Function()? accountId,
}) {
  return RevenueCatPurchaseService(
    sdk: sdk,
    apiKey: 'public-sdk-key',
    catalog: _catalog,
    appUserId: accountId,
  );
}

const StoreProductInfo _monthly = StoreProductInfo(
  id: 'com.scenova.pro.monthly',
  displayPrice: r'$6.99',
  period: 'month',
);

const StoreProductInfo _topUp = StoreProductInfo(
  id: 'com.scenova.topup.lookups20',
  displayPrice: r'$2.99',
);

/// A store SDK whose answers are scripted, so the client's mapping is exercised
/// without a store.
class _ScriptedStoreSdk implements StoreSdk {
  _ScriptedStoreSdk({
    List<StoreProductInfo>? catalogProducts,
    this.purchaseResult = StoreActionResult.completed,
    this.purchaseError,
    this.entitlementActive = false,
  }) : catalogProducts =
           catalogProducts ??
           const <StoreProductInfo>[
             _monthly,
             StoreProductInfo(
               id: 'com.scenova.pro.annual',
               displayPrice: r'$59.99',
               period: 'year',
             ),
             _topUp,
           ];

  final List<StoreProductInfo> catalogProducts;
  final StoreActionResult purchaseResult;
  final Object? purchaseError;
  final bool entitlementActive;

  int startCalls = 0;
  String? startedWithKey;
  String? startedWithUserId;
  final List<String> identified = <String>[];
  final List<String> offeringIds = <String>[];
  final List<String> purchaseOfferings = <String>[];
  final List<String> purchased = <String>[];
  String? restoredEntitlement;
  int manageCalls = 0;

  @override
  Future<void> start({required String apiKey, String? appUserId}) async {
    startCalls++;
    startedWithKey = apiKey;
    startedWithUserId = appUserId;
  }

  @override
  Future<void> identify(String appUserId) async => identified.add(appUserId);

  @override
  Future<List<StoreProductInfo>> products(String offeringId) async {
    offeringIds.add(offeringId);
    return catalogProducts;
  }

  @override
  Future<StoreActionResult> purchase({
    required String offeringId,
    required String productId,
  }) async {
    purchased.add(productId);
    purchaseOfferings.add(offeringId);
    final error = purchaseError;
    if (error != null) throw error;
    return purchaseResult;
  }

  @override
  Future<bool> restore(String entitlementId) async {
    restoredEntitlement = entitlementId;
    return entitlementActive;
  }

  @override
  Future<void> manageSubscriptions() async => manageCalls++;
}

/// The offerings payload RevenueCat answers with, shaped as the plugin reads it.
final Map<String, Object?> _offerings = <String, Object?>{
  'all': <String, Object?>{
    'default': <String, Object?>{
      'identifier': 'default',
      'serverDescription': 'The plans',
      'metadata': <String, Object?>{},
      'availablePackages': <Object?>[
        _package(
          r'$rc_monthly',
          'MONTHLY',
          'com.scenova.pro.monthly',
          r'$6.99',
          'P1M',
        ),
        _package(
          r'$rc_annual',
          'ANNUAL',
          'com.scenova.pro.annual',
          r'$59.99',
          'P1Y',
        ),
        _package(
          'topup20',
          'CUSTOM',
          'com.scenova.topup.lookups20',
          r'$2.99',
          null,
        ),
      ],
    },
  },
  'current': null,
};

Map<String, Object?> _package(
  String identifier,
  String type,
  String productId,
  String price,
  String? period,
) {
  return <String, Object?>{
    'identifier': identifier,
    'packageType': type,
    'product': <String, Object?>{
      'identifier': productId,
      'description': 'Scenova',
      'title': 'Scenova',
      'price': 1.0,
      'priceString': price,
      'currencyCode': 'USD',
      'subscriptionPeriod': period,
    },
    'presentedOfferingContext': <String, Object?>{
      'offeringIdentifier': 'default',
    },
  };
}

/// A customer record with the Pro entitlement active or absent.
Map<String, Object?> _customerInfo({required bool proActive}) {
  final entitlement = <String, Object?>{
    'identifier': 'pro',
    'isActive': proActive,
    'willRenew': proActive,
    'latestPurchaseDate': '2026-10-15T10:00:00Z',
    'originalPurchaseDate': '2026-10-15T10:00:00Z',
    'productIdentifier': 'com.scenova.pro.monthly',
    'isSandbox': false,
    'ownershipType': 'PURCHASED',
    'store': 'APP_STORE',
    'periodType': 'NORMAL',
  };
  return <String, Object?>{
    'entitlements': <String, Object?>{
      'all': <String, Object?>{'pro': entitlement},
      'active': <String, Object?>{if (proActive) 'pro': entitlement},
    },
    'allPurchaseDates': <String, Object?>{},
    'activeSubscriptions': <Object?>[if (proActive) 'com.scenova.pro.monthly'],
    'allPurchasedProductIdentifiers': <Object?>['com.scenova.pro.monthly'],
    'nonSubscriptionTransactions': <Object?>[],
    'firstSeen': '2026-10-15T10:00:00Z',
    'originalAppUserId': 'account-9',
    'allExpirationDates': <String, Object?>{},
    'requestDate': '2026-10-15T10:00:00Z',
  };
}
