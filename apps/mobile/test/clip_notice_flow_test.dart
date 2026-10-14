import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/clip_notice.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/clip_notice_inbox.dart';
import 'package:scenova/services/clip_notice_source.dart';
import 'package:scenova/services/feature_flags.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/push_tokens.dart';
import 'package:scenova/services/settings_controller.dart';

import 'support/harness.dart';

/// The payload the notification service pushes, as Firebase Cloud Messaging
/// carries it: every value a string (`C-008`).
const Map<String, dynamic> _wirePayload = <String, dynamic>{
  'lookupId': 'lk_ready',
  'clipUrl': 'https://cdn.scenova.test/lk_ready.mp4',
  'durationSeconds': '4',
  'resolution': '360p',
  'hasAudio': 'false',
};

/// A word lookup still generating, so a notice is what settles it.
LookupResult _waitingWord() => const LookupResult(
  lookupId: 'lk_ready',
  kind: LookupKind.word,
  rawSelection: 'xylograph',
  normalisedLemma: null,
  status: LookupStatus.generating,
  senses: <Sense>[
    Sense(
      senseLabel: '1',
      partOfSpeech: 'verb',
      glossPhrase: 'to print a picture from a carved block of wood',
    ),
  ],
  notice: null,
  correlationId: 'test',
);

ClipViewController _controllerFor(
  ScenovaServices services,
  String text, {
  Duration noticeThreshold = const Duration(milliseconds: 250),
}) {
  return ClipViewController(
    services: services,
    selection: CaptureSelection.parse(text),
    pollInterval: const Duration(milliseconds: 100),
    noticeThreshold: noticeThreshold,
    pollTimeout: const Duration(minutes: 5),
  );
}

void main() {
  group('ClipNotice.fromData', () {
    test('reads the contract payload the provider carries', () {
      final notice = ClipNotice.fromData(_wirePayload);

      expect(notice, isNotNull);
      expect(notice!.lookupId, 'lk_ready');
      expect(notice.clipUrl, 'https://cdn.scenova.test/lk_ready.mp4');
      expect(notice.durationSeconds, 4);
      expect(notice.resolution, '360p');
      expect(notice.hasAudio, isFalse);
      expect(notice.clip.url, notice.clipUrl);
    });

    test('reads a payload without a lookup or a clip as no notice', () {
      expect(
        ClipNotice.fromData(<String, dynamic>{'clipUrl': 'https://x.test/a'}),
        isNull,
      );
      expect(
        ClipNotice.fromData(<String, dynamic>{'lookupId': 'lk_1'}),
        isNull,
      );
      expect(
        ClipNotice.fromData(<String, dynamic>{'lookupId': ' ', 'clipUrl': ' '}),
        isNull,
      );
    });

    test('reads a typed payload as the provider would send it', () {
      final notice = ClipNotice.fromData(<String, dynamic>{
        'lookupId': 'lk_2',
        'clipUrl': 'https://cdn.scenova.test/lk_2.mp4',
        'durationSeconds': 3.5,
        'resolution': '360p',
        'hasAudio': true,
      });

      expect(notice!.durationSeconds, 3.5);
      expect(notice.hasAudio, isTrue);
    });

    test('an unreadable duration reads as none, not as a made-up length', () {
      final notice = ClipNotice.fromData(<String, dynamic>{
        'lookupId': 'lk_3',
        'clipUrl': 'https://cdn.scenova.test/lk_3.mp4',
        'durationSeconds': 'soon',
      });

      expect(notice!.durationSeconds, 0);
    });
  });

  group('ClipNoticeInbox', () {
    test('delivers a notice to whoever is listening', () async {
      final source = ScriptedClipNoticeSource();
      final inbox = ClipNoticeInbox(source: source);
      addTearDown(inbox.dispose);
      final received = <ClipNotice>[];
      inbox.notices.listen(received.add);

      source.deliverData(_wirePayload);
      await pumpEventQueue();

      expect(received.single.lookupId, 'lk_ready');
    });

    test('keeps a notice for its lookup until the view takes it', () async {
      final source = ScriptedClipNoticeSource();
      final inbox = ClipNoticeInbox(source: source);
      addTearDown(inbox.dispose);

      source.deliverData(_wirePayload);
      await pumpEventQueue();

      expect(inbox.takeFor('lk_ready')?.clipUrl, endsWith('lk_ready.mp4'));
      // Taken once: the next view to open has nothing waiting for it.
      expect(inbox.takeFor('lk_ready'), isNull);
    });

    test('takes up the notice the app was opened from', () async {
      final source = ScriptedClipNoticeSource(
        initialNotice: ClipNotice.fromData(_wirePayload),
      );
      final inbox = ClipNoticeInbox(source: source);
      addTearDown(inbox.dispose);

      await pumpEventQueue();

      expect(inbox.takeFor('lk_ready'), isNotNull);
    });

    test('drops a payload that is not a notice', () async {
      final source = ScriptedClipNoticeSource();
      final inbox = ClipNoticeInbox(source: source);
      addTearDown(inbox.dispose);
      final received = <ClipNotice>[];
      inbox.notices.listen(received.add);

      source.deliverData(<String, dynamic>{'lookupId': 'lk_1'});
      await pumpEventQueue();

      expect(received, isEmpty);
      expect(inbox.takeFor('lk_1'), isNull);
    });

    test('keeps only the most recent notice for a lookup', () async {
      final source = ScriptedClipNoticeSource();
      final inbox = ClipNoticeInbox(source: source);
      addTearDown(inbox.dispose);

      source.deliverData(_wirePayload);
      source.deliverData(<String, dynamic>{
        ..._wirePayload,
        'clipUrl': 'https://cdn.scenova.test/lk_ready-later.mp4',
      });
      await pumpEventQueue();

      expect(inbox.takeFor('lk_ready')?.clipUrl, endsWith('later.mp4'));
    });
  });

  group('the clip-ready notice settles the view', () {
    testWidgets('a notice plays the clip and keeps it on the device', (
      tester,
    ) async {
      final source = ScriptedClipNoticeSource();
      final services = buildServices(
        api: MockLookupApi(
          pollsUntilReady: 100000,
          script: <LookupResult>[_waitingWord()],
        ),
        clipNoticeSource: source,
      );
      final controller = _controllerFor(services, 'xylograph');
      addTearDown(controller.dispose);

      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();
      expect(controller.phase, ClipPhase.generating);

      source.deliverData(_wirePayload);
      await tester.pump();
      await tester.pump();

      expect(controller.phase, ClipPhase.playing);
      expect(controller.clip!.url, 'https://cdn.scenova.test/lk_ready.mp4');
      final saved = await services.historyStore.all();
      expect(saved.single.word, 'xylograph');
      expect(saved.single.clipUrl, 'https://cdn.scenova.test/lk_ready.mp4');
      await teardown(tester);
    });

    testWidgets('a notice that arrived first is taken up when the view opens', (
      tester,
    ) async {
      // The reader opened the app from the notice before the view was up.
      final source = ScriptedClipNoticeSource();
      final services = buildServices(
        api: MockLookupApi(
          pollsUntilReady: 100000,
          script: <LookupResult>[_waitingWord()],
        ),
        clipNoticeSource: source,
      );
      source.deliverData(_wirePayload);
      await tester.pump();

      final controller = _controllerFor(services, 'xylograph');
      addTearDown(controller.dispose);
      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();

      expect(controller.phase, ClipPhase.playing);
      expect(controller.clip, isNotNull);
      await teardown(tester);
    });

    testWidgets('reduce motion holds the noticed clip on a still frame', (
      tester,
    ) async {
      final source = ScriptedClipNoticeSource();
      final services = buildServices(
        api: MockLookupApi(
          pollsUntilReady: 100000,
          script: <LookupResult>[_waitingWord()],
        ),
        clipNoticeSource: source,
        settings: SettingsController()..reduceMotionOverride = true,
      );
      final controller = _controllerFor(services, 'xylograph');
      addTearDown(controller.dispose);

      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();

      // A source the platform cannot stream keeps the still poster, which is
      // where reduce motion holds the clip.
      source.deliver(
        ClipNotice(
          lookupId: controller.result!.lookupId,
          clipUrl: 'device://held-frame',
          durationSeconds: 4,
          resolution: '360p',
          hasAudio: false,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.phase, ClipPhase.playing);
      expect(controller.playing, isFalse);
      expect(find.text('Tap to play'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('a phrase registers for its notice without asking the reader', (
      tester,
    ) async {
      // A phrase clip has no delivery path but the notice, so the device is
      // registered as soon as the phrase generates; the prompt is not raised,
      // because the notify offer is where the reader's intent is behind it.
      final permission = ScriptedNotificationPermission();
      final pushApi = MockPushRegistrationApi();
      final services = buildServices(
        api: MockLookupApi(),
        pushApi: pushApi,
        notificationPermission: permission,
        pushTokens: ScriptedPushTokenProvider(
          const PushTokenIssued('test-push-token'),
        ),
      );
      final controller = _controllerFor(services, 'once in a while');

      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();

      expect(permission.requests, 0);
      expect(pushApi.tokens, <String>['test-push-token']);
      expect(pushApi.lookupIds, <String>[controller.result!.lookupId]);
      // The lookup is still generating, so its poll is stopped before the test
      // ends rather than outliving it.
      controller.dispose();
      await teardown(tester);
    });

    testWidgets('a notice the service cannot send leaves the phrase playable '
        'only from the device', (tester) async {
      // The reader takes the offer and refuses: no notice can come, so a
      // phrase shows the clip as unavailable with a retry (`FEAT-007`).
      final services = buildServices(
        api: MockLookupApi(pollsUntilReady: 100000),
        pushTokens: ScriptedPushTokenProvider(
          const PushTokenRefused(permanently: false),
          quietOutcome: const PushTokenRefused(permanently: false),
        ),
      );
      final controller = _controllerFor(services, 'once in a while');

      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Notify me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.phase, ClipPhase.fallback);
      expect(await services.historyStore.all(), isEmpty);
      controller.dispose();
      await teardown(tester);
    });

    testWidgets('the notice path is silent while the clip view is off', (
      tester,
    ) async {
      final source = ScriptedClipNoticeSource();
      final services = buildServices(
        api: MockLookupApi(
          pollsUntilReady: 100000,
          script: <LookupResult>[_waitingWord()],
        ),
        clipNoticeSource: source,
        featureFlags: const FixedFeatureFlags(clipViewEnabled: false),
      );
      final controller = _controllerFor(services, 'xylograph');
      addTearDown(controller.dispose);

      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();

      source.deliverData(_wirePayload);
      await tester.pump();
      await tester.pump();

      // No clip is played and nothing is stored; the word and its phrase are
      // what the reader gets.
      expect(controller.phase, ClipPhase.wordAndPhrase);
      expect(controller.playing, isFalse);
      expect(await services.historyStore.all(), isEmpty);
      await teardown(tester);
    });
  });
}
