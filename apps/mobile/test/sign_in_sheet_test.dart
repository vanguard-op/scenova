import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/screens/sign_in_controller.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/widgets/sign_in_sheet.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// Opens the sign-in sheet over a host surface so a test drives its states and
/// reads what came of the visit.
Future<ScenovaServices> pumpSignIn(
  WidgetTester tester, {
  AccountSession? session,
  SignInController? controller,
  bool online = true,
  ValueChanged<bool>? onResult,
}) async {
  usePhoneWindow(tester);
  final services = buildServices(accountSession: session, online: online);
  await tester.pumpWidget(
    ScenovaScope(
      services: services,
      child: MaterialApp(
        theme: AppTheme.build(
          brightness: Brightness.light,
          deviceClass: DeviceClass.mobile,
        ),
        home: _SignInHost(controller: controller, onResult: onResult),
      ),
    ),
  );
  // The host opens the sheet in a post-frame callback; the sheet then settles
  // in.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  return services;
}

/// A host that opens the sign-in sheet once mounted and records what came of it.
class _SignInHost extends StatefulWidget {
  const _SignInHost({this.controller, this.onResult});

  final SignInController? controller;
  final ValueChanged<bool>? onResult;

  @override
  State<_SignInHost> createState() => _SignInHostState();
}

class _SignInHostState extends State<_SignInHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final signedIn = await showSignInSheet(
      context,
      controller: widget.controller,
    );
    widget.onResult?.call(signedIn);
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

/// The email field, the password field, and the action.
Finder get _emailField => find.byType(TextField).at(0);
Finder get _passwordField => find.byType(TextField).at(1);
Finder get _signInButton => find.widgetWithText(ScenovaButton, 'Sign in');

Future<void> _fill(
  WidgetTester tester, {
  String email = 'marisol@example.com',
  String password = 'hunter2',
}) async {
  await tester.enterText(_emailField, email);
  await tester.enterText(_passwordField, password);
}

void main() {
  testWidgets('the form asks for an email address and a password', (
    tester,
  ) async {
    await pumpSignIn(tester);

    expect(find.byType(SignInSheet), findsOneWidget);
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(_signInButton, findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('an empty form names what is missing', (tester) async {
    final session = DevelopmentAccountSession();
    await pumpSignIn(tester, session: session);

    await tester.tap(_signInButton);
    await tester.pump();
    await tester.pump();

    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(session.signInCalls, 0);
    await teardown(tester);
  });

  testWidgets('a sign-in the provider refuses stays open with the message', (
    tester,
  ) async {
    final session = DevelopmentAccountSession(
      failure: const AccountSignInException(AccountSignInFailure.credentials),
    );
    var resolved = false;
    await pumpSignIn(
      tester,
      session: session,
      onResult: (_) => resolved = true,
    );

    await _fill(tester, password: 'wrong');
    await tester.tap(_signInButton);
    await tester.pump();
    await tester.pump();

    expect(find.text('That email and password don\'t match.'), findsOneWidget);
    expect(find.byType(SignInSheet), findsOneWidget);
    expect(resolved, isFalse);

    // The reader corrects the password and the message comes off the form.
    await tester.enterText(_passwordField, 'hunter2');
    await tester.pump();
    expect(find.text('That email and password don\'t match.'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a sign-in that goes through resolves the sheet', (tester) async {
    final session = DevelopmentAccountSession();
    bool? result;
    await pumpSignIn(
      tester,
      session: session,
      onResult: (value) => result = value,
    );

    await _fill(tester);
    await tester.tap(_signInButton);
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(session.signedIn, isTrue);
    expect(session.lastEmail, 'marisol@example.com');
    expect(find.byType(SignInSheet), findsNothing);
    await teardown(tester);
  });

  testWidgets('the password stays hidden until the reader reveals it', (
    tester,
  ) async {
    await pumpSignIn(tester);

    expect(tester.widget<TextField>(_passwordField).obscureText, isTrue);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();

    expect(tester.widget<TextField>(_passwordField).obscureText, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('an offline device is told before the attempt', (tester) async {
    final session = DevelopmentAccountSession();
    await pumpSignIn(tester, session: session, online: false);

    expect(
      find.text('You are offline. Sign in when you are back online.'),
      findsOneWidget,
    );

    await _fill(tester);
    await tester.tap(_signInButton);
    await tester.pump();
    await tester.pump();

    // The attempt's own message stands in place of the banner, so the offline
    // state is never said twice.
    expect(
      find.text('You\'re offline. Sign in when you\'re back online.'),
      findsOneWidget,
    );
    expect(
      find.text('You are offline. Sign in when you are back online.'),
      findsNothing,
    );
    expect(session.signInCalls, 0);
    await teardown(tester);
  });

  testWidgets('an attempt in flight holds the form still', (tester) async {
    final session = _HeldSession();
    await pumpSignIn(tester, session: session);

    await _fill(tester);
    await tester.tap(_signInButton);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(_emailField).enabled, isFalse);
    expect(tester.widget<TextField>(_passwordField).enabled, isFalse);
    expect(
      tester
          .widget<ScenovaButton>(find.widgetWithText(ScenovaButton, 'Not now'))
          .onPressed,
      isNull,
    );

    session.completer.complete();
    await tester.pumpAndSettle();
    await teardown(tester);
  });
}

/// A session whose sign-in resolves only when the test completes it.
class _HeldSession implements AccountSession {
  final Completer<void> completer = Completer<void>();

  @override
  Future<void> signIn({required String email, required String password}) =>
      completer.future;

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> hasAccount() async => false;
}
