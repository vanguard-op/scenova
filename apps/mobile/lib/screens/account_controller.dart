import 'package:flutter/foundation.dart';

import '../models/entitlement.dart';
import '../services/account_session.dart';
import '../services/entitlement_api.dart';
import '../services/entitlement_provider.dart';
import '../services/purchase_service.dart';

/// What the Account screen is showing.
enum AccountStatus {
  /// The entitlement is being read.
  loading,

  /// The reader holds no account; the screen asks them to sign in.
  signedOut,

  /// The plan and allowance are on screen.
  ready,

  /// The entitlement could not be read.
  error,
}

/// Owns the Account screen's state (`docs/Scenova/screens/08-account.md`).
///
/// It reads the entitlement from the service (`C-018`), drives the store's
/// purchase, management, and restore through [PurchaseService], and signs in
/// and out through [AccountSession]. A purchase the store could not complete
/// leaves the plan on screen unchanged and carries a reader-facing message and
/// a retry.
class AccountController extends ChangeNotifier {
  AccountController({
    required this.entitlements,
    required this.session,
    required this.purchases,
    required this.plan,
  });

  final EntitlementApi entitlements;
  final AccountSession session;
  final PurchaseService purchases;

  /// The reader's plan cache, shared with the tier gates (`FEAT-013`): a
  /// purchase or a sign-in/sign-out re-reads it so the gates the plan puts on
  /// the device take effect at once.
  final EntitlementProvider plan;

  AccountStatus _status = AccountStatus.loading;
  Entitlement? _entitlement;
  bool _busy = false;
  bool _purchasing = false;
  String? _actionError;
  Future<void> Function()? _retry;
  bool _disposed = false;

  AccountStatus get status => _status;

  /// The plan and allowance on screen, once they have loaded.
  Entitlement? get entitlement => _entitlement;

  /// Whether an account action is in flight; every action is disabled while it
  /// is.
  bool get busy => _busy;

  /// Whether a store purchase is in flight, so the primary action shows a
  /// spinner (`docs/Scenova/screens/08-account.md` → "Purchasing").
  bool get purchasing => _purchasing;

  /// The inline message beside the actions, when a purchase, restore, sign-in,
  /// or sign-out did not go through.
  String? get actionError => _actionError;

  /// Whether the reader can retry the last action that failed.
  bool get canRetry => _retry != null;

  /// Reads the entitlement (`C-018`).
  ///
  /// A 401 means the reader holds no account, which is the signed-out state
  /// rather than an error; anything else leaves the screen on its error state
  /// with a retry.
  Future<void> load() async {
    _status = AccountStatus.loading;
    _actionError = null;
    _retry = null;
    _notify();
    await _readEntitlement();
  }

  /// Starts the identity provider's sign-in flow, then reads the entitlement.
  Future<void> signIn() async {
    if (_busy) return;
    _beginAction();
    try {
      await session.signIn();
      await _readEntitlement();
      await plan.refresh();
    } on AccountSignInUnavailable {
      _fail('Signing in is not available in this build yet.');
    } on Object {
      _fail('Signing in did not work. Try again.');
    } finally {
      _endAction();
    }
  }

  /// Ends the account session on this device and returns to the signed-out
  /// state. The device's own history and saved clips stay.
  Future<void> signOut() async {
    if (_busy) return;
    _beginAction();
    try {
      await session.signOut();
      _entitlement = Entitlement.signedOut;
      _status = AccountStatus.signedOut;
      // The gates fall back to the signed-out plan before the service confirms
      // it, so a reader who signs out with no connection is not left with the
      // paid gates (`FEAT-013`).
      plan.clear();
    } on Object {
      _fail('Signing out did not work. Try again.');
    } finally {
      _endAction();
    }
  }

  /// Starts the Pro subscription through the store.
  Future<void> startPro() {
    return _runStore(purchases.startPro, retry: startPro);
  }

  /// Opens the store's management for the reader's plan.
  ///
  /// The reader may cancel or change the plan while they are there, so the
  /// entitlement is re-read on return.
  Future<void> managePlan() {
    return _runStore(
      purchases.managePlan,
      refreshOnDismiss: true,
      retry: managePlan,
    );
  }

  /// Restores a prior purchase to this account.
  Future<void> restorePurchases() {
    return _runStore(
      purchases.restore,
      retry: restorePurchases,
      nothingToRestore: 'No purchases to restore.',
    );
  }

  /// Re-runs the action that last failed.
  Future<void> retry() async {
    final action = _retry;
    if (action == null) return;
    await action();
  }

  Future<void> _runStore(
    Future<PurchaseOutcome> Function() action, {
    bool refreshOnDismiss = false,
    String? nothingToRestore,
    required Future<void> Function() retry,
  }) async {
    if (_busy) return;
    _beginAction(purchasing: true);
    try {
      final outcome = await action();
      switch (outcome) {
        case PurchaseCompleted():
          await _readEntitlement();
          await plan.refresh();
        case PurchaseDismissed():
          if (refreshOnDismiss) {
            await _readEntitlement();
            await plan.refresh();
          }
        case PurchaseNothingToRestore():
          _fail(nothingToRestore ?? 'No purchases to restore.');
        case PurchaseFailed(:final message):
          _fail(message);
      }
    } on StoreUnavailable {
      // The store could not be reached: the reader is told and the current plan
      // stays unchanged (`docs/Scenova/screens/08-account.md` → Edge Cases).
      _fail('The store is not reachable right now. Your plan has not changed.');
    } on Object {
      _fail('The purchase did not go through. Try again.');
    } finally {
      _endAction(retry: retry);
    }
  }

  /// Re-reads the entitlement without flashing the loading state.
  Future<void> _readEntitlement() async {
    try {
      final entitlement = await entitlements.fetch();
      if (_disposed) return;
      _entitlement = entitlement;
      _status = entitlement.signedIn
          ? AccountStatus.ready
          : AccountStatus.signedOut;
    } on EntitlementApiException catch (error) {
      if (_disposed) return;
      if (error.isSignedOut) {
        _entitlement = Entitlement.signedOut;
        _status = AccountStatus.signedOut;
      } else {
        _status = AccountStatus.error;
      }
    } on Object {
      if (_disposed) return;
      _status = AccountStatus.error;
    }
    _notify();
  }

  void _beginAction({bool purchasing = false}) {
    _actionError = null;
    _retry = null;
    _busy = true;
    _purchasing = purchasing;
    _notify();
  }

  void _endAction({Future<void> Function()? retry}) {
    _busy = false;
    _purchasing = false;
    if (_actionError != null) _retry = retry;
    _notify();
  }

  void _fail(String message) => _actionError = message;

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
