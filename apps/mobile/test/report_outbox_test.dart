import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/report.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/report_api.dart';
import 'package:scenova/services/report_outbox.dart';
import 'package:scenova/services/report_store.dart';

/// An outbox over a scripted intake and a connection driven by hand.
class _Fixture {
  _Fixture({
    bool online = true,
    int queueLimit = 100,
    PendingReportStore? store,
  }) : connectivity = ManualConnectivity(online: online),
       api = MockReportApi(),
       store = store ?? InMemoryPendingReportStore() {
    var counter = 0;
    outbox = ReportOutbox(
      api: api,
      store: this.store,
      connectivity: connectivity,
      queueLimit: queueLimit,
      newId: () => 'key-${++counter}',
    );
  }

  final ManualConnectivity connectivity;
  final MockReportApi api;
  final PendingReportStore store;
  late final ReportOutbox outbox;

  void dispose() {
    outbox.dispose();
    connectivity.dispose();
  }
}

void main() {
  test(
    'a report sent online is queued by the service and nothing is held',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);

      final outcome = await fixture.outbox.submit(
        lookupId: 'lk_1',
        reason: ReportReason.offensive,
      );

      expect(outcome, ReportDelivery.sent);
      expect(fixture.api.recorded.single.lookupId, 'lk_1');
      expect(fixture.api.recorded.single.reason, ReportReason.offensive);
      expect(fixture.outbox.pendingCount, 0);
    },
  );

  test('a report given offline is held and goes out on reconnect', () async {
    final fixture = _Fixture(online: false);
    addTearDown(fixture.dispose);

    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      reason: ReportReason.wrongMeaning,
      note: 'Showed the other sense',
    );

    expect(outcome, ReportDelivery.queued);
    expect(fixture.api.recorded, isEmpty);
    expect(fixture.outbox.pendingCount, 1);

    fixture.connectivity.setOnline(true);
    await pumpEventQueue();

    expect(fixture.api.recorded.single.reason, ReportReason.wrongMeaning);
    expect(fixture.api.recorded.single.note, 'Showed the other sense');
    expect(fixture.outbox.pendingCount, 0);
  });

  test('the held queue survives a relaunch', () async {
    final store = InMemoryPendingReportStore();
    final first = _Fixture(online: false, store: store);
    addTearDown(first.dispose);
    await first.outbox.submit(
      lookupId: 'lk_1',
      reason: ReportReason.lowQuality,
    );

    // A fresh process over the same device store: the report is still there.
    final second = _Fixture(store: store);
    addTearDown(second.dispose);
    await second.outbox.flush();

    expect(second.api.recorded.single.lookupId, 'lk_1');
    expect(second.api.recorded.single.reason, ReportReason.lowQuality);
    expect(second.outbox.pendingCount, 0);
  });

  test(
    'reporting the same clip again replaces the report held for it',
    () async {
      final fixture = _Fixture(online: false);
      addTearDown(fixture.dispose);

      await fixture.outbox.submit(lookupId: 'lk_1', reason: ReportReason.other);
      await fixture.outbox.submit(
        lookupId: 'lk_1',
        reason: ReportReason.offensive,
      );

      // One reader reports a given clip once (C-013), so one is held, not two.
      expect(fixture.outbox.pendingCount, 1);
      expect(fixture.outbox.pending.single.reason, ReportReason.offensive);

      fixture.connectivity.setOnline(true);
      await pumpEventQueue();

      expect(fixture.api.recorded, hasLength(1));
      expect(fixture.api.recorded.single.reason, ReportReason.offensive);
    },
  );

  test('a retry keeps the key the report was minted with', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);

    fixture.api.failStatus = 503;
    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      reason: ReportReason.offensive,
    );

    // The store was unavailable, so the report is held for another attempt.
    expect(outcome, ReportDelivery.failed);
    expect(fixture.outbox.pendingCount, 1);

    fixture.api.failStatus = null;
    await fixture.outbox.flush();

    // The same key is reused, so a report that reached the service twice is
    // recorded once (C-013, clientReportId).
    expect(fixture.api.recorded.single.clientReportId, 'key-1');
  });

  test('a report the service refused is not held for a retry', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);

    fixture.api.failStatus = 404;
    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      reason: ReportReason.offensive,
    );

    expect(outcome, ReportDelivery.failed);
    expect(fixture.outbox.pendingCount, 0);
  });

  test('a clip the reader already reported is not held again', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);

    fixture.api.failStatus = 409;
    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      reason: ReportReason.offensive,
    );

    // The service keeps the report it already holds (C-013, 409).
    expect(outcome, ReportDelivery.duplicate);
    expect(fixture.outbox.pendingCount, 0);
  });

  test('a refused report does not block the ones behind it', () async {
    final fixture = _Fixture(online: false);
    addTearDown(fixture.dispose);
    await fixture.outbox.submit(lookupId: 'lk_1', reason: ReportReason.other);
    await fixture.outbox.submit(lookupId: 'lk_2', reason: ReportReason.other);

    // The first lookup is gone from the service; the second still counts.
    fixture.api
      ..failStatus = 404
      ..failLookupId = 'lk_1';
    fixture.connectivity.setOnline(true);
    await pumpEventQueue();

    expect(fixture.api.recorded.single.lookupId, 'lk_2');
    expect(fixture.outbox.pendingCount, 0);
  });

  test('the held queue is bounded, keeping the latest reports', () async {
    final fixture = _Fixture(online: false, queueLimit: 2);
    addTearDown(fixture.dispose);

    await fixture.outbox.submit(lookupId: 'lk_1', reason: ReportReason.other);
    await fixture.outbox.submit(lookupId: 'lk_2', reason: ReportReason.other);
    await fixture.outbox.submit(lookupId: 'lk_3', reason: ReportReason.other);

    expect(fixture.outbox.pending.map((item) => item.lookupId), <String>[
      'lk_2',
      'lk_3',
    ]);
  });
}
