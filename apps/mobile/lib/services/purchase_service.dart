import 'package:flutter/foundation.dart';

/// The outcome of a store action (`FEAT-013`; `docs/Scenova/monetization.md` →
/// "Payment & Billing").
sealed class PurchaseOutcome {
  const PurchaseOutcome();
}

/// The store completed the purchase or restore.
final class PurchaseCompleted extends PurchaseOutcome {
  const PurchaseCompleted();
}

/// The reader backed out of the store sheet, or returned from managing the
/// plan. Nothing changed that the screen can read from the outcome.
final class PurchaseDismissed extends PurchaseOutcome {
  const PurchaseDismissed();
}

/// A restore found no prior purchase for the account.
final class PurchaseNothingToRestore extends PurchaseOutcome {
  const PurchaseNothingToRestore();
}

/// The store returned a failure. [message] is the reader-facing reason.
final class PurchaseFailed extends PurchaseOutcome {
  const PurchaseFailed(this.message);

  final String message;
}

/// The store could not be reached. The current plan stays unchanged
/// (`docs/Scenova/screens/08-account.md` → Edge Cases).
class StoreUnavailable implements Exception {
  const StoreUnavailable();

  @override
  String toString() => 'StoreUnavailable';
}

/// A product the store offers, with the price the reader would pay.
///
/// The price is the store's own localized display string: the store is the
/// merchant of record and prices every market in its own currency
/// (`docs/Scenova/monetization.md` → "Payment & Billing"), so the client never
/// formats or converts one itself.
@immutable
class StoreProduct {
  const StoreProduct({
    required this.id,
    required this.displayPrice,
    this.displayPeriod,
  });

  /// The store's product identifier, reported on the purchase events
  /// (`EVT-019`–`EVT-021`).
  final String id;

  /// The store's localized price string, e.g. `$6.99`.
  final String displayPrice;

  /// The billing period for a subscription (`month`, `year`), or null for a
  /// one-time pack.
  final String? displayPeriod;
}

/// What the store can sell: the Pro subscription and the lookup top-up
/// (`docs/Scenova/monetization.md` → "Pricing Tiers").
@immutable
class StoreOffering {
  const StoreOffering({
    required this.proMonthly,
    required this.topUp,
    this.proAnnual,
    this.trialDays = 7,
    this.topUpLookups = 20,
  });

  /// The monthly Pro plan, the one the Paywall's primary action starts.
  final StoreProduct proMonthly;

  /// The annual Pro plan, shown beside the monthly price when the store offers
  /// one.
  final StoreProduct? proAnnual;

  /// The one-time lookup pack.
  final StoreProduct topUp;

  /// The free-trial length that comes with Pro at sign-up.
  final int trialDays;

  /// How many lookups the top-up pack adds to the current period.
  final int topUpLookups;
}

/// The store: the Pro subscription, its management, the top-up, and the prices
/// the reader is shown (`docs/Scenova/monetization.md` → "Pricing Tiers").
///
/// The store is the merchant of record, so every action here opens the store's
/// own surface and reports back what it resolved to. The concrete store wraps
/// RevenueCat (D-008); this seam is what the Account screen and the Paywall
/// drive.
abstract interface class PurchaseService {
  /// The products the store offers, with their localized prices, so the
  /// Paywall and the Account screen show what the reader would actually pay.
  /// Throws [StoreUnavailable] when the store cannot be reached.
  Future<StoreOffering> offerings();

  /// Starts the Pro subscription, including the 7-day trial at sign-up.
  Future<PurchaseOutcome> startPro();

  /// Buys the one-time top-up pack
  /// (`docs/Scenova/monetization.md` → "Lookup Top-Up").
  Future<PurchaseOutcome> buyTopUp();

  /// Opens the store's management for the reader's subscription.
  Future<PurchaseOutcome> managePlan();

  /// Restores a prior purchase to this account.
  Future<PurchaseOutcome> restore();
}

/// A scripted store for development and tests.
///
/// Each action's outcome is scripted so the Account screen's and the Paywall's
/// purchasing, purchase-failed, restore, and store-unreachable states can all be
/// viewed and tested without a store. The default offering mirrors the prices in
/// `docs/Scenova/monetization.md`; the live prices are the store's own.
class MockPurchaseService implements PurchaseService {
  MockPurchaseService({
    this.offering = _defaultOffering,
    this.startProOutcome = const PurchaseCompleted(),
    this.topUpOutcome = const PurchaseCompleted(),
    this.managePlanOutcome = const PurchaseDismissed(),
    this.restoreOutcome = const PurchaseCompleted(),
    this.offline = false,
    this.latency = Duration.zero,
    this.offeringLatency = Duration.zero,
  });

  /// The products and prices the store answers with.
  final StoreOffering offering;

  final PurchaseOutcome startProOutcome;
  final PurchaseOutcome topUpOutcome;
  final PurchaseOutcome managePlanOutcome;
  final PurchaseOutcome restoreOutcome;

  /// When set, every action reports the store as unreachable.
  final bool offline;

  /// Simulated time the store sheet is open, so the purchasing state is
  /// visible.
  final Duration latency;

  /// Simulated time the offering takes to load, so the Paywall's loading state
  /// is visible. Kept apart from [latency] so a frame can show the offering
  /// ready and a purchase in flight at once.
  final Duration offeringLatency;

  /// How many times each action has been taken.
  int offeringsCalls = 0;
  int startProCalls = 0;
  int topUpCalls = 0;
  int managePlanCalls = 0;
  int restoreCalls = 0;

  /// The default prices, mirroring `docs/Scenova/monetization.md`.
  static const StoreOffering _defaultOffering = StoreOffering(
    proMonthly: StoreProduct(
      id: 'pro.monthly',
      displayPrice: r'$6.99',
      displayPeriod: 'month',
    ),
    proAnnual: StoreProduct(
      id: 'pro.annual',
      displayPrice: r'$59.99',
      displayPeriod: 'year',
    ),
    topUp: StoreProduct(id: 'topup.20', displayPrice: r'$2.99'),
  );

  @override
  Future<StoreOffering> offerings() async {
    offeringsCalls++;
    if (offline) throw const StoreUnavailable();
    if (offeringLatency != Duration.zero) {
      await Future<void>.delayed(offeringLatency);
    }
    return offering;
  }

  @override
  Future<PurchaseOutcome> startPro() async {
    startProCalls++;
    if (offline) throw const StoreUnavailable();
    await _wait();
    return startProOutcome;
  }

  @override
  Future<PurchaseOutcome> buyTopUp() async {
    topUpCalls++;
    if (offline) throw const StoreUnavailable();
    await _wait();
    return topUpOutcome;
  }

  @override
  Future<PurchaseOutcome> managePlan() async {
    managePlanCalls++;
    if (offline) throw const StoreUnavailable();
    await _wait();
    return managePlanOutcome;
  }

  @override
  Future<PurchaseOutcome> restore() async {
    restoreCalls++;
    if (offline) throw const StoreUnavailable();
    await _wait();
    return restoreOutcome;
  }

  Future<void> _wait() => latency == Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(latency);
}
