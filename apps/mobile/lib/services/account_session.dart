import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_client.dart';

/// Why a sign-in did not go through.
///
/// The identity provider's own error codes are mapped onto these, so the
/// presentation layer never reads a provider code and a change of provider does
/// not change what the reader is told (`FEAT-013`).
enum AccountSignInFailure {
  /// The email and password do not match an account. An address that holds no
  /// account reads the same way, so the app never says whether an address is
  /// known.
  credentials,

  /// The address is not a usable email address.
  email,

  /// The password does not meet the provider's policy.
  password,

  /// The provider could not be reached, or refused the attempt for now.
  unavailable,
}

/// A sign-in that did not go through, carrying the reason to show the reader.
class AccountSignInException implements Exception {
  const AccountSignInException(this.reason);

  final AccountSignInFailure reason;

  @override
  String toString() => 'AccountSignInException($reason)';
}

/// The reader's account session: signing in and out (`FEAT-013`).
///
/// Sign-in is with an email address and a password (D-032); this seam is where
/// the Account screen asks for it. Before sign-in the reader holds a
/// device-local guest allowance, and the entitlement follows the account once
/// they sign in (`docs/Scenova/user-flow.md` → Flow 5, Alternate Path C).
abstract interface class AccountSession {
  /// Signs the reader in with their email and password.
  ///
  /// A reader who has been reading on this device holds an anonymous identity
  /// that owns the lookups already made; that identity is upgraded to the
  /// account rather than replaced, so those lookups still resolve to the same
  /// caller (`C-002`, D-011).
  ///
  /// Throws [AccountSignInException] when the attempt does not go through.
  Future<void> signIn({required String email, required String password});

  /// Ends the account session on this device. The device's own history and
  /// saved clips stay (`FEAT-009`).
  Future<void> signOut();

  /// Whether the reader holds an account rather than an anonymous identity.
  ///
  /// The account-backed preferences (`C-020`) are written only for a reader who
  /// holds an account; before sign-in they are held on the device alone.
  Future<bool> hasAccount();
}

/// An in-memory session for development and tests.
///
/// It stands in for the identity provider so the Account screen's signed-in and
/// signed-out states are exercisable without one, and so the sign-in sheet's
/// submitting and failure states can be driven from a script.
class DevelopmentAccountSession implements AccountSession {
  DevelopmentAccountSession({
    this.signedIn = false,
    this.latency = Duration.zero,
    this.failure,
  });

  /// Whether the reader currently holds an account.
  bool signedIn;

  /// How long a sign-in takes, so the submitting state is visible in a
  /// development run.
  final Duration latency;

  /// The failure a sign-in answers with instead of signing in.
  AccountSignInException? failure;

  /// How many times each action has been taken.
  int signInCalls = 0;
  int signOutCalls = 0;

  /// The credentials the last attempt carried.
  String? lastEmail;
  String? lastPassword;

  @override
  Future<void> signIn({required String email, required String password}) async {
    signInCalls++;
    lastEmail = email;
    lastPassword = password;
    if (latency != Duration.zero) await Future<void>.delayed(latency);
    final refused = failure;
    if (refused != null) throw refused;
    signedIn = true;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    signedIn = false;
  }

  @override
  Future<bool> hasAccount() async => signedIn;
}

/// The account session through Firebase Authentication (D-005, D-032).
///
/// Sign-in is the email/password provider, which the docs fix as the only
/// method (D-032): a reader with no third-party sign-in to offer. The reader's
/// anonymous identity is upgraded in place with the credentials they give, so
/// the subject the gateway sees is the one the lookups already belong to
/// (`C-002`); an address that already holds an account signs into it instead,
/// and the device's own history and saved clips stay.
class FirebaseAccountSession implements AccountSession {
  FirebaseAccountSession({
    FirebaseAuth? authOverride,
    Future<FirebaseApp> Function()? initialize,
  }) : _auth = authOverride,
       _initialize = initialize ?? initializeFirebaseClient;

  FirebaseAuth? _auth;
  final Future<FirebaseApp> Function() _initialize;

  @override
  Future<void> signIn({required String email, required String password}) async {
    final auth = await _authInstance();
    try {
      final user = auth.currentUser;
      if (user != null && user.isAnonymous) {
        try {
          await user.linkWithCredential(
            EmailAuthProvider.credential(email: email, password: password),
          );
          return;
        } on FirebaseAuthException catch (error) {
          if (!_addressAlreadyHasAccount(error.code)) rethrow;
          // The address belongs to an account already; the reader is signed
          // into it, and the anonymous identity it replaces is dropped.
        }
      }
      await auth.signInWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (error) {
      throw AccountSignInException(failureFor(error.code));
    }
  }

  @override
  Future<void> signOut() async {
    await (await _authInstance()).signOut();
  }

  @override
  Future<bool> hasAccount() async =>
      (await _authInstance()).currentUser?.isAnonymous == false;

  /// The reason to show for a provider error code.
  ///
  /// A project with email enumeration protection answers an unknown address and
  /// a wrong password with the same code, and the client keeps that reading
  /// either way: it never says whether an address holds an account.
  @visibleForTesting
  static AccountSignInFailure failureFor(String code) {
    return switch (code) {
      'invalid-credential' ||
      'INVALID_LOGIN_CREDENTIALS' ||
      'user-not-found' ||
      'wrong-password' ||
      'user-disabled' => AccountSignInFailure.credentials,
      'invalid-email' => AccountSignInFailure.email,
      'weak-password' => AccountSignInFailure.password,
      _ => AccountSignInFailure.unavailable,
    };
  }

  /// Whether a failed link means the address is already taken by an account.
  static bool _addressAlreadyHasAccount(String code) =>
      code == 'email-already-in-use' || code == 'credential-already-in-use';

  Future<FirebaseAuth> _authInstance() async {
    final existing = _auth;
    if (existing != null) return existing;
    await _initialize();
    return _auth = FirebaseAuth.instance;
  }
}
