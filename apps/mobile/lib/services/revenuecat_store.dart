import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart' as rc;
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import 'purchase_service.dart';
import 'store_sdk.dart';

/// The store client behind [PurchaseService]: RevenueCat, wrapping StoreKit and
/// Play Billing (D-008).
///
/// It is what the Paywall and the Account screen actually drive. The public SDK
/// key, the entitlement, the offering, and the product catalog come from the
/// build path's own defines ([StoreConfig]), so a build carries the store client
/// configuration rather than reading it from anywhere at runtime.
///
/// Prices are never baked in and never formatted here: the store is the merchant
/// of record, prices every market in its own currency, and is the one that
/// localizes them (`docs/Scenova/monetization.md` → "Payment & Billing").
class RevenueCatPurchaseService implements PurchaseService {
  RevenueCatPurchaseService({
    required this.sdk,
    required this.apiKey,
    required this.catalog,
    this.appUserId,
  });

  /// The store SDK this client drives.
  final StoreSdk sdk;

  /// The public client SDK key the build path baked in for this store.
  final String apiKey;

  /// The entitlement, offering, and products the build was configured with.
  final StoreCatalog catalog;

  /// The account a purchase belongs to, as the services know it (`C-019`
  /// `accountId`). A build that has no identity buys as an anonymous store
  /// customer; the reader is identified again before every action, so a purchase
  /// made after sign-in is attributed to the account.
  final Future<String?> Function()? appUserId;

  bool _started = false;

  @override
  Future<StoreOffering> offerings() async {
    await _start();
    final products = await sdk.products(catalog.offeringId);
    final byId = <String, StoreProductInfo>{
      for (final product in products) product.id: product,
    };
    final monthly = byId[catalog.proMonthlyId];
    final topUp = byId[catalog.topUpId];
    if (monthly == null || topUp == null) {
      throw StoreCatalogException(<String>[
        if (monthly == null) catalog.proMonthlyId,
        if (topUp == null) catalog.topUpId,
      ]);
    }
    final annualId = catalog.proAnnualId;
    final annual = annualId == null ? null : byId[annualId];
    // The trial length and the pack size are the products' own declared values
    // (`docs/Scenova/monetization.md` → "Pricing Tiers"); the build bakes in the
    // identifiers, never a price or a figure.
    return StoreOffering(
      proMonthly: _toProduct(monthly),
      proAnnual: annual == null ? null : _toProduct(annual),
      topUp: _toProduct(topUp),
    );
  }

  @override
  Future<PurchaseOutcome> startPro() => _buy(catalog.proMonthlyId);

  @override
  Future<PurchaseOutcome> buyTopUp() => _buy(catalog.topUpId);

  @override
  Future<PurchaseOutcome> managePlan() async {
    await _start();
    await _identify();
    await sdk.manageSubscriptions();
    // The reader may cancel or change the plan while they are in the store's own
    // management, so nothing is claimed here; the caller re-reads the plan on
    // return (`docs/Scenova/screens/08-account.md` → Data Flow).
    return const PurchaseDismissed();
  }

  @override
  Future<PurchaseOutcome> restore() async {
    await _start();
    await _identify();
    final active = await sdk.restore(catalog.entitlementId);
    return active
        ? const PurchaseCompleted()
        : const PurchaseNothingToRestore();
  }

  Future<PurchaseOutcome> _buy(String productId) async {
    await _start();
    await _identify();
    try {
      final result = await sdk.purchase(
        offeringId: catalog.offeringId,
        productId: productId,
      );
      return switch (result) {
        StoreActionResult.completed => const PurchaseCompleted(),
        StoreActionResult.cancelled => const PurchaseDismissed(),
      };
    } on StorePurchaseDeclined catch (declined) {
      return PurchaseFailed(declined.message);
    }
  }

  /// Prepares the SDK once, with the reader the app already knows.
  Future<void> _start() async {
    if (_started) return;
    await sdk.start(apiKey: apiKey, appUserId: await _accountId());
    _started = true;
  }

  /// Points the store at the reader's account, when the app has one.
  Future<void> _identify() async {
    final accountId = await _accountId();
    if (accountId == null || accountId.isEmpty) return;
    await sdk.identify(accountId);
  }

  Future<String?> _accountId() async => appUserId?.call();

  static StoreProduct _toProduct(StoreProductInfo info) => StoreProduct(
    id: info.id,
    displayPrice: info.displayPrice,
    displayPeriod: info.period,
  );
}

/// The store answered, but the offering does not carry a product the build was
/// configured with, so there is nothing to sell.
///
/// This is a build-configuration fault rather than a store outage: the Paywall
/// shows its offering-error state and the reader can keep reading without a clip
/// (`docs/Scenova/screens/04-paywall.md` → States).
class StoreCatalogException implements Exception {
  const StoreCatalogException(this.missingProductIds);

  /// The product identifiers the offering did not carry.
  final List<String> missingProductIds;

  @override
  String toString() =>
      'StoreCatalogException(missing: ${missingProductIds.join(', ')})';
}

/// The store SDK through RevenueCat (D-008).
///
/// RevenueCat holds the store connection, so the client's own job is to map the
/// provider's shapes onto the app's: the offering's packages onto the products
/// the Paywall shows, the provider's error codes onto a reader-facing reason, and
/// its customer record onto whether a restore actually restored Pro. The
/// provider's own error codes and wording never reach the reader.
class RevenueCatStoreSdk implements StoreSdk {
  RevenueCatStoreSdk({StoreUrlOpener? open}) : _open = open ?? _openExternally;

  final StoreUrlOpener _open;

  /// The packages of each offering that has been read, keyed by offering and then
  /// by product identifier, so a purchase resolves the package the store quoted
  /// rather than fetching the catalog again.
  final Map<String, Map<String, rc.Package>> _packages =
      <String, Map<String, rc.Package>>{};

  /// The reader the SDK is currently acting for, so a repeat identification
  /// costs nothing.
  String? _identified;

  /// The provider's codes that mean the store could not be reached, rather than
  /// the reader being refused (`docs/Scenova/screens/08-account.md` → Edge
  /// Cases).
  static const Set<rc.PurchasesErrorCode> _unreachable =
      <rc.PurchasesErrorCode>{
        rc.PurchasesErrorCode.networkError,
        rc.PurchasesErrorCode.offlineConnectionError,
        rc.PurchasesErrorCode.apiEndpointBlocked,
        rc.PurchasesErrorCode.productRequestTimeout,
        rc.PurchasesErrorCode.unknownBackendError,
        rc.PurchasesErrorCode.unexpectedBackendResponseError,
      };

  @override
  Future<void> start({required String apiKey, String? appUserId}) async {
    await rc.Purchases.setLogLevel(
      kDebugMode ? rc.LogLevel.debug : rc.LogLevel.warn,
    );
    await _call(
      () => rc.Purchases.configure(
        rc.PurchasesConfiguration(apiKey)..appUserID = appUserId,
      ),
    );
    _identified = appUserId;
  }

  @override
  Future<void> identify(String appUserId) async {
    if (_identified == appUserId) return;
    await _call(() => rc.Purchases.logIn(appUserId));
    _identified = appUserId;
  }

  @override
  Future<List<StoreProductInfo>> products(String offeringId) async {
    final offerings = await _call(rc.Purchases.getOfferings);
    final offering = offerings.getOffering(offeringId);
    if (offering == null) {
      _packages[offeringId] = const <String, rc.Package>{};
      return const <StoreProductInfo>[];
    }
    _packages[offeringId] = <String, rc.Package>{
      for (final package in offering.availablePackages)
        package.storeProduct.identifier: package,
    };
    return offering.availablePackages.map(_info).toList();
  }

  @override
  Future<StoreActionResult> purchase({
    required String offeringId,
    required String productId,
  }) async {
    final package = await _packageFor(offeringId, productId);
    try {
      await rc.Purchases.purchase(rc.PurchaseParams.package(package));
      return StoreActionResult.completed;
    } on PlatformException catch (error) {
      final code = rc.PurchasesErrorHelper.getErrorCode(error);
      if (code == rc.PurchasesErrorCode.purchaseCancelledError) {
        return StoreActionResult.cancelled;
      }
      if (_unreachable.contains(code)) throw const StoreUnavailable();
      throw StorePurchaseDeclined(_reasonFor(code));
    }
  }

  @override
  Future<bool> restore(String entitlementId) async {
    final info = await _call(rc.Purchases.restorePurchases);
    return info.entitlements.active.containsKey(entitlementId);
  }

  @override
  Future<void> manageSubscriptions() async {
    // The store owns subscription management, and the store's own page is the
    // only place a reader can cancel or change the plan.
    final url = switch (defaultTargetPlatform) {
      TargetPlatform.android => Uri.parse(
        'https://play.google.com/store/account/subscriptions',
      ),
      _ => Uri.parse('https://apps.apple.com/account/subscriptions'),
    };
    if (!await _open(url)) throw const StoreUnavailable();
  }

  /// The package the store quoted for [productId], reading the offering when it
  /// has not been read yet — the Account screen starts a purchase without ever
  /// showing the offering's prices.
  Future<rc.Package> _packageFor(String offeringId, String productId) async {
    final cached = _packages[offeringId]?[productId];
    if (cached != null) return cached;
    await products(offeringId);
    final package = _packages[offeringId]?[productId];
    if (package == null) throw StoreCatalogException(<String>[productId]);
    return package;
  }

  /// Runs a store call, reporting an unreachable store as the app's own outage.
  Future<T> _call<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      if (_unreachable.contains(rc.PurchasesErrorHelper.getErrorCode(error))) {
        throw const StoreUnavailable();
      }
      rethrow;
    }
  }

  static StoreProductInfo _info(rc.Package package) {
    final product = package.storeProduct;
    return StoreProductInfo(
      id: product.identifier,
      displayPrice: product.priceString,
      period: _period(product.subscriptionPeriod),
    );
  }

  /// The billing period in words, from the store's ISO 8601 subscription period
  /// (`P1M` is a month, `P1Y` a year). A one-time product carries none.
  static String? _period(String? iso) => switch (iso) {
    'P1W' => 'week',
    'P1M' => 'month',
    'P1Y' => 'year',
    _ => null,
  };

  /// The plain reason to show the reader for a store refusal.
  static String _reasonFor(rc.PurchasesErrorCode code) => switch (code) {
    rc.PurchasesErrorCode.purchaseNotAllowedError =>
      'Purchases are not allowed on this device.',
    rc.PurchasesErrorCode.paymentPendingError =>
      'Your payment is still pending. It will apply when it clears.',
    rc.PurchasesErrorCode.productAlreadyPurchasedError ||
    rc.PurchasesErrorCode.receiptAlreadyInUseError =>
      'This purchase is already on your account.',
    _ => 'The payment did not go through. Try again.',
  };

  static Future<bool> _openExternally(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);
}

/// Opens a store page in the platform's own browser or store app.
typedef StoreUrlOpener = Future<bool> Function(Uri url);
