import '../models/action_label.dart';
import 'account_api.dart';
import 'account_session.dart';
import 'connectivity.dart';
import 'settings_controller.dart';

/// Brings the reader's account-backed choices onto the device (`C-022`).
///
/// Consent for model processing and the language of the selection-action label
/// are stored on the account once the reader signs in (`C-020`), so a device
/// that holds the account reads them back and applies them: the choices the
/// reader made elsewhere are in effect here too
/// (`FEAT-012` → Edge Cases: "the consent choice is stored on the account and
/// follows the reader to a new device; signed out, it is stored on the device").
///
/// A reader who is not signed in holds both on the device and never reaches the
/// account. A read that does not go through is silent: the device copy is
/// already in effect, and a background reconciliation must not interrupt the
/// reader.
///
/// [adopt] is called at the points where the account is known and no local
/// change is waiting to be written — a launch that opens already signed in, and
/// the moment a sign-in completes — so a read never races a choice the reader
/// has just made on this device. A change made while signed in is written
/// through as it is made (`C-020`).
class AccountPreferencesSync {
  AccountPreferencesSync({
    required this.api,
    required this.session,
    required this.settings,
    required this.connectivity,
  });

  /// The account store (`C-022`).
  final AccountApi api;

  /// The reader's account session: the account is read only for a reader who
  /// holds one.
  final AccountSession session;

  /// The reader's settings, where the account's choices are applied.
  final SettingsController settings;

  /// Whether the device has a connection.
  final ConnectivityMonitor connectivity;

  /// Reads the account's stored choices and applies them to the device.
  ///
  /// Resolves true when the account answered and its choices are in effect.
  /// Signed out, offline, or an account the store could not answer leaves the
  /// device copy as it is; the reader is never told, since nothing they were
  /// doing has failed.
  Future<bool> adopt() async {
    try {
      if (!connectivity.isOnline) return false;
      if (!await session.hasAccount()) return false;
      final account = await api.read();
      settings.consentModelProcessing = account.consentModelProcessing;
      // A language the catalogue does not offer reads as English, so the device
      // holds a language it can name and the label always has a reading
      // (`FEAT-012` → Edge Cases).
      settings.actionLabelLocale = ActionLabelLanguages.resolve(account.locale)
          .locale;
      return true;
    } on Object {
      // A token with no account after all, or an account store that could not
      // be reached: the device copy stands.
      return false;
    }
  }
}
