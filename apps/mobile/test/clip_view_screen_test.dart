import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/clip_notice.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/clip_notice_source.dart';
import 'package:scenova/services/clip_store.dart';
import 'package:scenova/services/feature_flags.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/poster_frame_store.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/push_tokens.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

const String _libraryPhrase = 'a short clip that shows what the word means';

/// A messaging service that hands back a fixed token, so the notify offer can
/// be driven through the real token provider without Firebase.
class _StubMessaging implements PushMessaging {
  _StubMessaging(this.token);

  final String token;
  int calls = 0;

  @override
  Future<String?> currentToken() async {
    calls++;
    return token;
  }
}

ClipViewController controllerFor(
  ScenovaServices services,
  String text, {
  Duration pollInterval = const Duration(milliseconds: 100),
  Duration noticeThreshold = const Duration(milliseconds: 250),
  Duration pollTimeout = const Duration(minutes: 5),
}) {
  return ClipViewController(
    services: services,
    selection: CaptureSelection.parse(text),
    pollInterval: pollInterval,
    noticeThreshold: noticeThreshold,
    pollTimeout: pollTimeout,
  );
}

void main() {
  testWidgets('the clip view shows the word with a spinner while resolving', (
    tester,
  ) async {
    final api = DelayedLookupApi();
    final services = buildServices(api: api);
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();

    expect(find.byType(ClipPlayer), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('come'), findsWidgets);

    api.completer.complete(
      await MockLookupApi().createLookup(_request('come')),
    );
    await tester.pump();
    await teardown(tester);
  });

  testWidgets('a library hit plays at once and is saved to history', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi());
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(find.text(_libraryPhrase), findsOneWidget);
    // Autoplay is on by default, so the control offers Pause.
    expect(findIcon(AppIcons.pause), findsOneWidget);

    final saved = await services.historyStore.all();
    expect(saved.single.word, 'come');
    await teardown(tester);
  });

  testWidgets('a lookup that resolves keeps a poster frame with its entry', (
    tester,
  ) async {
    final posters = InMemoryPosterFrameStore(
      onCapture: (clipUrl) async => testPosterFrame(),
    );
    final services = buildServices(api: MockLookupApi(), posterFrames: posters);
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    final saved = (await services.historyStore.all()).single;
    // The frame is derived as the entry is stored and keyed to it (`FEAT-009`).
    expect(saved.posterLocalKey, saved.id);
    expect(await posters.frame(saved.id), isNotNull);
    await teardown(tester);
  });

  testWidgets('a frame that cannot be derived leaves the entry without one', (
    tester,
  ) async {
    // The default in-memory store derives nothing, as a clip the platform
    // cannot read does not.
    final services = buildServices(api: MockLookupApi());
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect((await services.historyStore.all()).single.posterLocalKey, isNull);
    await teardown(tester);
  });

  testWidgets('a lookup that resolves keeps the clip on the device', (
    tester,
  ) async {
    final clips = InMemoryClipStore(
      onSave: (clipUrl) async => 'file:///device/come.mp4',
    );
    final services = buildServices(api: MockLookupApi(), clips: clips);
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    final saved = (await services.historyStore.all()).single;
    // The clip itself is kept as the entry is stored and keyed to it, so it
    // replays with no connection (`FEAT-009`).
    expect(saved.clipLocalKey, saved.id);
    expect(await clips.source(saved.id), 'file:///device/come.mp4');
    await teardown(tester);
  });

  testWidgets('a clip the device cannot keep leaves the entry on its source', (
    tester,
  ) async {
    // The default in-memory store keeps nothing, as a fetch the device cannot
    // complete does not; the entry still carries the source it was served from.
    final services = buildServices(api: MockLookupApi());
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    final saved = (await services.historyStore.all()).single;
    expect(saved.clipLocalKey, isNull);
    expect(saved.clipUrl, isNotNull);
    await teardown(tester);
  });

  testWidgets('an entry whose clip the device no longer holds falls back', (
    tester,
  ) async {
    // The entry names a clip the device store does not hold and has no source
    // to fall back on, so there is nothing to replay.
    final services = buildServices(api: MockLookupApi());
    final controller = ClipViewController(
      services: services,
      selection: CaptureSelection.parse('come'),
      savedEntry: seededEntry(
        word: 'come',
        phrase: 'to move towards someone',
        clipLocalKey: 'gone',
      ),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.fallback);
    expect(find.text('No clip for this word yet.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a word with several senses offers one clip per sense', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi());
    final controller = controllerFor(services, 'bank');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.senseChoice);
    expect(find.text('Which meaning fits here?'), findsOneWidget);
    expect(find.text('the land along the side of a river'), findsOneWidget);
    expect(find.text('a place that keeps money safe'), findsOneWidget);
    // The first sense carries audio and clips are muted by default.
    expect(find.text('Muted'), findsOneWidget);

    await tester.ensureVisible(
      find.text('a place that keeps money safe').first,
    );
    await tester.pump();
    await tester.tap(find.text('a place that keeps money safe').first);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(
      controller.chosenSense!.glossPhrase,
      'a place that keeps money safe',
    );
    await teardown(tester);
  });

  testWidgets('a generating lookup resolves once the clip is ready', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi(pollsUntilReady: 2));
    final controller = controllerFor(services, 'xylograph');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.generating);
    expect(find.text('Making your clip'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(controller.phase, ClipPhase.generating);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(controller.phase, ClipPhase.playing);
    await teardown(tester);
  });

  testWidgets('a clip is not kept when consent is withdrawn as it generates', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi(pollsUntilReady: 2));
    final controller = controllerFor(services, 'xylograph');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.generating);

    // The reader withdraws consent while the clip is being made; the clip that
    // lands is not kept (`FEAT-012` → Edge Cases).
    services.settings.consentModelProcessing = false;

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(await services.historyStore.all(), isEmpty);
    await teardown(tester);
  });

  testWidgets('a library clip is kept with consent withdrawn', (tester) async {
    final services = buildServices(api: MockLookupApi());
    // The library serves the clip without the reader's word leaving the device,
    // so it is kept whatever the consent says (`FEAT-012` → Edge Cases).
    services.settings.consentModelProcessing = false;
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(await services.historyStore.all(), hasLength(1));
    await teardown(tester);
  });

  testWidgets('a slow generation tells the reader and offers to notify', (
    tester,
  ) async {
    final pushApi = MockPushRegistrationApi();
    final services = buildServices(
      api: MockLookupApi(pollsUntilReady: 100),
      pushApi: pushApi,
    );
    final controller = controllerFor(
      services,
      'xylograph',
      pollInterval: const Duration(milliseconds: 100),
      noticeThreshold: const Duration(milliseconds: 250),
      pollTimeout: const Duration(milliseconds: 700),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.generating);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The progress state gives way to a still message, and the notice offers to
    // tell the reader when the clip is ready.
    expect(find.text('Making your clip'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Still making your clip'), findsOneWidget);
    expect(
      find.text('Your clip is still being made. It will be here shortly.'),
      findsOneWidget,
    );
    expect(find.text('Notify me'), findsOneWidget);

    await tester.tap(find.text('Notify me'));
    await tester.pump();
    expect(controller.willNotify, isTrue);
    // Taking the notice registers the device against the lookup the reader is
    // waiting on, so the push can find its way back (C-008).
    expect(pushApi.tokens, hasLength(1));
    expect(pushApi.lookupIds, <String>[controller.result!.lookupId]);

    // Left generating past the timeout, the lookup is reported with a retry
    // rather than polling forever.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(controller.phase, ClipPhase.error);
    expect(find.text('That lookup did not finish'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the still-making notice clears once the clip is ready', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi(pollsUntilReady: 5));
    final controller = controllerFor(
      services,
      'xylograph',
      pollInterval: const Duration(milliseconds: 100),
      noticeThreshold: const Duration(milliseconds: 250),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    // Past the wait threshold the reader is told the clip is still being made.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Your clip is still being made. It will be here shortly.'),
      findsOneWidget,
    );

    // The clip arrives; the notice has nothing left to wait on and leaves, so
    // it does not sit over the clip that just started playing.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.phase, ClipPhase.playing);
    expect(
      find.text('Your clip is still being made. It will be here shortly.'),
      findsNothing,
    );
    await teardown(tester);
  });

  testWidgets('a notice the service does not need says the lookup finished', (
    tester,
  ) async {
    // The service reports the lookup is no longer generating, so there is no
    // later event to notify about; the reader is told rather than left waiting.
    final pushApi = MockPushRegistrationApi()..declinesRegistration = true;
    final services = buildServices(
      api: MockLookupApi(pollsUntilReady: 100),
      pushApi: pushApi,
    );
    final controller = controllerFor(
      services,
      'xylograph',
      pollInterval: const Duration(milliseconds: 100),
      noticeThreshold: const Duration(milliseconds: 250),
      pollTimeout: const Duration(milliseconds: 900),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Notify me'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('This lookup already finished. It will update here.'),
      findsOneWidget,
    );

    // Let the wait time out so the poll stops rather than outliving the test.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await teardown(tester);
  });

  testWidgets('a notice that could not be set up says so', (tester) async {
    final pushApi = MockPushRegistrationApi()..failStatus = 400;
    final services = buildServices(
      api: MockLookupApi(pollsUntilReady: 100),
      pushApi: pushApi,
    );
    final controller = controllerFor(
      services,
      'xylograph',
      pollInterval: const Duration(milliseconds: 100),
      noticeThreshold: const Duration(milliseconds: 250),
      pollTimeout: const Duration(milliseconds: 900),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Notify me'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text(
        'We could not set up the notice. Try again when you are '
        'online.',
      ),
      findsOneWidget,
    );
    expect(pushApi.tokens, isEmpty);

    // Let the wait time out so the poll stops rather than outliving the test.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(controller.phase, ClipPhase.error);
    await teardown(tester);
  });

  testWidgets(
    'a refused permission reads as a refusal, not a connectivity problem',
    (tester) async {
      final pushApi = MockPushRegistrationApi();
      final services = buildServices(
        api: MockLookupApi(pollsUntilReady: 100),
        pushApi: pushApi,
        pushTokens: ScriptedPushTokenProvider(
          const PushTokenRefused(permanently: false),
        ),
      );
      final controller = controllerFor(
        services,
        'xylograph',
        pollInterval: const Duration(milliseconds: 100),
        noticeThreshold: const Duration(milliseconds: 250),
        pollTimeout: const Duration(milliseconds: 900),
      );
      addTearDown(controller.dispose);

      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Notify me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      // A refusal is what happened, so the reader is not sent to try again when
      // they are online.
      expect(
        find.text(
          'Notifications are off, so we cannot send a heads-up. You can turn '
          'them on any time.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Try again when you are online'),
        findsNothing,
      );
      expect(pushApi.tokens, isEmpty);

      // Let the wait time out so the poll stops rather than outliving the test.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await teardown(tester);
    },
  );

  testWidgets('a refusal the platform will not ask again offers the settings', (
    tester,
  ) async {
    final permission = ScriptedNotificationPermission();
    final services = buildServices(
      api: MockLookupApi(pollsUntilReady: 100),
      pushTokens: ScriptedPushTokenProvider(
        const PushTokenRefused(permanently: true),
      ),
      notificationPermission: permission,
    );
    final controller = controllerFor(
      services,
      'xylograph',
      pollInterval: const Duration(milliseconds: 100),
      noticeThreshold: const Duration(milliseconds: 250),
      pollTimeout: const Duration(milliseconds: 900),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Notify me'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text(
        'Notifications are off for Scenova. Turn them on in your phone '
        'settings to get a heads-up.',
      ),
      findsOneWidget,
    );
    // The reader has a way forward rather than a dead end.
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(permission.settingsOpened, 1);

    // Let the wait time out so the poll stops rather than outliving the test.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await teardown(tester);
  });

  testWidgets('the permission prompt is raised when the offer is taken', (
    tester,
  ) async {
    final permission = ScriptedNotificationPermission();
    final messaging = _StubMessaging('fcm-token');
    final pushApi = MockPushRegistrationApi();
    final services = buildServices(
      api: MockLookupApi(pollsUntilReady: 100),
      pushApi: pushApi,
      pushTokens: FirebaseMessagingPushTokenProvider(
        permission: permission,
        messagingOverride: messaging,
      ),
    );
    final controller = controllerFor(
      services,
      'xylograph',
      pollInterval: const Duration(milliseconds: 100),
      noticeThreshold: const Duration(milliseconds: 250),
      pollTimeout: const Duration(milliseconds: 900),
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Nothing has been asked at launch: the prompt waits for the reader.
    expect(permission.requests, 0);
    expect(messaging.calls, 0);

    await tester.tap(find.text('Notify me'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // Taking the offer is the moment the prompt is raised, and the granted
    // token is then registered against the lookup.
    expect(permission.requests, 1);
    expect(messaging.calls, 1);
    expect(pushApi.tokens, <String>['fcm-token']);
    expect(
      find.text("We'll let you know when your clip is ready."),
      findsOneWidget,
    );

    // Let the wait time out so the poll stops rather than outliving the test.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await teardown(tester);
  });

  testWidgets('a word with no clip shows the note and a retry', (tester) async {
    final services = buildServices(api: MockLookupApi());
    final controller = controllerFor(services, 'quixotic');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.fallback);
    expect(find.text('No clip for this word yet.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('offline with no saved clip shows the offline message', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi(), online: false);
    final controller = controllerFor(services, 'quixotic');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.offline);
    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(find.text('This word is not saved on this device'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('offline with a saved clip replays it from the device', (
    tester,
  ) async {
    // The device kept the clip itself, so it replays with no connection.
    final services = buildServices(
      api: MockLookupApi(),
      online: false,
      clips: InMemoryClipStore(
        seed: <String, String>{'seed-come': 'file:///device/come.mp4'},
      ),
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipLocalKey: 'seed-come',
          ),
        ],
      ),
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(controller.clip?.url, 'file:///device/come.mp4');
    expect(find.text('to move towards someone'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('with offline replay off a saved clip does not play offline', (
    tester,
  ) async {
    // The kill switch (`enable_offline_history`) disables offline replay while
    // the on-device history stays: the saved clip is not served with no
    // connection, and the reader is told why.
    final services = buildServices(
      api: MockLookupApi(),
      online: false,
      clips: InMemoryClipStore(
        seed: <String, String>{'seed-come': 'file:///device/come.mp4'},
      ),
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipLocalKey: 'seed-come',
          ),
        ],
      ),
      featureFlags: const FixedFeatureFlags(offlineHistoryEnabled: false),
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.offline);
    expect(controller.playing, isFalse);
    expect(
      find.text(
        'Saved clips need a connection to play. Your history is still '
        'here.',
      ),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('a Free reader\'s saved lookup does not replay offline', (
    tester,
  ) async {
    // The Free tier keeps the word and phrase but not the clip
    // (`docs/Scenova/monetization.md` → "Feature Gate Mapping"), so a saved
    // lookup replays only while online.
    final services = buildServices(
      api: MockLookupApi(),
      online: false,
      entitlement: const Entitlement(
        tier: PlanTier.free,
        signedIn: true,
        lookupsUsed: 3,
        lookupsLimit: 20,
      ),
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipUrl: 'https://clips.example/come.mp4',
          ),
        ],
      ),
    );
    final controller = ClipViewController(
      services: services,
      selection: CaptureSelection.parse('come'),
      savedEntry: (await services.historyStore.all()).single,
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.offline);
    expect(controller.playing, isFalse);
    expect(find.text('come'), findsWidgets);
    await teardown(tester);
  });

  testWidgets('a Pro reader\'s saved lookup replays offline', (tester) async {
    final services = buildServices(
      api: MockLookupApi(),
      online: false,
      entitlement: const Entitlement(
        tier: PlanTier.pro,
        signedIn: true,
        lookupsUsed: 3,
        lookupsLimit: 50,
      ),
      clips: InMemoryClipStore(
        seed: <String, String>{'seed-come': 'file:///device/come.mp4'},
      ),
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipLocalKey: 'seed-come',
          ),
        ],
      ),
    );
    final controller = ClipViewController(
      services: services,
      selection: CaptureSelection.parse('come'),
      savedEntry: (await services.historyStore.all()).single,
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(controller.clip?.url, 'file:///device/come.mp4');
    await teardown(tester);
  });

  testWidgets('a Free reader\'s lookup keeps no clip on the device', (
    tester,
  ) async {
    final clips = InMemoryClipStore(onSave: (url) async => 'device://$url');
    final services = buildServices(
      api: MockLookupApi(),
      entitlement: const Entitlement(
        tier: PlanTier.free,
        signedIn: true,
        lookupsUsed: 3,
        lookupsLimit: 20,
      ),
      clips: clips,
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    final saved = (await services.historyStore.all()).single;
    expect(saved.clipLocalKey, isNull);
    expect(saved.clipUrl, isNotNull);
    await teardown(tester);
  });

  testWidgets('a failed lookup shows the error state with a retry', (
    tester,
  ) async {
    final services = buildServices(
      api: ThrowingLookupApi(
        const LookupApiException(500, 'The lookup service is unavailable.'),
      ),
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.error);
    expect(find.text('That lookup did not finish'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('reduce motion holds the clip on a still frame', (tester) async {
    final settings = SettingsController()..reduceMotionOverride = true;
    final services = buildServices(api: MockLookupApi(), settings: settings);
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(controller.playing, isFalse);
    expect(find.text('Tap to play'), findsOneWidget);

    await tester.tap(find.byType(ClipPlayer));
    await tester.pump();
    expect(controller.playing, isTrue);
    await teardown(tester);
  });

  testWidgets('a denied lookup offers to turn model processing back on', (
    tester,
  ) async {
    final services = buildServices(
      api: MockLookupApi(script: <LookupResult>[_denied('come')]),
      settings: SettingsController()..consentModelProcessing = false,
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.denied);
    expect(find.text('Turn on model processing'), findsOneWidget);

    await tester.tap(find.text('Turn on model processing'));
    await tester.pump();
    await tester.pump();

    expect(services.settings.consentModelProcessing, isTrue);
    expect(controller.phase, ClipPhase.playing);
    await teardown(tester);
  });

  testWidgets('an exhausted allowance shows the word and offers plans', (
    tester,
  ) async {
    final services = buildServices(
      api: MockLookupApi(),
      entitlement: const Entitlement(
        tier: PlanTier.free,
        signedIn: false,
        lookupsUsed: 20,
        lookupsLimit: 20,
      ),
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.allowanceExhausted);
    expect(find.text('come'), findsWidgets);
    expect(find.text('See plans'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the exhausted state opens the Paywall sheet', (tester) async {
    final services = buildServices(
      api: MockLookupApi(),
      entitlement: const Entitlement(
        tier: PlanTier.free,
        signedIn: true,
        lookupsUsed: 20,
        lookupsLimit: 20,
      ),
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('See plans'));
    await tester.pumpAndSettle();

    expect(find.text('Start Pro'), findsOneWidget);
    expect(find.text('Buy a top-up'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('with the paid tier killed the Paywall is hidden', (
    tester,
  ) async {
    final services = buildServices(
      api: MockLookupApi(),
      featureFlags: const FixedFeatureFlags(paidTierEnabled: false),
      entitlement: const Entitlement(
        tier: PlanTier.free,
        signedIn: true,
        lookupsUsed: 20,
        lookupsLimit: 20,
      ),
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    // The word and phrase still show; only the Paywall is gone.
    expect(controller.phase, ClipPhase.allowanceExhausted);
    expect(find.text('come'), findsWidgets);
    expect(find.text('See plans'), findsNothing);
    expect(
      find.text('You have used this month\'s lookups. They reset next month.'),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('a very long word wraps to two lines and then truncates', (
    tester,
  ) async {
    final longWord = 'pneumonoultramicroscopicsilicovolcanoconiosis${'x' * 40}';
    final services = buildServices(api: MockLookupApi());
    final controller = controllerFor(services, longWord);
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    final headings = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == longWord &&
          widget.maxLines == 2 &&
          widget.overflow == TextOverflow.ellipsis,
    );
    expect(headings, findsWidgets);
    await teardown(tester);
  });

  testWidgets('the page presentation keeps the History action', (tester) async {
    final services = buildServices(api: MockLookupApi());
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller, onOpenHistory: () {});
    await tester.pump();
    await tester.pump();

    expect(find.text('History'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a second selection reuses the open clip view', (tester) async {
    final harness = await pumpHarness(tester, api: MockLookupApi());
    await tester.pump();

    unawaited(harness.router.openSelection(CaptureSelection.parse('come')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ClipViewScreen), findsOneWidget);

    unawaited(harness.router.openSelection(CaptureSelection.parse('bank')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // One view, updated in place rather than stacked.
    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(find.text('Which meaning fits here?'), findsOneWidget);

    harness.router.dismissClip();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await teardown(tester);
  });

  testWidgets('a phrase clip arrives by the clip-ready notice and is kept', (
    tester,
  ) async {
    final source = ScriptedClipNoticeSource();
    final api = RecordingLookupApi(MockLookupApi());
    final services = buildServices(api: api, clipNoticeSource: source);
    final controller = controllerFor(services, 'once in a while');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    // The phrase shows with no clip: a phrase clip is never served on the
    // lookup read path (`C-001`/`C-002`, `FEAT-007`).
    expect(controller.phase, ClipPhase.generating);
    expect(controller.clip, isNull);

    // The clip-ready notice reaches the device, carrying the clip.
    source.deliver(
      ClipNotice(
        lookupId: controller.result!.lookupId,
        clipUrl: 'https://cdn.scenova.test/phrase.mp4',
        durationSeconds: 4,
        resolution: '360p',
        hasAudio: false,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(controller.clip!.url, 'https://cdn.scenova.test/phrase.mp4');
    final saved = await services.historyStore.all();
    expect(saved.single.kind, LookupKind.phrase);
    expect(saved.single.hasClip, isTrue);
    expect(api.createCalls, 1);

    // The same phrase looked up again is served from the device, with no new
    // generation (`FEAT-007`). The tree is reset first so a fresh clip view
    // mounts, as a later lookup would.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final replay = controllerFor(services, 'once in a while');
    addTearDown(replay.dispose);
    await pumpClipView(tester, services, replay);
    await tester.pump();
    await tester.pump();

    expect(replay.phase, ClipPhase.playing);
    expect(api.createCalls, 1);
    await teardown(tester);
  });

  testWidgets('a notice for another lookup leaves the open view alone', (
    tester,
  ) async {
    final source = ScriptedClipNoticeSource();
    final services = buildServices(
      api: MockLookupApi(pollsUntilReady: 100000),
      clipNoticeSource: source,
    );
    final controller = controllerFor(services, 'xylograph');

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.generating);

    // A notice for a lookup this view is not waiting on is not its clip.
    source.deliver(
      const ClipNotice(
        lookupId: 'some-other-lookup',
        clipUrl: 'https://cdn.scenova.test/other.mp4',
        durationSeconds: 4,
        resolution: '360p',
        hasAudio: false,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.generating);
    expect(controller.clip, isNull);

    controller.dispose();
    await teardown(tester);
  });

  testWidgets(
    'a phrase whose notice can never come shows the clip unavailable',
    (tester) async {
      // The reader refused notifications for good, so no notice can reach the
      // device; a phrase has no other delivery path, so the clip is unavailable
      // with a retry rather than a lookup that waits on nothing (`FEAT-007`).
      final services = buildServices(
        api: MockLookupApi(),
        pushTokens: ScriptedPushTokenProvider(
          const PushTokenIssued('test-push-token'),
          quietOutcome: const PushTokenRefused(permanently: true),
        ),
      );
      final controller = controllerFor(services, 'once in a while');
      addTearDown(controller.dispose);

      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();

      expect(controller.phase, ClipPhase.fallback);
      expect(find.text('No clip for this phrase yet.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(await services.historyStore.all(), isEmpty);
      await teardown(tester);
    },
  );

  testWidgets('a saved phrase plays from the device when offline', (
    tester,
  ) async {
    final services = buildServices(
      api: MockLookupApi(),
      online: false,
      clips: InMemoryClipStore(
        seed: <String, String>{
          'seed-once in a while': 'file:///device/once-in-a-while.mp4',
        },
      ),
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'once in a while',
            phrase: 'once in a while',
            kind: LookupKind.phrase,
            clipLocalKey: 'seed-once in a while',
          ),
        ],
      ),
    );
    final controller = controllerFor(services, 'once in a while');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
    expect(controller.clip?.url, 'file:///device/once-in-a-while.mp4');
    expect(find.text('once in a while'), findsWidgets);
    await teardown(tester);
  });

  testWidgets('an offline phrase with no saved clip says so', (tester) async {
    final services = buildServices(api: MockLookupApi(), online: false);
    final controller = controllerFor(services, 'once in a while');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.offline);
    expect(
      find.text('This phrase is not saved on this device'),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('a selection over six words asks the reader to narrow it', (
    tester,
  ) async {
    final api = RecordingLookupApi(MockLookupApi());
    final services = buildServices(api: api);
    final controller = controllerFor(
      services,
      'the quick brown fox jumps over the lazy dog',
    );
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();

    expect(controller.phase, ClipPhase.selectionTooLong);
    expect(find.text('Pick a shorter phrase'), findsOneWidget);
    // No lookup was sent for the over-limit selection.
    expect(api.createCalls, 0);
    await teardown(tester);
  });

  testWidgets('a declined phrase shows the fallback and stores nothing', (
    tester,
  ) async {
    final services = buildServices(
      api: MockLookupApi(
        script: <LookupResult>[_phraseFallback('tough it out')],
      ),
    );
    final controller = controllerFor(services, 'tough it out');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.fallback);
    expect(find.text('No clip for this phrase yet.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(await services.historyStore.all(), isEmpty);
    await teardown(tester);
  });

  testWidgets('the wait threshold is told at ten seconds, not the next poll', (
    tester,
  ) async {
    // A three-second poll against a ten-second threshold: counting poll ticks
    // would tell the reader at twelve seconds. The wait is a wall-clock
    // deadline, so it is told at ten.
    final services = buildServices(api: MockLookupApi(pollsUntilReady: 100000));
    final controller = controllerFor(
      services,
      'xylograph',
      pollInterval: const Duration(seconds: 3),
      noticeThreshold: const Duration(seconds: 10),
    );

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.generating);

    // Three poll ticks in — nine seconds — and the notice is not due yet.
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
    expect(controller.pastWaitThreshold, isFalse);
    expect(find.text('Still making your clip'), findsNothing);

    // One second later the wait has passed, before the next poll at twelve.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(controller.pastWaitThreshold, isTrue);
    expect(find.text('Still making your clip'), findsOneWidget);

    // The lookup is still generating, so stop its timers before the test ends.
    controller.dispose();
    await teardown(tester);
  });

  testWidgets('with the in-context view off the reader sees word and phrase', (
    tester,
  ) async {
    final services = buildServices(
      api: MockLookupApi(),
      featureFlags: const FixedFeatureFlags(clipViewEnabled: false),
    );
    final controller = controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    expect(controller.phase, ClipPhase.wordAndPhrase);
    expect(find.text('come'), findsWidgets);
    expect(find.text(_libraryPhrase), findsOneWidget);
    // No clip is offered and nothing plays.
    expect(controller.playing, isFalse);
    expect(findIcon(AppIcons.pause), findsNothing);
    expect(findIcon(AppIcons.play), findsNothing);
    await teardown(tester);
  });
}

LookupRequest _request(String selection) => LookupRequest(
  selection: selection,
  clientLookupId: 'key-$selection',
  platform: LookupPlatform.android,
  locale: 'en',
  consentModelProcessing: true,
);

LookupResult _denied(String selection) => LookupResult(
  lookupId: 'denied-1',
  kind: LookupKind.word,
  rawSelection: selection,
  normalisedLemma: selection,
  status: LookupStatus.denied,
  senses: const <Sense>[],
  notice: null,
  correlationId: 'test',
);

/// A phrase the provider declined: the phrase shows with no clip and nothing is
/// stored (`FEAT-007`).
LookupResult _phraseFallback(String selection) => LookupResult(
  lookupId: 'phrase-fallback-1',
  kind: LookupKind.phrase,
  rawSelection: selection,
  normalisedLemma: null,
  status: LookupStatus.fallback,
  senses: <Sense>[
    Sense(senseLabel: '1', partOfSpeech: '', glossPhrase: selection),
  ],
  notice: null,
  correlationId: 'test',
);
