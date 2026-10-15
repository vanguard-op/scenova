import 'package:flutter/foundation.dart';

/// One product a store offers, as its SDK reports it.
///
/// The price is the store's own localized display string: the store is the
/// merchant of record and prices every market in its own currency
/// (`docs/Scenova/monetization.md` → "Payment & Billing"), so the client never
/// formats or converts one itself.
@immutable
class StoreProductInfo {
  const StoreProductInfo({
    required this.id,
    required this.displayPrice,
    this.period,
  });

  /// The store's product identifier.
  final String id;

  /// The store's localized price string, e.g. `$6.99`.
  final String displayPrice;

  /// The billing period in words (`month`, `year`), or null for a one-time
  /// product.
  final String? period;
}

/// What a store action resolved to, at the SDK boundary.
enum StoreActionResult {
  /// The store completed the purchase or restore.
  completed,

  /// The reader backed out of the store's own sheet, so nothing changed.
  cancelled,
}

/// The store refused the purchase, carrying the plain reason to show the reader.
///
/// The store's own error codes and wording stay behind this seam: the reader is
/// told in the product's voice, briefly (`DELIVERY.md` → Behavior Rules).
class StorePurchaseDeclined implements Exception {
  const StorePurchaseDeclined(this.message);

  /// The reader-facing reason.
  final String message;

  @override
  String toString() => 'StorePurchaseDeclined($message)';
}

/// The store SDK the client drives (`FEAT-013`).
///
/// RevenueCat wraps StoreKit and Play Billing (D-008), so this seam is what the
/// store client is built against: the products and prices the Paywall shows, the
/// two purchases, the restore, and the store's own subscription management. The
/// concrete SDK reads the public key and product catalog the build path baked in
/// (`docs/Scenova/monetization.md` → "Pricing Tiers").
///
/// An unreachable store is reported as the app's own `StoreUnavailable`, thrown
/// from `purchase_service.dart`, so the screens show it the way the spec
/// describes (`docs/Scenova/screens/08-account.md` → Edge Cases).
abstract interface class StoreSdk {
  /// Prepares the SDK with the store's public key and the reader it acts for.
  Future<void> start({required String apiKey, String? appUserId});

  /// Points the SDK at the reader's account, so a purchase is attributed to the
  /// account the entitlement service reconciles it against (`C-019`,
  /// `accountId`). A call that repeats the id already in use costs nothing.
  Future<void> identify(String appUserId);

  /// The packages the offering carries, with the store's own prices.
  Future<List<StoreProductInfo>> products(String offeringId);

  /// Opens the store's own sheet for [productId] and buys it.
  Future<StoreActionResult> purchase({
    required String offeringId,
    required String productId,
  });

  /// Restores the reader's prior purchases to the current account. True when the
  /// Pro entitlement is active afterwards.
  ///
  /// A restore is about the plan: a top-up is spent within the month it was
  /// bought and does not carry over (`docs/Scenova/monetization.md` → "Lookup
  /// Top-Up"), so it is not something a reader restores.
  Future<bool> restore(String entitlementId);

  /// Opens the store's own management for the reader's subscription.
  Future<void> manageSubscriptions();
}
