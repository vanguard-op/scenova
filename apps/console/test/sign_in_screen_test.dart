import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/screens/sign_in_screen.dart';
import 'package:scenova_console/services/operator_auth.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

void main() {
  group('SignInScreen', () {
    testWidgets('carries the brand lockup in its heading', (tester) async {
      final auth = FakeOperatorAuth();
      addTearDown(auth.dispose);
      await pumpThemed(tester, SignInScreen(auth: auth));

      // The heading leads with the lockup, which sizes the mark to the
      // wordmark's cap height.
      expect(find.byType(BrandLockup), findsOneWidget);
      expect(find.text(BrandLockup.wordmark), findsOneWidget);
    });

    testWidgets('asks for an email and a password before signing in', (
      tester,
    ) async {
      final auth = FakeOperatorAuth();
      addTearDown(auth.dispose);
      await pumpThemed(tester, SignInScreen(auth: auth));

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(auth.current, isNull);
    });

    testWidgets('reports a refused sign-in without leaving the form', (
      tester,
    ) async {
      final auth = FakeOperatorAuth()
        ..signInFailure = const OperatorAuthException(
          'The email or password is incorrect.',
        );
      addTearDown(auth.dispose);
      await pumpThemed(tester, SignInScreen(auth: auth));

      await tester.enterText(
        find.byType(TextField).first,
        'curator@example.com',
      );
      await tester.enterText(find.byType(TextField).last, 'secret');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('The email or password is incorrect.'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('moves to the second-factor step when the provider asks', (
      tester,
    ) async {
      final auth = FakeOperatorAuth()..outcome = const SecondFactorRequired();
      addTearDown(auth.dispose);
      await pumpThemed(tester, SignInScreen(auth: auth));

      await tester.enterText(
        find.byType(TextField).first,
        'curator@example.com',
      );
      await tester.enterText(find.byType(TextField).last, 'secret');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your code'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Verify'));
      // The submit button spins while the provider is answering, so the test
      // pumps rather than waiting for a settle.
      await tester.pump();

      expect(auth.submittedCodes, <String>['123456']);
    });

    testWidgets('a rejected code keeps the code step open', (tester) async {
      final auth = FakeOperatorAuth()
        ..outcome = const SecondFactorRequired()
        ..secondFactorFailure = const OperatorAuthException(
          'That code was not accepted. Enter the current code and try again.',
        );
      addTearDown(auth.dispose);
      await pumpThemed(tester, SignInScreen(auth: auth));

      await tester.enterText(
        find.byType(TextField).first,
        'curator@example.com',
      );
      await tester.enterText(find.byType(TextField).last, 'secret');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your code'), findsOneWidget);
      expect(find.textContaining('not accepted'), findsOneWidget);
    });
  });
}
