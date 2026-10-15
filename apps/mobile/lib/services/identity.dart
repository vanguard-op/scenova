import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_client.dart';

/// The reader's identity for the lookup path.
///
/// `C-001` and `C-002` authenticate every lookup with a Firebase ID token in the
/// `Authorization` header: anonymous before accounts ship, upgraded to the
/// reader's account at sign-in. The token is read per request so a refreshed
/// token is always presented, and the client never holds a secret that grants
/// server access (architecture → "Authentication & Authorization").
abstract interface class IdentityProvider {
  /// The token for the `Authorization: Bearer` header, or null when no identity
  /// is available. Refreshed per request.
  Future<String?> idToken();

  /// The account the identity belongs to, as the services know it: the token's
  /// subject, which is the account the entitlement service holds and the one a
  /// store purchase is attributed to (`C-019` `accountId`). Null when no
  /// identity is available.
  ///
  /// The reader's identity is upgraded in place at sign-in (D-011), so this is
  /// the anonymous install's subject before sign-in and the account's after,
  /// with no separate call to make at either point.
  Future<String?> accountId();
}

/// The pre-account identity for local runs.
///
/// The gateway enforces authentication before accounts ship. Outside production
/// it runs its own verifier, which accepts a pseudonymous `dev:<subject>` token
/// (`.env` → `AUTH_MODE=dev`), so the live lookup path is authenticated locally
/// before a Firebase project is wired to the client. The subject is
/// pseudonymous and scoped to the app instance, and carries nothing about the
/// reader; at sign-in it is replaced by the account subject, so a lookup created
/// anonymously and polled after sign-in still resolves to the same caller
/// (`C-002`).
class AnonymousIdentity implements IdentityProvider {
  AnonymousIdentity({String? subject}) : _subject = subject ?? _newSubject();

  String _subject;

  /// The pseudonymous subject the gateway sees.
  String get subject => _subject;

  @override
  Future<String?> idToken() async => 'dev:$_subject';

  @override
  Future<String?> accountId() async => _subject;

  /// Adopts the reader's account subject at sign-in, so the identity the
  /// gateway sees is upgraded in place (D-011).
  void upgradeTo(String accountId) => _subject = accountId;

  /// A fresh pseudonymous subject, unique to this device's install.
  static String _newSubject() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// The reader's identity through Firebase Authentication (D-011).
///
/// Before accounts ship the reader is signed in anonymously, so the lookup path
/// is authenticated without the reader creating an account; at sign-in the same
/// identity is upgraded to the account and the gateway sees one subject.
///
/// The client's project configuration is the committed `firebase_options.dart`,
/// and initialisation is deferred to the first request rather than done at
/// startup, so a build that never authenticates pays nothing. `initialize` and
/// `authOverride` are injectable for tests.
class FirebaseIdentity implements IdentityProvider {
  FirebaseIdentity({
    FirebaseAuth? authOverride,
    Future<FirebaseApp> Function()? initialize,
  }) : _auth = authOverride,
       _initialize = initialize ?? initializeFirebaseClient;

  FirebaseAuth? _auth;
  final Future<FirebaseApp> Function() _initialize;

  /// Whether the reader holds an account rather than an anonymous identity.
  Future<bool> isAccount() async =>
      (await _authInstance()).currentUser?.isAnonymous == false;

  @override
  Future<String?> idToken() async {
    final auth = await _authInstance();
    final user = auth.currentUser ?? (await auth.signInAnonymously()).user;
    return user?.getIdToken();
  }

  @override
  Future<String?> accountId() async {
    final auth = await _authInstance();
    final user = auth.currentUser ?? (await auth.signInAnonymously()).user;
    return user?.uid;
  }

  Future<FirebaseAuth> _authInstance() async {
    final existing = _auth;
    if (existing != null) return existing;
    await _initialize();
    return _auth = FirebaseAuth.instance;
  }
}
