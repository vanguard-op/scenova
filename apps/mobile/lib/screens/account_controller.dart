import 'package:flutter/foundation.dart';

import '../models/entitlement.dart';
import '../services/account_api.dart';
import '../services/account_preferences_sync.dart';
import '../services/account_session.dart';
import '../services/clip_store.dart';
import '../services/entitlement_api.dart';
import '../services/entitlement_provider.dart';
import '../services/history_store.dart';
import '../services/poster_frame_store.dart';
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

/// The outcome of a deletion the reader confirmed (`C-021`).
sealed class AccountDeletionOutcome {
  const AccountDeletionOutcome();
}

/// The account and its entitlement were removed and the reader is signed out.
final class AccountDeleted extends AccountDeletionOutcome {
  const AccountDeleted();
}

/// The deletion did not complete, so the account is unchanged. [message] is the
/// reader-facing reason the confirmation offers a retry against.
final class AccountDeletionFailed extends AccountDeletionOutcome {
  const AccountDeletionFailed(this.message);

  final String message;
}

/// Owns the Account screen's state (`docs/Scenova/screens/08-account.md`).
///
/// It reads the entitlement from the service (`C-018`), drives the store's
/// purchase, management, and restore through [PurchaseService], signs in and
/// out through [AccountSession], and deletes the account through [AccountApi]
/// (`C-021`). A purchase the store could not complete leaves the plan on screen
/// unchanged and carries a reader-facing message and a retry.
class AccountController extends ChangeNotifier {
  AccountController({
    required this.entitlements,
    required this.session,
    required this.purchases,
    required this.plan,
    required this.accountApi,
    required this.history,
    required this.clips,
    required this.posterFrames,
    this.accountPreferences,
  });

  final EntitlementApi entitlements;
  final AccountSession session;
  final PurchaseService purchases;

  /// The account store, for the reader's own deletion (`C-021`).
  final AccountApi accountApi;

  /// The device's lookup history, which a confirmed deletion clears.
  final HistoryStore history;

  /// The clips the device keeps beside the history, cleared with it.
  final ClipStore clips;

  /// The poster frames the device derives for the history, cleared with it.
  final PosterFrameStore posterFrames;

  /// Reads the account's stored consent and selection-action language onto this
  /// device when the reader signs in (`C-022`). Absent in a bare controller
  /// test, where there is no account store to read.
  final AccountPreferencesSync? accountPreferences;

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

  /// Whether the reader holds a plan the store granted, so the deletion
  /// confirmation says billing continues there until the subscription is
  /// cancelled.
  ///
  /// The plan the entitlement service reports is the one the store set
  /// (`C-019`): Pro and its trial are store subscriptions, while a Free reader
  /// holds none. The product never cancels a subscription itself, so the
  /// reader is told to cancel it in the store (`C-021`).
  bool get hasActiveSubscription {
    final entitlement = _entitlement;
    return entitlement != null && (entitlement.isPro || entitlement.isTrial);
  }

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

  /// Takes up the account the reader has just signed into, then reads the plan
  /// and allowance it holds.
  ///
  /// The sign-in itself belongs to the sign-in sheet, which hands the reader's
  /// credentials to the identity provider (`FEAT-013`, D-032); this brings the
  /// account's own choices onto the device (`C-022`) and re-reads what the
  /// account now holds, so the consent, the label language, and the plan take
  /// effect at once.
  Future<void> signedIn() async {
    _actionError = null;
    _retry = null;
    await accountPreferences?.adopt();
    await _readEntitlement();
    await plan.refresh();
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

  /// Deletes the reader's account and its entitlement (`C-021`).
  ///
  /// On confirmation the account is removed, the reader's device history — the
  /// saved lookups, their clips, and their poster frames — is cleared, and the
  /// reader is signed out; the shared library is untouched
  /// (`docs/Scenova/user-flow.md` → Flow 8). The plan cache is dropped so the
  /// device-local guest allowance applies, and the screen returns to its
  /// signed-out state.
  ///
  /// A deletion that does not complete leaves the account unchanged and
  /// resolves with the reader-facing reason, so the confirmation can offer a
  /// retry.
  Future<AccountDeletionOutcome> deleteAccount() async {
    _beginAction();
    try {
      final deleted = await accountApi.deleteAccount();
      if (!deleted) return const AccountDeletionFailed(_deleteFailed);
      // The device's own copy is cleared after the account is gone, so a
      // deletion that did not complete leaves the reader's history intact.
      await _clearDeviceHistory();
      await session.signOut();
      _entitlement = Entitlement.signedOut;
      _status = AccountStatus.signedOut;
      // The gates fall back to the signed-out plan at once, so the device-local
      // guest allowance applies without waiting on the service (`FEAT-013`).
      plan.clear();
      return const AccountDeleted();
    } on AccountApiException catch (error) {
      // The account service could not be reached, or the caller no longer holds
      // an account: the deletion did not complete and the reader can retry
      // (`docs/Scenova/screens/08-account.md` → Edge Cases).
      return AccountDeletionFailed(
        error.isUnavailable ? _deleteUnreachable : _deleteFailed,
      );
    } on Object {
      return const AccountDeletionFailed(_deleteFailed);
    } finally {
      _endAction();
    }
  }

  /// The reader-facing reason a deletion did not complete.
  static const String _deleteFailed =
      'Your account could not be deleted. Try again.';

  /// The same, for a device or account store that could not be reached.
  static const String _deleteUnreachable =
      'Your account could not be deleted. Check your connection and try again.';

  /// Removes the lookups, clips, and poster frames the device holds.
  ///
  /// Best-effort: the account is already gone by the time this runs, so a
  /// device that refuses its own write never turns a completed deletion into a
  /// failure the reader is told about.
  Future<void> _clearDeviceHistory() async {
    try {
      await history.clear();
      await clips.clear();
      await posterFrames.clear();
    } on Object {
      // The reader is still signed out; the local copy is the device's own.
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
