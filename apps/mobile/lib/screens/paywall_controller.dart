import 'package:flutter/foundation.dart';

import '../models/entitlement.dart';
import '../services/analytics.dart';
import '../services/entitlement_provider.dart';
import '../services/purchase_service.dart';

/// What came of the Paywall sheet.
///
/// A successful purchase resolves to one of these so the scope that opened the
/// sheet can continue the lookup; a dismissal resolves to null
/// (`docs/Scenova/screens/04-paywall.md` → Data Flow).
enum PaywallOutcome { proStarted, topUpBought }

/// Which purchase is in flight, so the sheet shows its spinner on the control
/// the reader pressed.
enum PaywallAction { startPro, topUp }

/// What the Paywall sheet is showing
/// (`docs/Scenova/screens/04-paywall.md` → States).
enum PaywallStatus {
  /// The store's products and prices are being read.
  loading,

  /// The meter and the options are on screen.
  ready,

  /// The reader holds no account, so the sheet asks them to sign in first.
  signedOut,

  /// The store could not be reached: the reader is told and can keep reading
  /// without a clip.
  storeUnavailable,

  /// The offering could not be read for another reason.
  error,
}

/// Owns the Paywall sheet's state
/// (`docs/Scenova/screens/04-paywall.md`; `FEAT-013`).
///
/// It reads the store's products and prices, drives the Pro subscription and the
/// top-up through [PurchaseService], and asks [AccountSession] to sign the
/// reader in when they hold no account. A purchase the store could not complete
/// leaves the reader on their current plan and carries a reader-facing message
/// and a retry.
class PaywallController extends ChangeNotifier {
  PaywallController({
    required Entitlement entitlement,
    required this.purchases,
    required this.plan,
    required this.analytics,
  }) : _entitlement = entitlement,
       _signedIn = entitlement.signedIn;

  final PurchaseService purchases;

  /// The reader's plan cache, shared with the tier gates (`FEAT-013`): a
  /// completed purchase re-reads it, so the allowance and the clip-retention
  /// gate take effect on the lookup that follows, and a sign-in reads back the
  /// plan the account holds.
  final EntitlementProvider plan;

  final AnalyticsClient analytics;

  Entitlement _entitlement;
  bool _signedIn;
  PaywallStatus _status = PaywallStatus.loading;
  StoreOffering? _offering;
  PaywallAction? _purchasing;
  String? _actionError;
  PaywallAction? _retryAction;
  bool _disposed = false;

  /// The reader's plan and the lookups they have spent, for the meter.
  Entitlement get entitlement => _entitlement;

  /// Whether the reader holds an account. It starts from the entitlement and
  /// turns true once the reader signs in from the sheet.
  bool get holdsAccount => _signedIn;

  PaywallStatus get status => _status;

  /// The store's products and prices, once they have loaded.
  StoreOffering? get offering => _offering;

  /// The purchase in flight, or null.
  PaywallAction? get purchasing => _purchasing;

  /// Whether a purchase is in flight; every action is disabled while it is.
  bool get busy => _purchasing != null;

  /// The inline message shown when a purchase did not go through.
  String? get actionError => _actionError;

  /// Whether the reader can retry the action that last failed.
  bool get canRetry => _retryAction != null;

  /// The reader already holds Pro or is inside the trial, so the Pro offer is
  /// not shown again and no second charge is started
  /// (`docs/Scenova/screens/04-paywall.md` → Edge Cases). The top-up stays
  /// available, because a Pro reader whose 50 lookups are spent buys one
  /// (`docs/Scenova/monetization.md` → "Pro Tier").
  bool get alreadyPro => _entitlement.isPro || _entitlement.isTrial;

  /// The plan is being removed — a refund, or a subscription that lapsed — so
  /// the sheet shows the current plan and starts no new charge
  /// (`docs/Scenova/screens/04-paywall.md` → Edge Cases).
  bool get refundInProgress => _entitlement.status == EntitlementStatus.expired;

  /// Reads the store's offering, or settles on the state that explains why it
  /// could not be read.
  Future<void> load() async {
    _actionError = null;
    _retryAction = null;
    _notify();
    analytics.paywallViewed(
      plan: _entitlement.tier.name,
      lookupsUsed: _entitlement.lookupsUsed ?? 0,
    );
    if (!_signedIn) {
      _status = PaywallStatus.signedOut;
      _notify();
      return;
    }
    await _readOffering();
  }

  /// Starts the Pro subscription, including the trial.
  Future<PaywallOutcome?> startPro() =>
      _purchase(PaywallAction.startPro, PaywallOutcome.proStarted);

  /// Buys the one-time top-up pack.
  Future<PaywallOutcome?> buyTopUp() =>
      _purchase(PaywallAction.topUp, PaywallOutcome.topUpBought);

  /// Re-runs the purchase that last failed.
  Future<PaywallOutcome?> retry() async {
    return switch (_retryAction) {
      PaywallAction.startPro => startPro(),
      PaywallAction.topUp => buyTopUp(),
      null => null,
    };
  }

  /// Takes up the account the reader has just signed into, then reads the plan
  /// it holds and the store's offering, so the options appear.
  ///
  /// The sign-in itself belongs to the sign-in sheet, which hands the reader's
  /// credentials to the identity provider (`FEAT-013`, D-032).
  Future<void> signedIn() async {
    if (busy) return;
    _actionError = null;
    _retryAction = null;
    _signedIn = true;
    _notify();
    // The plan follows the account, so the meter reads what the account holds
    // rather than what the device showed before sign-in (`FEAT-013`).
    await plan.refresh();
    _entitlement = await plan.current();
    await _readOffering();
  }

  /// Reads the store's offering, or settles on the state that explains why it
  /// could not be read.
  Future<void> _readOffering() async {
    _status = PaywallStatus.loading;
    _notify();
    try {
      final offering = await purchases.offerings();
      if (_disposed) return;
      _offering = offering;
      _status = PaywallStatus.ready;
    } on StoreUnavailable {
      if (_disposed) return;
      _status = PaywallStatus.storeUnavailable;
    } on Object {
      if (_disposed) return;
      _status = PaywallStatus.error;
    }
    _notify();
  }

  Future<PaywallOutcome?> _purchase(
    PaywallAction action,
    PaywallOutcome success,
  ) async {
    if (busy) return null;
    final offering = _offering;
    if (offering == null) return null;
    final product = action == PaywallAction.startPro
        ? offering.proMonthly
        : offering.topUp;
    final kind = action == PaywallAction.startPro ? 'subscription' : 'topup';

    _actionError = null;
    _retryAction = null;
    _purchasing = action;
    _notify();
    analytics.purchaseStarted(productId: product.id, productKind: kind);
    try {
      final outcome = action == PaywallAction.startPro
          ? await purchases.startPro()
          : await purchases.buyTopUp();
      if (_disposed) return null;
      switch (outcome) {
        case PurchaseCompleted():
          analytics.purchaseCompleted(productId: product.id, productKind: kind);
          // The plan the reader just bought is read back, so the retried lookup
          // spends the new allowance and keeps its clip (`FEAT-013`).
          await plan.refresh();
          return success;
        case PurchaseDismissed():
          // The reader backed out of the store sheet; the plan is unchanged and
          // nothing is said.
          return null;
        case PurchaseNothingToRestore():
          _fail('No purchases to restore.', action, product, kind);
          return null;
        case PurchaseFailed(:final message):
          _fail(message, action, product, kind);
          return null;
      }
    } on StoreUnavailable {
      // The store could not be reached: the reader is told and can keep reading
      // without a clip (`docs/Scenova/screens/04-paywall.md` → Edge Cases).
      _fail(
        'The store is not reachable right now. You can keep reading without a '
        'clip.',
        action,
        product,
        kind,
        reason: 'store_unavailable',
      );
      return null;
    } on Object {
      _fail(
        'The purchase did not go through. Try again.',
        action,
        product,
        kind,
        reason: 'failed',
      );
      return null;
    } finally {
      _purchasing = null;
      _notify();
    }
  }

  void _fail(
    String message,
    PaywallAction action,
    StoreProduct product,
    String kind, {
    String reason = 'declined',
  }) {
    _actionError = message;
    _retryAction = action;
    analytics.purchaseFailed(productId: product.id, reason: reason);
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
