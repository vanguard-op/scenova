import 'package:flutter/foundation.dart';

import '../services/account_session.dart';
import '../services/connectivity.dart';

/// Owns the sign-in form's state (`FEAT-013`; `docs/Scenova/screens/08-account.md`
/// → "Signed out").
///
/// The reader's email and password are read here, checked, and handed to the
/// identity provider through [AccountSession]. A failed attempt leaves the form
/// as the reader typed it with one reader-facing message; a reader who is
/// offline is told before the attempt is made, since the provider cannot be
/// reached from here.
class SignInController extends ChangeNotifier {
  SignInController({required this.session, required this.connectivity});

  final AccountSession session;
  final ConnectivityMonitor connectivity;

  bool _submitting = false;
  String? _emailError;
  String? _passwordError;
  String? _formError;
  bool _disposed = false;

  /// Whether a sign-in is in flight; the form is held still while it is.
  bool get submitting => _submitting;

  /// What is wrong with the email field, once the reader has submitted.
  String? get emailError => _emailError;

  /// What is wrong with the password field, once the reader has submitted.
  String? get passwordError => _passwordError;

  /// The message shown when the attempt itself did not go through.
  String? get formError => _formError;

  /// Checks the reader's input and signs them in.
  ///
  /// Resolves true once they hold an account. Every attempt clears the messages
  /// from the one before it, so a corrected field stops showing the old one.
  Future<bool> submit({required String email, required String password}) async {
    if (_submitting) return false;
    _formError = null;
    _emailError = _checkEmail(email);
    _passwordError = _checkPassword(password);
    if (_emailError != null || _passwordError != null) {
      _notify();
      return false;
    }
    if (!connectivity.isOnline) {
      _formError = 'You\'re offline. Sign in when you\'re back online.';
      _notify();
      return false;
    }
    _submitting = true;
    _notify();
    try {
      await session.signIn(email: email.trim(), password: password);
      return true;
    } on AccountSignInException catch (error) {
      if (_disposed) return false;
      _formError = _messageFor(error.reason);
      return false;
    } on Object {
      if (_disposed) return false;
      _formError = 'Signing in did not work. Try again.';
      return false;
    } finally {
      _submitting = false;
      _notify();
    }
  }

  /// Drops the messages from the attempt before this one.
  ///
  /// The reader correcting a field should not have to read the old message
  /// under it, so a change to either field clears both the field messages and
  /// the one from the attempt itself.
  void clearErrors() {
    if (_emailError == null && _passwordError == null && _formError == null) {
      return;
    }
    _emailError = null;
    _passwordError = null;
    _formError = null;
    _notify();
  }

  /// What the reader is told for a failure the provider reported.
  String _messageFor(AccountSignInFailure reason) => switch (reason) {
    AccountSignInFailure.credentials => 'That email and password don\'t match.',
    AccountSignInFailure.email => 'Check your email address.',
    AccountSignInFailure.password => 'That password is too short.',
    AccountSignInFailure.unavailable =>
      'Scenova could not be reached. Check your connection and try again.',
  };

  /// The address as the provider will read it, or the message to show.
  ///
  /// One `@`, something before it, and a dotted domain after it: enough to
  /// catch a slip without turning away an address the provider would accept.
  static String? _checkEmail(String email) {
    final address = email.trim();
    if (address.isEmpty) return 'Enter your email address.';
    final parts = address.split('@');
    if (parts.length != 2 || parts[0].isEmpty) {
      return 'Check your email address.';
    }
    final domain = parts[1];
    if (!domain.contains('.') ||
        domain.startsWith('.') ||
        domain.endsWith('.') ||
        domain.contains('..')) {
      return 'Check your email address.';
    }
    return null;
  }

  /// A password the provider can be asked about. Sign-in never imposes a
  /// length of its own, since the account already holds one.
  static String? _checkPassword(String password) =>
      password.isEmpty ? 'Enter your password.' : null;

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
