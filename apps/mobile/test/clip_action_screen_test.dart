import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/app.dart';
import 'package:scenova/models/analytics_event.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/screens/home_screen.dart';
import 'package:scenova/screens/onboarding_screen.dart';
import 'package:scenova/services/analytics_api.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// The Android selection action's surface (`FEAT-001`, `FEAT-008`). These cover
/// the paths that carry risk: the clip opening in place rather than the app, an
/// empty selection, the dismiss that returns the reader to their page, and
/// selections arriving twice — the same word reusing the open lookup, a new
/// word replacing it, each reported once.
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

  Future<ScenovaServices> pumpAction(
    WidgetTester tester, {
    LookupApi? api,
    SettingsController? settings,
    AnalyticsApi? analyticsApi,
  }) async {
    usePhoneWindow(tester);
    final services = buildServices(
      api: api ?? MockLookupApi(),
      settings: settings,
      analyticsApi: analyticsApi,
    );
    await tester.pumpWidget(
      ScenovaApp(
        services: services,
        entryPoint: CaptureEntryPoint.selectionAction,
      ),
    );
    await tester.pump();
    return services;
  }

  /// The `lookup_started` events queued for the intake.
  Iterable<AnalyticsEvent> lookupsStarted(ScenovaServices services) => services
      .analytics
      .pending
      .where((event) => event.name == AnalyticsEventName.lookupStarted);

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
    final api = RecordingLookupApi(MockLookupApi());
    final services = await pumpAction(tester, api: api);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();
    expect(find.byType(ClipViewScreen), findsOneWidget);

    await deliverCapture(tester, 'bank');
    await tester.pump();
    await tester.pump();

    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(find.text('Which meaning fits here?'), findsOneWidget);
    // A second word is its own lookup: one lookup each, and the first is not
    // started again.
    expect(api.createCalls, 2);
    expect(lookupsStarted(services), hasLength(2));
    expect(
      lookupsStarted(services).map((event) => event.properties['source']),
      everyElement('android_action'),
    );

    await teardown(tester);
  });

  testWidgets('the action invoked again on the same word reuses the lookup', (
    tester,
  ) async {
    mockActionPlatform();
    final api = RecordingLookupApi(MockLookupApi());
    final services = await pumpAction(tester, api: api);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    // The reading app's action arrives again on the warm activity, for the word
    // the card already carries.
    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    expect(api.createCalls, 1);
    expect(lookupsStarted(services), hasLength(1));
    // The open lookup is reused as it stands: the card, its word, and its clip
    // are the ones already on screen, so the clip is not played a second time.
    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(
      find.text('a short clip that shows what the word means'),
      findsOneWidget,
    );
    expect(services.analytics.pending.map((event) => event.name.wire), <String>[
      'app_opened',
      'lookup_started',
      'lookup_served',
      'clip_played',
    ]);

    await teardown(tester);
  });

  testWidgets('a word delivered twice before the card opens starts it once', (
    tester,
  ) async {
    mockActionPlatform();
    final api = RecordingLookupApi(MockLookupApi());
    final services = await pumpAction(tester, api: api);

    // Both deliveries land before the first frame, so the card that opens is
    // the first one and it carries the selection once.
    await deliverCapture(tester, 'come');
    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    expect(api.createCalls, 1);
    expect(lookupsStarted(services), hasLength(1));
    expect(find.byType(ClipViewScreen), findsOneWidget);

    await teardown(tester);
  });
}
