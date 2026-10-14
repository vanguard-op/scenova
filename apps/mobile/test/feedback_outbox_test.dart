import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/feedback.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/feedback_api.dart';
import 'package:scenova/services/feedback_outbox.dart';
import 'package:scenova/services/feedback_store.dart';

/// An outbox over a scripted intake and a connection driven by hand.
class _Fixture {
  _Fixture({
    bool online = true,
    int queueLimit = 100,
    PendingFeedbackStore? store,
  }) : connectivity = ManualConnectivity(online: online),
       api = MockFeedbackApi(),
       store = store ?? InMemoryPendingFeedbackStore() {
    var counter = 0;
    outbox = FeedbackOutbox(
      api: api,
      store: this.store,
      connectivity: connectivity,
      queueLimit: queueLimit,
      newId: () => 'key-${++counter}',
    );
  }

  final ManualConnectivity connectivity;
  final MockFeedbackApi api;
  final PendingFeedbackStore store;
  late final FeedbackOutbox outbox;

  void dispose() {
    outbox.dispose();
    connectivity.dispose();
  }
}

void main() {
  test('a rating given online is recorded and leaves nothing held', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);

    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      rating: ClipRating.helpful,
    );

    expect(outcome, FeedbackDelivery.recorded);
    expect(fixture.api.recorded.single.lookupId, 'lk_1');
    expect(fixture.api.recorded.single.rating, ClipRating.helpful);
    expect(fixture.outbox.pendingCount, 0);
  });

  test('a rating given offline is held and goes out on reconnect', () async {
    final fixture = _Fixture(online: false);
    addTearDown(fixture.dispose);

    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      rating: ClipRating.notHelpful,
    );

    expect(outcome, FeedbackDelivery.queued);
    expect(fixture.api.recorded, isEmpty);
    expect(fixture.outbox.pendingCount, 1);

    fixture.connectivity.setOnline(true);
    await pumpEventQueue();

    expect(fixture.api.recorded.single.rating, ClipRating.notHelpful);
    expect(fixture.outbox.pendingCount, 0);
  });

  test('the held queue survives a relaunch', () async {
    final store = InMemoryPendingFeedbackStore();
    final first = _Fixture(online: false, store: store);
    addTearDown(first.dispose);
    await first.outbox.submit(lookupId: 'lk_1', rating: ClipRating.wrong);

    // A fresh process over the same device store: the rating is still there.
    final second = _Fixture(store: store);
    addTearDown(second.dispose);
    await second.outbox.flush();

    expect(second.api.recorded.single.lookupId, 'lk_1');
    expect(second.api.recorded.single.rating, ClipRating.wrong);
    expect(second.outbox.pendingCount, 0);
  });

  test('rating the same clip again replaces the rating held for it', () async {
    final fixture = _Fixture(online: false);
    addTearDown(fixture.dispose);

    await fixture.outbox.submit(
      lookupId: 'lk_1',
      rating: ClipRating.notHelpful,
    );
    await fixture.outbox.submit(lookupId: 'lk_1', rating: ClipRating.wrong);

    // Only the reader's latest rating counts (C-012), so one is held, not two.
    expect(fixture.outbox.pendingCount, 1);
    expect(fixture.outbox.pending.single.rating, ClipRating.wrong);

    fixture.connectivity.setOnline(true);
    await pumpEventQueue();

    expect(fixture.api.recorded, hasLength(1));
    expect(fixture.api.recorded.single.rating, ClipRating.wrong);
  });

  test('a retry keeps the key the rating was minted with', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);

    fixture.api.failStatus = 503;
    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      rating: ClipRating.helpful,
    );

    // The store was unavailable, so the rating is held for another attempt.
    expect(outcome, FeedbackDelivery.failed);
    expect(fixture.outbox.pendingCount, 1);

    fixture.api.failStatus = null;
    await fixture.outbox.flush();

    // The same key is reused, so a rating that reached the service twice is
    // recorded once (C-012, clientFeedbackId).
    expect(fixture.api.recorded.single.clientFeedbackId, 'key-1');
  });

  test('a rating the service refused is not held for a retry', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);

    fixture.api.failStatus = 404;
    final outcome = await fixture.outbox.submit(
      lookupId: 'lk_1',
      rating: ClipRating.helpful,
    );

    expect(outcome, FeedbackDelivery.failed);
    expect(fixture.outbox.pendingCount, 0);
  });

  test('a refused rating does not block the ones behind it', () async {
    final fixture = _Fixture(online: false);
    addTearDown(fixture.dispose);
    await fixture.outbox.submit(lookupId: 'lk_1', rating: ClipRating.helpful);
    await fixture.outbox.submit(lookupId: 'lk_2', rating: ClipRating.helpful);

    // The first lookup is gone from the service; the second still counts.
    fixture.api
      ..failStatus = 404
      ..failLookupId = 'lk_1';
    fixture.connectivity.setOnline(true);
    await pumpEventQueue();

    expect(fixture.api.recorded.single.lookupId, 'lk_2');
    expect(fixture.outbox.pendingCount, 0);
  });

  test('the held queue is bounded, keeping the latest ratings', () async {
    final fixture = _Fixture(online: false, queueLimit: 2);
    addTearDown(fixture.dispose);

    await fixture.outbox.submit(lookupId: 'lk_1', rating: ClipRating.helpful);
    await fixture.outbox.submit(lookupId: 'lk_2', rating: ClipRating.helpful);
    await fixture.outbox.submit(lookupId: 'lk_3', rating: ClipRating.helpful);

    expect(fixture.outbox.pending.map((item) => item.lookupId), <String>[
      'lk_2',
      'lk_3',
    ]);
  });
}
