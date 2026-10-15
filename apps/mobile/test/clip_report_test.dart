import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/clip_notice.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/models/report.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/clip_notice_source.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/report_api.dart';
import 'package:scenova/services/reported_clip_store.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// A saved lookup the device holds, with the service lookup it was saved from,
/// so an offline clip replays and can still be reported.
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

/// Opens the Report sheet over a playing clip and lets it settle in.
Future<void> _openReportSheet(WidgetTester tester) async {
  await tester.tap(find.text('Report'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Chooses a reason and submits the report.
Future<void> _chooseAndSubmit(
  WidgetTester tester, {
  String reason = 'It shows the wrong meaning',
}) async {
  await tester.ensureVisible(find.text(reason));
  await tester.pump();
  await tester.tap(find.text(reason));
  await tester.pump();
  await tester.ensureVisible(find.text('Submit report'));
  await tester.pump();
  await tester.tap(find.text('Submit report'));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'the report sheet opens on the reasons and holds Submit until one '
    'is chosen',
    (tester) async {
      final services = buildServices(api: MockLookupApi());
      final controller = _controllerFor(services, 'come');
      addTearDown(controller.dispose);

      usePhoneWindow(tester);
      await pumpClipView(tester, services, controller);
      await tester.pump();
      await tester.pump();
      expect(controller.phase, ClipPhase.playing);

      await _openReportSheet(tester);

      expect(find.text('Report this clip'), findsOneWidget);
      for (final reason in ReportReason.values) {
        expect(find.text(reason.label), findsOneWidget);
      }
      expect(find.text('Add a note (optional)'), findsOneWidget);

      // No reason chosen: Submit stays disabled (`FEAT-011`, Edge Cases).
      ScenovaButton submit() => tester.widget<ScenovaButton>(
        find.widgetWithText(ScenovaButton, 'Submit report'),
      );
      expect(submit().onPressed, isNull);

      await tester.tap(find.text(ReportReason.wrongMeaning.label));
      await tester.pump();

      expect(submit().onPressed, isNotNull);
      await teardown(tester);
    },
  );

  testWidgets('reporting a clip queues it for review and confirms', (
    tester,
  ) async {
    final api = MockReportApi();
    final services = buildServices(api: MockLookupApi(), reportApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await _openReportSheet(tester);
    await _chooseAndSubmit(tester);

    expect(api.recorded.single.lookupId, controller.result!.lookupId);
    expect(api.recorded.single.reason, ReportReason.wrongMeaning);
    // The sheet closes and the reader is told what came of it.
    expect(find.text('Report this clip'), findsNothing);
    expect(
      find.text("Thanks — we'll check this clip before it's shown again."),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('the note the reader writes goes with the report', (
    tester,
  ) async {
    final api = MockReportApi();
    final services = buildServices(api: MockLookupApi(), reportApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await _openReportSheet(tester);
    await tester.enterText(find.byType(TextField), 'It showed the other sense');
    await tester.pump();
    await _chooseAndSubmit(tester, reason: 'Something else');

    expect(api.recorded.single.note, 'It showed the other sense');
    await teardown(tester);
  });

  testWidgets('a report made offline is held and sent on reconnect', (
    tester,
  ) async {
    final api = MockReportApi();
    final services = buildServices(
      api: MockLookupApi(),
      reportApi: api,
      online: false,
      history: InMemoryHistoryStore(seed: <HistoryEntry>[_savedLibraryHit()]),
    );
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.playing);

    await _openReportSheet(tester);

    // The sheet tells the reader the report will be sent later.
    expect(
      find.text(
        "You're offline. Your report will be sent when you're back online.",
      ),
      findsOneWidget,
    );

    await _chooseAndSubmit(tester);

    expect(
      find.text("Saved. Your report will go out when you're back online."),
      findsOneWidget,
    );
    expect(api.recorded, isEmpty);
    expect(services.reportOutbox.pendingCount, 1);

    (services.connectivity as ManualConnectivity).setOnline(true);
    await tester.pump();
    await tester.pump();

    expect(api.recorded.single.lookupId, 'lk_saved');
    expect(api.recorded.single.reason, ReportReason.wrongMeaning);
    expect(services.reportOutbox.pendingCount, 0);
    await teardown(tester);
  });

  testWidgets('a report the service would not take is shown with a retry', (
    tester,
  ) async {
    final api = MockReportApi()..failStatus = 404;
    final services = buildServices(api: MockLookupApi(), reportApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await _openReportSheet(tester);
    await _chooseAndSubmit(tester);

    // The sheet stays open with an inline message and a retry.
    expect(find.text('Report this clip'), findsOneWidget);
    expect(find.text("We couldn't send that just now."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    api.failStatus = null;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Report this clip'), findsNothing);
    expect(api.recorded.single.reason, ReportReason.wrongMeaning);
    await teardown(tester);
  });

  testWidgets('a clip the reader already reported is confirmed, not refused', (
    tester,
  ) async {
    final api = MockReportApi()..failStatus = 409;
    final services = buildServices(api: MockLookupApi(), reportApi: api);
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    await _openReportSheet(tester);
    await _chooseAndSubmit(tester);

    expect(find.text('Report this clip'), findsNothing);
    expect(
      find.text("You've already reported this clip. Thanks."),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('a phrase clip is reported as private to the device', (
    tester,
  ) async {
    final api = MockReportApi();
    final source = ScriptedClipNoticeSource();
    final services = buildServices(
      api: MockLookupApi(),
      reportApi: api,
      clipNoticeSource: source,
    );
    final controller = _controllerFor(services, 'once in a while');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    // A phrase clip reaches the device by the clip-ready notice.
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

    await _openReportSheet(tester);

    // The reader is told the clip is private to the device and the report has
    // no shared effect (`FEAT-011`).
    expect(find.textContaining('saved only on your device'), findsOneWidget);

    await _chooseAndSubmit(tester);

    expect(
      find.text(
        'Thanks. This clip lives only on your device, so nothing else changes.',
      ),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('the report action is not offered until a clip is playing', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi(pollsUntilReady: 100000));
    final controller = _controllerFor(services, 'xylograph');

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.generating);

    // A report names the clip the reader saw; there is none yet.
    expect(find.text('Report'), findsNothing);

    // The lookup is still generating, so stop its timers before the test ends.
    controller.dispose();
    await teardown(tester);
  });

  testWidgets('reporting a clip registers for the regenerated clip notice', (
    tester,
  ) async {
    final api = MockReportApi();
    final pushApi = MockPushRegistrationApi();
    final services = buildServices(
      api: MockLookupApi(),
      reportApi: api,
      pushApi: pushApi,
    );
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.playing);
    final lookupId = controller.result!.lookupId;

    await _openReportSheet(tester);
    await _chooseAndSubmit(tester);
    await tester.pump();

    // A word report regenerates one clip for the reporting reader, delivered by
    // the clip-ready notice, so the device is registered for it (`FEAT-011`).
    expect(services.reportedClips.isAwaiting(lookupId), isTrue);
    expect(pushApi.lookupIds, <String>[lookupId]);
    await teardown(tester);
  });

  testWidgets('a phrase report registers for no notice', (tester) async {
    final api = MockReportApi();
    final source = ScriptedClipNoticeSource();
    final services = buildServices(
      api: MockLookupApi(),
      reportApi: api,
      clipNoticeSource: source,
    );
    final controller = _controllerFor(services, 'once in a while');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();

    // A phrase clip reaches the device by the clip-ready notice.
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
    final lookupId = controller.result!.lookupId;

    await _openReportSheet(tester);
    await _chooseAndSubmit(tester);
    await tester.pump();

    // A phrase clip is private to the device, so its report has no shared
    // effect and nothing is regenerated to wait on (`FEAT-011`).
    expect(services.reportedClips.isAwaiting(lookupId), isFalse);
    await teardown(tester);
  });

  testWidgets('the regenerated clip replaces the reported one in history', (
    tester,
  ) async {
    final api = MockReportApi();
    final source = ScriptedClipNoticeSource();
    final store = InMemoryReportedClipStore();
    final services = buildServices(
      api: MockLookupApi(),
      reportApi: api,
      clipNoticeSource: source,
      reportedClipStore: store,
    );
    final controller = _controllerFor(services, 'come');
    addTearDown(controller.dispose);

    usePhoneWindow(tester);
    await pumpClipView(tester, services, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ClipPhase.playing);
    final lookupId = controller.result!.lookupId;

    await _openReportSheet(tester);
    await _chooseAndSubmit(tester);
    await tester.pump();

    final reported = (await services.historyStore.all()).single;
    expect(reported.lookupId, lookupId);
    expect(reported.clipUrl, 'mock://clip/library-hit');

    // The regenerated clip arrives by the clip-ready notice (`FEAT-011`).
    source.deliver(
      ClipNotice(
        lookupId: lookupId,
        clipUrl: 'https://cdn.scenova.test/regenerated.mp4',
        durationSeconds: 4,
        resolution: '360p',
        hasAudio: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final replaced = (await services.historyStore.all()).single;
    expect(replaced.id, reported.id);
    expect(replaced.clipUrl, 'https://cdn.scenova.test/regenerated.mp4');
    // The awaited record is cleared once the clip has been replaced.
    expect(await store.load(), isNot(contains(lookupId)));
    await teardown(tester);
  });
}
