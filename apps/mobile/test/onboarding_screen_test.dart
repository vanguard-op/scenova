import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/app.dart';
import 'package:scenova/screens/home_screen.dart';
import 'package:scenova/screens/onboarding_controller.dart';
import 'package:scenova/screens/onboarding_screen.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/widgets/enable_action_guide.dart';

import 'support/harness.dart';

/// A settings controller as a fresh install sees it: the platform entry point is
/// not on yet and setup has not run.
SettingsController freshInstall() =>
    SettingsController(actionEnabled: false, onboardingComplete: false);

/// Taps a control, scrolling it into view first: the setup column is taller than
/// a phone window, so the buttons sit below the fold.
Future<void> tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets('first open shows the explanation, progress, and enable card', (
    tester,
  ) async {
    await pumpOnboarding(tester, settings: freshInstall());

    expect(find.text('See what a word means'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(EnableActionGuide), findsOneWidget);
    expect(find.text('Step 1 of 2'), findsOneWidget);
    expect(find.text('Send the word to the model provider'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('the enable step is skipped when the action is already on', (
    tester,
  ) async {
    await pumpOnboarding(
      tester,
      settings: SettingsController(actionEnabled: true),
    );

    // Only consent is asked; the enable card is not shown.
    expect(find.byType(EnableActionGuide), findsNothing);
    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(find.text('Send the word to the model provider'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('being sent to settings shows the instruction and return note', (
    tester,
  ) async {
    await pumpOnboarding(tester, settings: freshInstall());

    await tapText(tester, 'Show me how');

    expect(find.text('Turn Scenova on there, then come back.'), findsOneWidget);
    expect(find.text("I've turned it on"), findsOneWidget);
    // The card no longer offers to send the reader away again.
    expect(find.text('Show me how'), findsNothing);

    await teardown(tester);
  });

  testWidgets('checking again while the action is still off shows a reminder', (
    tester,
  ) async {
    await pumpOnboarding(tester, settings: freshInstall());

    await tapText(tester, 'Show me how');
    await tapText(tester, "I've turned it on");

    expect(find.textContaining('not showing in the menu yet'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('returning with the action on advances the step', (tester) async {
    final settings = freshInstall();
    await pumpOnboarding(tester, settings: settings);

    await tapText(tester, 'Show me how');

    // The platform reports the action on while the reader is away.
    settings.actionEnabled = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.text('Turn Scenova on there, then come back.'), findsNothing);
    expect(find.byType(EnableActionGuide), findsNothing);
    expect(find.text('Step 2 of 2'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('consent declined shows the note and is stored at once', (
    tester,
  ) async {
    final settings = freshInstall();
    await pumpOnboarding(tester, settings: settings);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(find.textContaining('Generation is off.'), findsOneWidget);
    expect(settings.consentModelProcessing, isFalse);

    // Consent can be granted again from the same line.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.textContaining('Generation is off.'), findsNothing);
    expect(settings.consentModelProcessing, isTrue);

    await teardown(tester);
  });

  testWidgets('Continue stores the choices and completes setup', (
    tester,
  ) async {
    final settings = freshInstall();
    var completed = false;
    await pumpOnboarding(
      tester,
      settings: settings,
      onComplete: () => completed = true,
    );

    await tapText(tester, 'Continue');
    await tester.pump();

    expect(completed, isTrue);
    expect(settings.onboardingComplete, isTrue);
    expect(settings.consentModelProcessing, isTrue);

    await teardown(tester);
  });

  testWidgets('Continue completes setup with consent declined', (tester) async {
    final settings = freshInstall();
    var completed = false;
    await pumpOnboarding(
      tester,
      settings: settings,
      onComplete: () => completed = true,
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tapText(tester, 'Continue');
    await tester.pump();

    expect(completed, isTrue);
    expect(settings.onboardingComplete, isTrue);
    expect(settings.consentModelProcessing, isFalse);

    await teardown(tester);
  });

  testWidgets('Skip completes setup without enabling the action', (
    tester,
  ) async {
    final settings = freshInstall();
    var completed = false;
    await pumpOnboarding(
      tester,
      settings: settings,
      onComplete: () => completed = true,
    );

    await tapText(tester, 'Skip for now');
    await tester.pump();

    expect(completed, isTrue);
    expect(settings.onboardingComplete, isTrue);
    expect(settings.actionEnabled, isFalse);

    await teardown(tester);
  });

  test('finishing twice does not start a second commit', () async {
    final settings = freshInstall();
    final controller = OnboardingController(settings: settings);
    addTearDown(controller.dispose);

    final first = controller.finish();
    expect(controller.submitting, isTrue);

    await controller.finish();
    expect(settings.onboardingComplete, isTrue);

    await first;
    expect(controller.submitting, isFalse);
  });

  testWidgets('a first launch lands on Onboarding and Continue opens Home', (
    tester,
  ) async {
    usePhoneWindow(tester);
    final services = buildServices(settings: freshInstall());
    await tester.pumpWidget(ScenovaApp(services: services));
    await tester.pump();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    await tapText(tester, 'Continue');
    await tester.pump();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);

    await teardown(tester);
  });

  testWidgets('a returning reader lands straight on Home', (tester) async {
    usePhoneWindow(tester);
    final services = buildServices(
      settings: SettingsController(onboardingComplete: true),
    );
    await tester.pumpWidget(ScenovaApp(services: services));
    await tester.pump();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);

    await teardown(tester);
  });
}
