import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/clip_notice.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/clip_notice_inbox.dart';
import 'package:scenova/services/clip_notice_source.dart';
import 'package:scenova/services/clip_store.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/poster_frame_store.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/push_registrar.dart';
import 'package:scenova/services/push_tokens.dart';
import 'package:scenova/services/reported_clip_store.dart';
import 'package:scenova/services/reported_clip_watch.dart';
import 'package:scenova/services/saved_clip_keeper.dart';

import 'support/harness.dart';

/// A saved lookup whose clip the reader reported, with the service lookup it was
/// saved from so a regenerated clip can be matched back to it.
HistoryEntry _reported({String lookupId = 'lk_1'}) {
  return HistoryEntry(
    id: 'lk_1-1',
    word: 'come',
    phrase: 'to move towards someone or something',
    kind: LookupKind.word,
    savedAt: DateTime(2026, 1, 1),
    clipUrl: 'https://cdn.scenova.test/reported.mp4',
    clipLocalKey: 'reported-clip',
    posterLocalKey: 'reported-poster',
    lookupId: lookupId,
  );
}

ClipNotice _regenerated({String lookupId = 'lk_1'}) => ClipNotice(
  lookupId: lookupId,
  clipUrl: 'https://cdn.scenova.test/regenerated.mp4',
  durationSeconds: 4,
  resolution: '360p',
  hasAudio: false,
);

/// A watch with its collaborators, so a test drives a notice by hand.
class _Rig {
  _Rig({
    required this.watch,
    required this.source,
    required this.pushApi,
    required this.history,
    required this.clipStore,
    required this.posterStore,
    required this.store,
  });

  final ReportedClipWatch watch;
  final ScriptedClipNoticeSource source;
  final MockPushRegistrationApi pushApi;
  final InMemoryHistoryStore history;
  final InMemoryClipStore clipStore;
  final InMemoryPosterFrameStore posterStore;
  final InMemoryReportedClipStore store;
}

Future<_Rig> _rig({
  List<HistoryEntry> seed = const <HistoryEntry>[],
  Map<String, String> keptClips = const <String, String>{},
  Map<String, Uint8List> keptPosters = const <String, Uint8List>{},
  Set<String> awaiting = const <String>{},
}) async {
  final connectivity = ManualConnectivity();
  final source = ScriptedClipNoticeSource();
  final inbox = ClipNoticeInbox(source: source);
  final pushApi = MockPushRegistrationApi();
  final push = PushRegistrar(
    api: pushApi,
    tokens: ScriptedPushTokenProvider(const PushTokenIssued('token-1')),
    connectivity: connectivity,
  );
  final history = InMemoryHistoryStore(seed: seed);
  final clipStore = InMemoryClipStore(
    seed: keptClips,
    // The device keeps the regenerated clip under the entry's own key.
    onSave: (url) async => 'device://$url',
  );
  final posterStore = InMemoryPosterFrameStore(
    seed: keptPosters,
    onCapture: (_) async => testPosterFrame(),
  );
  final store = InMemoryReportedClipStore(seed: awaiting);
  final watch = ReportedClipWatch(
    history: history,
    savedClips: SavedClipKeeper(
      history: history,
      clips: clipStore,
      posters: posterStore,
    ),
    store: store,
    push: push,
    notices: inbox,
  );
  addTearDown(() {
    watch.dispose();
    push.dispose();
    inbox.dispose();
    connectivity.dispose();
  });
  return _Rig(
    watch: watch,
    source: source,
    pushApi: pushApi,
    history: history,
    clipStore: clipStore,
    posterStore: posterStore,
    store: store,
  );
}

void main() {
  test(
    'a reported clip registers the device for its regenerated notice',
    () async {
      final rig = await _rig(seed: <HistoryEntry>[_reported()]);

      await rig.watch.watch('lk_1');

      expect(rig.watch.isAwaiting('lk_1'), isTrue);
      expect(rig.pushApi.lookupIds, <String>['lk_1']);
      expect(rig.pushApi.tokens, <String>['token-1']);
    },
  );

  test('the regenerated clip replaces the reported one in history', () async {
    final rig = await _rig(
      seed: <HistoryEntry>[_reported()],
      keptClips: <String, String>{'reported-clip': 'device://reported.mp4'},
      keptPosters: <String, Uint8List>{'reported-poster': testPosterFrame()},
    );
    await rig.watch.watch('lk_1');

    rig.source.deliver(_regenerated());
    await pumpEventQueue();

    final entry = (await rig.history.all()).single;
    // The entry keeps its word, phrase, and place; only its clip changes.
    expect(entry.id, 'lk_1-1');
    expect(entry.word, 'come');
    expect(entry.phrase, 'to move towards someone or something');
    expect(entry.clipUrl, 'https://cdn.scenova.test/regenerated.mp4');
    // The reported clip and its poster left the device.
    expect(await rig.clipStore.source('reported-clip'), isNull);
    expect(await rig.posterStore.frame('reported-poster'), isNull);
    // The regenerated clip is kept, with a poster derived from it.
    expect(
      await rig.clipStore.source('lk_1-1'),
      'device://https://cdn.scenova.test/regenerated.mp4',
    );
    expect(await rig.posterStore.frame('lk_1-1'), isNotNull);
    // The awaited record is cleared once the clip has been replaced, so a
    // relaunch does not look for it again.
    expect(await rig.store.load(), isNot(contains('lk_1')));
  });

  test(
    'a notice for a lookup the reader did not report is left alone',
    () async {
      final rig = await _rig(
        seed: <HistoryEntry>[_reported()],
        keptClips: <String, String>{'reported-clip': 'device://reported.mp4'},
      );

      rig.source.deliver(_regenerated(lookupId: 'lk_other'));
      await pumpEventQueue();

      final entry = (await rig.history.all()).single;
      expect(entry.clipUrl, 'https://cdn.scenova.test/reported.mp4');
      expect(
        await rig.clipStore.source('reported-clip'),
        'device://reported.mp4',
      );
    },
  );

  test('a report made before a relaunch is still replaced', () async {
    // The awaited set is kept on the device, so a notice that opens the app
    // from a notification still finds the reported clip.
    final rig = await _rig(
      seed: <HistoryEntry>[_reported()],
      keptClips: <String, String>{'reported-clip': 'device://reported.mp4'},
      awaiting: <String>{'lk_1'},
    );
    await pumpEventQueue();
    expect(rig.watch.isAwaiting('lk_1'), isTrue);

    rig.source.deliver(_regenerated());
    await pumpEventQueue();

    final entry = (await rig.history.all()).single;
    expect(entry.clipUrl, 'https://cdn.scenova.test/regenerated.mp4');
  });
}
