import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/analytics_event.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/analytics.dart';
import 'package:scenova/services/analytics_api.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/settings_controller.dart';

/// A client with deterministic identifiers and a high flush threshold, so a
/// test can inspect the queue without a send racing it.
AnalyticsClient _client({
  AnalyticsApi? api,
  SettingsController? settings,
  ConnectivityMonitor? connectivity,
  DateTime Function()? clock,
  int flushThreshold = 1000,
  int queueLimit = 500,
}) {
  var counter = 0;
  return AnalyticsClient(
    api: api ?? MockAnalyticsApi(),
    settings: settings ?? SettingsController(),
    connectivity: connectivity ?? ManualConnectivity(),
    anonymousId: 'anon',
    sessionId: 'session',
    appVersion: '9.9.9',
    locale: 'en-GB',
    platform: LookupPlatform.ios,
    newId: () => 'evt-${counter++}',
    clock: clock,
    flushThreshold: flushThreshold,
    queueLimit: queueLimit,
  );
}

void main() {
  group('AnalyticsEventName taxonomy', () {
    test('carries every taxonomy event with a unique EVT id', () {
      expect(AnalyticsEventName.values, hasLength(21));

      final ids = <String>{};
      for (final name in AnalyticsEventName.values) {
        expect(name.id, matches(RegExp(r'^EVT-\d{3}$')));
        expect(name.wire, isNotEmpty);
        expect(ids.add(name.id), isTrue, reason: '${name.id} is duplicated');
      }

      expect(AnalyticsEventName.lookupStarted.id, 'EVT-005');
      expect(AnalyticsEventName.lookupStarted.wire, 'lookup_started');
      expect(AnalyticsEventName.purchaseFailed.wire, 'purchase_failed');
    });

    test('gates exactly the reading-behaviour events on consent', () {
      final gated = AnalyticsEventName.values
          .where((name) => name.suppressedWithoutConsent)
          .map((name) => name.wire)
          .toSet();

      // Analytics Data Governance: these three, and only these three, are
      // suppressed until model-processing consent is granted.
      expect(gated, <String>{
        'lookup_started',
        'clip_played',
        'history_viewed',
      });
    });

    test('constrains every event to its taxonomy key properties', () {
      expect(AnalyticsEventName.lookupStarted.keyProperties, <String>{
        'kind',
        'source',
      });
      // The event's `platform` key property is the contract's common field, so
      // it is not repeated as a free-form property.
      expect(AnalyticsEventName.actionEnabled.keyProperties, isEmpty);
    });
  });

  group('AnalyticsClient common properties', () {
    test('an event carries the common properties in the C-007 wire shape', () {
      final client = _client(clock: () => DateTime.utc(2026, 1, 2, 3, 4, 5));
      addTearDown(client.dispose);

      client.appOpened(source: AppOpenSource.launch);
      final event = client.pending.single;
      final json = event.toJson();

      expect(json.keys, <String>{
        'eventId',
        'name',
        'occurredAt',
        'anonymousId',
        'sessionId',
        'platform',
        'appVersion',
        'locale',
        'properties',
      });
      expect(json['eventId'], 'evt-0');
      expect(json['name'], 'app_opened');
      expect(json['occurredAt'], '2026-01-02T03:04:05.000Z');
      expect(json['anonymousId'], 'anon');
      expect(json['sessionId'], 'session');
      expect(json['platform'], 'ios');
      expect(json['appVersion'], '9.9.9');
      expect(json['locale'], 'en-GB');
      expect(json['properties'], <String, Object?>{'source': 'launch'});
      expect(event.occurredAt.isUtc, isTrue);
    });

    test('each occurrence gets its own id', () {
      final client = _client();
      addTearDown(client.dispose);
      client.appOpened(source: AppOpenSource.launch);
      client.appOpened(source: AppOpenSource.resume);
      expect(
        client.pending.map((event) => event.eventId).toSet(),
        hasLength(2),
      );
    });
  });

  group('AnalyticsClient consent gating', () {
    test('suppresses reading behaviour until consent, then records it', () {
      final settings = SettingsController(consentModelProcessing: false);
      final client = _client(settings: settings);
      addTearDown(client.dispose);

      client.lookupStarted(kind: LookupKind.word, source: LookupSource.typed);
      client.clipPlayed(clipSource: ClipSource.library, entryId: 'lib-come');
      client.historyViewed(itemCount: 3);
      expect(client.pending, isEmpty);

      // Lifecycle and purchase events are not suppressed, and consent_changed
      // must be recorded even as consent is turned off.
      client.appOpened(source: AppOpenSource.launch);
      client.consentChanged(consent: false);
      client.purchaseCompleted(
        productId: 'pro.monthly',
        productKind: 'subscription',
      );
      expect(client.pending.map((event) => event.name.wire), <String>[
        'app_opened',
        'consent_changed',
        'purchase_completed',
      ]);

      settings.consentModelProcessing = true;
      client.lookupStarted(kind: LookupKind.word, source: LookupSource.typed);
      expect(client.pending.last.name, AnalyticsEventName.lookupStarted);
    });
  });

  group('AnalyticsClient no personal data', () {
    test('a reading event carries only the taxonomy key properties', () {
      final client = _client();
      addTearDown(client.dispose);

      client.lookupStarted(
        kind: LookupKind.phrase,
        source: LookupSource.androidAction,
      );
      final event = client.pending.single;

      expect(event.properties.keys, <String>{'kind', 'source'});
      expect(event.properties['kind'], 'phrase');
      expect(event.properties['source'], 'android_action');
      // The selected text is never a property.
      expect(event.toJson().toString(), isNot(contains('give up')));
    });

    test('a free-form property key is refused', () {
      final client = _client();
      addTearDown(client.dispose);

      expect(
        () => client.track(
          AnalyticsEventName.lookupStarted,
          properties: <String, Object?>{'word': 'bank'},
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(client.pending, isEmpty);
    });
  });

  group('AnalyticsClient delivery', () {
    test('flush delivers in batches of at most fifty', () async {
      final api = MockAnalyticsApi();
      final client = _client(api: api);
      addTearDown(client.dispose);

      for (var i = 0; i < 51; i++) {
        client.appOpened(source: AppOpenSource.resume);
      }
      await client.flush();

      expect(api.batches.map((batch) => batch.length), <int>[50, 1]);
      expect(client.pending, isEmpty);
    });

    test(
      'reaching the flush threshold sends without an explicit flush',
      () async {
        final api = MockAnalyticsApi();
        final client = _client(api: api, flushThreshold: 2);
        addTearDown(client.dispose);

        client.appOpened(source: AppOpenSource.launch);
        client.appOpened(source: AppOpenSource.resume);
        await pumpEventQueue();

        expect(api.sent, hasLength(2));
        expect(client.pending, isEmpty);
      },
    );

    test(
      'an offline flush keeps the queue and sends on reconnection',
      () async {
        final api = MockAnalyticsApi();
        final connectivity = ManualConnectivity(online: false);
        final client = _client(api: api, connectivity: connectivity);
        addTearDown(client.dispose);

        client.appOpened(source: AppOpenSource.launch);
        await client.flush();
        expect(api.sent, isEmpty);
        expect(client.pendingCount, 1);

        // Let the connectivity subscription settle before the change, so the
        // test exercises the reconnection rather than the subscription's start.
        await pumpEventQueue();
        connectivity.setOnline(true);
        await pumpEventQueue();
        expect(api.sent, hasLength(1));
        expect(client.pending, isEmpty);
      },
    );

    test('a rate-limited batch stays queued for a later attempt', () async {
      final api = MockAnalyticsApi()..failStatus = 429;
      final client = _client(api: api);
      addTearDown(client.dispose);

      client.appOpened(source: AppOpenSource.launch);
      await client.flush();
      expect(client.pendingCount, 1);

      api.failStatus = null;
      await client.flush();
      expect(client.pending, isEmpty);
      expect(api.sent, hasLength(1));
    });

    test('an unavailable intake holds the batch for retry', () async {
      // C-007: a 503 from the event intake is retryable — the batch is retained
      // and sent again, never dropped, so the phase's events (a report, a
      // purchase) are not lost to a brief outage.
      final api = MockAnalyticsApi()..failStatus = 503;
      final client = _client(api: api);
      addTearDown(client.dispose);

      client.appOpened(source: AppOpenSource.launch);
      await client.flush();
      expect(api.sent, isEmpty);
      expect(client.pendingCount, 1);

      api.failStatus = null;
      await client.flush();
      expect(client.pending, isEmpty);
      expect(api.sent, hasLength(1));
    });

    test('a rejected batch is dropped rather than retried', () async {
      final api = MockAnalyticsApi()..failStatus = 400;
      final client = _client(api: api);
      addTearDown(client.dispose);

      client.appOpened(source: AppOpenSource.launch);
      await client.flush();

      expect(client.pending, isEmpty);
      expect(api.sent, isEmpty);
    });

    test('the offline queue is bounded', () {
      final client = _client(
        connectivity: ManualConnectivity(online: false),
        queueLimit: 2,
      );
      addTearDown(client.dispose);

      for (var i = 0; i < 4; i++) {
        client.appOpened(source: AppOpenSource.resume);
      }
      expect(client.pendingCount, 2);
    });
  });
}
