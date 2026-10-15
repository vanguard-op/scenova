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

/// The store: the Pro subscription, its management, and restore
/// (`docs/Scenova/monetization.md` → "Pricing Tiers").
///
/// The store is the merchant of record, so every action here opens the store's
/// own surface and reports back what it resolved to. The concrete store wraps
/// RevenueCat (D-008); this seam is what the Account screen drives.
abstract interface class PurchaseService {
  /// Starts the Pro subscription, including the 7-day trial at sign-up.
  Future<PurchaseOutcome> startPro();

  /// Opens the store's management for the reader's subscription.
  Future<PurchaseOutcome> managePlan();

  /// Restores a prior purchase to this account.
  Future<PurchaseOutcome> restore();
}

/// A scripted store for development and tests.
///
/// Each action's outcome is scripted so the Account screen's purchasing,
/// purchase-failed, restore, and store-unreachable states can all be viewed and
/// tested without a store.
class MockPurchaseService implements PurchaseService {
  MockPurchaseService({
    this.startProOutcome = const PurchaseCompleted(),
    this.managePlanOutcome = const PurchaseDismissed(),
    this.restoreOutcome = const PurchaseCompleted(),
    this.offline = false,
    this.latency = Duration.zero,
  });

  final PurchaseOutcome startProOutcome;
  final PurchaseOutcome managePlanOutcome;
  final PurchaseOutcome restoreOutcome;

  /// When set, every action reports the store as unreachable.
  final bool offline;

  /// Simulated time the store sheet is open, so the purchasing state is
  /// visible.
  final Duration latency;

  /// How many times each action has been taken.
  int startProCalls = 0;
  int managePlanCalls = 0;
  int restoreCalls = 0;

  @override
  Future<PurchaseOutcome> startPro() async {
    startProCalls++;
    if (offline) throw const StoreUnavailable();
    await _wait();
    return startProOutcome;
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
