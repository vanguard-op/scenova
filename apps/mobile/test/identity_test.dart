import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/identity.dart';

/// A Firebase user whose anonymous flag and ID token are scripted.
class _FakeUser implements User {
  _FakeUser({required this.anonymous, this.token});

  final bool anonymous;
  final String? token;

  @override
  bool get isAnonymous => anonymous;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A credential carrying the user a scripted sign-in produced.
class _FakeCredential implements UserCredential {
  _FakeCredential(this.user);

  @override
  final User? user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A FirebaseAuth whose current user and anonymous sign-in are scripted.
class _FakeAuth implements FirebaseAuth {
  _FakeAuth({this.current, this.signsInAs});

  User? current;

  /// The user a call to `signInAnonymously` yields, or null for a sign-in that
  /// produces no user.
  User? signsInAs;
  int signInCalls = 0;

  @override
  User? get currentUser => current;

  @override
  Future<UserCredential> signInAnonymously() async {
    signInCalls++;
    current = signsInAs;
    return _FakeCredential(signsInAs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('AnonymousIdentity', () {
    test(
      'presents the dev token the gateway verifies its subject from',
      () async {
        final identity = AnonymousIdentity(subject: 'reader-1');

        expect(await identity.idToken(), 'dev:reader-1');
      },
    );

    test('keeps one subject across requests', () async {
      final identity = AnonymousIdentity();

      expect(await identity.idToken(), await identity.idToken());
    });

    test('mints a distinct pseudonymous subject per install', () {
      expect(AnonymousIdentity().subject, isNot(AnonymousIdentity().subject));
    });

    test('carries no reader data in the subject', () {
      // Pseudonymous: a hex token, never a word, phrase, email, or name.
      expect(AnonymousIdentity().subject, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('upgrades to the account subject at sign-in', () async {
      final identity = AnonymousIdentity(subject: 'anon-1');

      identity.upgradeTo('account-9');

      expect(identity.subject, 'account-9');
      expect(await identity.idToken(), 'dev:account-9');
    });
  });

  group('FirebaseIdentity', () {
    test(
      'presents the signed-in user\'s ID token without signing in again',
      () async {
        final auth = _FakeAuth(
          current: _FakeUser(anonymous: true, token: 'id-token-1'),
        );
        final identity = FirebaseIdentity(authOverride: auth);

        expect(await identity.idToken(), 'id-token-1');
        expect(auth.signInCalls, 0);
      },
    );

    test('signs in anonymously when the client holds no user', () async {
      final auth = _FakeAuth(
        signsInAs: _FakeUser(anonymous: true, token: 'anon-token'),
      );
      final identity = FirebaseIdentity(authOverride: auth);

      expect(await identity.idToken(), 'anon-token');
      expect(auth.signInCalls, 1);
      // The signed-in user is adopted, so later requests reuse the identity
      // rather than signing in again (D-011).
      expect(await identity.idToken(), 'anon-token');
      expect(auth.signInCalls, 1);
    });

    test('reports no token when the sign-in yields no user', () async {
      final auth = _FakeAuth();
      final identity = FirebaseIdentity(authOverride: auth);

      expect(await identity.idToken(), isNull);
    });

    test('reads an anonymous identity as not an account', () async {
      final auth = _FakeAuth(current: _FakeUser(anonymous: true));
      final identity = FirebaseIdentity(authOverride: auth);

      expect(await identity.isAccount(), isFalse);
    });

    test('reads a signed-in account as an account', () async {
      final auth = _FakeAuth(current: _FakeUser(anonymous: false));
      final identity = FirebaseIdentity(authOverride: auth);

      expect(await identity.isAccount(), isTrue);
    });
  });
}
