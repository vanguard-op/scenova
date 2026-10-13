import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/widgets/app_icons.dart';
import 'package:scenova/widgets/clip_player.dart';
import 'package:scenova/widgets/offline_banner.dart';

import 'support/harness.dart';

const String _libraryPhrase = 'a short clip that shows what the word means';

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
    final services = buildServices(
      api: MockLookupApi(),
      online: false,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipUrl: 'device://come',
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
    expect(find.text('to move towards someone'), findsOneWidget);
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
        lookupsRemaining: 0,
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

  testWidgets('a phrase clip is saved to the device and replayed from it', (
    tester,
  ) async {
    final api = RecordingLookupApi(MockLookupApi(pollsUntilReady: 1));
    final services = buildServices(api: api);
    final controller = controllerFor(services, 'once in a while');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(controller.phase, ClipPhase.playing);
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

  testWidgets('a saved phrase plays from the device when offline', (
    tester,
  ) async {
    final services = buildServices(
      api: MockLookupApi(),
      online: false,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'once in a while',
            phrase: 'once in a while',
            kind: LookupKind.phrase,
            clipUrl: 'device://once-in-a-while',
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
