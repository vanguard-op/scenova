import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_client.dart';

/// The reader's account session: signing in and out (`FEAT-013`).
///
/// Sign-in itself is provided by the identity provider; this seam is where the
/// Account screen asks for it. Before sign-in the reader holds a device-local
/// guest allowance, and the entitlement follows the account once they sign in
/// (`docs/Scenova/user-flow.md` → Flow 5, Alternate Path C).
abstract interface class AccountSession {
  /// Starts the identity provider's sign-in flow and resolves once the reader
  /// holds an account. A flow the reader cancels resolves with no account; a
  /// flow that cannot start throws.
  Future<void> signIn();

  /// Ends the account session on this device. The device's own history and
  /// saved clips stay (`FEAT-009`).
  Future<void> signOut();

  /// Whether the reader holds an account rather than an anonymous identity.
  ///
  /// The account-backed preferences (`C-020`) are written only for a reader who
  /// holds an account; before sign-in they are held on the device alone.
  Future<bool> hasAccount();
}

/// Sign-in is not available on this build.
///
/// The docs name Firebase Authentication as the identity provider (D-005) but
/// do not fix the sign-in method, so the production flow is left for that
/// decision rather than invented here.
class AccountSignInUnavailable implements Exception {
  const AccountSignInUnavailable();

  @override
  String toString() => 'AccountSignInUnavailable';
}

/// An in-memory session for development and tests.
///
/// It stands in for the identity provider so the Account screen's signed-in and
/// signed-out states are exercisable without one.
class DevelopmentAccountSession implements AccountSession {
  DevelopmentAccountSession({this.signedIn = false});

  /// Whether the reader currently holds an account.
  bool signedIn;

  /// How many times each action has been taken.
  int signInCalls = 0;
  int signOutCalls = 0;

  @override
  Future<void> signIn() async {
    signInCalls++;
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

/// The account session through Firebase Authentication (D-005).
///
/// [signedIn] and [signOut] read and clear the platform session. The sign-in
/// flow is injected: the docs fix the provider but not the method, so the app
/// supplies the flow once that is chosen; until then sign-in reports
/// [AccountSignInUnavailable] rather than pretending to have an account.
class FirebaseAccountSession implements AccountSession {
  FirebaseAccountSession({
    FirebaseAuth? authOverride,
    Future<FirebaseApp> Function()? initialize,
    this.signInFlow,
  }) : _auth = authOverride,
       _initialize = initialize ?? initializeFirebaseClient;

  FirebaseAuth? _auth;
  final Future<FirebaseApp> Function() _initialize;

  /// The identity provider's sign-in flow, injected once the method is chosen.
  final Future<void> Function(FirebaseAuth auth)? signInFlow;

  @override
  Future<void> signIn() async {
    final flow = signInFlow;
    if (flow == null) throw const AccountSignInUnavailable();
    await flow(await _authInstance());
  }

  @override
  Future<void> signOut() async {
    await (await _authInstance()).signOut();
  }

  @override
  Future<bool> hasAccount() async =>
      (await _authInstance()).currentUser?.isAnonymous == false;

  Future<FirebaseAuth> _authInstance() async {
    final existing = _auth;
    if (existing != null) return existing;
    await _initialize();
    return _auth = FirebaseAuth.instance;
  }
}
