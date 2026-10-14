import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/app.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/screens/home_screen.dart';
import 'package:scenova/screens/onboarding_screen.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/theme/colors.dart';
import 'package:scenova/widgets/app_icons.dart';

import 'support/harness.dart';

/// The Android selection action's surface (`FEAT-001`, `FEAT-008`). These cover
/// the paths that carry risk: the clip opening in place rather than the app, an
/// empty selection, the dismiss that returns the reader to their page, and a
/// second selection reusing the open view.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(CaptureChannel.channelName);
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Answers the action entry point and records the calls the action makes, so
  /// a test asserts the surface and the dismissal handshake together.
  List<String> mockActionPlatform() {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        CaptureChannel.methodEntryPoint =>
          CaptureEntryPoint.selectionAction.wire,
        CaptureChannel.methodPendingSelection => null,
        _ => null,
      };
    });
    return calls;
  }

  Future<void> pumpAction(
    WidgetTester tester, {
    LookupApi? api,
    SettingsController? settings,
  }) async {
    usePhoneWindow(tester);
    final services = buildServices(
      api: api ?? MockLookupApi(),
      settings: settings,
    );
    await tester.pumpWidget(
      ScenovaApp(
        services: services,
        entryPoint: CaptureEntryPoint.selectionAction,
      ),
    );
    await tester.pump();
  }

  testWidgets('a selection opens the clip in place, not the app', (
    tester,
  ) async {
    mockActionPlatform();
    await pumpAction(tester);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    expect(find.byType(ClipViewScreen), findsOneWidget);
    // The card sits over the reading page: the backdrop lets the page through
    // and there is no app surface behind it.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.backgroundColor, ScenovaPalette.transparent);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(OnboardingScreen), findsNothing);
    // History is an app destination the in-place card cannot open.
    expect(find.text('History'), findsNothing);

    await teardown(tester);
  });

  testWidgets('the action shows the clip before onboarding is complete', (
    tester,
  ) async {
    // The action is enabled in the reading app, not in Scenova, so a reader can
    // invoke it before they have been through Onboarding.
    mockActionPlatform();
    await pumpAction(
      tester,
      settings: SettingsController(onboardingComplete: false),
    );

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);

    await teardown(tester);
  });

  testWidgets('an empty selection opens the empty state and starts no lookup', (
    tester,
  ) async {
    mockActionPlatform();
    final api = RecordingLookupApi(MockLookupApi());
    await pumpAction(tester, api: api);

    await deliverCapture(tester, '   ');
    await tester.pump();
    await tester.pump();

    expect(find.text('Nothing to look up'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Back to Home'), findsNothing);
    expect(api.createCalls, 0);

    await teardown(tester);
  });

  testWidgets('dismissing the card closes the activity', (tester) async {
    final calls = mockActionPlatform();
    await pumpAction(tester);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.close));
    await tester.pump();

    // The reader returns to the reading app rather than an app surface.
    expect(calls, contains(CaptureChannel.methodDismiss));
    await teardown(tester);
  });

  testWidgets('a second selection updates the open view in place', (
    tester,
  ) async {
    mockActionPlatform();
    await pumpAction(tester);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();
    expect(find.byType(ClipViewScreen), findsOneWidget);

    await deliverCapture(tester, 'bank');
    await tester.pump();
    await tester.pump();

    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(find.text('Which meaning fits here?'), findsOneWidget);

    await teardown(tester);
  });
}
