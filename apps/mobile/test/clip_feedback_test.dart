import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/feedback.dart';
import 'package:scenova/models/clip_notice.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/clip_notice_source.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/feedback_api.dart';
import 'package:scenova/services/feedback_store.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/widgets/app_icons.dart';

import 'support/harness.dart';

/// A saved lookup the device holds, with the service lookup it was saved from.
HistoryEntry _savedLibraryHit({String? lookupId = 'lk_saved'}) {
  return HistoryEntry(
    id: 'come-1',
    word: 'come',
    phrase: 'a short clip that shows what the word means',
    kind: LookupKind.word,
    savedAt: DateTime.now(),
    clipUrl: 'mock://clip/library-hit',
    lookupId: lookupId,
  );
}

ClipViewController _controllerFor(ScenovaServices services, String text) {
  return ClipViewController(
    services: services,
    selection: CaptureSelection.parse(text),
  );
}

void main() {
  testWidgets('rating a clip sends it against the lookup it was served for', (
    tester,
  ) async {
    final api = MockFeedbackApi();
    final services = buildServices(api: MockLookupApi(), feedbackApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.helpful));
    await tester.pump();
    await tester.pump();

    expect(controller.feedback, ClipRating.helpful);
    expect(controller.feedbackDelivery, FeedbackDelivery.recorded);
    expect(api.recorded.single.lookupId, controller.result!.lookupId);
    expect(api.recorded.single.rating, ClipRating.helpful);
    expect(find.text('Thanks — noted.'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('a clip can be marked as showing the wrong meaning', (
    tester,
  ) async {
    final api = MockFeedbackApi();
    final services = buildServices(api: MockLookupApi(), feedbackApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.wrong));
    await tester.pump();
    await tester.pump();

    expect(api.recorded.single.rating, ClipRating.wrong);
    await teardown(tester);
  });

  testWidgets('rating the same clip again replaces the earlier rating', (
    tester,
  ) async {
    final api = MockFeedbackApi();
    final services = buildServices(api: MockLookupApi(), feedbackApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.notHelpful));
    await tester.pump();
    await tester.pump();
    await tester.tap(findIcon(AppIcons.helpful));
    await tester.pump();
    await tester.pump();

    expect(controller.feedback, ClipRating.helpful);
    expect(api.recorded.last.rating, ClipRating.helpful);
    await teardown(tester);
  });

  testWidgets('a rating made offline is held and sent on reconnect', (
    tester,
  ) async {
    final api = MockFeedbackApi();
    final services = buildServices(
      api: MockLookupApi(),
      feedbackApi: api,
      online: false,
      history: InMemoryHistoryStore(seed: <HistoryEntry>[_savedLibraryHit()]),
    );
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    // The clip replays from the device with no connection.
    expect(controller.phase, ClipPhase.playing);

    await tester.tap(findIcon(AppIcons.notHelpful));
    await tester.pump();
    await tester.pump();

    expect(controller.feedbackDelivery, FeedbackDelivery.queued);
    expect(
      find.text("Saved. It will go out when you're back online."),
      findsOneWidget,
    );
    expect(api.recorded, isEmpty);
    expect(services.feedbackOutbox.pendingCount, 1);

    (services.connectivity as ManualConnectivity).setOnline(true);
    await tester.pump();
    await tester.pump();

    expect(api.recorded.single.lookupId, 'lk_saved');
    expect(api.recorded.single.rating, ClipRating.notHelpful);
    expect(services.feedbackOutbox.pendingCount, 0);
    await teardown(tester);
  });

  testWidgets('a rating the service would not take is shown with a retry', (
    tester,
  ) async {
    final api = MockFeedbackApi()..failStatus = 404;
    final services = buildServices(api: MockLookupApi(), feedbackApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.helpful));
    await tester.pump();
    await tester.pump();

    expect(controller.feedbackDelivery, FeedbackDelivery.failed);
    expect(find.text("We couldn't save that just now."), findsOneWidget);

    api.failStatus = null;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();

    expect(controller.feedbackDelivery, FeedbackDelivery.recorded);
    expect(api.recorded.single.rating, ClipRating.helpful);
    await teardown(tester);
  });

  testWidgets('a phrase clip is rated against its own lookup', (tester) async {
    final api = MockFeedbackApi();
    final source = ScriptedClipNoticeSource();
    final services = buildServices(
      api: MockLookupApi(),
      feedbackApi: api,
      clipNoticeSource: source,
    );
    final controller = _controllerFor(services, 'once in a while');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    // A phrase clip reaches the device by the clip-ready notice; once it has,
    // the reader can rate it.
    expect(controller.phase, ClipPhase.generating);
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

    await tester.tap(findIcon(AppIcons.helpful));
    await tester.pump();
    await tester.pump();

    expect(api.recorded.single.lookupId, controller.result!.lookupId);
    expect(api.recorded.single.rating, ClipRating.helpful);
    await teardown(tester);
  });

  testWidgets('a rating held for the connection is written to the device', (
    tester,
  ) async {
    final store = InMemoryPendingFeedbackStore();
    final services = buildServices(
      api: MockLookupApi(),
      feedbackApi: MockFeedbackApi(),
      feedbackStore: store,
      online: false,
      history: InMemoryHistoryStore(seed: <HistoryEntry>[_savedLibraryHit()]),
    );
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.wrong));
    await tester.pump();
    await tester.pump();

    // The queue outlives the process, so the rating is not lost by a relaunch.
    final held = await store.load();
    expect(held.single.lookupId, 'lk_saved');
    expect(held.single.rating, ClipRating.wrong);
    await teardown(tester);
  });
}
