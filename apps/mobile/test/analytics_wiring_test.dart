import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/app.dart';
import 'package:scenova/models/analytics_event.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/screens/onboarding_controller.dart';
import 'package:scenova/services/analytics.dart';
import 'package:scenova/services/analytics_api.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

List<String> _names(ScenovaServices services) => services.analytics.pending
    .map((event) => event.name.wire)
    .toList(growable: false);

void main() {
  test(
    'setup records the consent change, the action, and completion',
    () async {
      final settings = SettingsController(
        actionEnabled: false,
        onboardingComplete: false,
      );
      final client = AnalyticsClient(
        api: MockAnalyticsApi(),
        settings: settings,
        connectivity: ManualConnectivity(),
        anonymousId: 'a',
        sessionId: 's',
        appVersion: 'v',
        platform: LookupPlatform.ios,
      );
      addTearDown(client.dispose);
      final controller = OnboardingController(
        settings: settings,
        analytics: client,
      );
      addTearDown(controller.dispose);

      controller.setConsent(false);
      settings.actionEnabled = true;
      controller.refreshActionEnabled();
      await controller.finish();

      expect(_namesFor(client), <String>[
        'consent_changed',
        'action_enabled',
        'onboarding_completed',
      ]);
      expect(client.pending.last.properties, <String, Object?>{
        'action_enabled': true,
        'consent': false,
      });
    },
  );

  testWidgets('a library hit records started, served, and played', (
    tester,
  ) async {
    final api = MockAnalyticsApi();
    final services = buildServices(api: MockLookupApi(), analyticsApi: api);
    final controller = ClipViewController(
      services: services,
      selection: CaptureSelection.parse('come'),
      source: LookupSource.typed,
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(_names(services), <String>[
      'lookup_started',
      'lookup_served',
      'clip_played',
    ]);
    final started = services.analytics.pending.first;
    expect(started.properties, <String, Object?>{
      'kind': 'word',
      'source': 'typed',
    });
    final played = services.analytics.pending.last;
    expect(played.properties, <String, Object?>{
      'clip_source': 'library',
      'entry_id': 'lib-come',
    });

    await teardown(tester);
  });

  testWidgets('a generated clip is recorded as generated, not a library hit', (
    tester,
  ) async {
    final api = MockAnalyticsApi();
    final services = buildServices(
      api: MockLookupApi(pollsUntilReady: 2),
      analyticsApi: api,
    );
    final controller = ClipViewController(
      services: services,
      selection: CaptureSelection.parse('xylograph'),
      source: LookupSource.androidAction,
      pollInterval: const Duration(milliseconds: 100),
      noticeThreshold: const Duration(milliseconds: 250),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(_names(services), <String>['lookup_started', 'clip_played']);
    expect(
      services.analytics.pending.first.properties['source'],
      'android_action',
    );
    expect(
      services.analytics.pending.last.properties['clip_source'],
      'generated',
    );

    await teardown(tester);
  });

  testWidgets('rating a clip records the rating and the clip source', (
    tester,
  ) async {
    final api = MockAnalyticsApi();
    final services = buildServices(api: MockLookupApi(), analyticsApi: api);
    final controller = ClipViewController(
      services: services,
      selection: CaptureSelection.parse('come'),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.helpful));
    await tester.pump();

    final feedback = services.analytics.pending.last;
    expect(feedback.name, AnalyticsEventName.clipFeedbackGiven);
    expect(feedback.properties, <String, Object?>{
      'rating': 'helpful',
      'clip_source': 'library',
    });

    await teardown(tester);
  });

  testWidgets('an exhausted allowance is recorded with the plan', (
    tester,
  ) async {
    final api = MockAnalyticsApi();
    final services = buildServices(
      api: MockLookupApi(),
      analyticsApi: api,
      entitlement: const Entitlement(
        tier: PlanTier.free,
        signedIn: true,
        lookupsUsed: 20,
        lookupsLimit: 20,
      ),
    );
    final controller = ClipViewController(
      services: services,
      selection: CaptureSelection.parse('come'),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.allowanceExhausted);
    final exhausted = services.analytics.pending.last;
    expect(exhausted.name, AnalyticsEventName.allowanceExhausted);
    expect(exhausted.properties, <String, Object?>{'plan': 'free'});

    await teardown(tester);
  });

  testWidgets('a warm entry reports one open for the foregrounding', (
    tester,
  ) async {
    usePhoneWindow(tester);
    final api = MockAnalyticsApi();
    final services = buildServices(
      settings: SettingsController(onboardingComplete: true),
      analyticsApi: api,
    );

    await tester.pumpWidget(ScenovaApp(services: services));
    await tester.pump();

    final launched = services.analytics.pending.single;
    expect(launched.name, AnalyticsEventName.appOpened);
    expect(launched.properties, <String, Object?>{'source': 'launch'});

    // Android pauses and resumes the activity around an intent delivered to
    // one already in the foreground, so the warm entry reports a resume for a
    // foregrounding the app never left. The launch already reported it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(
      api.sent
          .where((event) => event.name == AnalyticsEventName.appOpened)
          .map((event) => event.properties['source']),
      <String>['launch'],
    );

    await teardown(tester);
  });

  testWidgets('leaving the foreground and returning records a second open', (
    tester,
  ) async {
    usePhoneWindow(tester);
    final api = MockAnalyticsApi();
    final services = buildServices(
      settings: SettingsController(onboardingComplete: true),
      analyticsApi: api,
    );

    await tester.pumpWidget(ScenovaApp(services: services));
    await tester.pump();

    // The app leaves the screen, then comes back: the launch is delivered on
    // the way out and the return is a foregrounding of its own.
    for (final state in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump();

    expect(
      api.sent
          .where((event) => event.name == AnalyticsEventName.appOpened)
          .map((event) => event.properties['source']),
      <String>['launch', 'resume'],
    );

    await teardown(tester);
  });

  testWidgets('losing focus without leaving the screen is not an open', (
    tester,
  ) async {
    usePhoneWindow(tester);
    final api = MockAnalyticsApi();
    final services = buildServices(
      settings: SettingsController(onboardingComplete: true),
      analyticsApi: api,
    );

    await tester.pumpWidget(ScenovaApp(services: services));
    await tester.pump();

    // The notify offer's permission prompt takes focus away and gives it back;
    // the reader never left the app.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(
      api.sent
          .where((event) => event.name == AnalyticsEventName.appOpened)
          .map((event) => event.properties['source']),
      <String>['launch'],
    );

    await teardown(tester);
  });
}

/// The wire names queued on a bare [AnalyticsClient], for the controller test.
List<String> _namesFor(AnalyticsClient client) =>
    client.pending.map((event) => event.name.wire).toList(growable: false);
