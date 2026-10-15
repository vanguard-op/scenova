import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/clip_store.dart';
import 'package:scenova/services/entitlement_api.dart';
import 'package:scenova/services/entitlement_provider.dart';
import 'package:scenova/services/feature_flags.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/poster_frame_store.dart';
import 'package:scenova/services/saved_clip_keeper.dart';
import 'package:scenova/services/tier_gates.dart';

/// The Free tier at its cap, as `C-018` reports it.
const Entitlement _free = Entitlement(
  tier: PlanTier.free,
  signedIn: true,
  lookupsUsed: 12,
  lookupsLimit: 20,
);

/// A Pro reader, as `C-018` reports it.
const Entitlement _pro = Entitlement(
  tier: PlanTier.pro,
  signedIn: true,
  lookupsUsed: 8,
  lookupsLimit: 50,
);

TierGates _gates(Entitlement plan, {bool paidTier = true}) => TierGates(
  entitlements: FixedEntitlementProvider(plan),
  flags: FixedFeatureFlags(paidTierEnabled: paidTier),
);

HistoryEntry _entry(String word, {Duration age = const Duration(minutes: 1)}) {
  return HistoryEntry(
    id: 'seed-$word',
    word: word,
    phrase: 'meaning of $word',
    kind: LookupKind.word,
    savedAt: DateTime.now().subtract(age),
    clipUrl: 'https://clips.example/$word.mp4',
  );
}

void main() {
  group('TierGates', () {
    test('the Free tier keeps no clip and caps the history', () async {
      final gates = _gates(_free);

      expect(await gates.retainsClips(), isFalse);
      expect(await gates.historyLimit(), kFreeTierHistoryCapacity);
    });

    test('Pro keeps clips and leaves the history uncapped', () async {
      final gates = _gates(_pro);

      expect(await gates.retainsClips(), isTrue);
      expect(await gates.historyLimit(), isNull);
    });

    test('the trial carries the Pro gates', () async {
      final gates = _gates(
        const Entitlement(tier: PlanTier.trial, signedIn: true),
      );

      expect(await gates.retainsClips(), isTrue);
      expect(await gates.historyLimit(), isNull);
    });

    test('a signed-out reader is held to the Free gates', () async {
      final gates = _gates(Entitlement.signedOut);

      expect(await gates.retainsClips(), isFalse);
      expect(await gates.historyLimit(), kFreeTierHistoryCapacity);
    });

    test('the pre-account plan keeps clips and stays capped', () async {
      // A build that has not read the plan yet behaves as it did before the
      // tiers shipped: clips are kept, the history is capped at the Free limit.
      final gates = _gates(Entitlement.unmeteredGuest);

      expect(await gates.retainsClips(), isTrue);
      expect(await gates.historyLimit(), kFreeTierHistoryCapacity);
    });

    test('the paid-tier kill switch reverts every reader to Free', () async {
      final gates = _gates(_pro, paidTier: false);

      expect(await gates.retainsClips(), isFalse);
      expect(await gates.historyLimit(), kFreeTierHistoryCapacity);
    });
  });

  group('SavedClipKeeper under the tier gates', () {
    SavedClipKeeper keeper(TierGates gates, ClipStore clips) => SavedClipKeeper(
      history: InMemoryHistoryStore(),
      clips: clips,
      posters: InMemoryPosterFrameStore(),
      gates: gates,
    );

    test('Pro keeps the clip on the device', () async {
      final clips = InMemoryClipStore(onSave: (url) async => 'device://$url');
      final entry = _entry('come');

      final kept = await keeper(_gates(_pro), clips).keepClip(entry);

      expect(kept.clipLocalKey, isNotNull);
      expect(await clips.source(kept.clipLocalKey!), isNotNull);
    });

    test('Free keeps the word and phrase but not the clip', () async {
      final clips = InMemoryClipStore(onSave: (url) async => 'device://$url');
      final entry = _entry('come');

      final kept = await keeper(_gates(_free), clips).keepClip(entry);

      expect(kept.clipLocalKey, isNull);
      // The source stays, so the lookup replays while online.
      expect(kept.clipUrl, entry.clipUrl);
    });
  });

  group('the device history cap', () {
    test('the Free plan drops the oldest lookups off', () async {
      final store = InMemoryHistoryStore()..planLimit = () async => 2;
      for (var i = 0; i < 4; i++) {
        await store.save(_entry('word$i', age: Duration(minutes: 4 - i)));
      }

      expect((await store.all()).map((entry) => entry.word), <String>[
        'word3',
        'word2',
      ]);
    });

    test('a Pro plan keeps every lookup', () async {
      final store = InMemoryHistoryStore()..planLimit = () async => null;
      for (var i = 0; i < 4; i++) {
        await store.save(_entry('word$i', age: Duration(minutes: 4 - i)));
      }

      expect(await store.all(), hasLength(4));
    });

    test('a plan that cannot be read keeps the store bounded', () async {
      final store = InMemoryHistoryStore(capacity: 2)
        ..planLimit = () async => throw StateError('no plan');

      await store.save(_entry('one'));
      await store.save(_entry('two'));
      await store.save(_entry('three'));

      expect(await store.all(), hasLength(2));
    });
  });

  group('ApiEntitlementProvider', () {
    test('reads the plan and answers from the cache', () async {
      final provider = ApiEntitlementProvider(
        api: MockEntitlementApi(plan: _pro),
      );

      expect((await provider.current()).tier, PlanTier.guest);

      await provider.refresh();

      expect((await provider.current()).tier, PlanTier.pro);
      expect((await provider.current()).lookupsLimit, 50);
    });

    test('a 401 is the signed-out plan', () async {
      final provider = ApiEntitlementProvider(
        api: MockEntitlementApi(
          error: const EntitlementApiException(401, 'Sign in.'),
        ),
      );

      await provider.refresh();

      expect((await provider.current()).signedIn, isFalse);
      expect((await provider.current()).tier, PlanTier.guest);
    });

    test('an unreachable service leaves the last known plan in place', () async {
      final provider = ApiEntitlementProvider(
        api: MockEntitlementApi(plan: _pro),
      );
      await provider.refresh();

      // The service drops; the cached plan stands rather than the reader being
      // blocked (`C-018`).
      final offline = ApiEntitlementProvider(
        api: MockEntitlementApi(
          error: const EntitlementApiException(0, 'offline'),
        ),
        initial: _pro,
      );
      await offline.refresh();

      expect((await offline.current()).tier, PlanTier.pro);
      expect((await provider.current()).tier, PlanTier.pro);
    });

    test('signing out drops the plan to the signed-out one', () async {
      final provider = ApiEntitlementProvider(
        api: MockEntitlementApi(plan: _pro),
      );
      await provider.refresh();

      provider.clear();

      expect((await provider.current()).signedIn, isFalse);
    });
  });
}
