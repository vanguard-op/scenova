import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/screens/sign_in_controller.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/connectivity.dart';

/// A controller over a scripted session and connection.
({SignInController controller, DevelopmentAccountSession session}) build({
  bool online = true,
  AccountSignInException? failure,
}) {
  final session = DevelopmentAccountSession(failure: failure);
  final controller = SignInController(
    session: session,
    connectivity: ManualConnectivity(online: online),
  );
  addTearDown(controller.dispose);
  return (controller: controller, session: session);
}

void main() {
  test('an empty form is refused before the provider is asked', () async {
    final (:controller, :session) = build();

    expect(await controller.submit(email: '', password: ''), isFalse);

    expect(controller.emailError, 'Enter your email address.');
    expect(controller.passwordError, 'Enter your password.');
    expect(session.signInCalls, 0);
  });

  test('an address the provider would not read is refused', () async {
    final (:controller, :session) = build();

    expect(
      await controller.submit(email: 'marisol@example', password: 'hunter2'),
      isFalse,
    );

    expect(controller.emailError, 'Check your email address.');
    expect(controller.passwordError, isNull);
    expect(session.signInCalls, 0);
  });

  test('the credentials are handed over with the address trimmed', () async {
    final (:controller, :session) = build();

    expect(
      await controller.submit(
        email: '  marisol@example.com ',
        password: ' hunter2 ',
      ),
      isTrue,
    );

    expect(session.lastEmail, 'marisol@example.com');
    // A password is the reader's own; it is never trimmed.
    expect(session.lastPassword, ' hunter2 ');
    expect(controller.formError, isNull);
  });

  test('an offline device is told before the provider is asked', () async {
    final (:controller, :session) = build(online: false);

    expect(
      await controller.submit(
        email: 'marisol@example.com',
        password: 'hunter2',
      ),
      isFalse,
    );

    expect(
      controller.formError,
      'You\'re offline. Sign in when you\'re back online.',
    );
    expect(session.signInCalls, 0);
  });

  test('a refused sign-in carries the provider\'s reason', () async {
    final cases = <AccountSignInFailure, String>{
      AccountSignInFailure.credentials: 'That email and password don\'t match.',
      AccountSignInFailure.email: 'Check your email address.',
      AccountSignInFailure.password: 'That password is too short.',
      AccountSignInFailure.unavailable:
          'Scenova could not be reached. Check your connection and try again.',
    };

    for (final MapEntry(key: reason, value: message) in cases.entries) {
      final (:controller, session: _) = build(
        failure: AccountSignInException(reason),
      );

      expect(
        await controller.submit(
          email: 'marisol@example.com',
          password: 'hunter2',
        ),
        isFalse,
      );

      expect(controller.formError, message, reason: reason.name);
      expect(controller.emailError, isNull);
    }
  });

  test('a failure the provider did not name is reported plainly', () async {
    final controller = SignInController(
      session: _ThrowingSession(),
      connectivity: ManualConnectivity(),
    );
    addTearDown(controller.dispose);

    expect(
      await controller.submit(
        email: 'marisol@example.com',
        password: 'hunter2',
      ),
      isFalse,
    );

    expect(controller.formError, 'Signing in did not work. Try again.');
  });

  test('correcting a field takes the last attempt\'s messages off', () async {
    final (:controller, :session) = build();

    await controller.submit(email: '', password: '');
    expect(controller.emailError, isNotNull);

    controller.clearErrors();

    expect(controller.emailError, isNull);
    expect(controller.passwordError, isNull);
    expect(controller.formError, isNull);
  });
}

/// A session that fails with something the provider did not name.
class _ThrowingSession implements AccountSession {
  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async => throw StateError('unexpected');

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> hasAccount() async => false;
}
