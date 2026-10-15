import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/account_session.dart';

/// A Firebase failure carrying the provider's code.
class _AuthError extends FirebaseAuthException {
  _AuthError(String code) : super(code: code);
}

/// A Firebase user whose anonymous flag and credential linking are scripted.
class _FakeUser implements User {
  _FakeUser({required this.anonymous});

  bool anonymous;
  int linkCalls = 0;

  /// The failure a link answers with instead of taking the credential.
  _AuthError? linkError;

  @override
  bool get isAnonymous => anonymous;

  @override
  Future<UserCredential> linkWithCredential(AuthCredential credential) async {
    linkCalls++;
    final refused = linkError;
    if (refused != null) throw refused;
    // Linking a credential is what makes the identity an account.
    anonymous = false;
    return _FakeCredential(this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A credential carrying the user the call produced.
class _FakeCredential implements UserCredential {
  _FakeCredential(this.user);

  @override
  final User? user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A FirebaseAuth whose current user and sign-in are scripted.
class _FakeAuth implements FirebaseAuth {
  _FakeAuth({this.current});

  User? current;

  /// The failure a sign-in answers with instead of producing a user.
  _AuthError? signInError;

  int signInCalls = 0;
  int signOutCalls = 0;
  String? lastEmail;
  String? lastPassword;

  @override
  User? get currentUser => current;

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    signInCalls++;
    lastEmail = email;
    lastPassword = password;
    final refused = signInError;
    if (refused != null) throw refused;
    final user = _FakeUser(anonymous: false);
    current = user;
    return _FakeCredential(user);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    current = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('AccountSignInFailure', () {
    test('keeps an unknown address and a wrong password reading alike', () {
      // A project with email enumeration protection answers both with
      // `invalid-credential`, and the client never says which it was.
      for (final code in <String>[
        'invalid-credential',
        'INVALID_LOGIN_CREDENTIALS',
        'user-not-found',
        'wrong-password',
        'user-disabled',
      ]) {
        expect(
          FirebaseAccountSession.failureFor(code),
          AccountSignInFailure.credentials,
          reason: code,
        );
      }
    });

    test('names the address and the password where the provider does', () {
      expect(
        FirebaseAccountSession.failureFor('invalid-email'),
        AccountSignInFailure.email,
      );
      expect(
        FirebaseAccountSession.failureFor('weak-password'),
        AccountSignInFailure.password,
      );
    });

    test('reads anything else as the provider being unreachable', () {
      for (final code in <String>[
        'network-request-failed',
        'too-many-requests',
        'operation-not-allowed',
        'internal-error',
      ]) {
        expect(
          FirebaseAccountSession.failureFor(code),
          AccountSignInFailure.unavailable,
          reason: code,
        );
      }
    });
  });

  group('FirebaseAccountSession', () {
    test('upgrades the anonymous identity rather than replacing it', () async {
      final user = _FakeUser(anonymous: true);
      final auth = _FakeAuth(current: user);
      final session = FirebaseAccountSession(authOverride: auth);

      await session.signIn(email: 'marisol@example.com', password: 'hunter2');

      // The credentials are linked onto the identity the lookups already
      // belong to, so the gateway sees one subject (C-002, D-011).
      expect(user.linkCalls, 1);
      expect(auth.signInCalls, 0);
      expect(auth.currentUser, same(user));
      expect(await session.hasAccount(), isTrue);
    });

    test('signs into an address that already holds an account', () async {
      final user = _FakeUser(anonymous: true)
        ..linkError = _AuthError('email-already-in-use');
      final auth = _FakeAuth(current: user);
      final session = FirebaseAccountSession(authOverride: auth);

      await session.signIn(email: 'marisol@example.com', password: 'hunter2');

      expect(user.linkCalls, 1);
      expect(auth.signInCalls, 1);
      expect(auth.lastEmail, 'marisol@example.com');
      expect(auth.lastPassword, 'hunter2');
    });

    test('signs in directly when no anonymous identity is held', () async {
      final auth = _FakeAuth();
      final session = FirebaseAccountSession(authOverride: auth);

      await session.signIn(email: 'marisol@example.com', password: 'hunter2');

      expect(auth.signInCalls, 1);
      expect(await session.hasAccount(), isTrue);
    });

    test('reports a refused sign-in with the reason to show', () async {
      final auth = _FakeAuth()..signInError = _AuthError('invalid-credential');
      final session = FirebaseAccountSession(authOverride: auth);

      await expectLater(
        session.signIn(email: 'marisol@example.com', password: 'wrong'),
        throwsA(
          isA<AccountSignInException>().having(
            (error) => error.reason,
            'reason',
            AccountSignInFailure.credentials,
          ),
        ),
      );
    });

    test('reports a password the provider will not take', () async {
      final user = _FakeUser(anonymous: true)
        ..linkError = _AuthError('weak-password');
      final session = FirebaseAccountSession(
        authOverride: _FakeAuth(current: user),
      );

      await expectLater(
        session.signIn(email: 'marisol@example.com', password: 'short'),
        throwsA(
          isA<AccountSignInException>().having(
            (error) => error.reason,
            'reason',
            AccountSignInFailure.password,
          ),
        ),
      );
    });

    test('reports a provider that cannot be reached', () async {
      final auth = _FakeAuth()
        ..signInError = _AuthError('network-request-failed');
      final session = FirebaseAccountSession(authOverride: auth);

      await expectLater(
        session.signIn(email: 'marisol@example.com', password: 'hunter2'),
        throwsA(
          isA<AccountSignInException>().having(
            (error) => error.reason,
            'reason',
            AccountSignInFailure.unavailable,
          ),
        ),
      );
    });

    test(
      'reads an anonymous identity as no account and ends a session',
      () async {
        final auth = _FakeAuth(current: _FakeUser(anonymous: true));
        final session = FirebaseAccountSession(authOverride: auth);

        expect(await session.hasAccount(), isFalse);

        await session.signOut();

        expect(auth.signOutCalls, 1);
        expect(auth.currentUser, isNull);
      },
    );
  });
}
