import 'dart:async';

import '../models/clip_notice.dart';
import '../models/history_entry.dart';
import 'clip_notice_inbox.dart';
import 'history_store.dart';
import 'push_registrar.dart';
import 'reported_clip_store.dart';
import 'saved_clip_keeper.dart';

/// The reported clips awaiting their regenerated replacement (`FEAT-011`).
///
/// A report regenerates one clip for the reporting reader, and it reaches them
/// by the clip-ready notice (`C-008`), so the reporter's device registers for
/// that notice and, when it arrives, the regenerated clip replaces the reported
/// one in the reader's history: the reported clip and its poster frame are
/// removed from the device and the regenerated clip takes the entry's place
/// (`FEAT-009`, `FEAT-011`).
///
/// The watch is process-wide rather than owned by the clip view, because the
/// notice arrives whether the reader is still on the clip, elsewhere in Scenova,
/// or outside it; the replacement has to happen either way. Which lookups are
/// awaited is kept on the device, so a notice that opens the app from a
/// notification still finds its reported clip.
class ReportedClipWatch {
  ReportedClipWatch({
    required this.history,
    required this.savedClips,
    required this.store,
    required this.push,
    required ClipNoticeInbox notices,
  }) {
    _subscription = notices.notices.listen(_onNotice);
    unawaited(_load());
  }

  final HistoryStore history;
  final SavedClipKeeper savedClips;
  final ReportedClipStore store;
  final PushRegistrar push;

  late final StreamSubscription<ClipNotice> _subscription;

  /// The lookups reported so far, so a notice for one is read as a regenerated
  /// clip rather than an ordinary clip-ready notice.
  final Set<String> _awaiting = <String>{};

  /// The lookups whose notice this watch has taken up. A lookup stays here for
  /// the session once its notice has arrived, so the clip view defers to the
  /// watch for the whole replacement rather than writing the entry beside it.
  final Set<String> _handling = <String>{};

  bool _loaded = false;
  bool _disposed = false;

  /// Whether this watch is handling [lookupId]'s notice — its reported clip is
  /// awaiting a regenerated one, or the watch has already taken its notice up.
  ///
  /// The clip view consults this so a notice it is already showing does not
  /// write the history entry a second time: the watch owns that replacement.
  bool isAwaiting(String lookupId) =>
      _awaiting.contains(lookupId) || _handling.contains(lookupId);

  /// Records that the reader reported [lookupId]'s clip and registers this
  /// device for the regenerated clip's notice (`C-008`, `FEAT-011`).
  ///
  /// The lookup is recorded before anything is awaited, so a notice that races
  /// the registration is still read as a replacement. The registration does not
  /// raise the notification prompt — the report is a request for a fresh clip,
  /// not for a notification — so a reader who has not allowed notifications is
  /// registered silently and simply does not receive the notice.
  Future<void> watch(String lookupId) async {
    if (_disposed) return;
    _awaiting.add(lookupId);
    await _load();
    await _persist();
    await push.requestClipReadyNotice(lookupId: lookupId, prompt: false);
  }

  /// Replaces the reported clip a notice delivered, and stops awaiting it.
  Future<void> _onNotice(ClipNotice notice) async {
    if (_disposed || !_awaiting.contains(notice.lookupId)) return;
    // Claimed before the first await, so the clip view's own notice handling —
    // which runs after this one — leaves the entry to the watch.
    _handling.add(notice.lookupId);
    try {
      await _replace(notice);
    } finally {
      _awaiting.remove(notice.lookupId);
      await _persist();
    }
  }

  /// Removes the reported clip and its poster from the device and saves the
  /// regenerated clip in the entry's place.
  ///
  /// The entry keeps its word, phrase, and position in the reader's history; an
  /// entry the reader has since removed has nothing to replace and is left
  /// alone.
  Future<void> _replace(ClipNotice notice) async {
    final reported = await _entryFor(notice.lookupId);
    if (reported == null) return;

    final clipKey = reported.clipLocalKey;
    final posterKey = reported.posterLocalKey;
    if (clipKey != null) await savedClips.clips.remove(clipKey);
    if (posterKey != null) await savedClips.posters.remove(posterKey);

    final replaced = HistoryEntry(
      id: reported.id,
      word: reported.word,
      phrase: reported.phrase,
      kind: reported.kind,
      savedAt: reported.savedAt,
      clipUrl: notice.clipUrl,
      hasAudio: notice.hasAudio,
      lookupId: reported.lookupId,
    );
    await history.save(replaced);
    final kept = await savedClips.keepClip(replaced);
    await savedClips.keepPoster(kept);
  }

  /// The saved lookup the reader reported, when it is still in history.
  Future<HistoryEntry?> _entryFor(String lookupId) async {
    final entries = await history.all();
    for (final entry in entries) {
      if (entry.lookupId == lookupId) return entry;
    }
    return null;
  }

  /// Reads the awaited set once, on first use.
  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    Set<String> stored;
    try {
      stored = await store.load();
    } on Object {
      // A set the device cannot read starts empty rather than failing the
      // watch; the reader's next report is still kept.
      stored = <String>{};
    }
    if (_disposed) return;
    _awaiting.addAll(stored);
  }

  Future<void> _persist() async {
    try {
      await store.save(Set<String>.of(_awaiting));
    } on Object {
      // A set the device refuses to write is still held for this session; the
      // replacement must not surface as an unhandled error.
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
  }
}
