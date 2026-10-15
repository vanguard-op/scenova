import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/action_label.dart';
import '../services/account_api.dart';
import '../services/app_services.dart';

/// What the Preferences screen is showing.
enum PreferencesStatus {
  /// The settings are being read.
  loading,

  /// The setting rows are on screen.
  ready,
}

/// Owns the Preferences screen's state (`docs/Scenova/screens/07-preferences.md`).
///
/// Every change is written at once and takes effect immediately: the clip
/// behaviour lands in the reader's settings, and the two account-backed choices
/// — consent for model processing and the selection-action language — are also
/// written to the reader's account (`C-020`) when they hold one, so the choice
/// follows them to a new device. Signed out, the device copy is the whole story.
class PreferencesController extends ChangeNotifier {
  PreferencesController({required this.services}) {
    // The screen reads the clip behaviour from the shared settings, so a change
    // made on another surface is reflected here too.
    services.settings.addListener(_onSettingsChanged);
    // A choice that could not reach the account is retried when a connection
    // returns, so the reader does not have to make it twice.
    _connectivity = services.connectivity.changes.listen(_onConnectivity);
  }

  final ScenovaServices services;

  PreferencesStatus _status = PreferencesStatus.loading;
  int _historyCount = 0;
  bool _hasAccount = false;
  bool _clearing = false;
  String? _accountError;
  ({bool? consentModelProcessing, String? locale})? _pendingAccountWrite;
  StreamSubscription<bool>? _connectivity;
  bool _disposed = false;

  PreferencesStatus get status => _status;

  /// Whether the reader holds an account, so the account-backed choices are
  /// written to it as well as to the device.
  bool get hasAccount => _hasAccount;

  /// How many lookups the device is holding.
  int get historyCount => _historyCount;

  /// Whether history is being removed, so the clear row shows a spinner
  /// (`docs/Scenova/screens/07-preferences.md` → "Clearing history").
  bool get clearing => _clearing;

  /// A reader-facing note when an account-backed choice could not reach the
  /// account. The choice itself is already stored and in effect on the device.
  String? get accountError => _accountError;

  /// Whether a failed account write can be retried.
  bool get canRetryAccountSync => _accountError != null && _hasAccount;

  // The clip behaviour, read straight from the reader's settings.
  bool get soundOn => services.settings.soundOn;

  /// The effective reduce-motion value: the platform's setting wins when it is
  /// on (`FEAT-012` → Edge Cases).
  bool get reduceMotion => services.settings.reduceMotion;

  /// Whether the device's own reduce-motion setting is forcing motion down, so
  /// the app preference cannot turn it back up.
  bool get reduceMotionLockedByPlatform =>
      services.settings.platformReduceMotion;

  bool get consentModelProcessing => services.settings.consentModelProcessing;

  /// The chosen selection-action language, resolved against the offered set.
  ActionLabelLanguage get actionLabelLanguage =>
      services.settings.actionLabelLanguage;

  /// Reads the device's history size and whether the reader holds an account.
  ///
  /// The settings themselves are already loaded, so the rows are readable
  /// throughout; the count and the account state are what this waits on.
  Future<void> load() async {
    _status = PreferencesStatus.loading;
    _notify();
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        services.historyStore.all(),
        services.accountSession.hasAccount(),
      ]);
      if (_disposed) return;
      _historyCount = (results[0] as List<Object?>).length;
      _hasAccount = results[1] as bool;
    } on Object {
      // The history count and the account state are best-effort; the reader's
      // local settings are readable regardless.
      if (_disposed) return;
    }
    _status = PreferencesStatus.ready;
    _notify();
  }

  /// Clips carry sound, or stay muted. Written at once (`FEAT-012`).
  void setSound(bool value) => services.settings.soundOn = value;

  /// Reduces motion, holding a clip on a still frame. The device's own
  /// reduce-motion setting overrides this (`FEAT-012` → Edge Cases).
  void setReduceMotion(bool value) {
    if (services.settings.platformReduceMotion) return;
    services.settings.reduceMotionOverride = value;
  }

  /// The reader's consent for model processing.
  ///
  /// Generation is enabled or disabled at once and the choice is stored; a
  /// signed-in reader's choice is also written to their account (`C-020`).
  Future<void> setConsent(bool value) async {
    services.settings.consentModelProcessing = value;
    services.analytics.consentChanged(consent: value);
    await _writeToAccount(consentModelProcessing: value);
  }

  /// The language the selection-action label is shown in.
  Future<void> setLanguage(String locale) async {
    services.settings.actionLabelLocale = locale;
    await _writeToAccount(locale: locale);
  }

  /// Removes every saved lookup and its clip from the device.
  ///
  /// The queues of reports and ratings still waiting for a connection are not
  /// history, so they are left alone (`FEAT-012` → Edge Cases). Resolves true
  /// when the device copy was removed.
  Future<bool> clearHistory() async {
    if (_clearing) return false;
    _clearing = true;
    _notify();
    var cleared = true;
    try {
      await services.historyStore.clear();
      await services.clips.clear();
      await services.posterFrames.clear();
      _historyCount = 0;
    } on Object {
      cleared = false;
    }
    _clearing = false;
    _notify();
    return cleared;
  }

  /// Retries an account-backed choice that could not reach the account.
  Future<void> retryAccountSync() => _flushAccountWrite();

  /// Writes an account-backed choice to the reader's account, when they hold
  /// one. Signed out, the device copy is the whole story.
  Future<void> _writeToAccount({
    bool? consentModelProcessing,
    String? locale,
  }) async {
    if (!_hasAccount) return;
    _pendingAccountWrite = (
      consentModelProcessing: consentModelProcessing,
      locale: locale,
    );
    _accountError = null;
    _notify();
    await _flushAccountWrite();
  }

  Future<void> _flushAccountWrite() async {
    final pending = _pendingAccountWrite;
    if (pending == null || !_hasAccount) return;
    if (!services.connectivity.isOnline) {
      // The choice already applies on the device; it reaches the account when
      // the connection returns.
      _accountError =
          'Saved on this device. It will reach your account when '
          'you are back online.';
      _notify();
      return;
    }
    try {
      await services.accountApi.update(
        consentModelProcessing: pending.consentModelProcessing,
        locale: pending.locale,
      );
      if (_disposed) return;
      _pendingAccountWrite = null;
      _accountError = null;
    } on AccountApiException catch (error) {
      if (_disposed) return;
      if (error.isSignedOut) {
        // The token holds no account after all; the device copy stands alone.
        _hasAccount = false;
        _pendingAccountWrite = null;
        _accountError = null;
      } else {
        _accountError =
            'Saved on this device. Your account could not be '
            'reached.';
      }
    } on Object {
      if (_disposed) return;
      _accountError =
          'Saved on this device. Your account could not be reached.';
    }
    _notify();
  }

  void _onConnectivity(bool online) {
    if (!online || _pendingAccountWrite == null) return;
    unawaited(_flushAccountWrite());
  }

  void _onSettingsChanged() => _notify();

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    services.settings.removeListener(_onSettingsChanged);
    unawaited(_connectivity?.cancel());
    super.dispose();
  }
}
