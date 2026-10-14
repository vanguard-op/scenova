import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_client.dart';

/// The authenticated operator behind the console.
///
/// The review endpoints take an operator's Firebase ID token carrying the
/// `curator` custom claim and a multi-factor session (`C-014` auth). The
/// console carries the operator's identity for the top bar and the sign-out
/// action; the role and the second factor are enforced at the gateway, never
/// trusted from the client.
@immutable
class OperatorSession {
  const OperatorSession({required this.subject, this.email, this.displayName});

  /// The identity provider's subject.
  final String subject;

  final String? email;
  final String? displayName;

  /// What the top bar shows: the operator's name, or their email, or the
  /// subject as a last resort.
  String get label {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final mail = email?.trim();
    if (mail != null && mail.isNotEmpty) return mail;
    return subject;
  }
}

/// The result of a sign-in attempt.
sealed class SignInOutcome {
  const SignInOutcome();
}

/// The operator is signed in.
final class SignedIn extends SignInOutcome {
  const SignedIn();
}

/// The identity provider accepted the password but the account is enrolled in
/// a second factor; [OperatorAuth.submitSecondFactor] completes the sign-in.
final class SecondFactorRequired extends SignInOutcome {
  const SecondFactorRequired();
}

/// A sign-in failure with wording a curator can act on.
class OperatorAuthException implements Exception {
  const OperatorAuthException(this.message);

  final String message;

  @override
  String toString() => 'OperatorAuthException($message)';
}

/// The operator's identity for the review surface (`C-014` auth).
abstract interface class OperatorAuth {
  /// The signed-in operator, or null when there is no session.
  OperatorSession? get current;

  /// Emits on sign-in and sign-out, so the console can redirect to the
  /// identity provider when a session ends while the queue is open.
  Stream<OperatorSession?> get changes;

  /// Signs in with the identity provider.
  ///
  /// Returns [SecondFactorRequired] when the account is enrolled in a second
  /// factor; the caller then collects the code and calls
  /// [submitSecondFactor]. Throws [OperatorAuthException] on a refusal.
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  });

  /// Completes a sign-in that is waiting on a second factor.
  Future<void> submitSecondFactor(String code);

  /// Abandons a sign-in that is waiting on a second factor.
  void cancelSecondFactor();

  /// The operator's Firebase ID token for the `Authorization` header, or null
  /// when there is no session. Refreshed per request.
  Future<String?> idToken();

  /// Signs the operator out.
  Future<void> signOut();
}

/// The operator's identity through Firebase Authentication (`C-014` auth).
///
/// The account is an operator's, created and granted the `curator` claim by
/// `make curator`, and enrolled in a TOTP second factor. Sign-in completes only
/// with both, so the gateway's role and second-factor gate is met by the
/// session the console presents.
class FirebaseOperatorAuth implements OperatorAuth {
  FirebaseOperatorAuth({
    FirebaseAuth? authOverride,
    Future<FirebaseApp> Function()? initialize,
  }) : _auth = authOverride,
       _initialize = initialize ?? initializeFirebaseClient;

  FirebaseAuth? _auth;
  final Future<FirebaseApp> Function() _initialize;
  MultiFactorResolver? _resolver;
  final StreamController<OperatorSession?> _changes =
      StreamController<OperatorSession?>.broadcast();

  @override
  OperatorSession? get current => _sessionOf(_auth?.currentUser);

  @override
  Stream<OperatorSession?> get changes async* {
    final auth = await _authInstance();
    yield _sessionOf(auth.currentUser);
    yield* auth.authStateChanges().map(_sessionOf);
  }

  @override
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async {
    final auth = await _authInstance();
    try {
      await auth.signInWithEmailAndPassword(email: email, password: password);
      _resolver = null;
      return const SignedIn();
    } on FirebaseAuthMultiFactorException catch (error) {
      _resolver = error.resolver;
      return const SecondFactorRequired();
    } on FirebaseAuthException catch (error) {
      throw OperatorAuthException(_messageFor(error));
    }
  }

  @override
  Future<void> submitSecondFactor(String code) async {
    final resolver = _resolver;
    if (resolver == null) {
      throw const OperatorAuthException(
        'No sign-in is waiting for a code. Sign in again.',
      );
    }
    if (resolver.hints.isEmpty) {
      throw const OperatorAuthException(
        'This account has no second factor enrolled. Ask an administrator.',
      );
    }
    try {
      final assertion = await TotpMultiFactorGenerator.getAssertionForSignIn(
        resolver.hints.first.uid,
        code.trim(),
      );
      await resolver.resolveSignIn(assertion);
      _resolver = null;
    } on FirebaseAuthMultiFactorException catch (error) {
      // The provider kept the session open for a retry.
      _resolver = error.resolver;
      throw const OperatorAuthException(
        'That code was not accepted. Enter the current code and try again.',
      );
    } on FirebaseAuthException catch (error) {
      throw OperatorAuthException(_messageFor(error));
    }
  }

  @override
  void cancelSecondFactor() => _resolver = null;

  @override
  Future<String?> idToken() async {
    final auth = await _authInstance();
    return auth.currentUser?.getIdToken();
  }

  @override
  Future<void> signOut() async {
    _resolver = null;
    final auth = await _authInstance();
    await auth.signOut();
  }

  Future<FirebaseAuth> _authInstance() async {
    final existing = _auth;
    if (existing != null) return existing;
    await _initialize();
    return _auth = FirebaseAuth.instance;
  }

  OperatorSession? _sessionOf(User? user) {
    if (user == null) return null;
    return OperatorSession(
      subject: user.uid,
      email: user.email,
      displayName: user.displayName,
    );
  }

  /// Turns a provider error into wording a curator can act on, without
  /// surfacing the provider's own text.
  String _messageFor(FirebaseAuthException error) => switch (error.code) {
    'invalid-email' => 'That email address is not valid.',
    'user-disabled' => 'This account has been disabled.',
    'user-not-found' ||
    'wrong-password' ||
    'invalid-credential' => 'The email or password is incorrect.',
    'too-many-requests' =>
      'Too many attempts just now. Wait a moment and try again.',
    'network-request-failed' =>
      'The identity provider could not be reached. Check your connection.',
    _ => 'Sign-in failed. Try again.',
  };

  /// Releases the change stream.
  void dispose() => _changes.close();
}

/// The pre-project operator session for local runs.
///
/// The gateway enforces the curator role and the second factor before a
/// Firebase project is wired to the console. Outside production it runs its own
/// verifier, which accepts a `dev:curator:mfa:<subject>` token (`.env` →
/// `AUTH_MODE=dev`), so the live review path is authenticated locally. The
/// subject is whatever the operator typed; it carries nothing about a real
/// person and never leaves the developer's machine.
class DevOperatorAuth implements OperatorAuth {
  DevOperatorAuth([this._subject]);

  String? _subject;
  final StreamController<OperatorSession?> _changes =
      StreamController<OperatorSession?>.broadcast();

  @override
  OperatorSession? get current {
    final subject = _subject;
    if (subject == null) return null;
    return OperatorSession(subject: subject, email: subject);
  }

  @override
  Stream<OperatorSession?> get changes => _changes.stream;

  @override
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async {
    final trimmed = email.trim();
    if (trimmed.isEmpty) {
      throw const OperatorAuthException('Enter your email address.');
    }
    if (password.isEmpty) {
      throw const OperatorAuthException('Enter your password.');
    }
    _subject = trimmed;
    _changes.add(current);
    return const SignedIn();
  }

  @override
  Future<void> submitSecondFactor(String code) async {}

  @override
  void cancelSecondFactor() {}

  @override
  Future<String?> idToken() async {
    final subject = _subject;
    if (subject == null) return null;
    return 'dev:curator:mfa:$subject';
  }

  @override
  Future<void> signOut() async {
    _subject = null;
    _changes.add(null);
  }

  void dispose() => _changes.close();
}
